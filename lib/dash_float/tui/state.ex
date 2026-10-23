defmodule DashFloat.TUI.State do
  @moduledoc """
  Pure UI state and every state transition for `DashFloat.TUI`.

  All logic here is deterministic: no processes, no terminal, no timers. The
  input draft lives in the textarea's Rust-side state, reached through its
  synchronous in-memory API. Transitions return `{state, action}` where
  `action` is `:quit`, `{:submit, prompt}`, `:cancel`, or `nil`; the TUI
  interprets actions. See ADR 0002 for the event flow.
  """

  alias DashFloat.TUI.View

  @type phase :: :idle | :streaming | :executing_tool
  @type entry_kind :: :user | :assistant | :tool | :system
  @type action :: :quit | {:submit, String.t()} | nil

  @max_history 500
  @default_size {80, 24}

  @enforce_keys [:input]
  defstruct [
    :input,
    :provider,
    phase: :idle,
    entries: [],
    in_flight: nil,
    scroll: 0,
    follow?: true,
    history: [],
    history_index: nil,
    draft: "",
    size: @default_size,
    live?: false,
    task_ref: nil,
    task_pid: nil
  ]

  @type t :: %__MODULE__{
          input: reference(),
          provider: {:ok, DashFloat.Config.t()} | {:error, String.t()} | nil,
          phase: phase(),
          entries: [{entry_kind(), String.t()}],
          in_flight: String.t() | nil,
          scroll: non_neg_integer(),
          follow?: boolean(),
          history: [String.t()],
          history_index: non_neg_integer() | nil,
          draft: String.t(),
          size: {pos_integer(), pos_integer()},
          live?: boolean(),
          task_ref: reference() | nil,
          task_pid: pid() | nil
        }

  @typedoc """
  One message of the stream contract (see `stream_message/2` and ADR 0002).
  """
  @type stream_msg ::
          {:token, String.t()}
          | {:phase, :streaming}
          | {:phase, :executing_tool | :idle}
          | {:entry, :tool | :system, String.t()}

  ## Construction

  @doc """
  Builds the initial state from the App's mount opts. Under `test_mode: {w, h}`
  the size comes from the opts; live, it is read from the terminal (falling
  back to 80x24 without a TTY) and kept fresh by later Resize events. The
  provider is loaded once by the Application and handed in as `:provider`
  (ADR 0004).
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      input: ExRatatui.textarea_new(),
      provider: Keyword.get(opts, :provider),
      size: initial_size(opts),
      live?: is_nil(Keyword.get(opts, :test_mode))
    }
  end

  @doc "The configured model name for the status bar, or nil when unusable."
  def provider_model(%__MODULE__{provider: {:ok, %{model: model}}}), do: model
  def provider_model(%__MODULE__{}), do: nil

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

  ## Input draft

  @doc "Current draft text (lines joined with `\\n`)."
  @spec input_text(t()) :: String.t()
  def input_text(%__MODULE__{input: input}), do: ExRatatui.textarea_get_value(input)

  @doc "Number of lines in the draft."
  @spec input_line_count(t()) :: non_neg_integer()
  def input_line_count(%__MODULE__{input: input}), do: ExRatatui.textarea_line_count(input)

  @doc "Inserts pasted text at the cursor (bracketed paste)."
  @spec paste(t(), String.t()) :: t()
  def paste(%__MODULE__{input: input} = state, content) when is_binary(content) do
    ExRatatui.textarea_insert_str(input, content)
    leave_history(state)
  end

  ## Key routing

  @doc """
  Routes one key event. Modifiers arrive as `ExRatatui` strings
  (`["ctrl"]`, `["shift"]`, ...). Returns `{state, action}`.
  """
  @spec handle_key(t(), String.t(), [String.t()]) :: {t(), action()}
  def handle_key(state, code, modifiers)

  # Quit (raw mode turns Ctrl+C into a key event, not SIGINT).
  def handle_key(state, "c", ["ctrl"]), do: {state, :quit}
  def handle_key(state, "q", ["ctrl"]), do: {state, :quit}

  # Enter / Ctrl+Enter submit; Shift+Enter / Alt+Enter insert a newline.
  def handle_key(state, "enter", mods) when mods in [[], ["ctrl"]], do: submit(state)
  def handle_key(state, "enter", ["shift"]), do: forward(state, "enter", [])
  def handle_key(state, "enter", ["alt"]), do: forward(state, "enter", [])

  # Esc cancels a running stream; a no-op otherwise (ADR 0004).
  def handle_key(%{phase: :streaming, task_pid: pid} = state, "esc", _) when is_pid(pid),
    do: {state, :cancel}

  def handle_key(state, "esc", _), do: {state, nil}

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

    * `{:token, text}` — append to the in-flight entry
    * `{:phase, :streaming}` — set the phase only; re-announcing streaming
      never finalizes (a producer resuming after a tool interlude must not
      fragment its reply)
    * `{:phase, :executing_tool | :idle}` — set the phase and finalize the
      in-flight entry
    * `{:entry, kind, text}` — append a complete entry

  Messages that violate the contract have no matching clause and crash —
  contract violations are bugs.
  """
  @spec stream_message(t(), stream_msg()) :: t()
  def stream_message(state, {:token, text}) when is_binary(text) do
    %{state | in_flight: (state.in_flight || "") <> text}
  end

  def stream_message(state, {:phase, :streaming}), do: %{state | phase: :streaming}

  def stream_message(state, {:phase, phase}) when phase in [:executing_tool, :idle] do
    state
    |> finalize_in_flight()
    |> Map.put(:phase, phase)
  end

  def stream_message(state, {:entry, kind, text})
      when kind in [:tool, :system] and is_binary(text),
      do: append_entry(state, kind, text)

  defp finalize_in_flight(%{in_flight: in_flight} = state) when in_flight in [nil, ""],
    do: %{state | in_flight: nil}

  defp finalize_in_flight(%{in_flight: in_flight} = state) do
    state
    |> append_entry(:assistant, in_flight)
    |> Map.put(:in_flight, nil)
  end

  defp append_entry(state, kind, text) do
    text = String.trim_trailing(text, "\n")
    %{state | entries: state.entries ++ [{kind, text}]}
  end

  ## Producer-task monitoring

  @doc "Records the pid and monitor ref of the producer Task started for this stream."
  @spec claim_task(t(), pid(), reference()) :: t()
  def claim_task(state, pid, ref) when is_pid(pid) and is_reference(ref),
    do: %{state | task_pid: pid, task_ref: ref}

  @doc """
  Applies a producer-task `{:DOWN, ref, :process, _pid, reason}`. Normal exits
  only ensure the phase is `:idle` (finalizing any partial reply);
  `:noproc` — the monitor attaching after an already-finished task — is
  treated the same, because a producer that exits between `start_child/2`
  returning and `Process.monitor/1` attaching cannot be distinguished from a
  successful one after the fact. Other exits finalize the stream, log a
  `:system` entry explaining what happened, and return to `:idle` so input
  keeps working — a dead producer must never brick the UI (ADR 0001: failures
  degrade to chat messages). Returns `{state, :handled}` when the ref was ours,
  `{state, :ignored}` otherwise.
  """
  @spec task_down(t(), reference(), term()) :: {t(), :handled | :ignored}
  def task_down(%{task_ref: ref} = state, ref, reason) do
    cleared = %{state | task_ref: nil, task_pid: nil}

    state =
      if reason in [:normal, :noproc] do
        stream_message(cleared, {:phase, :idle})
      else
        stream_failed(cleared, reason)
      end

    {state, :handled}
  end

  def task_down(state, _other_ref, _reason), do: {state, :ignored}

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
  defp format_reason(reason), do: "[stream failed: #{inspect(reason) |> String.slice(0, 120)}]"

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

  @doc "Total display lines in the log (entries plus any in-flight entry)."
  @spec log_line_count(t()) :: non_neg_integer()
  def log_line_count(%{entries: entries, in_flight: in_flight}) do
    # Count via :binary.matches — avoids String.split's per-line list building
    # on the hot render path.
    count = Enum.reduce(entries, 0, fn {_kind, text}, acc -> acc + line_count(text) end)

    if in_flight in [nil, ""] do
      count
    else
      count + line_count(in_flight)
    end
  end

  defp line_count(text), do: length(:binary.matches(text, "\n")) + 1

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

  defp page_up(state) do
    height = log_height(state)

    # Nothing to scroll (empty or viewport-sized log): stay pinned. Unfollowing
    # here would make the user miss the next reply entirely.
    if log_line_count(state) - height <= 0 do
      state
    else
      %{state | follow?: false, scroll: max(effective_scroll(state, height) - max(height, 1), 0)}
    end
  end

  defp page_down(state) do
    height = log_height(state)
    bottom = max(log_line_count(state) - height, 0)
    target = effective_scroll(state, height) + max(height, 1)

    if target >= bottom do
      %{state | scroll: 0, follow?: true}
    else
      %{state | follow?: false, scroll: target}
    end
  end

  defp log_height(state) do
    %{log: log} = View.regions(state.size, input_line_count(state))
    log.height
  end

  ## Resize

  @doc "Records the new terminal size; scroll intents stay and are clamped at render."
  @spec resize(t(), integer(), integer()) :: t()
  def resize(state, width, height) when is_integer(width) and is_integer(height),
    do: %{state | size: {max(width, 1), max(height, 1)}}
end
