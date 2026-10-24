defmodule DashFloat.TUI.State do
  @moduledoc """
  Pure UI state and every state transition for `DashFloat.TUI`.

  All logic here is deterministic: no processes, no terminal, no timers (the
  one side-effecting exception is `claim_agent/1`, called from the TUI process
  at mount so the monitor lives there). The input draft lives in the
  textarea's Rust-side state, reached through its synchronous in-memory API.
  Transitions return `{state, action}` where `action` is `:quit`,
  `{:submit, prompt}`, `{:confirm, decision}`, `:cancel`, or `nil`; the TUI
  interprets actions. The one clock is injectable (`now` arguments, defaulting
  to the monotonic clock) so the animation tick and rate math stay pure.
  See ADRs 0002, 0006, and 0007.
  """

  alias DashFloat.TUI.Render
  alias DashFloat.TUI.View
  alias DashFloat.TUI.Wrap

  @type phase :: :idle | :streaming | :executing_tool | :confirming
  @type entry_kind :: :user | :assistant | :tool | :system

  @type entry :: %{
          kind: entry_kind(),
          text: String.t(),
          logical: [ExRatatui.Text.Line.t()],
          lines: [ExRatatui.Text.Line.t()]
        }
  @type confirm :: %{ref: term(), id: term(), name: String.t()}
  @type action ::
          :quit | {:submit, String.t()} | {:confirm, :approved | :rejected} | :cancel | nil

  @type stats :: %{
          tokens: non_neg_integer(),
          first_token_at: integer() | nil,
          rate: float() | nil,
          prompt_tokens: non_neg_integer() | nil,
          completion_tokens: non_neg_integer() | nil,
          context_total: non_neg_integer(),
          turn_total: non_neg_integer() | nil
        }

  @max_history 500
  @default_size {80, 24}
  # Live re-renders of the in-flight reply stop above this; finalize still
  # parses once at the end (ADR 0006).
  @in_flight_cap 64 * 1024

  @enforce_keys [:input]
  defstruct [
    :input,
    :provider,
    :cwd,
    :agent,
    :confirm,
    phase: :idle,
    entries: [],
    in_flight: nil,
    in_flight_lines: nil,
    in_flight_dirty: false,
    anim_step: 0,
    tick_ref: nil,
    stats: %{
      tokens: 0,
      first_token_at: nil,
      rate: nil,
      prompt_tokens: nil,
      completion_tokens: nil,
      context_total: 0,
      turn_total: nil
    },
    scroll: 0,
    follow?: true,
    history: [],
    history_index: nil,
    draft: "",
    size: @default_size,
    live?: false,
    agent_ref: nil
  ]

  @type t :: %__MODULE__{
          input: reference(),
          provider: {:ok, DashFloat.Config.t()} | {:error, String.t()} | nil,
          cwd: String.t(),
          agent: pid() | atom(),
          phase: phase(),
          entries: [entry()],
          in_flight: String.t() | nil,
          in_flight_lines: [ExRatatui.Text.Line.t()] | nil,
          in_flight_dirty: boolean(),
          anim_step: non_neg_integer(),
          tick_ref: reference() | nil,
          stats: stats(),
          scroll: non_neg_integer(),
          follow?: boolean(),
          history: [String.t()],
          history_index: non_neg_integer() | nil,
          draft: String.t(),
          size: {pos_integer(), pos_integer()},
          live?: boolean(),
          agent_ref: reference() | nil,
          confirm: confirm() | nil
        }

  @typedoc """
  One message of the stream contract (see `stream_message/2` and ADR 0002 /
  0006 / 0007). The agent is the single voice; the tool messages are ADR 0007.
  """
  @type stream_msg ::
          {:token, String.t()}
          | {:usage,
             %{
               prompt_tokens: non_neg_integer(),
               completion_tokens: non_neg_integer(),
               total_tokens: non_neg_integer()
             }}
          | {:phase, :streaming}
          | {:phase, :executing_tool | :idle}
          | {:tool_call, tool_call_msg()}
          | {:tool_result, tool_result_msg()}
          | {:confirm, term(), confirm_msg()}
          | {:entry, :tool | :system, String.t()}

  @typep tool_call_msg :: %{id: term(), name: String.t(), args: map()}

  @typep tool_result_msg :: %{
           id: term(),
           name: String.t(),
           ok: boolean(),
           status: String.t(),
           output: String.t() | nil
         }

  @typep confirm_msg :: %{id: term(), name: String.t(), args: map(), lines: [String.t()]}

  ## Construction

  @doc """
  Builds the initial state from the App's mount opts. Under `test_mode: {w, h}`
  the size comes from the opts; live, it is read from the terminal (falling
  back to 80x24 without a TTY) and kept fresh by later Resize events. The
  provider is loaded once by the Application and handed in as `:provider`
  (ADR 0005); the agent the UI talks to as `:agent` (pid or name, default
  `DashFloat.Agent` — ADR 0007). The `cwd` label is computed here, once —
  status truth, not I/O per frame (ADR 0006).
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      input: ExRatatui.textarea_new(),
      provider: Keyword.get(opts, :provider),
      agent: Keyword.get(opts, :agent, DashFloat.Agent),
      confirm: nil,
      cwd: cwd_label(),
      size: initial_size(opts),
      live?: is_nil(Keyword.get(opts, :test_mode))
    }
  end

  @doc """
  The status bar's model label ([ADR 0008](../../docs/decisions/0008-config-layout-profiles-json5.md)):
  `"nickname (profile)"`, falling back to the bare nickname, then the model id.
  """
  @spec provider_label(t()) :: String.t() | nil
  def provider_label(%__MODULE__{provider: {:ok, provider}}), do: label(provider)
  def provider_label(%__MODULE__{}), do: nil

  defp label(%DashFloat.Config{nickname: nickname, profile: profile})
       when is_binary(nickname) and is_binary(profile),
       do: "#{nickname} (#{profile})"

  defp label(%DashFloat.Config{nickname: nickname}) when is_binary(nickname),
    do: nickname

  defp label(%DashFloat.Config{model: model}) when is_binary(model), do: model
  defp label(_other), do: nil

  @doc "The provider's context window, or nil when it was not configured."
  @spec provider_context_tokens(t()) :: pos_integer() | nil
  def provider_context_tokens(%__MODULE__{provider: {:ok, %{context_tokens: n}}})
      when is_integer(n) and n > 0,
      do: n

  def provider_context_tokens(%__MODULE__{}), do: nil

  @doc "The status bar's cwd label (`~/<last two segments>`, computed at new/1)."
  @spec cwd_label(t()) :: String.t()
  def cwd_label(%__MODULE__{cwd: cwd}), do: cwd

  defp cwd_label do
    case File.cwd() do
      {:ok, path} -> format_cwd(path)
      {:error, _reason} -> "~"
    end
  end

  defp format_cwd(path) do
    segments =
      path
      |> Path.split()
      |> Enum.reject(&(&1 == "/"))

    case Enum.take(segments, -2) do
      [] -> "~"
      tail -> "~/" <> Path.join(tail)
    end
  end

  defp initial_size(opts) do
    case Keyword.get(opts, :test_mode) do
      {w, h} when is_integer(w) and is_integer(h) ->
        {w, h}

      nil ->
        case ExRatatui.terminal_size() do
          {w, h} when is_integer(w) and is_integer(h) -> {w, h}
          {:error, _reason} -> @default_size
        end
    end
  end

  ## Status labels

  @doc "The live tok/s rate as one decimal, or nil before any rate exists."
  @spec rate_label(t()) :: String.t() | nil
  def rate_label(%__MODULE__{stats: %{rate: nil}}), do: nil

  def rate_label(%__MODULE__{stats: %{rate: rate}}),
    do: :erlang.float_to_binary(rate, decimals: 1)

  @doc """
  Context usage, `4.1k` or `4.1k/128k` when a provider window is configured;
  `—` until something has streamed.
  """
  @spec context_label(t()) :: String.t()
  def context_label(%__MODULE__{stats: %{context_total: 0}}), do: "—"

  def context_label(%__MODULE__{stats: %{context_total: total}} = state) do
    case provider_context_tokens(state) do
      nil -> humanize(total)
      window -> humanize(total) <> "/" <> humanize(window)
    end
  end

  # 999_999 reads "1.0m", not "1000k": a value that rounds up to the next
  # unit's thousand boundary uses that unit.
  defp humanize(n) when n < 1_000, do: Integer.to_string(n)
  defp humanize(n) when n < 999_950, do: trim_zero(n / 1_000) <> "k"
  defp humanize(n) when n < 999_950_000, do: trim_zero(n / 1_000_000) <> "m"
  defp humanize(n), do: trim_zero(n / 1_000_000_000) <> "b"

  defp trim_zero(x) do
    x
    |> Float.round(1)
    |> :erlang.float_to_binary(decimals: 1)
    |> String.trim_trailing(".0")
  end

  ## Input draft

  @doc "Current draft text (lines joined with `\\n`)."
  @spec input_text(t()) :: String.t()
  def input_text(%__MODULE__{input: input}), do: ExRatatui.textarea_get_value(input)

  @doc "Number of lines in the draft."
  @spec input_line_count(t()) :: non_neg_integer()
  def input_line_count(%__MODULE__{input: input}), do: ExRatatui.textarea_line_count(input)

  @doc "Inserts pasted text at the cursor (bracketed paste), normalizing CRLF and CR."
  @spec paste(t(), String.t()) :: t()
  def paste(%__MODULE__{input: input} = state, content) when is_binary(content) do
    ExRatatui.textarea_insert_str(input, normalize_newlines(content))
    leave_history(state)
  end

  defp normalize_newlines(content) do
    content
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
  end

  ## Key routing

  @doc """
  Routes one key event. Modifiers arrive as `ExRatatui` strings
  (`["ctrl"]`, `["shift"]`, ...). Returns `{state, action}`.
  """
  @spec handle_key(t(), String.t(), [String.t()]) :: {t(), action()}
  def handle_key(state, code, modifiers)

  # Quit (raw mode turns Ctrl+C into a key event, not SIGINT) — even
  # mid-decision.
  def handle_key(state, "c", ["ctrl"]), do: {state, :quit}
  def handle_key(state, "q", ["ctrl"]), do: {state, :quit}

  # Confirmation mode (a pending confirm from the agent, ADR 0007): Enter
  # approves, Esc rejects, and every other key is swallowed — typing
  # mid-decision must not reach the textarea nor become an accidental
  # approve.
  def handle_key(%{confirm: pending} = state, "enter", mods)
      when pending != nil and mods in [[], ["ctrl"]],
      do: {state, {:confirm, :approved}}

  def handle_key(%{confirm: pending} = state, "esc", _modifiers) when pending != nil,
    do: {state, {:confirm, :rejected}}

  def handle_key(%{confirm: pending} = state, _code, _modifiers) when pending != nil,
    do: {state, nil}

  # Enter / Ctrl+Enter submit; Shift+Enter / Alt+Enter insert a newline.
  def handle_key(state, "enter", mods) when mods in [[], ["ctrl"]], do: submit(state)
  def handle_key(state, "enter", ["shift"]), do: forward(state, "enter", [])
  def handle_key(state, "enter", ["alt"]), do: forward(state, "enter", [])

  # Esc interrupts a streaming reply or a running tool (ADR 0005/0007); a
  # no-op otherwise (including the post-decision confirming gap).
  def handle_key(%{phase: phase} = state, "esc", _modifiers)
      when phase in [:streaming, :executing_tool],
      do: {state, :cancel}

  def handle_key(state, "esc", _modifiers), do: {state, nil}

  # Log scrolling.
  def handle_key(state, "page_up", _modifiers), do: {page_up(state), nil}
  def handle_key(state, "page_down", _modifiers), do: {page_down(state), nil}

  # History-aware Up/Down: history only at the draft's row boundaries.
  def handle_key(state, "up", _modifiers) do
    if on_first_row?(state), do: {history_prev(state), nil}, else: forward(state, "up", [])
  end

  def handle_key(state, "down", _modifiers) do
    if on_last_row?(state), do: {history_next(state), nil}, else: forward(state, "down", [])
  end

  # Everything else (typing, editing, Emacs shortcuts) goes to the textarea.
  def handle_key(state, code, modifiers) when is_binary(code) and is_list(modifiers),
    do: forward(state, code, modifiers)

  defp forward(state, code, modifiers) do
    ExRatatui.textarea_handle_key(state.input, code, modifiers)
    # Editing while browsing history keeps the edited text: it becomes the
    # live draft (no longer restorable by navigating down).
    {leave_history(state), nil}
  end

  # Only for actual editing keys; history_prev/next call the textarea API
  # directly and must not trip this.
  defp leave_history(%{history_index: nil} = state), do: state

  defp leave_history(state) do
    %{state | history_index: nil, draft: input_text(state)}
  end

  defp on_first_row?(state) do
    {row, _col} = ExRatatui.textarea_cursor(state.input)
    row == 0
  end

  defp on_last_row?(state) do
    {row, _col} = ExRatatui.textarea_cursor(state.input)
    row == ExRatatui.textarea_line_count(state.input) - 1
  end

  ## Submit

  @doc """
  Submits the draft: appends a `:user` entry, pushes history, clears the
  draft, and flips the phase to `:streaming`. Returns `{state, nil}` when the
  draft is blank or a request is already in flight (one at a time; queueing is
  Phase 2).
  """
  @spec submit(t()) :: {t(), {:submit, String.t()} | nil}
  def submit(%__MODULE__{} = state) do
    text = input_text(state)

    if state.phase == :idle and text != "" and String.trim(text) != "" do
      state
      |> push_history(text)
      |> append_entry(:user, text)
      |> clear_input()
      |> Map.put(:phase, :streaming)
      # A new question re-pins the log: the user wants to watch its answer
      # arrive even if they had paged up first.
      |> Map.put(:follow?, true)
      |> then(&{&1, {:submit, text}})
    else
      {state, nil}
    end
  end

  defp push_history(state, text) do
    history =
      if state.history != [] and List.last(state.history) == text do
        state.history
      else
        Enum.take(state.history ++ [text], -@max_history)
      end

    %{state | history: history, history_index: nil, draft: ""}
  end

  defp clear_input(state) do
    ExRatatui.textarea_set_value(state.input, "")
    state
  end

  ## Stream messages (the Phase 2 seam)

  @doc """
  Applies one stream-contract message:

    * `{:token, text}` — append to the in-flight entry verbatim, count it, start
      the rate clock on the first token, mark the live lines stale
    * `{:usage, map}` — reconcile prompt/completion tokens, add the frame's
      total to the context accumulator; no phase change
    * `{:phase, :streaming}` — set the phase only; re-announcing streaming
      never finalizes (a producer resuming after a tool interlude must not
      fragment its reply)
    * `{:phase, :executing_tool | :idle}` — set the phase and finalize the
      in-flight entry, freezing the rate
    * `{:tool_call, call}` — append the gear row built by `Render.tool_call/2`
    * `{:tool_result, result}` — append the status row and dim output built by
      `Render.tool_result/3`
    * `{:confirm, ref, request}` — append the preview entry built by
      `Render.confirm_preview/1`, then arm `state.confirm` and flip to the
      `:confirming` phase (ADR 0007)
    * `{:entry, kind, text}` — append a complete entry

  `now` is monotonic milliseconds (injectable so the rate math is testable).
  Messages that violate the contract have no matching clause and crash —
  contract violations are bugs.
  """
  @spec stream_message(t(), stream_msg(), integer()) :: t()
  def stream_message(state, msg, now \\ System.monotonic_time(:millisecond))

  def stream_message(state, {:token, text}, now) when is_binary(text) do
    %{
      state
      | in_flight: (state.in_flight || "") <> text,
        stats: %{
          state.stats
          | tokens: state.stats.tokens + 1,
            first_token_at: state.stats.first_token_at || now
        },
        in_flight_dirty: true
    }
  end

  # A usage frame arriving after the turn finalized belongs to a turn that is
  # already over: applying it would poison the next turn's rate math (its
  # completion count is not this turn's). Ignored.
  def stream_message(%{phase: :idle} = state, {:usage, _usage}, _now), do: state

  def stream_message(state, {:usage, usage}, _now) when is_map(usage) do
    %{
      prompt_tokens: prompt,
      completion_tokens: completion,
      total_tokens: total
    } = usage

    # Usage frames carry the turn's running total — single-frame providers
    # send it once, per-chunk reporters on every frame. The turn's truth is
    # the LAST frame, banked once at finalize (ADR 0006); summing every frame
    # would inflate the context on per-chunk providers.
    stats = %{
      state.stats
      | prompt_tokens: prompt,
        completion_tokens: completion,
        # The usage frame is the authoritative count: the per-delta estimate is
        # reconciled here, so the frozen rate is computed from real tokens.
        tokens: completion,
        turn_total: total
    }

    %{state | stats: stats}
  end

  # Any phase message supersedes a pending confirm: the agent is the single
  # voice, and a confirm the UI never decided must not outlive the turn it
  # belonged to (agent death included — agent_down routes through here).
  def stream_message(state, {:phase, :streaming}, _now),
    do: %{state | phase: :streaming, confirm: nil}

  def stream_message(state, {:phase, phase}, now) when phase in [:executing_tool, :idle] do
    state
    |> finalize_in_flight(now)
    |> Map.put(:phase, phase)
    |> Map.put(:confirm, nil)
  end

  def stream_message(state, {:entry, kind, text}, _now)
      when kind in [:tool, :system] and is_binary(text),
      do: append_entry(state, kind, text)

  def stream_message(state, {:tool_call, %{id: _id, name: name, args: args}}, _now) do
    {text, lines} = Render.tool_call(name, args)
    put_entry(state, :tool, text, lines)
  end

  def stream_message(
        state,
        {:tool_result, %{id: _id, name: name, ok: _ok, status: status, output: output}},
        _now
      ) do
    {text, lines} = Render.tool_result(name, status, output)
    put_entry(state, :tool, text, lines)
  end

  def stream_message(
        state,
        {:confirm, ref, %{id: id, name: name, args: _args, lines: lines}},
        _now
      ) do
    {text, entry_lines} = Render.confirm_preview(lines)

    state
    |> put_entry(:tool, text, entry_lines)
    |> Map.put(:confirm, %{ref: ref, id: id, name: name})
    |> Map.put(:phase, :confirming)
  end

  # Finalizing renders the reply once and freezes the cumulative rate; the
  # streaming counters reset for the next turn, the frozen rate and context
  # accumulator stay visible.
  defp finalize_in_flight(%{in_flight: in_flight} = state, now) when in_flight in [nil, ""] do
    %{
      state
      | in_flight: nil,
        in_flight_lines: nil,
        in_flight_dirty: false,
        stats: frozen(state, now)
    }
  end

  defp finalize_in_flight(%{in_flight: in_flight} = state, now) do
    state
    |> append_entry(:assistant, in_flight)
    |> Map.merge(%{in_flight: nil, in_flight_lines: nil, in_flight_dirty: false})
    |> Map.put(:stats, frozen(state, now))
  end

  # The turn's banked usage total joins the conversation accumulator exactly
  # once, here (ADR 0006). Phase 3 caveat: a producer that emits the tool
  # transition before flushing usage would fold that episode's total into the
  # next episode's banking slot — producers must send usage before each phase
  # change (the in-contract order).
  defp frozen(%{stats: stats}, now) do
    %{
      stats
      | rate: rate(stats.tokens, stats.first_token_at, now) || stats.rate,
        tokens: 0,
        first_token_at: nil,
        # The turn's banked usage total joins the conversation accumulator
        # exactly once, here (ADR 0006).
        context_total: stats.context_total + (stats.turn_total || 0),
        turn_total: nil
    }
  end

  defp rate(tokens, first_token_at, now)
       when is_integer(first_token_at) and is_integer(now) and tokens > 0 and now > first_token_at do
    tokens * 1000 / (now - first_token_at)
  end

  defp rate(_tokens, _first_token_at, _now), do: nil

  # `text` stays verbatim (ADR 0006: it is the persistence truth); `logical`
  # is the width-free render truth, `lines` its wrap at the current width —
  # what the view renders and the scroll math counts. Tool-contract entries
  # carry their styled logical lines from the Render builders.
  defp append_entry(state, kind, text),
    do: put_entry(state, kind, text, Render.entry_lines(kind, text))

  defp put_entry(state, kind, text, logical) do
    entry = %{
      kind: kind,
      text: text,
      logical: logical,
      lines: Wrap.wrap(logical, log_width(state))
    }

    %{state | entries: state.entries ++ [entry]}
  end

  defp log_width(%__MODULE__{size: {width, _height}}), do: width

  ## Animation tick

  @doc """
  Steps the spinner and refreshes the live in-flight render. Returns
  `{state, :halt}` immediately when idle — an idle UI must never keep a timer
  alive (ADR 0006). `now` is monotonic milliseconds.
  """
  @spec tick(t(), integer()) :: {t(), :cont | :halt}
  def tick(%__MODULE__{phase: :idle} = state, _now), do: {state, :halt}

  def tick(%__MODULE__{} = state, now) do
    stats = state.stats

    state =
      state
      |> Map.put(:anim_step, state.anim_step + 1)
      |> Map.put(:stats, %{
        stats
        | rate: rate(stats.tokens, stats.first_token_at, now) || stats.rate
      })
      |> refresh_in_flight()

    {state, :cont}
  end

  defp refresh_in_flight(%{in_flight_dirty: false} = state), do: state

  defp refresh_in_flight(%{in_flight: in_flight} = state)
       when byte_size(in_flight) <= @in_flight_cap do
    width = log_width(state)
    %{state | in_flight_lines: wrapped_assistant(in_flight, width), in_flight_dirty: false}
  end

  # Above the cap the live view keeps its last render; finalize still parses
  # once at the end (ADR 0006).
  defp refresh_in_flight(state), do: state

  @doc "True when an active phase has no tick scheduled yet."
  @spec needs_tick?(t()) :: boolean()
  def needs_tick?(%__MODULE__{phase: :idle}), do: false
  def needs_tick?(%__MODULE__{tick_ref: nil}), do: true
  def needs_tick?(%__MODULE__{}), do: false

  ## Agent monitoring

  @doc """
  Monitors the agent (`state.agent`, a pid or registered name) so its death
  degrades the UI instead of bricking input. A side effect on purpose — the
  only one in this module — called from the TUI process at mount so the
  monitor lives there, not in `new/1` (ADR 0007).
  """
  @spec claim_agent(t()) :: t()
  def claim_agent(%__MODULE__{} = state) do
    %{state | agent_ref: Process.monitor(state.agent)}
  end

  @doc """
  Applies an agent `{:DOWN, ref, :process, _pid, reason}`. Normal exits (and
  `:noproc` — the monitor attaching after an already-dead name) only ensure
  the phase is `:idle` (finalizing any partial reply); anything else
  finalizes the stream, logs a `:system` entry explaining what happened, and
  returns to `:idle` so input keeps working — a dead agent must never brick
  the UI (ADR 0001: failures degrade to chat messages). Returns
  `{state, :handled}` when the ref was ours, `{state, :ignored}` otherwise.
  """
  @spec agent_down(t(), reference(), term()) :: {t(), :handled | :ignored}
  def agent_down(%{agent_ref: ref} = state, ref, reason) do
    cleared = %{state | agent_ref: nil}

    state =
      if reason in [:normal, :noproc] do
        stream_message(cleared, {:phase, :idle})
      else
        stream_failed(cleared, "[agent failed: #{String.slice(inspect(reason), 0, 120)}]")
      end

    {state, :handled}
  end

  def agent_down(state, _other_ref, _reason), do: {state, :ignored}

  @doc """
  Clears the pending confirmation once the decision has been sent to the
  agent. The phase stays `:confirming` until the agent's next phase message
  arrives — the gap is one mailbox hop, invisible under render coalescing.
  """
  @spec confirm_decided(t()) :: t()
  def confirm_decided(%__MODULE__{} = state), do: %{state | confirm: nil}

  @doc """
  Degrades to `:idle` with a `:system` entry explaining the failure. A binary
  reason is already user-facing text and is logged verbatim; anything else is
  inspected.
  """
  @spec stream_failed(t(), term()) :: t()
  def stream_failed(state, reason) do
    state
    |> stream_message({:entry, :system, format_reason(reason)})
    |> stream_message({:phase, :idle})
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: "[stream failed: #{String.slice(inspect(reason), 0, 120)}]"

  ## History navigation

  # history_index counts steps back from the newest entry; nil means the live
  # draft. Entering history saves the draft; navigating past the newest
  # restores it.
  defp history_prev(%{history: []} = state), do: state

  defp history_prev(state) do
    next = min((state.history_index || -1) + 1, length(state.history) - 1)

    state
    |> maybe_save_draft()
    |> set_history_index(next)
  end

  defp history_next(%{history_index: nil} = state), do: state

  defp history_next(state) do
    next = state.history_index - 1

    if next < 0 do
      set_draft(state, state.draft)
      %{state | history_index: nil}
    else
      set_history_index(state, next)
    end
  end

  defp maybe_save_draft(%{history_index: nil} = state), do: %{state | draft: input_text(state)}
  defp maybe_save_draft(state), do: state

  defp set_history_index(state, index) do
    text =
      state.history
      |> Enum.reverse()
      |> Enum.at(index)

    set_draft(state, text)
    %{state | history_index: index}
  end

  defp set_draft(state, text) do
    ExRatatui.textarea_set_value(state.input, text)
    move_cursor_to_end(state.input, text)
    state
  end

  defp move_cursor_to_end(input, text) do
    lines =
      text
      |> String.split("\n")
      |> length()

    # set_value leaves the cursor at {0, 0}; walk to the last line, then end.
    Enum.each(
      List.duplicate("down", max(lines - 1, 0)) ++ ["end"],
      &ExRatatui.textarea_handle_key(input, &1, [])
    )
  end

  ## Scrolling

  @doc "Total display lines in the log (stored entry lines plus any in-flight lines)."
  @spec log_line_count(t()) :: non_neg_integer()
  def log_line_count(%{entries: entries, in_flight_lines: in_flight_lines}) do
    count = Enum.reduce(entries, 0, fn %{lines: lines}, acc -> acc + length(lines) end)
    count + length(in_flight_lines || [])
  end

  @doc """
  Effective scroll offset for a viewport of `height` lines: the intent
  clamped to the content. When following, it is pinned to the bottom.
  """
  @spec effective_scroll(t(), non_neg_integer()) :: non_neg_integer()
  def effective_scroll(state, height) when is_integer(height) and height >= 0 do
    total = log_line_count(state)
    max_offset = max(total - height, 0)

    if state.follow?,
      do: max_offset,
      else: min(state.scroll, max_offset)
  end

  defp page_up(state), do: scroll(state, :up, log_height(state))
  defp page_down(state), do: scroll(state, :down, log_height(state))

  # One wheel notch scrolls three lines — the terminal convention for
  # alternate-screen apps (issue #21; ADR 0006 amendment).
  @wheel_lines 3

  @doc """
  Scrolls the log one wheel notch. Wheel routing is focus-free (ADR 0006
  amendment): it always addresses the log view — never the input draft —
  including mid-confirmation. Semantics mirror the page keys at line
  granularity: up unfollows (with page_up's nothing-to-scroll guard), down
  re-pins at the bottom.
  """
  @spec wheel_scroll(t(), :up | :down) :: t()
  def wheel_scroll(state, :up), do: scroll(state, :up, @wheel_lines)
  def wheel_scroll(state, :down), do: scroll(state, :down, @wheel_lines)

  defp scroll(state, :up, step) do
    height = log_height(state)

    # Nothing to scroll (empty or viewport-sized log): stay pinned. Unfollowing
    # here would make the user miss the next reply entirely.
    if log_line_count(state) - height <= 0 do
      state
    else
      %{state | follow?: false, scroll: max(effective_scroll(state, height) - max(step, 1), 0)}
    end
  end

  defp scroll(state, :down, step) do
    height = log_height(state)
    bottom = max(log_line_count(state) - height, 0)
    target = effective_scroll(state, height) + max(step, 1)

    if target >= bottom do
      %{state | scroll: 0, follow?: true}
    else
      %{state | follow?: false, scroll: target}
    end
  end

  defp log_height(state) do
    %{log: log} = View.regions(state.size, input_line_count(state), state.phase != :idle)
    log.height
  end

  ## Resize

  @doc """
  Records the new terminal size and, when the width changed, re-wraps the log
  to it: stored entries re-wrap from their logical lines (no re-parse), and
  the in-flight reply re-renders from its text under the same 64 KiB live
  cap. Above the cap no fresh render is possible until finalize, and a
  stale-width render would truncate at the new edge, so the live view
  clears until the reply finalizes (ADR 0006, amended). Scroll intents stay
  and are clamped at render.
  """
  @spec resize(t(), integer(), integer()) :: t()
  def resize(state, width, height) when is_integer(width) and is_integer(height) do
    width = max(width, 1)
    height = max(height, 1)

    case state.size do
      {^width, ^height} ->
        state

      {old_width, _old_height} when old_width == width ->
        %{state | size: {width, height}}

      _old_size ->
        %{
          state
          | size: {width, height},
            entries: Enum.map(state.entries, &rewrap_entry(&1, width)),
            in_flight_lines: rewrap_in_flight(state, width)
        }
    end
  end

  # Hand-built entries (tests, older state) may lack :logical; re-wrapping
  # from their stored lines is the best available truth there.
  defp rewrap_entry(entry, width) do
    logical = Map.get(entry, :logical, entry.lines)
    %{entry | lines: Wrap.wrap(logical, width)}
  end

  defp rewrap_in_flight(%{in_flight: in_flight} = _state, width)
       when is_binary(in_flight) and in_flight != "" and byte_size(in_flight) <= @in_flight_cap,
       do: wrapped_assistant(in_flight, width)

  defp rewrap_in_flight(_state, _width), do: nil

  defp wrapped_assistant(text, width) do
    :assistant
    |> Render.entry_lines(text)
    |> Wrap.wrap(width)
  end
end
