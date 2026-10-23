defmodule DashFloat.TUI.View do
  @moduledoc """
  Pure rendering: `render/2` maps state + frame to `{widget, rect}` tuples.
  Also owns the shared region split used by both rendering and
  `DashFloat.TUI.State`'s scroll arithmetic. See ADR 0002.
  """

  alias DashFloat.TUI.State
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Style
  alias ExRatatui.Text.{Line, Span}
  alias ExRatatui.Widgets.{Block, Paragraph, Textarea}

  @phases %{
    idle: {"Idle", :dark_gray},
    streaming: {"Streaming", :yellow},
    executing_tool: {"Executing Tool", :cyan}
  }

  @doc """
  Splits `width` x `height` into status (1 row), log (rest), and input
  (`2 + input_lines` rows, clamped to a third of the frame).
  """
  def regions({width, height}, input_lines)
      when is_integer(width) and is_integer(height) and is_integer(input_lines) do
    area = %Rect{x: 0, y: 0, width: max(width, 0), height: max(height, 0)}

    [status, log, input] =
      ExRatatui.Layout.split(area, :vertical, [
        {:length, 1},
        {:min, 0},
        {:length, input_height(input_lines, height)}
      ])

    %{status: status, log: log, input: input}
  end

  @doc "Input region height: borders plus draft lines, capped at a third of the frame."
  def input_height(input_lines, height) do
    max_third = max(div(height, 3), 3)
    input_lines |> Kernel.+(2) |> min(max_third) |> max(3)
  end

  @doc "Renders the three regions. Pure; never raises on odd sizes."
  def render(%State{} = state, %ExRatatui.Frame{width: width, height: height}) do
    regions = regions({width, height}, State.input_line_count(state))

    [
      {status_widget(state, regions.log.height), regions.status},
      {log_widget(state, regions.log.height), regions.log},
      {input_widget(state), regions.input}
    ]
  end

  ## Status bar

  defp status_widget(state, log_height) do
    {label, color} = Map.fetch!(@phases, state.phase)

    %Paragraph{
      text: [
        Line.new([
          Span.new("DashFloat", style: %Style{modifiers: [:bold]}),
          Span.new("  model: —  ctx: —", style: %Style{fg: :dark_gray}),
          Span.new("  ● ", style: %Style{fg: color}),
          Span.new(label, style: %Style{fg: color}),
          Span.new("  #{position(state, log_height)}", style: %Style{fg: :dark_gray})
        ])
      ]
    }
  end

  defp position(state, log_height) do
    total = State.log_line_count(state)

    cond do
      total == 0 ->
        "log empty"

      state.follow? ->
        "follow L#{total}"

      log_height <= 0 ->
        "L#{min(State.effective_scroll(state, log_height) + 1, total)}/#{total}"

      true ->
        top = State.effective_scroll(state, log_height) + 1
        bottom = min(top + log_height - 1, total)
        "L#{top}-#{bottom}/#{total}"
    end
  end

  ## Log

  # Only the visible window is built and encoded per frame: per-frame cost is
  # O(viewport), not O(total log) — the full log stays in memory until Phase 4
  # persistence (ADR 0002).
  defp log_widget(state, height) do
    %Paragraph{
      text: log_lines(state, State.effective_scroll(state, height), height),
      scroll: {0, 0}
    }
  end

  defp log_lines(%State{entries: [], in_flight: in_flight}, _offset, _height)
       when in_flight in [nil, ""] do
    [Line.new([Span.new("(log is empty — say something)", style: %Style{fg: :dark_gray})])]
  end

  defp log_lines(state, offset, height) do
    pairs =
      case state.in_flight do
        in_flight when in_flight in [nil, ""] -> state.entries
        in_flight -> state.entries ++ [{:assistant, in_flight}]
      end

    # Walk entries counting display lines; build Lines only for entries that
    # intersect [offset, offset + height).
    {_, acc} =
      Enum.reduce_while(pairs, {0, []}, fn {_kind, text} = pair, {skipped, acc} ->
        n = line_count(text)

        if skipped + n <= offset do
          {:cont, {skipped + n, acc}}
        else
          take_window(pair, skipped, n, acc, offset, height)
        end
      end)

    acc
  end

  # Windowing step of log_lines/3: build Lines for the first entry that
  # intersects [offset, offset + height) and report whether the walk is done.
  defp take_window(pair, skipped, n, acc, offset, height) do
    taken =
      pair
      |> entry_lines()
      |> Enum.drop(max(offset - skipped, 0))
      |> Enum.take(height - length(acc))

    acc = acc ++ taken

    if length(acc) >= height do
      {:halt, {skipped, acc}}
    else
      {:cont, {skipped + n, acc}}
    end
  end

  defp line_count(text), do: length(:binary.matches(text, "\n")) + 1

  defp entry_lines({:user, text}) do
    text
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.map(fn
      {line, 1} -> Line.new([Span.new("❯ ", style: %Style{modifiers: [:bold]}), Span.new(line)])
      {line, _} -> Line.new([Span.new("  " <> line)])
    end)
  end

  defp entry_lines({kind, text}) when kind in [:tool, :system] do
    text
    |> String.split("\n")
    |> Enum.map(&Line.new([Span.new(&1, style: %Style{fg: :dark_gray})]))
  end

  defp entry_lines({:assistant, text}) do
    text |> String.split("\n") |> Enum.map(&Line.new([Span.new(&1)]))
  end

  ## Input

  defp input_widget(state) do
    %Textarea{
      state: state.input,
      block: %Block{
        title: "Input",
        borders: [:all],
        border_type: :rounded
      },
      placeholder:
        "ask anything — Enter send · Shift+Enter newline · PgUp/PgDn scroll · Ctrl+Q quit",
      placeholder_style: %Style{fg: :dark_gray}
    }
  end
end
