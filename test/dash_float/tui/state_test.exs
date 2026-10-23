defmodule DashFloat.TUI.StateTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias DashFloat.TUI.State

  defp new_state(opts \\ []) do
    State.new(Keyword.merge([test_mode: {80, 24}], opts))
  end

  defp type(state, text) do
    Enum.reduce(String.codepoints(text), state, fn c, acc ->
      {acc, nil} = State.handle_key(acc, c, [])
      acc
    end)
  end

  # Submits text and returns the state with the phase forced back to idle
  # (mid-stream submits are refused by design).
  defp idle_submit(state, text) do
    {state, action} = state |> type(text) |> State.handle_key("enter", [])
    assert {:submit, ^text} = action
    Map.put(state, :phase, :idle)
  end

  describe "new/1" do
    test "initial state is idle with empty log and test-mode size" do
      state = new_state()
      assert state.phase == :idle
      assert state.entries == []
      assert state.in_flight == nil
      assert state.history == []
      assert state.follow? == true
      assert state.size == {80, 24}
      assert state.live? == false
      assert State.input_text(state) == ""
    end

    test "mount opts carry the demo stream opts" do
      assert new_state(demo_stream_opts: [interval_ms: 1]).demo_stream_opts == [interval_ms: 1]
    end
  end

  describe "handle_key/3 — quit" do
    test "Ctrl+C and Ctrl+Q quit" do
      assert {_, :quit} = new_state() |> State.handle_key("c", ["ctrl"])
      assert {_, :quit} = new_state() |> State.handle_key("q", ["ctrl"])
    end

    test "plain c and q type" do
      state = type(new_state(), "cq")
      assert State.input_text(state) == "cq"
    end
  end

  describe "handle_key/3 — enter semantics" do
    test "Enter submits the draft" do
      state = type(new_state(), "hello")
      {state, action} = State.handle_key(state, "enter", [])
      assert {:submit, "hello"} = action
      assert State.input_text(state) == ""
      assert state.entries == [{:user, "hello"}]
      assert state.phase == :streaming
      assert state.history == ["hello"]
    end

    test "Ctrl+Enter also submits" do
      state = type(new_state(), "hi")
      {_state, action} = State.handle_key(state, "enter", ["ctrl"])
      assert {:submit, "hi"} = action
    end

    test "Shift+Enter and Alt+Enter insert newlines" do
      state = type(new_state(), "one")
      {state, nil} = State.handle_key(state, "enter", ["shift"])
      state = type(state, "two")
      # cursor sits at the end, so Alt+Enter appends a trailing newline
      {state, nil} = State.handle_key(state, "enter", ["alt"])
      assert State.input_text(state) == "one\ntwo\n"
      assert State.input_line_count(state) == 3
    end

    test "blank and whitespace-only drafts do not submit" do
      {state, nil} = new_state() |> State.handle_key("enter", [])
      assert state.entries == []

      {state, nil} =
        new_state()
        |> type("  ")
        |> State.handle_key("enter", [])

      assert state.entries == []
      assert state.phase == :idle
    end

    test "submit is refused while a request is in flight" do
      state = idle_submit(new_state(), "first")
      # put ourselves back into a streaming phase
      state = Map.put(state, :phase, :streaming)
      state = type(state, "second")
      {state, action} = State.handle_key(state, "enter", [])
      assert action == nil
      assert state.entries == [{:user, "first"}]
      assert State.input_text(state) == "second"
    end
  end

  describe "handle_key/3 — history-aware Up/Down" do
    test "Up on the first row enters history; Down on the last row leaves it" do
      base = new_state() |> idle_submit("one") |> idle_submit("two")

      {state, nil} = State.handle_key(base, "up", [])
      assert state.history_index == 0
      assert State.input_text(state) == "two"

      {state, nil} = State.handle_key(state, "up", [])
      assert state.history_index == 1
      assert State.input_text(state) == "one"

      {state, nil} = State.handle_key(state, "down", [])
      assert state.history_index == 0
      assert State.input_text(state) == "two"

      {state, nil} = State.handle_key(state, "down", [])
      assert state.history_index == nil
      assert State.input_text(state) == ""
    end

    test "the pre-navigation draft is restored" do
      base = new_state() |> idle_submit("kept") |> type("dra")

      {state, nil} = State.handle_key(base, "up", [])
      assert State.input_text(state) == "kept"

      {state, nil} = State.handle_key(state, "down", [])
      assert State.input_text(state) == "dra"
    end

    test "Up inside a multi-line draft moves the cursor, not history" do
      state = type(new_state(), "one")
      {state, nil} = State.handle_key(state, "enter", ["shift"])
      state = type(state, "two")

      {state, nil} = State.handle_key(state, "up", [])
      assert state.history_index == nil
      assert State.input_text(state) == "one\ntwo"
    end

    test "Up with empty history is a no-op" do
      {state, nil} = new_state() |> State.handle_key("up", [])
      assert state.history_index == nil
    end

    test "Down at the last row with live draft is a no-op" do
      {state, nil} = new_state() |> State.handle_key("down", [])
      assert state.history_index == nil
    end

    test "editing while browsing history keeps the edited text as the draft" do
      base = new_state() |> idle_submit("prev")

      {state, nil} = State.handle_key(base, "up", [])
      assert State.input_text(state) == "prev"

      {state, nil} = State.handle_key(state, "x", [])
      assert state.history_index == nil
      assert State.input_text(state) == "prevx"

      # Down no longer discards the edit
      {state, nil} = State.handle_key(state, "down", [])
      assert State.input_text(state) == "prevx"
    end

    test "consecutive duplicate submits are not stored twice" do
      state = new_state() |> idle_submit("same") |> idle_submit("same")
      assert state.history == ["same"]
    end

    test "history is capped at 500 entries" do
      state = %{new_state() | history: Enum.map(1..500, &"h#{&1}")}
      {state, _} = submit(state, "new")
      assert length(state.history) == 500
      assert List.last(state.history) == "new"
    end

    defp submit(state, text) do
      state |> type(text) |> State.handle_key("enter", [])
    end
  end

  describe "stream_message/2" do
    test "tokens accumulate in the in-flight entry" do
      state =
        new_state()
        |> State.stream_message({:token, "hel"})
        |> State.stream_message({:token, "lo"})

      assert state.in_flight == "hello"
      assert state.entries == []
      assert State.log_line_count(state) == 1
    end

    test "re-announcing :streaming never finalizes the in-flight entry" do
      state =
        new_state()
        |> State.stream_message({:token, "The answer is "})
        |> State.stream_message({:token, "42."})
        |> State.stream_message({:phase, :streaming})
        |> State.stream_message({:token, " (confident)"})
        |> State.stream_message({:phase, :idle})

      assert state.entries == [{:assistant, "The answer is 42. (confident)"}]
      assert state.in_flight == nil
      assert state.phase == :idle
    end

    test "leaving :streaming for :executing_tool finalizes the in-flight entry" do
      state =
        new_state()
        |> State.stream_message({:token, "one\ntwo"})
        |> State.stream_message({:phase, :executing_tool})

      assert state.entries == [{:assistant, "one\ntwo"}]
      assert state.in_flight == nil
      assert state.phase == :executing_tool

      state = State.stream_message(state, {:phase, :idle})
      assert state.phase == :idle
      assert state.entries == [{:assistant, "one\ntwo"}]
    end

    test "tool and system entries append as complete entries" do
      state =
        new_state()
        |> State.stream_message({:entry, :tool, "[tool] ran"})
        |> State.stream_message({:entry, :system, "reconnected"})

      assert state.entries == [{:tool, "[tool] ran"}, {:system, "reconnected"}]
    end

    test "contract violations crash instead of corrupting state" do
      # Built dynamically so the compile-time type checker cannot narrow them
      # into an "impossible input" warning — these are runtime garbage.
      bogus = String.to_atom("bogus")
      not_binary = String.to_atom("not_binary")
      user = String.to_atom("user")
      bad_phase = List.to_tuple([:phase, bogus])
      bad_token = List.to_tuple([:token, not_binary])
      bad_entry = List.to_tuple([:entry, user, "not allowed via messages"])

      assert_raise FunctionClauseError, fn ->
        new_state() |> State.stream_message(bad_phase)
      end

      assert_raise FunctionClauseError, fn ->
        new_state() |> State.stream_message(bad_token)
      end

      assert_raise FunctionClauseError, fn ->
        new_state() |> State.stream_message(bad_entry)
      end
    end
  end

  describe "scrolling" do
    defp full_state(lines) do
      Enum.reduce(1..lines, new_state(), fn i, acc ->
        State.stream_message(acc, {:entry, :system, "line #{i}"})
      end)
    end

    test "empty log: offsets are zero and page_up keeps following" do
      {state, nil} = new_state() |> State.handle_key("page_up", [])
      assert state.follow?
      assert State.effective_scroll(state, 20) == 0
    end

    test "page_up on a viewport-sized log is a no-op (stays pinned)" do
      state = full_state(20)
      {state, nil} = State.handle_key(state, "page_up", [])
      assert state.follow?
      assert State.effective_scroll(state, 20) == 0
    end

    test "submit re-pins the log so the new reply is visible" do
      state = full_state(100)
      {state, nil} = State.handle_key(state, "page_up", [])
      refute state.follow?

      state = idle_submit(state, "next question")
      assert state.follow?
      # 100 log lines + the new user entry = 101; bottom is 101 - 20
      assert State.effective_scroll(state, 20) == 81
    end

    test "follow pins to the bottom as content grows" do
      state = full_state(50)
      assert State.effective_scroll(state, 20) == 30
      state = State.stream_message(state, {:entry, :system, "more"})
      assert State.effective_scroll(state, 20) == 31
    end

    test "page_up unfollows and pages back; page_down re-pins at the bottom" do
      state = full_state(100)
      {state, nil} = State.handle_key(state, "page_up", [])
      refute state.follow?
      assert State.effective_scroll(state, 20) == 60

      {state, nil} = State.handle_key(state, "page_up", [])
      assert State.effective_scroll(state, 20) == 40

      {state, nil} = State.handle_key(state, "page_down", [])
      assert State.effective_scroll(state, 20) == 60

      {state, nil} = State.handle_key(state, "page_down", [])
      assert state.follow?
      assert State.effective_scroll(state, 20) == 80
    end

    test "new content does not move an unfollowed view, but clamping still holds" do
      state = full_state(100)
      {state, nil} = State.handle_key(state, "page_up", [])
      offset = State.effective_scroll(state, 20)

      state = State.stream_message(state, {:entry, :system, "more"})
      assert State.effective_scroll(state, 20) == offset

      # shrink the viewport: the intent clamps to the new maximum
      assert State.effective_scroll(state, 10) <= 91
    end

    test "stale scroll intents clamp to content" do
      state = %{full_state(10) | scroll: 999, follow?: false}
      assert State.effective_scroll(state, 20) == 0
    end

    test "log_line_count counts display lines of multi-line entries" do
      state =
        new_state()
        |> State.stream_message({:entry, :system, "a\nb"})
        |> State.stream_message({:token, "c\nd"})

      assert State.log_line_count(state) == 4
    end
  end

  describe "task monitoring" do
    test "claim_task records the monitor ref" do
      ref = make_ref()
      state = new_state() |> State.claim_task(ref)
      assert state.task_ref == ref
    end

    test "a normal task DOWN finalizes a partial reply and ensures idle" do
      ref = make_ref()

      state =
        new_state()
        |> State.claim_task(ref)
        |> State.stream_message({:token, "partial"})

      {state, handled} = State.task_down(state, ref, :normal)
      assert handled == :handled
      assert state.phase == :idle
      assert state.task_ref == nil
      assert state.in_flight == nil
      assert {:assistant, "partial"} in state.entries
    end

    test "a :noproc DOWN (monitor attached after a fast exit) is a success" do
      ref = make_ref()

      state =
        new_state()
        |> State.claim_task(ref)
        |> State.stream_message({:phase, :idle})

      {state, handled} = State.task_down(state, ref, :noproc)
      assert handled == :handled
      assert state.phase == :idle
      assert state.entries == []
      assert state.task_ref == nil
    end

    test "an abnormal task DOWN degrades to idle with a system entry" do
      ref = make_ref()

      state =
        new_state()
        |> State.claim_task(ref)
        |> State.stream_message({:token, "partial reply"})

      {state, handled} = State.task_down(state, ref, :killed)
      assert handled == :handled
      assert state.task_ref == nil
      assert state.phase == :idle
      # the partial reply is kept as an assistant entry, then explained
      assert {:assistant, "partial reply"} in state.entries

      assert Enum.any?(state.entries, fn {kind, text} ->
               kind == :system and text =~ "stream failed"
             end)
    end

    test "a foreign DOWN ref is ignored" do
      state = new_state() |> State.claim_task(make_ref())
      {state, handled} = State.task_down(state, make_ref(), :killed)
      assert handled == :ignored
      assert state.phase == :idle
      assert state.entries == []
    end
  end

  describe "resize/3" do
    test "records the new size" do
      state = new_state() |> State.resize(120, 40)
      assert state.size == {120, 40}
    end

    test "degenerate sizes clamp to 1x1" do
      state = new_state() |> State.resize(0, -3)
      assert state.size == {1, 1}
    end
  end

  describe "paste/2" do
    test "inserts multi-line text at the cursor" do
      state = new_state() |> State.paste("line one\nline two")
      assert State.input_text(state) == "line one\nline two"
    end

    test "pasting while browsing history keeps the edited text as the draft" do
      base = new_state() |> idle_submit("prev")

      {state, nil} = State.handle_key(base, "up", [])
      state = State.paste(state, "pasted")
      assert state.history_index == nil
      assert State.input_text(state) == "prevpasted"

      {state, nil} = State.handle_key(state, "down", [])
      assert State.input_text(state) == "prevpasted"
    end
  end
end
