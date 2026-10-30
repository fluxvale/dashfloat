defmodule DashFloat.TUI.View do
  @moduledoc """
  Pure rendering: `render/2` maps state + frame to `{widget, rect}` tuples.
  Also owns the shared region split used by both rendering and
  `DashFloat.TUI.State`'s scroll arithmetic. See ADR 0002; the status,
  activity, and entry styling are ADR 0006's.
  """

  alias DashFloat.Config.Onboarding
  alias DashFloat.Mode
  alias DashFloat.TUI.Palette
  alias DashFloat.TUI.Selection
  alias DashFloat.TUI.State
  alias DashFloat.TUI.Theme
  alias DashFloat.TUI.Wrap
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Style
  alias ExRatatui.Text.Line
  alias ExRatatui.Text.Span
  alias ExRatatui.Widgets.Block
  alias ExRatatui.Widgets.Paragraph
  alias ExRatatui.Widgets.Popup
  alias ExRatatui.Widgets.SlashCommands
  alias ExRatatui.Widgets.Textarea

  @phases %{
    idle: {"Idle", :status_idle},
    streaming: {"Streaming", :status_busy},
    executing_tool: {"Running tool", :status_tool},
    checking: {"Checking", :status_tool},
    confirming: {"Confirm", :status_tool}
  }

  # The mode span's role (ADR 0016 §8) — display truth, kept local to the
  # view; the label text comes from Mode.label/1.
  @mode_roles %{
    plan: :status_idle,
    build: :assistant,
    auto: :status_tool,
    unchained: :error
  }

  # Two cells of padding on every side of the chrome (issues #28 and #108;
  # ADR 0006 amendment): text never hugs a screen edge, and the log rect's
  # width — which IS the wrap width — shrinks with it.
  @margin 2

  # The composer's placeholder, shown ONLY before the session's first
  # exchange (ADR 0015 §3, amended #91). The key map lives in /help.
  @input_hint "ask anything"

  # The attach prompt's one activity line (ADR 0018 §5): label, draft, and
  # the dim key hints.
  @attach_label "Attach image: "
  @attach_hint "  ⏎ attach · tab complete · esc keep · ^o close · ^d clear"

  @doc """
  Splits `width` x `height` into status (1 row), log (rest), activity
  (1 row while an overlay exists — an active phase, the exit prompt, or the
  open attach prompt — else 0), input (`2 + input_lines` rows, clamped to a
  third of the frame), and the permanent stats footer (1 row, ADR 0015) —
  the whole chrome inset by two cells per side.
  """
  @spec regions({integer(), integer()}, integer(), boolean()) :: %{
          status: Rect.t(),
          log: Rect.t(),
          activity: Rect.t(),
          input: Rect.t(),
          footer: Rect.t()
        }
  def regions({width, height}, input_lines, active?)
      when is_integer(width) and is_integer(height) and is_integer(input_lines) and
             is_boolean(active?) do
    area = inset_area(width, height)

    [status, log, activity, input, footer] =
      ExRatatui.Layout.split(area, :vertical, [
        {:length, 1},
        {:min, 0},
        {:length, if(active?, do: 1, else: 0)},
        {:length, input_height(input_lines, area.height)},
        {:length, 1}
      ])

    %{status: status, log: log, activity: activity, input: input, footer: footer}
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

  @doc """
  Renders the five regions — status, log, activity, input, and the stats
  footer — plus any open command palette on top (ADR 0020), or, while the
  startup phase owns the screen, the one setup box instead (ADR 0009). Pure;
  never raises on odd sizes.
  """
  @spec render(State.t(), ExRatatui.Frame.t()) :: [{ExRatatui.widget(), Rect.t()}]
  def render(%State{setup: setup} = _state, %ExRatatui.Frame{width: width, height: height})
      when setup != nil do
    # The startup phase (ADR 0009) replaces the chat UI with one setup box:
    # the forced-selection modal or the onboarding wizard.
    [{setup_widget(setup, width), inset_area(width, height)}]
  end

  def render(%State{} = state, %ExRatatui.Frame{width: width, height: height}) do
    # The transient row exists for an active phase OR an armed exit guard
    # (issue #28; ADR 0006 amendment) — even while idle.
    regions = regions({width, height}, State.input_line_count(state), State.overlay?(state))

    [
      {status_widget(state, regions.log.height), regions.status},
      {log_widget(state, regions.log.height), regions.log},
      {activity_widget(state), regions.activity},
      {input_widget(state), regions.input},
      {footer_widget(state), regions.footer}
    ] ++ palette_widgets(state, inset_area(width, height))
  end

  ## Setup screens (ADR 0009: forced selection + onboarding wizard)

  # wizard_lines/2 takes the frame width: a refused write's message wraps to
  # the box so its remedy is never clipped (issue #39).

  defp wizard_lines(%{step: :welcome}, _width) do
    [
      {"Welcome to DashFloat.", :assistant},
      {"Set up your first profile — every step is skippable.", :dim},
      blank(),
      hint("⏎ begin · ctrl+q quit")
    ]
  end

  defp wizard_lines(%{step: :profile_name, draft: draft}, _width) do
    [
      {"Name your first profile — it becomes the default.", :assistant},
      blank(),
      input_line(draft, false),
      hint("⏎ accept · backspace edit · esc back")
    ]
  end

  defp wizard_lines(%{step: :provider} = wizard, _width) do
    [
      {"Add a provider.", :assistant},
      blank() | option_lines(wizard, &provider_option/2)
    ] ++ [blank(), hint("↑↓ move · ⏎ choose · esc back")]
  end

  defp wizard_lines(%{step: :custom_url, draft: draft}, _width) do
    [
      {"The provider's base URL (OpenAI-compatible).", :assistant},
      blank(),
      input_line(draft, false),
      hint("⏎ accept · esc back")
    ]
  end

  defp wizard_lines(%{step: :label, draft: draft}, _width) do
    [
      {"Label this provider (optional — defaults to the URL host).", :assistant},
      blank(),
      input_line(draft, false),
      hint("⏎ accept · esc back")
    ]
  end

  # No refused write pending: Enter's promise is the immediate 0600 write.

  defp wizard_lines(%{step: :key, draft: draft, error: nil}, _width) do
    [
      {"The API key: paste it, type $ENV_VAR to use a reference,", :assistant},
      {"or leave it empty to skip.", :assistant},
      blank(),
      input_line(draft, true),
      hint("⏎ accept · written to keys.json5 (0600) immediately · esc back")
    ]
  end

  # A refused write pending: the hint matches file state — nothing was
  # written, and the screen says so instead of repeating the promise
  # (issue #39's hint contract). The remedy lives in the error text — for a
  # pre-existing-value or unparseable-file refusal it is NOT the typed key,
  # so the hint stays generic instead of promising that fixing the draft
  # fixes the write (issue #42).

  defp wizard_lines(%{step: :key, draft: draft, error: error}, width) do
    [
      {"The API key: paste it, type $ENV_VAR to use a reference,", :assistant},
      {"or leave it empty to skip.", :assistant},
      blank(),
      input_line(draft, true)
    ] ++
      error_lines(error, width) ++
      [blank(), hint("apply the remedy · ⏎ retries the write")]
  end

  defp wizard_lines(%{step: :fetching}, _width) do
    [
      {"Fetching models…", :assistant},
      blank(),
      hint("esc type it manually instead")
    ]
  end

  defp wizard_lines(%{step: :model_pick} = wizard, _width) do
    [
      {"Pick a model.", :assistant},
      blank() | option_lines(wizard, &model_pick_option/2)
    ] ++ [blank(), hint("↑↓ move · ⏎ choose · esc back")]
  end

  # Manual entry is the explicit fallback (issue #64): a failed fetch lands
  # here with its reason as a dim note between the title and the input —
  # informational, never styled as an error.

  defp wizard_lines(%{step: :model_manual, draft: draft, note: nil}, _width) do
    [
      {"The model id.", :assistant},
      blank(),
      input_line(draft, false),
      hint("⏎ accept · empty skips · nickname defaults to the id · esc back")
    ]
  end

  defp wizard_lines(%{step: :model_manual, draft: draft, note: note}, width) do
    [
      {"The model id.", :assistant}
      | note_lines(note, width)
    ] ++
      [blank(), input_line(draft, false)] ++
      [hint("⏎ accept · empty skips · nickname defaults to the id · esc back")]
  end

  defp wizard_lines(%{step: :loop, error: nil} = wizard, _width) do
    [
      {"Anything else? The profile works as-is.", :assistant},
      blank() | option_lines(wizard, &loop_option/2)
    ] ++ [blank(), hint("↑↓ move · ⏎ choose · esc back")]
  end

  # A refused settings write lands here: the remedy is on screen, and picking
  # done again retries the write in place (issue #39).

  defp wizard_lines(%{step: :loop, error: error} = wizard, width) do
    [
      {"Anything else? The profile works as-is.", :assistant},
      blank() | error_lines(error, width)
    ] ++
      [blank() | option_lines(wizard, &loop_option/2)] ++
      [blank(), hint("apply the remedy · ⏎ on done retries the write · esc back")]
  end

  defp wizard_lines(%{step: :mcp_name, draft: draft}, _width) do
    [
      {"MCP server name.", :assistant},
      blank(),
      input_line(draft, false),
      hint("⏎ accept · empty skips · esc back")
    ]
  end

  defp wizard_lines(%{step: :mcp_command, draft: draft}, _width) do
    [
      {"MCP command (e.g. uvx).", :assistant},
      blank(),
      input_line(draft, false),
      hint("⏎ accept · empty cancels · esc back")
    ]
  end

  defp wizard_lines(%{step: :mcp_args, draft: draft}, _width) do
    [
      {"MCP arguments (space-separated, optional).", :assistant},
      blank(),
      input_line(draft, false),
      hint("⏎ accept · esc back")
    ]
  end

  defp wizard_lines(%{step: :mcp_token, draft: draft}, _width) do
    [
      {"Token environment variable (optional).", :assistant},
      blank(),
      input_line(draft, true),
      hint("stored as $VAR — the value never lands in a file · esc back")
    ]
  end

  defp wizard_lines(%{step: :done}, _width) do
    [
      {"All set — config written.", :assistant},
      {"DashFloat is starting under your new profile.", :dim},
      blank(),
      hint("⏎ continue")
    ]
  end

  # A typing line: the draft (masked for secrets) with a block cursor.

  defp setup_widget({:select, names, index}, _width) do
    setup_box(
      "DashFloat — select a profile",
      [
        {"Which profile should DashFloat start?", :assistant},
        blank()
        | Enum.with_index(names, fn name, i -> {:option, i == index, name} end)
      ] ++ [blank(), hint("↑↓ move · ⏎ start · ctrl+q quit")]
    )
  end

  defp setup_widget(%Onboarding{} = wizard, width),
    do: setup_box("DashFloat — first run", wizard_lines(wizard, width))

  defp setup_box(title, lines) do
    %Paragraph{
      text: Enum.map(lines, &setup_line/1),
      block: %Block{
        title: Span.new(" #{title} ", style: Theme.style(:accent)),
        borders: [:all],
        border_type: :rounded,
        border_style: Theme.style(:dim)
      },
      scroll: {0, 0}
    }
  end

  # One line per wizard step — plain conversational copy, Octofriend-style,
  # with the current input line masked when it is a secret (ADR 0009).

  defp provider_option(_wizard, {:preset, preset}),
    do: "#{preset.name} — #{preset.base_url}"

  defp provider_option(_wizard, :custom),
    do: "Custom OpenAI-compatible URL…"

  defp provider_option(_wizard, :skip),
    do: "Skip — configure later"

  defp model_pick_option(_wizard, {:model, id}), do: id

  defp model_pick_option(_wizard, :manual), do: "Type a model id"

  defp loop_option(_wizard, :add_provider), do: "Add another provider"

  defp loop_option(_wizard, :add_mcp), do: "Add an MCP server"

  defp loop_option(_wizard, :done), do: "Done — write the config and start"

  defp input_line(draft, masked) do
    shown = if masked, do: String.duplicate("*", String.length(draft)), else: draft
    {"❯ " <> shown <> "█", :assistant}
  end

  # A selection list: the wizard's options with the chosen one highlighted.

  defp option_lines(wizard, label) do
    wizard
    |> Onboarding.options()
    |> Enum.with_index(fn option, index ->
      {:option, index == wizard.choice, label.(wizard, option)}
    end)
  end

  defp blank, do: {"", :dim}

  defp hint(text), do: {text, :hint}

  # A refused write's message (issue #39): error and remedy, word-wrapped to
  # the setup box's inner width (frame minus margin and borders) so the
  # remedy is never clipped — floored at 1 for degenerate frames, never above
  # the true inner width. The log view's wrapper supplies the semantics
  # (ADR 0009's never-clipped remedy): word wrap with a glyph-boundary
  # fallback for tokens wider than the row — paths in remedies — so nothing
  # is silently clipped mid-token (issue #42).
  defp error_lines(message, width) do
    message
    |> wrap_remedy(max(width - 2 * @margin - 2, 1))
    |> Enum.map(&{&1, :error})
  end

  # The manual-fallback note (issue #64): the fetch's failure reason, word-
  # wrapped like a refusal but in the dim style — informational, not an
  # error.
  defp note_lines(message, width) do
    message
    |> wrap_remedy(max(width - 2 * @margin - 2, 1))
    |> Enum.map(&{&1, :dim})
  end

  defp wrap_remedy(text, width) do
    [Line.new([Span.new(text)])]
    |> Wrap.wrap(width)
    |> Enum.map(fn %Line{spans: spans} -> Enum.map_join(spans, & &1.content) end)
  end

  defp setup_line({:option, true, text}),
    do: Line.new([Span.new("❯ " <> text, style: Theme.style(:accent))])

  defp setup_line({:option, false, text}),
    do: Line.new([Span.new("  " <> text, style: Theme.style(:dim))])

  defp setup_line({text, role}), do: Line.new([Span.new(text, style: Theme.style(role))])

  ## Status bar

  # One left-flowing line: mode, phase, log position — non-empty groups
  # joined with a separator BETWEEN them, so a fresh session opens with the
  # phase dot, never a dangling leading separator. cwd, model, and rate
  # moved to the stats footer (ADR 0015 §2), and ctx followed them in stage
  # 2 (ADR 0015 §2 amendment) — moved, not duplicated.
  # The mode span leads (ADR 0016 §7): it is session state, always shown.
  defp status_widget(state, log_height) do
    {label, role} = Map.fetch!(@phases, state.phase)

    spans =
      [
        mode_spans(state),
        phase_spans(label, role),
        position_spans(state, log_height)
      ]
      |> Enum.reject(&(&1 == []))
      |> Enum.intersperse([separator()])
      |> List.flatten()

    %Paragraph{text: [Line.new(spans)]}
  end

  # The stats footer under the composer (ADR 0015 §2): cwd, model, live
  # tok/s in the old status-bar span vocabulary, plus the stage-2
  # tokens-used + percent-of-context span (ADR 0015 §2 amendment). Static
  # data read at render time — live while streaming because the tick
  # recomputes the rate; the rate and context spans are omitted entirely
  # until one exists.
  defp footer_widget(state) do
    context_spans =
      case State.context_label(state) do
        nil -> []
        label -> [separator(), Span.new(label, style: Theme.style(:dim))]
      end

    rate_spans =
      case State.rate_label(state) do
        nil -> []
        rate -> [separator(), Span.new("#{rate} tok/s", style: Theme.style(:dim))]
      end

    %Paragraph{
      text: [
        Line.new(
          [Span.new("❯ " <> State.cwd_label(state), style: Theme.style(:dim))] ++
            [
              separator(),
              Span.new(State.provider_label(state) || "—", style: Theme.style(:assistant))
            ] ++ images_spans(state) ++ context_spans ++ rate_spans
        )
      ]
    }
  end

  # The capability glyph (ADR 0018 §1): 📎 beside the model label while the
  # selected model accepts images — visible before any attach attempt.
  defp images_spans(%State{} = state) do
    if State.provider_images?(state),
      do: [Span.new(" 📎", style: Theme.style(:dim))],
      else: []
  end

  # The mode group is bare — the bar intersperses separators between groups
  # (ADR 0016 §7): always present, so the bar opens with the mode label.
  defp mode_spans(state) do
    role = Map.fetch!(@mode_roles, state.mode)
    label = Mode.label(state.mode)

    [Span.new(label, style: Theme.style(role))]
  end

  defp phase_spans(label, role) do
    [
      Span.new("● ", style: Theme.style(role)),
      Span.new(label, style: Theme.style(role))
    ]
  end

  defp position_spans(state, log_height) do
    position = position(state, log_height)
    [Span.new(position, style: Theme.style(:dim))]
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

  # A collapsed selection (press without extension yet) highlights
  # nothing: a single reversed cell under the pointer reads as a cursor
  # artifact, not a selection (review cosmetic).
  defp highlight_selection(rows, _offset, %State{selection: %{anchor: cell, head: cell}}),
    do: rows

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

  # The open attach prompt (ADR 0018 §5) replaces the phase labels — one
  # line like the exit guard: accent label, the draft with the composer's
  # block cursor, and the dim key hints. The DRAFT owns the row (§4's
  # "fix the path and retry" UX — the path being edited is the payload):
  # the hints show only when everything fits beside them, and when they
  # drop the draft's TAIL extends into the freed space, `…` marking the
  # clipped head (completion and editing work at the end).
  defp activity_widget(%State{attach: %{draft: draft}} = state) do
    width = content_width(elem(state.size, 0))
    {draft_shown, hint} = attach_layout(draft, width, String.length(@attach_label))

    %Paragraph{
      text: [
        Line.new(
          [
            Span.new(@attach_label, style: Theme.style(:accent)),
            Span.new(draft_shown <> "█", style: Theme.style(:assistant))
          ] ++ hint_spans(hint)
        )
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

  # Everything fits — the full draft plus the hints. Anything else drops
  # the hints and tail-shows the draft into the whole remaining row.
  defp attach_layout(draft, width, label_len) do
    if label_len + String.length(draft) + 1 + String.length(@attach_hint) <= width do
      {draft, @attach_hint}
    else
      budget = max(width - label_len - 1, 1)

      shown =
        if String.length(draft) >= budget,
          do: "…" <> String.slice(draft, String.length(draft) - budget + 1, budget),
          else: draft

      {shown, ""}
    end
  end

  defp hint_spans(""), do: []

  defp hint_spans(hint),
    do: [Span.new(hint, style: Theme.style(:hint))]

  defp spinner_frame(state) do
    frames = Theme.spinner_frames()
    Enum.at(frames, rem(state.anim_step, length(frames)))
  end

  defp activity_label(%{phase: :confirming}), do: "Approve this change?"
  defp activity_label(%{phase: :executing_tool}), do: "Running tool…"
  defp activity_label(%{phase: :checking}), do: "Checking…"
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
        title: input_title(state),
        borders: [:all],
        border_type: :rounded,
        border_style: Theme.style(:dim)
      },
      # The ghost (ADR 0015 §3) rides the placeholder slot in the existing
      # placeholder styling; the textarea only shows a placeholder while the
      # draft is empty, which is the display gate. Past the session's first
      # exchange an empty composer shows NOTHING (#91: a mid-session hint
      # reads as patronizing) — until then, the short neutral hint.
      placeholder: placeholder(state),
      placeholder_style: Theme.style(:dim),
      wrap_mode: :word_or_glyph,
      cursor_style: cursor_style(state)
    }
  end

  # The placeholder precedence (#91): a landed ghost IS the placeholder,
  # wherever the session stands; otherwise the short hint shows only while
  # the session has no entries yet — the first prompt, a command's output,
  # or a resume note all make it underway, and then: no placeholder at all.
  defp placeholder(%State{suggestion: suggestion}) when suggestion != nil, do: suggestion
  defp placeholder(%State{entries: []}), do: @input_hint
  defp placeholder(%State{}), do: nil

  # The composer's title (ADR 0018 §5): pending attachments ride the title
  # as a count — the one chip the composer shows for them.
  defp input_title(%State{attachments: []}),
    do: Span.new("❯ ", style: Theme.style(:accent))

  defp input_title(%State{attachments: attachments}),
    do: Span.new("❯ 📎 #{length(attachments)}", style: Theme.style(:accent))

  # The composer's cursor artifact (ADR 0015 §1): absent while the pane is
  # unfocused, static bright reversed while idle (zero timers — ADR 0006's
  # idle discipline stands), and a 500 ms on/off blink in active phases riding
  # the existing 125 ms tick — 4 anim_steps on, 4 off at the 8 Hz budget.
  defp cursor_style(%State{focused?: false}), do: %Style{}
  defp cursor_style(%State{phase: :idle}), do: Theme.style(:cursor)

  defp cursor_style(%State{anim_step: step}) do
    if rem(div(step, 4), 2) == 0, do: Theme.style(:cursor), else: %Style{}
  end

  ## Command palette (ADR 0020)

  # The palette renders last — on top of every region. A filter popup is the
  # composer's derived state and additionally gates on idle.
  defp palette_widgets(%State{palette: %Palette{mode: :filter}, phase: phase}, _area)
       when phase != :idle,
       do: []

  defp palette_widgets(%State{palette: nil}, _area), do: []

  defp palette_widgets(%State{} = state, area), do: render_palette(state, area)

  # The command lists — autocomplete and Ctrl+P alike, "the same list" — go
  # through the widget's renderer; the model and profile pickers build
  # Popup + List with custom labels. Styles are Theme roles only (ADR 0006).
  defp render_palette(
         %State{palette: %Palette{kind: :commands, items: items, selected: selected}},
         area
       ) do
    SlashCommands.render_autocomplete(items,
      area: area,
      selected: selected,
      highlight_style: Theme.style(:accent),
      style: Theme.style(:dim)
    )
  end

  # "id (context detail) · current" — the marker only on the provider's
  # current model, the detail only when the catalog carries a context.
  defp render_palette(
         %State{
           palette: %Palette{kind: :models, items: entries, selected: selected},
           provider: {:ok, config}
         },
         area
       ) do
    items = Enum.map(entries, &model_item(&1.model, &1.context, config.model))
    [picker("Models", items, selected, area)]
  end

  defp render_palette(
         %State{palette: %Palette{kind: :profiles, items: names, selected: selected}},
         area
       ) do
    [picker("Profiles", names, selected, area)]
  end

  # The detail rides the status bar's own humanize ladder (999 reads "999",
  # not "0k"); the marker only on the provider's current model.
  defp model_item(id, context, current) do
    detail = if is_integer(context), do: " (#{State.humanize(context)})", else: ""
    marker = if id == current, do: " · current", else: ""

    id <> detail <> marker
  end

  defp picker(title, items, selected, area) do
    {%Popup{
       content: %ExRatatui.Widgets.List{
         items: items,
         selected: selected,
         highlight_style: Theme.style(:accent),
         style: Theme.style(:dim),
         block: %Block{
           title: Span.new(" #{title} ", style: Theme.style(:accent)),
           borders: [:all],
           border_type: :rounded,
           border_style: Theme.style(:dim)
         }
       },
       percent_width: 50,
       percent_height: 40
     }, area}
  end
end
