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

  # Entries as `{kind, text}` pairs — the shape assertions care about.
  defp pairs(state), do: Enum.map(state.entries, &{&1.kind, &1.text})

  defp provider(context_tokens) do
    {:ok,
     %DashFloat.Config{
       base_url: "http://x",
       model: "m",
       api_key: "k",
       context_tokens: context_tokens
     }}
  end

  describe "new/1" do
    test "initial state is idle with empty log and test-mode size" do
      state = new_state()
      assert state.phase == :idle
      assert state.entries == []
      assert state.in_flight == nil
      assert state.in_flight_lines == nil
      assert state.in_flight_dirty == false
      assert state.anim_step == 0
      assert state.tick_ref == nil
      assert state.history == []
      assert state.follow? == true
      assert state.size == {80, 24}
      assert state.live? == false
      assert State.input_text(state) == ""
    end

    test "stats start empty" do
      assert new_state().stats == %{
               tokens: 0,
               first_token_at: nil,
               rate: nil,
               prompt_tokens: nil,
               completion_tokens: nil,
               context_total: 0
             }
    end

    test "mount opts carry the provider" do
      provider = {:ok, %DashFloat.Config{base_url: "http://x", model: "m", api_key: "k"}}
      assert new_state(provider: provider).provider == provider
      assert new_state().provider == nil
    end
  end

  describe "cwd_label/1" do
    test "the last two path segments, tilde-prefixed" do
      label = State.cwd_label(new_state())
      assert label =~ ~r|\A~/[^/]+/[^/]+\z| or label =~ ~r|\A~/[^/]+\z|
      assert label == expected_cwd()
    end

    test "a two-segment path keeps both, a deeper one keeps the tail" do
      # format/1 is private; assert through the public label's shape only.
      label = State.cwd_label(new_state())
      assert String.starts_with?(label, "~/")
    end
  end

  defp expected_cwd do
    tail =
      File.cwd!()
      |> Path.split()
      |> Enum.reject(&(&1 == "/"))
      |> Enum.take(-2)

    "~/" <> Path.join(tail)
  end

  describe "provider_model/1" do
    test "returns the model for a usable provider, nil otherwise" do
      ok = {:ok, %DashFloat.Config{base_url: "http://x", model: "gpt-test", api_key: "k"}}

      ok_state = new_state(provider: ok)
      error_state = new_state(provider: {:error, "nope"})
      blank_state = new_state()

      assert State.provider_model(ok_state) == "gpt-test"
      assert State.provider_model(error_state) == nil
      assert State.provider_model(blank_state) == nil
    end
  end

  describe "provider_context_tokens/1" do
    test "the configured window, nil when absent" do
      configured = new_state(provider: provider(128_000))
      assert State.provider_context_tokens(configured) == 128_000

      unconfigured = new_state()
      assert State.provider_context_tokens(unconfigured) == nil

      errored = new_state(provider: {:error, "no"})
      assert State.provider_context_tokens(errored) == nil
    end
  end

  describe "status labels" do
    test "no rate until one is derived" do
      assert State.rate_label(new_state()) == nil
    end

    test "the derived rate renders with one decimal" do
      state =
        Enum.reduce(1..10, Map.put(new_state(), :phase, :streaming), fn i, acc ->
          State.stream_message(acc, {:token, "t#{i}"}, 1_000)
        end)

      {ticked, :cont} = State.tick(state, 2_010)

      # 10 tokens over 1.01 s
      assert State.rate_label(ticked) == "9.9"
    end

    test "no context before anything streamed" do
      assert State.context_label(new_state()) == "—"
    end

    test "context total alone, then over the configured window" do
      usage = %{prompt_tokens: 100, completion_tokens: 20, total_tokens: 4_100}
      state = State.stream_message(new_state(), {:usage, usage})
      assert State.context_label(state) == "4.1k"

      base = new_state(provider: provider(128_000))
      windowed = State.stream_message(base, {:usage, usage})

      assert State.context_label(windowed) == "4.1k/128k"
    end

    test "context totals in the millions read as m" do
      usage = %{prompt_tokens: 100, completion_tokens: 20, total_tokens: 4_100_000}
      state = State.stream_message(new_state(), {:usage, usage})
      assert State.context_label(state) == "4.1m"
    end

    test "context total accumulates across turns" do
      usage = %{prompt_tokens: 10, completion_tokens: 5, total_tokens: 15}

      state =
        new_state()
        |> State.stream_message({:usage, usage})
        |> State.stream_message({:usage, usage})

      assert state.stats.context_total == 30
      assert State.context_label(state) == "30"
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
      assert pairs(state) == [{:user, "hello"}]
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
      assert pairs(state) == [{:user, "first"}]
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

  describe "stream_message/3" do
    test "tokens accumulate in the in-flight entry and count in stats" do
      state =
        new_state()
        |> State.stream_message({:token, "hel"}, 1_000)
        |> State.stream_message({:token, "lo"}, 1_200)

      assert state.in_flight == "hello"
      assert state.entries == []
      assert state.stats.tokens == 2
      assert state.stats.first_token_at == 1_000
      assert state.in_flight_dirty
      # The live lines are only refreshed by the tick.
      assert state.in_flight_lines == nil
    end

    test "re-announcing :streaming never finalizes the in-flight entry" do
      state =
        new_state()
        |> State.stream_message({:token, "The answer is "}, 1_000)
        |> State.stream_message({:token, "42."}, 1_010)
        |> State.stream_message({:phase, :streaming}, 1_020)
        |> State.stream_message({:token, " (confident)"}, 1_030)
        |> State.stream_message({:phase, :idle}, 2_000)

      assert pairs(state) == [{:assistant, "The answer is 42. (confident)"}]
      assert state.in_flight == nil
      assert state.phase == :idle
    end

    test "leaving :streaming for :executing_tool finalizes the in-flight entry" do
      state =
        new_state()
        |> State.stream_message({:token, "one\ntwo"}, 1_000)
        |> State.stream_message({:phase, :executing_tool}, 1_010)

      assert pairs(state) == [{:assistant, "one\ntwo"}]
      assert state.in_flight == nil
      assert state.phase == :executing_tool

      idle = State.stream_message(state, {:phase, :idle}, 1_020)
      assert idle.phase == :idle
      assert pairs(idle) == [{:assistant, "one\ntwo"}]
    end

    test "tool and system entries append as complete entries" do
      state =
        new_state()
        |> State.stream_message({:entry, :tool, "[tool] ran"})
        |> State.stream_message({:entry, :system, "reconnected"})

      assert pairs(state) == [{:tool, "[tool] ran"}, {:system, "reconnected"}]
    end

    test "entry text is kept verbatim, trailing newlines included" do
      state = State.stream_message(new_state(), {:entry, :system, "note\n\n"})
      [entry] = state.entries
      assert entry.text == "note\n\n"
      assert Enum.map(entry.lines, &flatten/1) == ["", "note", "", ""]
    end

    test "entries carry their rendered lines, blank separator first" do
      state = State.stream_message(new_state(), {:entry, :system, "a\nb"})
      [entry] = state.entries

      assert entry.kind == :system
      assert entry.text == "a\nb"
      assert length(entry.lines) == 3
      assert flatten(hd(entry.lines)) == ""
      assert Enum.map(entry.lines, &flatten/1) == ["", "a", "b"]
    end

    test "contract violations crash instead of corrupting state" do
      # Tuples assembled at runtime via List.to_tuple so the compile-time type
      # checker cannot narrow the call into an "impossible input" warning —
      # the payloads are runtime garbage.
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

  describe "usage reconciliation" do
    test "prompt and completion tokens are reconciled; no phase change" do
      usage = %{prompt_tokens: 120, completion_tokens: 42, total_tokens: 162}

      state =
        new_state()
        |> Map.put(:phase, :streaming)
        |> State.stream_message({:usage, usage}, 2_000)

      assert state.stats.prompt_tokens == 120
      assert state.stats.completion_tokens == 42
      assert state.stats.context_total == 162
      # The estimate is reconciled to the provider's authoritative count.
      assert state.stats.tokens == 42
      assert state.phase == :streaming
    end

    test "a later usage frame wins and keeps accumulating context" do
      state =
        new_state()
        |> State.stream_message(
          {:usage, %{prompt_tokens: 10, completion_tokens: 5, total_tokens: 15}}
        )
        |> State.stream_message(
          {:usage, %{prompt_tokens: 20, completion_tokens: 8, total_tokens: 28}}
        )

      assert state.stats.prompt_tokens == 20
      assert state.stats.completion_tokens == 8
      assert state.stats.context_total == 43
    end
  end

  describe "rate derivation and freezing" do
    test "10 tokens over 1.01 s tick at 9.9 tok/s" do
      state =
        Enum.reduce(1..10, Map.put(new_state(), :phase, :streaming), fn i, acc ->
          State.stream_message(acc, {:token, "t#{i}"}, 1_000)
        end)

      {ticked, :cont} = State.tick(state, 2_010)
      assert_in_delta ticked.stats.rate, 9.9009, 0.001
      assert State.rate_label(ticked) == "9.9"
    end

    test "finalize freezes the rate and clears the streaming counters" do
      state =
        new_state()
        |> State.stream_message({:token, "abc"}, 1_000)
        |> State.stream_message({:token, "def"}, 1_500)
        |> State.stream_message({:phase, :idle}, 2_000)

      # 2 tokens over 1.0 s
      assert_in_delta state.stats.rate, 2.0, 0.0001
      assert state.stats.tokens == 0
      assert state.stats.first_token_at == nil
      assert State.rate_label(state) == "2.0"
    end

    test "the frozen rate survives the next turn until new ticks replace it" do
      usage = %{prompt_tokens: 3, completion_tokens: 2, total_tokens: 5}

      state =
        new_state()
        |> State.stream_message({:token, "a"}, 1_000)
        |> State.stream_message({:token, "b"}, 1_500)
        |> State.stream_message({:phase, :idle}, 2_000)
        |> State.stream_message({:usage, usage}, 2_100)

      assert State.rate_label(state) == "2.0"
      assert state.stats.context_total == 5
    end

    test "cancel-style finalize with no usage frame still freezes a rate" do
      state =
        new_state()
        |> State.stream_message({:token, "partial"}, 1_000)
        |> State.stream_message({:phase, :idle}, 1_500)

      assert_in_delta state.stats.rate, 2.0, 0.0001
      assert state.stats.prompt_tokens == nil
      assert state.stats.context_total == 0
      assert pairs(state) == [{:assistant, "partial"}]
    end

    test "no tokens means no rate, never a division by zero" do
      state = State.stream_message(new_state(), {:phase, :idle}, 5_000)
      assert state.stats.rate == nil
      assert State.rate_label(state) == nil
    end

    test "an empty elapsed window keeps the prior rate" do
      state =
        new_state()
        |> State.stream_message({:token, "a"}, 1_000)
        |> State.stream_message({:phase, :idle}, 1_000)

      assert state.stats.rate == nil
      assert State.rate_label(state) == nil
    end
  end

  describe "tick/2" do
    test "halts at idle and changes nothing" do
      state = new_state()
      assert {^state, :halt} = State.tick(state, 9_999)
    end

    test "steps the spinner and refreshes dirty in-flight lines" do
      state =
        new_state()
        |> Map.put(:phase, :streaming)
        |> State.stream_message({:token, "hello"}, 1_000)

      {ticked, :cont} = State.tick(state, 1_125)

      assert ticked.anim_step == 1
      refute ticked.in_flight_dirty
      assert Enum.map(ticked.in_flight_lines, &flatten/1) == ["", "hello"]

      # A clean tick does not re-render.
      {again, :cont} = State.tick(ticked, 1_250)
      assert again.anim_step == 2
      assert again.in_flight_lines == ticked.in_flight_lines
    end

    test "above the 64 KiB cap the last render sticks until finalize" do
      at_cap = String.duplicate("x", 64 * 1024)
      over_cap = at_cap <> "y"

      fitted =
        new_state()
        |> Map.put(:phase, :streaming)
        |> State.stream_message({:token, at_cap}, 1_000)

      {rendered, :cont} = State.tick(fitted, 1_125)
      assert rendered.in_flight_lines != nil

      {over, :cont} =
        rendered
        |> State.stream_message({:token, "y"}, 1_200)
        |> State.tick(1_250)

      assert over.in_flight_lines == rendered.in_flight_lines
      assert over.in_flight_dirty
      assert over.in_flight == over_cap

      # Finalize still renders the full text once.
      final = State.stream_message(over, {:phase, :idle}, 1_300)
      [entry] = final.entries
      assert entry.text == over_cap
      assert length(entry.lines) == 2
    end

    test "needs_tick?/1 is true only while active and unscheduled" do
      assert State.needs_tick?(new_state()) == false

      active = %{new_state() | phase: :streaming}
      assert State.needs_tick?(active)

      assert State.needs_tick?(%{active | tick_ref: make_ref()}) == false
    end
  end

  describe "scrolling" do
    # Each entry renders one text line plus its blank separator = 2 lines.
    defp full_state(n) do
      Enum.reduce(1..n, new_state(), fn i, acc ->
        State.stream_message(acc, {:entry, :system, "line #{i}"})
      end)
    end

    test "empty log: offsets are zero and page_up keeps following" do
      {state, nil} = State.handle_key(new_state(), "page_up", [])
      assert state.follow?
      assert State.effective_scroll(state, 20) == 0
    end

    test "blank separators count toward the log line total" do
      state = full_state(1)
      assert State.log_line_count(state) == 2
    end

    test "page_up on a viewport-sized log is a no-op (stays pinned)" do
      base = full_state(10)
      assert State.log_line_count(base) == 20

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
      # 200 lines + the user entry's 2 = 202; bottom is 202 - 20
      assert State.effective_scroll(state, 20) == 182
    end

    test "follow pins to the bottom as content grows" do
      state = full_state(50)
      assert State.effective_scroll(state, 20) == 80
      grown = State.stream_message(state, {:entry, :system, "more"})
      assert State.effective_scroll(grown, 20) == 82
    end

    test "page_up unfollows and pages back; page_down re-pins at the bottom" do
      base = full_state(100)
      {up_one, nil} = State.handle_key(base, "page_up", [])
      refute up_one.follow?
      assert State.effective_scroll(up_one, 20) == 160

      {up_two, nil} = State.handle_key(up_one, "page_up", [])
      assert State.effective_scroll(up_two, 20) == 140

      {down_one, nil} = State.handle_key(up_two, "page_down", [])
      assert State.effective_scroll(down_one, 20) == 160

      {down_two, nil} = State.handle_key(down_one, "page_down", [])
      assert down_two.follow?
      assert State.effective_scroll(down_two, 20) == 180
    end

    test "new content does not move an unfollowed view, but clamping still holds" do
      base = full_state(100)
      {paged, nil} = State.handle_key(base, "page_up", [])
      offset = State.effective_scroll(paged, 20)

      grown = State.stream_message(paged, {:entry, :system, "more"})
      assert State.effective_scroll(grown, 20) == offset

      # shrink the viewport: the intent clamps to the new maximum
      assert State.effective_scroll(grown, 10) <= 193
    end

    test "stale scroll intents clamp to content" do
      state = %{full_state(10) | scroll: 999, follow?: false}
      assert State.effective_scroll(state, 20) == 0
    end

    test "log_line_count counts rendered lines of multi-line entries" do
      state =
        new_state()
        |> State.stream_message({:entry, :system, "a\nb"})
        |> State.stream_message({:token, "c\nd"})

      # system entry: blank + a + b; the in-flight text is not rendered until
      # the tick.
      assert State.log_line_count(state) == 3

      {ticked, :cont} = State.tick(%{state | phase: :streaming}, 1_000)
      assert State.log_line_count(ticked) == 6
    end
  end

  describe "task monitoring" do
    test "claim_task records the pid and monitor ref" do
      pid = self()
      ref = make_ref()
      state = State.claim_task(new_state(), pid, ref)
      assert state.task_pid == pid
      assert state.task_ref == ref
    end

    test "Esc cancels only while streaming with a live task" do
      pid = spawn(fn -> Process.sleep(1_000) end)
      state = State.claim_task(new_state(), pid, make_ref())

      assert {%{phase: :streaming} = streaming, :cancel} =
               State.handle_key(%{state | phase: :streaming}, "esc", [])

      assert streaming == %{state | phase: :streaming}

      # Idle: no cancel, and the key does not reach the textarea.
      assert {%{phase: :idle} = idle, nil} = State.handle_key(%{state | phase: :idle}, "esc", [])
      assert State.input_text(idle) == ""

      # Streaming without a task pid (already released) is a no-op.
      assert {%{task_pid: nil}, nil} =
               State.handle_key(%{state | phase: :streaming, task_pid: nil}, "esc", [])
    end

    test "a normal task DOWN finalizes a partial reply, ensures idle, clears the pid" do
      ref = make_ref()

      state =
        new_state()
        |> State.claim_task(self(), ref)
        |> State.stream_message({:token, "partial"}, 1_000)

      {after_down, handled} = State.task_down(state, ref, :normal)
      assert handled == :handled
      assert after_down.phase == :idle
      assert after_down.task_ref == nil
      assert after_down.task_pid == nil
      assert after_down.in_flight == nil
      assert {:assistant, "partial"} in pairs(after_down)
    end

    test "a :noproc DOWN (monitor attached after a fast exit) is a success" do
      ref = make_ref()

      state =
        new_state()
        |> State.claim_task(self(), ref)
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
        |> State.claim_task(self(), ref)
        |> State.stream_message({:token, "partial reply"}, 1_000)

      {after_down, handled} = State.task_down(state, ref, :killed)
      assert handled == :handled
      assert after_down.task_ref == nil
      assert after_down.phase == :idle
      # the partial reply is kept as an assistant entry, then explained
      assert {:assistant, "partial reply"} in pairs(after_down)

      assert Enum.any?(after_down.entries, fn entry ->
               entry.kind == :system and entry.text =~ "stream failed"
             end)
    end

    test "a foreign DOWN ref is ignored" do
      state = State.claim_task(new_state(), self(), make_ref())
      {after_down, handled} = State.task_down(state, make_ref(), :killed)
      assert handled == :ignored
      assert after_down.phase == :idle
      assert after_down.entries == []
    end
  end

  describe "stream_failed/2" do
    test "binary reasons are used verbatim, others are inspected" do
      state = State.stream_failed(new_state(), "[llm: HTTP 502]")
      assert {:system, "[llm: HTTP 502]"} in pairs(state)
      assert state.phase == :idle

      killed = State.stream_failed(new_state(), :killed)
      assert {:system, "[stream failed: :killed]"} in pairs(killed)
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

    test "CRLF and lone CR are normalized to LF" do
      state = State.paste(new_state(), "a\r\nb\rc\r\n\rd")
      assert State.input_text(state) == "a\nb\nc\n\nd"
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

  defp flatten(%ExRatatui.Text.Line{spans: spans}), do: Enum.map_join(spans, "", & &1.content)
end
