defmodule DashFloat.TUI.StateTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias DashFloat.TUI.State

  defp new_state(opts \\ []) do
    [test_mode: {80, 24}]
    |> Keyword.merge(opts)
    |> State.new()
  end

  defp type(state, text) do
    points = String.codepoints(text)

    Enum.reduce(points, state, fn c, acc ->
      {acc, nil} = State.handle_key(acc, c, [])
      acc
    end)
  end

  # Sends the key asserting it produces no action; returns the new state.
  defp press(state, code, modifiers) do
    {state, nil} = State.handle_key(state, code, modifiers)
    state
  end

  # Submits text and returns the state with the phase forced back to idle
  # (mid-stream submits are refused by design).
  defp idle_submit(state, text) do
    {state, action} =
      state
      |> type(text)
      |> State.handle_key("enter", [])

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
      assert {_state, :quit} = State.handle_key(new_state(), "c", ["ctrl"])
      assert {_state, :quit} = State.handle_key(new_state(), "q", ["ctrl"])
    end

    test "plain c and q type" do
      state = type(new_state(), "cq")
      assert State.input_text(state) == "cq"
    end
  end

  describe "handle_key/3 — enter semantics" do
    test "Enter submits the draft" do
      {state, action} =
        new_state()
        |> type("hello")
        |> State.handle_key("enter", [])

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
      state =
        new_state()
        |> type("one")
        |> press("enter", ["shift"])
        |> type("two")
        # cursor sits at the end, so Alt+Enter appends a trailing newline
        |> press("enter", ["alt"])

      assert State.input_text(state) == "one\ntwo\n"
      assert State.input_line_count(state) == 3
    end

    test "blank and whitespace-only drafts do not submit" do
      {empty, nil} = State.handle_key(new_state(), "enter", [])
      assert empty.entries == []

      {blank, nil} =
        new_state()
        |> type("  ")
        |> State.handle_key("enter", [])

      assert blank.entries == []
      assert blank.phase == :idle
    end

    test "submit is refused while a request is in flight" do
      streaming =
        new_state()
        |> idle_submit("first")
        # put ourselves back into a streaming phase
        |> Map.put(:phase, :streaming)
        |> type("second")

      {state, action} = State.handle_key(streaming, "enter", [])
      assert action == nil
      assert state.entries == [{:user, "first"}]
      assert State.input_text(state) == "second"
    end
  end

  describe "handle_key/3 — history-aware Up/Down" do
    test "Up on the first row enters history; Down on the last row leaves it" do
      base =
        new_state()
        |> idle_submit("one")
        |> idle_submit("two")

      {up_one, nil} = State.handle_key(base, "up", [])
      assert up_one.history_index == 0
      assert State.input_text(up_one) == "two"

      {up_two, nil} = State.handle_key(up_one, "up", [])
      assert up_two.history_index == 1
      assert State.input_text(up_two) == "one"

      {down_one, nil} = State.handle_key(up_two, "down", [])
      assert down_one.history_index == 0
      assert State.input_text(down_one) == "two"

      {down_two, nil} = State.handle_key(down_one, "down", [])
      assert down_two.history_index == nil
      assert State.input_text(down_two) == ""
    end

    test "the pre-navigation draft is restored" do
      base =
        new_state()
        |> idle_submit("kept")
        |> type("dra")

      {browsing, nil} = State.handle_key(base, "up", [])
      assert State.input_text(browsing) == "kept"

      {restored, nil} = State.handle_key(browsing, "down", [])
      assert State.input_text(restored) == "dra"
    end

    test "Up inside a multi-line draft moves the cursor, not history" do
      state =
        new_state()
        |> type("one")
        |> press("enter", ["shift"])
        |> type("two")
        |> press("up", [])

      assert state.history_index == nil
      assert State.input_text(state) == "one\ntwo"
    end

    test "Up with empty history is a no-op" do
      {state, nil} = State.handle_key(new_state(), "up", [])
      assert state.history_index == nil
    end

    test "Down at the last row with live draft is a no-op" do
      {state, nil} = State.handle_key(new_state(), "down", [])
      assert state.history_index == nil
    end

    test "editing while browsing history keeps the edited text as the draft" do
      base = idle_submit(new_state(), "prev")

      {browsing, nil} = State.handle_key(base, "up", [])
      assert State.input_text(browsing) == "prev"

      {edited, nil} = State.handle_key(browsing, "x", [])
      assert edited.history_index == nil
      assert State.input_text(edited) == "prevx"

      # Down no longer discards the edit
      {after_down, nil} = State.handle_key(edited, "down", [])
      assert State.input_text(after_down) == "prevx"
    end

    test "consecutive duplicate submits are not stored twice" do
      state =
        new_state()
        |> idle_submit("same")
        |> idle_submit("same")

      assert state.history == ["same"]
    end

    test "history is capped at 500 entries" do
      seeded = %{new_state() | history: Enum.map(1..500, &"h#{&1}")}
      {state, _action} = submit(seeded, "new")
      assert length(state.history) == 500
      assert List.last(state.history) == "new"
    end

    defp submit(state, text) do
      state
      |> type(text)
      |> State.handle_key("enter", [])
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

      idle = State.stream_message(state, {:phase, :idle})
      assert idle.phase == :idle
      assert idle.entries == [{:assistant, "one\ntwo"}]
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
      bogus = :bogus
      not_binary = :not_binary
      user = :user
      bad_phase = List.to_tuple([:phase, bogus])
      bad_token = List.to_tuple([:token, not_binary])
      bad_entry = List.to_tuple([:entry, user, "not allowed via messages"])

      assert_raise FunctionClauseError, fn ->
        State.stream_message(new_state(), bad_phase)
      end

      assert_raise FunctionClauseError, fn ->
        State.stream_message(new_state(), bad_token)
      end

      assert_raise FunctionClauseError, fn ->
        State.stream_message(new_state(), bad_entry)
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
      {state, nil} = State.handle_key(new_state(), "page_up", [])
      assert state.follow?
      assert State.effective_scroll(state, 20) == 0
    end

    test "page_up on a viewport-sized log is a no-op (stays pinned)" do
      base = full_state(20)
      {paged, nil} = State.handle_key(base, "page_up", [])
      assert paged.follow?
      assert State.effective_scroll(paged, 20) == 0
    end

    test "submit re-pins the log so the new reply is visible" do
      base = full_state(100)
      {paged, nil} = State.handle_key(base, "page_up", [])
      refute paged.follow?

      state = idle_submit(paged, "next question")
      assert state.follow?
      # 100 log lines + the new user entry = 101; bottom is 101 - 20
      assert State.effective_scroll(state, 20) == 81
    end

    test "follow pins to the bottom as content grows" do
      state = full_state(50)
      assert State.effective_scroll(state, 20) == 30
      grown = State.stream_message(state, {:entry, :system, "more"})
      assert State.effective_scroll(grown, 20) == 31
    end

    test "page_up unfollows and pages back; page_down re-pins at the bottom" do
      base = full_state(100)
      {up_one, nil} = State.handle_key(base, "page_up", [])
      refute up_one.follow?
      assert State.effective_scroll(up_one, 20) == 60

      {up_two, nil} = State.handle_key(up_one, "page_up", [])
      assert State.effective_scroll(up_two, 20) == 40

      {down_one, nil} = State.handle_key(up_two, "page_down", [])
      assert State.effective_scroll(down_one, 20) == 60

      {down_two, nil} = State.handle_key(down_one, "page_down", [])
      assert down_two.follow?
      assert State.effective_scroll(down_two, 20) == 80
    end

    test "new content does not move an unfollowed view, but clamping still holds" do
      base = full_state(100)
      {paged, nil} = State.handle_key(base, "page_up", [])
      offset = State.effective_scroll(paged, 20)

      grown = State.stream_message(paged, {:entry, :system, "more"})
      assert State.effective_scroll(grown, 20) == offset

      # shrink the viewport: the intent clamps to the new maximum
      assert State.effective_scroll(grown, 10) <= 91
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
      state = State.claim_task(new_state(), ref)
      assert state.task_ref == ref
    end

    test "a normal task DOWN finalizes a partial reply and ensures idle" do
      ref = make_ref()

      state =
        new_state()
        |> State.claim_task(ref)
        |> State.stream_message({:token, "partial"})

      {after_down, handled} = State.task_down(state, ref, :normal)
      assert handled == :handled
      assert after_down.phase == :idle
      assert after_down.task_ref == nil
      assert after_down.in_flight == nil
      assert {:assistant, "partial"} in after_down.entries
    end

    test "a :noproc DOWN (monitor attached after a fast exit) is a success" do
      ref = make_ref()

      state =
        new_state()
        |> State.claim_task(ref)
        |> State.stream_message({:phase, :idle})

      {after_down, handled} = State.task_down(state, ref, :noproc)
      assert handled == :handled
      assert after_down.phase == :idle
      assert after_down.entries == []
      assert after_down.task_ref == nil
    end

    test "an abnormal task DOWN degrades to idle with a system entry" do
      ref = make_ref()

      state =
        new_state()
        |> State.claim_task(ref)
        |> State.stream_message({:token, "partial reply"})

      {after_down, handled} = State.task_down(state, ref, :killed)
      assert handled == :handled
      assert after_down.task_ref == nil
      assert after_down.phase == :idle
      # the partial reply is kept as an assistant entry, then explained
      assert {:assistant, "partial reply"} in after_down.entries

      assert Enum.any?(after_down.entries, fn {kind, text} ->
               kind == :system and text =~ "stream failed"
             end)
    end

    test "a foreign DOWN ref is ignored" do
      state = State.claim_task(new_state(), make_ref())
      {after_down, handled} = State.task_down(state, make_ref(), :killed)
      assert handled == :ignored
      assert after_down.phase == :idle
      assert after_down.entries == []
    end
  end

  describe "resize/3" do
    test "records the new size" do
      state = State.resize(new_state(), 120, 40)
      assert state.size == {120, 40}
    end

    test "degenerate sizes clamp to 1x1" do
      state = State.resize(new_state(), 0, -3)
      assert state.size == {1, 1}
    end
  end

  describe "paste/2" do
    test "inserts multi-line text at the cursor" do
      state = State.paste(new_state(), "line one\nline two")
      assert State.input_text(state) == "line one\nline two"
    end

    test "pasting while browsing history keeps the edited text as the draft" do
      base = idle_submit(new_state(), "prev")

      {browsing, nil} = State.handle_key(base, "up", [])
      pasted = State.paste(browsing, "pasted")
      assert pasted.history_index == nil
      assert State.input_text(pasted) == "prevpasted"

      {after_down, nil} = State.handle_key(pasted, "down", [])
      assert State.input_text(after_down) == "prevpasted"
    end
  end
end
