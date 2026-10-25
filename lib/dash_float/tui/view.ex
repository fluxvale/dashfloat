defmodule DashFloat.TUI.View do
  @moduledoc """
  Pure rendering: `render/2` maps state + frame to `{widget, rect}` tuples.
  Also owns the shared region split used by both rendering and
  `DashFloat.TUI.State`'s scroll arithmetic. See ADR 0002; the status,
  activity, and entry styling are ADR 0006's.
  """

  alias DashFloat.TUI.Selection
  alias DashFloat.TUI.State
  alias DashFloat.TUI.Theme
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Text.Line
  alias ExRatatui.Text.Span
  alias ExRatatui.Widgets.Block
  alias ExRatatui.Widgets.Paragraph
  alias ExRatatui.Widgets.Textarea

  @phases %{
    idle: {"Idle", :status_idle},
    streaming: {"Streaming", :status_busy},
    executing_tool: {"Running tool", :status_tool},
    confirming: {"Confirm", :status_tool}
  }

  # One cell of padding on every side of the chrome (issue #28; ADR 0006
  # amendment): text never hugs a screen edge, and the log rect's width —
  # which IS the wrap width — shrinks with it.
  @margin 1

  @doc """
  Splits `width` x `height` into status (1 row), log (rest), activity
  (1 row while an overlay exists — an active phase or the exit prompt —
  else 0), and input (`2 + input_lines` rows, clamped to a third of the
  frame) — the whole chrome inset by one cell per side.
  """
  @spec regions({integer(), integer()}, integer(), boolean()) :: %{
          status: Rect.t(),
          log: Rect.t(),
          activity: Rect.t(),
          input: Rect.t()
        }
  def regions({width, height}, input_lines, active?)
      when is_integer(width) and is_integer(height) and is_integer(input_lines) and
             is_boolean(active?) do
    area = inset_area(width, height)

    [status, log, activity, input] =
      ExRatatui.Layout.split(area, :vertical, [
        {:length, 1},
        {:min, 0},
        {:length, if(active?, do: 1, else: 0)},
        {:length, input_height(input_lines, area.height)}
      ])

    %{status: status, log: log, activity: activity, input: input}
  end

  @doc """
  The wrap width at a frame width: the log rect's width (same inset as
  `regions/3`), floored at 1 so a degenerate frame wraps at one column
  instead of zero. Everything that measures log text — wrap, re-wrap,
  windowing, selection columns — reads this, never the raw frame width.
  """
  @spec content_width(integer()) :: pos_integer()
  def content_width(frame_width) when is_integer(frame_width),
    do: max(frame_width - 2 * @margin, 1)

  defp inset_area(width, height) do
    %Rect{
      x: @margin,
      y: @margin,
      width: max(width - 2 * @margin, 0),
      height: max(height - 2 * @margin, 0)
    }
  end

  @doc "Input region height: borders plus draft lines, capped at a third of the frame."
  @spec input_height(integer(), integer()) :: pos_integer()
  def input_height(input_lines, height) do
    max_third = max(div(height, 3), 3)

    input_lines
    |> Kernel.+(2)
    |> min(max_third)
    |> max(3)
  end

  @doc "Renders the four regions. Pure; never raises on odd sizes."
  @spec render(State.t(), ExRatatui.Frame.t()) :: [{ExRatatui.widget(), Rect.t()}]
  def render(%State{} = state, %ExRatatui.Frame{width: width, height: height}) do
    # The transient row exists for an active phase OR an armed exit guard
    # (issue #28; ADR 0006 amendment) — even while idle.
    regions = regions({width, height}, State.input_line_count(state), State.overlay?(state))

    [
      {status_widget(state, regions.log.height), regions.status},
      {log_widget(state, regions.log.height), regions.log},
      {activity_widget(state), regions.activity},
      {input_widget(state), regions.input}
    ]
  end

  ## Status bar

  # One left-flowing line, ADR order: cwd, model, context, rate, phase, log
  # position. Token fields are omitted entirely until something streamed.
  defp status_widget(state, log_height) do
    {label, role} = Map.fetch!(@phases, state.phase)

    %Paragraph{
      text: [
        Line.new(
          [Span.new("❯ " <> State.cwd_label(state), style: Theme.style(:dim))] ++
            model_spans(state) ++
            context_spans(state) ++
            rate_spans(state) ++
            phase_spans(label, role) ++ position_spans(state, log_height)
        )
      ]
    }
  end

  defp model_spans(state) do
    [separator(), Span.new(State.provider_label(state) || "—", style: Theme.style(:assistant))]
  end

  defp context_spans(%{stats: %{context_total: 0}}), do: []

  defp context_spans(state) do
    [separator(), Span.new("ctx " <> State.context_label(state), style: Theme.style(:dim))]
  end

  defp rate_spans(state) do
    case State.rate_label(state) do
      nil -> []
      rate -> [separator(), Span.new("#{rate} tok/s", style: Theme.style(:dim))]
    end
  end

  defp phase_spans(label, role) do
    [
      separator(),
      Span.new("● ", style: Theme.style(role)),
      Span.new(label, style: Theme.style(role))
    ]
  end

  defp position_spans(state, log_height) do
    position = position(state, log_height)
    [separator(), Span.new(position, style: Theme.style(:dim))]
  end

  defp separator, do: Span.new(" · ", style: Theme.style(:hint))

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
  # persistence (ADR 0002). Stored rendered lines are sliced; nothing renders
  # here (ADR 0006). A selection highlights its covered columns in reverse
  # video (issue #28; ADR 0006 amendment).
  defp log_widget(%State{entries: [], in_flight: in_flight, in_flight_lines: nil}, _height)
       when in_flight in [nil, ""] do
    %Paragraph{
      text: [Line.new([Span.new("(log is empty — say something)", style: Theme.style(:dim))])],
      scroll: {0, 0}
    }
  end

  defp log_widget(state, height) do
    offset = State.effective_scroll(state, height)

    text =
      state
      |> display_lines(offset, height)
      |> highlight_selection(offset, state)

    %Paragraph{text: text, scroll: {0, 0}}
  end

  defp highlight_selection(rows, _offset, %State{selection: nil}), do: rows

  defp highlight_selection(rows, offset, %State{selection: selection}) do
    Enum.with_index(rows, fn row, i ->
      Selection.highlight(row, Selection.columns(selection, offset + i))
    end)
  end

  @doc """
  The display rows `[offset, offset + height)` of the log's stored wrapped
  lines (entries plus the in-flight block), windowed — the same walk feeds
  the rendered log and the selection copy, so geometry can never disagree.
  """
  @spec display_lines(State.t(), non_neg_integer(), non_neg_integer()) :: [
          ExRatatui.Text.Line.t()
        ]
  def display_lines(%State{} = state, offset, height)
      when is_integer(offset) and is_integer(height) do
    {_skipped, acc} =
      state
      |> blocks()
      |> Enum.reduce_while({0, []}, &take_block(&1, &2, offset, height))

    acc
  end

  defp blocks(%State{in_flight_lines: nil} = state), do: Enum.map(state.entries, & &1.lines)

  defp blocks(%State{in_flight_lines: lines} = state),
    do: Enum.map(state.entries, & &1.lines) ++ [lines]

  defp take_block(lines, {skipped, acc}, offset, height) do
    n = length(lines)

    if skipped + n <= offset do
      {:cont, {skipped + n, acc}}
    else
      taken =
        lines
        |> Enum.drop(max(offset - skipped, 0))
        |> Enum.take(height - length(acc))

      acc = acc ++ taken

      if length(acc) >= height, do: {:halt, {skipped, acc}}, else: {:cont, {skipped + n, acc}}
    end
  end

  ## Activity line

  # The armed exit guard outranks every other activity text while it lives
  # (issue #28) — including mid-stream and mid-confirm.
  defp activity_widget(%State{exit_guard_at: at}) when is_integer(at) do
    %Paragraph{
      text: [
        Line.new([Span.new("Press Ctrl+C again to exit", style: Theme.style(:status_tool))])
      ],
      scroll: {0, 0}
    }
  end

  defp activity_widget(%{phase: :idle}) do
    %Paragraph{text: [], scroll: {0, 0}}
  end

  defp activity_widget(state) do
    %Paragraph{
      text: [
        Line.new([
          Span.new(spinner_frame(state), style: Theme.style(:accent)),
          Span.new(" "),
          Span.new(activity_label(state), style: Theme.style(:accent)),
          Span.new(activity_hint(state), style: Theme.style(:hint))
        ])
      ],
      scroll: {0, 0}
    }
  end

  defp spinner_frame(state) do
    frames = Theme.spinner_frames()
    Enum.at(frames, rem(state.anim_step, length(frames)))
  end

  defp activity_label(%{phase: :confirming}), do: "Approve this change?"
  defp activity_label(%{phase: :executing_tool}), do: "Running tool…"
  defp activity_label(%{stats: %{tokens: 0}}), do: "Thinking…"
  defp activity_label(_state), do: "Streaming…"

  # The confirming decision replaces the interrupt hint (Esc rejects there).
  defp activity_hint(%{phase: :confirming}), do: "  ⏎ approve · esc reject"
  defp activity_hint(_state), do: "  esc interrupt"

  ## Input

  defp input_widget(state) do
    %Textarea{
      state: state.input,
      block: %Block{
        title: Span.new("❯ ", style: Theme.style(:accent)),
        borders: [:all],
        border_type: :rounded,
        border_style: Theme.style(:dim)
      },
      placeholder:
        "ask anything — Enter send · Shift+Enter newline · Esc interrupt · Ctrl+Q quit",
      placeholder_style: Theme.style(:dim),
      wrap_mode: :word_or_glyph
    }
  end
end
