defmodule DashFloat.TUI.State do
  @moduledoc """
  Pure UI state and every state transition for `DashFloat.TUI`.

  All logic here is deterministic: no processes, no terminal, no timers. The
  input draft lives in the textarea's Rust-side state, reached through its
  synchronous in-memory API. Transitions return `{state, action}` where
  `action` is `:quit`, `{:submit, prompt}`, or `nil`; the TUI interprets
  actions. See ADR 0002 for the event flow.
  """

  alias DashFloat.TUI.View

  @type phase :: :idle | :streaming | :executing_tool
  @type entry_kind :: :user | :assistant | :tool | :system

  @max_history 500
  @default_size {80, 24}

  @enforce_keys [:input]
  defstruct [
    :input,
    :demo_stream_opts,
    phase: :idle,
    entries: [],
    in_flight: nil,
    scroll: 0,
    follow?: true,
    history: [],
    history_index: nil,
    draft: "",
    size: @default_size,
    live?: false
  ]

  @type t :: %__MODULE__{
          input: reference(),
          demo_stream_opts: keyword(),
          phase: phase(),
          entries: [{entry_kind(), String.t()}],
          in_flight: String.t() | nil,
          scroll: non_neg_integer(),
          follow?: boolean(),
          history: [String.t()],
          history_index: non_neg_integer() | nil,
          draft: String.t(),
          size: {pos_integer(), pos_integer()},
          live?: boolean()
        }

  ## Construction

  @doc """
  Builds the initial state from the App's mount opts. Under `test_mode: {w, h}`
  the size comes from the opts; live, it is read from the terminal (falling
  back to 80x24 without a TTY) and kept fresh by later Resize events.
  """
  def new(opts) do
    %__MODULE__{
      input: ExRatatui.textarea_new(),
      demo_stream_opts: Keyword.get(opts, :demo_stream_opts, []),
      size: initial_size(opts),
      live?: is_nil(Keyword.get(opts, :test_mode))
    }
  end

  defp initial_size(opts) do
    case Keyword.get(opts, :test_mode) do
      {w, h} when is_integer(w) and is_integer(h) ->
        {w, h}

      nil ->
        case ExRatatui.terminal_size() do
          {w, h} when is_integer(w) and is_integer(h) -> {w, h}
          {:error, _} -> @default_size
        end
    end
  end

  ## Input draft

  @doc "Current draft text (lines joined with `\\n`)."
  def input_text(%__MODULE__{input: input}), do: ExRatatui.textarea_get_value(input)

  @doc "Number of lines in the draft."
  def input_line_count(%__MODULE__{input: input}), do: ExRatatui.textarea_line_count(input)

  @doc "Inserts pasted text at the cursor (bracketed paste)."
  def paste(%__MODULE__{input: input} = state, content) when is_binary(content) do
    ExRatatui.textarea_insert_str(input, content)
    state
  end

  ## Key routing

  @doc """
  Routes one key event. Modifiers arrive as `ExRatatui` strings
  (`["ctrl"]`, `["shift"]`, ...). Returns `{state, action}`.
  """
  def handle_key(state, code, modifiers)

  # Quit (raw mode turns Ctrl+C into a key event, not SIGINT).
  def handle_key(state, "c", ["ctrl"]), do: {state, :quit}
  def handle_key(state, "q", ["ctrl"]), do: {state, :quit}

  # Enter / Ctrl+Enter submit; Shift+Enter / Alt+Enter insert a newline.
  def handle_key(state, "enter", mods) when mods in [[], ["ctrl"]], do: submit(state)
  def handle_key(state, "enter", ["shift"]), do: forward(state, "enter", [])
  def handle_key(state, "enter", ["alt"]), do: forward(state, "enter", [])

  # Log scrolling.
  def handle_key(state, "page_up", _), do: {page_up(state), nil}
  def handle_key(state, "page_down", _), do: {page_down(state), nil}

  # History-aware Up/Down: history only at the draft's row boundaries.
  def handle_key(state, "up", _) do
    if on_first_row?(state), do: {history_prev(state), nil}, else: forward(state, "up", [])
  end

  def handle_key(state, "down", _) do
    if on_last_row?(state), do: {history_next(state), nil}, else: forward(state, "down", [])
  end

  # Everything else (typing, editing, Emacs shortcuts) goes to the textarea.
  def handle_key(state, code, modifiers) when is_binary(code) and is_list(modifiers),
    do: forward(state, code, modifiers)

  defp forward(state, code, modifiers) do
    ExRatatui.textarea_handle_key(state.input, code, modifiers)
    {state, nil}
  end

  defp on_first_row?(state) do
    {row, _} = ExRatatui.textarea_cursor(state.input)
    row == 0
  end

  defp on_last_row?(state) do
    {row, _} = ExRatatui.textarea_cursor(state.input)
    row == ExRatatui.textarea_line_count(state.input) - 1
  end

  ## Submit

  @doc """
  Submits the draft: appends a `:user` entry, pushes history, clears the
  draft, and flips the phase to `:streaming`. Returns `{state, nil}` when the
  draft is blank or a request is already in flight (one at a time; queueing is
  Phase 2).
  """
  def submit(%__MODULE__{} = state) do
    text = input_text(state)

    if state.phase == :idle and text != "" and String.trim(text) != "" do
      state
      |> push_history(text)
      |> append_entry(:user, text)
      |> clear_input()
      |> Map.put(:phase, :streaming)
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
        (state.history ++ [text]) |> Enum.take(-@max_history)
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
    * `{:phase, phase}` — set the status phase; leaving `:streaming`
      finalizes the in-flight entry
    * `{:entry, kind, text}` — append a complete entry

  Messages that violate the contract have no matching clause and crash —
  contract violations are bugs.
  """
  def stream_message(state, {:token, text}) when is_binary(text) do
    %{state | in_flight: (state.in_flight || "") <> text}
  end

  def stream_message(state, {:phase, phase}) when phase in [:streaming, :executing_tool, :idle] do
    state
    |> finalize_in_flight()
    |> Map.put(:phase, phase)
  end

  def stream_message(state, {:entry, kind, text})
      when kind in [:tool, :system] and is_binary(text),
      do: append_entry(state, kind, text)

  defp finalize_in_flight(%{in_flight: in_flight} = state) when in_flight in [nil, ""],
    do: %{state | in_flight: nil}

  defp finalize_in_flight(%{in_flight: in_flight} = state),
    do: state |> append_entry(:assistant, in_flight) |> Map.put(:in_flight, nil)

  defp append_entry(state, kind, text) do
    text = String.trim_trailing(text, "\n")
    %{state | entries: state.entries ++ [{kind, text}]}
  end

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
    text = state.history |> Enum.reverse() |> Enum.at(index)
    set_draft(state, text)
    %{state | history_index: index}
  end

  defp set_draft(state, text) do
    ExRatatui.textarea_set_value(state.input, text)
    move_cursor_to_end(state.input, text)
    state
  end

  defp move_cursor_to_end(input, text) do
    lines = text |> String.split("\n") |> length()
    # set_value leaves the cursor at {0, 0}; walk to the last line, then end.
    (List.duplicate("down", max(lines - 1, 0)) ++ ["end"])
    |> Enum.each(&ExRatatui.textarea_handle_key(input, &1, []))
  end

  ## Scrolling

  @doc "Total display lines in the log (entries plus any in-flight entry)."
  def log_line_count(%{entries: entries, in_flight: in_flight}) do
    count = entries |> line_count()

    if in_flight in [nil, ""] do
      count
    else
      count + line_count([{:assistant, in_flight}])
    end
  end

  defp line_count(entries),
    do:
      entries
      |> Enum.map(fn {_kind, text} -> text |> String.split("\n") |> length() end)
      |> Enum.sum()

  @doc """
  Effective scroll offset for a viewport of `height` lines: the intent
  clamped to the content. When following, it is pinned to the bottom.
  """
  def effective_scroll(state, height) when is_integer(height) and height >= 0 do
    total = log_line_count(state)
    max_offset = max(total - height, 0)

    if state.follow?,
      do: max_offset,
      else: min(state.scroll, max_offset)
  end

  defp page_up(state) do
    height = log_height(state)
    %{state | follow?: false, scroll: max(effective_scroll(state, height) - max(height, 1), 0)}
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
  def resize(state, width, height) when is_integer(width) and is_integer(height),
    do: %{state | size: {max(width, 1), max(height, 1)}}
end
