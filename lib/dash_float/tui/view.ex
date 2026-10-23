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

    case ExRatatui.Layout.split(area, :vertical, [
           {:length, 1},
           {:min, 0},
           {:length, input_height(input_lines, height)}
         ]) do
      [status, log, input] -> %{status: status, log: log, input: input}
      {:error, reason} -> raise ArgumentError, "layout failed: #{inspect(reason)}"
    end
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

      true ->
        top = State.effective_scroll(state, log_height) + 1
        bottom = min(top + log_height - 1, total)
        "L#{top}-#{bottom}/#{total}"
    end
  end

  ## Log

  defp log_widget(state, height) do
    %Paragraph{
      text: log_lines(state),
      scroll: {State.effective_scroll(state, height), 0}
    }
  end

  defp log_lines(%State{entries: [], in_flight: in_flight}) when in_flight in [nil, ""] do
    [Line.new([Span.new("(log is empty — say something)", style: %Style{fg: :dark_gray})])]
  end

  defp log_lines(state) do
    state.entries
    |> Enum.map(&entry_lines/1)
    |> append_in_flight(state)
    |> List.flatten()
  end

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

  defp append_in_flight(lines, %{in_flight: in_flight}) when in_flight in [nil, ""], do: lines

  defp append_in_flight(lines, %{in_flight: in_flight}),
    do: lines ++ entry_lines({:assistant, in_flight})

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
