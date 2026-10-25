defmodule DashFloat.TUI.StateTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias DashFloat.TUI.Render
  alias DashFloat.TUI.State
  alias DashFloat.TUI.View

  defp new_state(opts \\ []) do
    [test_mode: {80, 24}]
    |> Keyword.merge(opts)
    |> State.new()
  end

  # One completed stream turn carrying `usage` (banked at finalize).
  defp bank_usage(state, usage) do
    state
    |> Map.put(:phase, :streaming)
    |> State.stream_message({:usage, usage}, 1_000)
    |> State.stream_message({:phase, :idle}, 2_000)
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
      assert state.agent_ref == nil
      assert state.confirm == nil
      assert State.input_text(state) == ""
    end

    test "stats start empty" do
      assert new_state().stats == %{
               tokens: 0,
               first_token_at: nil,
               rate: nil,
               prompt_tokens: nil,
               completion_tokens: nil,
               context_total: 0,
               turn_total: nil
             }
    end

    test "mount opts carry the provider; the agent defaults to the name" do
      provider = {:ok, %DashFloat.Config{base_url: "http://x", model: "m", api_key: "k"}}
      assert new_state(provider: provider).provider == provider
      assert new_state().provider == nil
      assert new_state().agent == DashFloat.Agent
      assert new_state(agent: self()).agent == self()
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

  describe "provider_label/1" do
    test "nickname and profile compose as \"nickname (profile)\"" do
      provider =
        {:ok,
         %DashFloat.Config{
           base_url: "http://x",
           model: "glm-5.3",
           api_key: "k",
           nickname: "Sol",
           profile: "work"
         }}

      state = new_state(provider: provider)
      assert State.provider_label(state) == "Sol (work)"
    end

    test "falls back to the bare nickname without a profile, then the model id" do
      nickname_only =
        {:ok,
         %DashFloat.Config{base_url: "http://x", model: "glm-5.3", api_key: "k", nickname: "Sol"}}

      model_only = {:ok, %DashFloat.Config{base_url: "http://x", model: "glm-5.3", api_key: "k"}}

      nickname_state = new_state(provider: nickname_only)
      model_state = new_state(provider: model_only)
      assert State.provider_label(nickname_state) == "Sol"
      assert State.provider_label(model_state) == "glm-5.3"
    end

    test "nil for an error provider, no provider, or a provider with no names" do
      error_state = new_state(provider: {:error, "nope"})
      blank_state = new_state()
      # A Config with neither nickname nor model (hand-made, e.g. an
      # env-only shape) has no label — the view's placeholder takes over.
      nameless = new_state(provider: {:ok, %DashFloat.Config{base_url: "http://x", api_key: "k"}})
      assert State.provider_label(error_state) == nil
      assert State.provider_label(blank_state) == nil
      assert State.provider_label(nameless) == nil
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
      state = bank_usage(new_state(), usage)
      assert State.context_label(state) == "4.1k"

      base = bank_usage(new_state(provider: provider(128_000)), usage)
      assert State.context_label(base) == "4.1k/128k"
    end

    test "context totals in the millions read as m, in the billions b" do
      usage = %{prompt_tokens: 100, completion_tokens: 20, total_tokens: 4_100_000}
      state = bank_usage(new_state(), usage)
      assert State.context_label(state) == "4.1m"

      big =
        bank_usage(new_state(), %{
          prompt_tokens: 1,
          completion_tokens: 1,
          total_tokens: 2_500_000_000
        })

      assert State.context_label(big) == "2.5b"
    end

    test "humanize boundaries roll into the next unit" do
      # 999_999 rounds up and reads "1m", never "1000k".
      assert new_state()
             |> bank_usage(%{prompt_tokens: 1, completion_tokens: 1, total_tokens: 999_999})
             |> State.context_label() ==
               "1m"

      assert new_state()
             |> bank_usage(%{prompt_tokens: 1, completion_tokens: 1, total_tokens: 999})
             |> State.context_label() ==
               "999"
    end

    test "context total accumulates across turns" do
      usage = %{prompt_tokens: 10, completion_tokens: 5, total_tokens: 15}

      state =
        new_state()
        |> bank_usage(usage)
        |> bank_usage(usage)

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

  describe "handle_key/3 — confirmation mode" do
    defp confirming do
      ref = make_ref()

      {State.stream_message(new_state(), {:confirm, ref, confirm_request(["+ x"])}), ref}
    end

    test "Enter and Ctrl+Enter approve; Esc rejects — both carry no state change" do
      {state, _ref} = confirming()

      assert {^state, {:confirm, :approved}} = State.handle_key(state, "enter", [])
      assert {^state, {:confirm, :approved}} = State.handle_key(state, "enter", ["ctrl"])
      assert {^state, {:confirm, :rejected}} = State.handle_key(state, "esc", [])
    end

    test "quit keys still quit mid-decision" do
      {state, _ref} = confirming()
      assert {_state, :quit} = State.handle_key(state, "q", ["ctrl"])
      assert {_state, :quit} = State.handle_key(state, "c", ["ctrl"])
    end

    test "every other key is swallowed — nothing reaches the textarea" do
      {state, _ref} = confirming()

      for {code, mods} <- [
            {"x", []},
            {"enter", ["shift"]},
            {"enter", ["alt"]},
            {"up", []},
            {"page_up", []}
          ] do
        {^state, nil} = State.handle_key(state, code, mods)
      end

      assert State.input_text(state) == ""
    end

    test "confirm_decided clears the confirm; the phase waits for the agent" do
      {state, _ref} = confirming()
      decided = State.confirm_decided(state)

      assert decided.confirm == nil
      assert decided.phase == :confirming

      # After the decision the keys route normally again (no swallowing,
      # no cancel — the gap is one mailbox hop).
      {gap, nil} = State.handle_key(decided, "esc", [])
      assert gap == decided

      {typed, nil} = State.handle_key(decided, "x", [])
      assert State.input_text(typed) == "x"
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

    test "tool_call appends a gear row summarizing the path argument" do
      state =
        State.stream_message(
          new_state(),
          {:tool_call, %{id: "t1", name: "read_file", args: %{"path" => "lib/foo.ex"}}}
        )

      [entry] = state.entries
      assert entry.kind == :tool
      assert entry.text == "⚙ read_file lib/foo.ex"
      assert Enum.map(entry.lines, &flatten/1) == ["", "⚙ read_file lib/foo.ex"]
    end

    test "tool_call summarizes execute_command by its command; bare name without either" do
      cmd =
        State.stream_message(
          new_state(),
          {:tool_call, %{id: "t2", name: "execute_command", args: %{"command" => "mix test"}}}
        )

      assert pairs(cmd) == [{:tool, "⚙ execute_command mix test"}]

      bare =
        State.stream_message(new_state(), {:tool_call, %{id: "t3", name: "list_dir", args: %{}}})

      assert pairs(bare) == [{:tool, "⚙ list_dir"}]
    end

    test "tool_result appends the status row with dim, indented, verbatim output" do
      state =
        State.stream_message(
          new_state(),
          {:tool_result,
           %{id: "t1", name: "read_file", ok: true, status: "ok", output: "line one\nline two"}}
        )

      [entry] = state.entries
      assert entry.kind == :tool
      assert entry.text == "⚙ read_file → ok\nline one\nline two"

      assert Enum.map(entry.lines, &flatten/1) == [
               "",
               "⚙ read_file → ok",
               "  line one",
               "  line two"
             ]
    end

    test "tool_result without output is a single row" do
      state =
        State.stream_message(
          new_state(),
          {:tool_result,
           %{id: "t1", name: "write_file", ok: false, status: "rejected", output: nil}}
        )

      [entry] = state.entries
      assert entry.text == "⚙ write_file → rejected"
      assert Enum.map(entry.lines, &flatten/1) == ["", "⚙ write_file → rejected"]
    end

    test "confirm appends the preview entry, arms the decision, flips to :confirming" do
      ref = make_ref()

      state =
        State.stream_message(
          new_state(),
          {:confirm, ref,
           %{
             id: "c1",
             name: "write_file",
             args: %{"path" => "a.ex"},
             lines: ["@@ -1 +1 @@", "- old", "+ new", "$ mix format"]
           }}
        )

      [entry] = state.entries
      assert entry.kind == :tool
      assert entry.text == "@@ -1 +1 @@\n- old\n+ new\n$ mix format"
      assert length(entry.lines) == 5
      assert state.confirm == %{ref: ref, id: "c1", name: "write_file"}
      assert state.phase == :confirming
    end

    test ":confirming is an active phase: it ticks and steps the spinner" do
      state =
        State.stream_message(new_state(), {:confirm, make_ref(), confirm_request(["+ x"])})

      assert State.needs_tick?(state)

      {ticked, :cont} = State.tick(state, 1_000)
      assert ticked.anim_step == 1
    end

    defp confirm_request(lines), do: %{id: "c", name: "write_file", args: %{}, lines: lines}

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
      # The turn's total is banked, not yet accumulated — per-chunk usage
      # reporters send running totals, so only the last frame may count.
      assert state.stats.turn_total == 162
      assert state.stats.context_total == 0
      # The estimate is reconciled to the provider's authoritative count.
      assert state.stats.tokens == 42
      assert state.phase == :streaming
    end

    test "a later usage frame wins; the turn banks once at finalize, then accumulates" do
      turn_one =
        new_state()
        |> Map.put(:phase, :streaming)
        |> State.stream_message(
          {:usage, %{prompt_tokens: 10, completion_tokens: 5, total_tokens: 15}}
        )
        |> State.stream_message(
          {:usage, %{prompt_tokens: 20, completion_tokens: 8, total_tokens: 28}}
        )

      assert turn_one.stats.prompt_tokens == 20
      assert turn_one.stats.turn_total == 28

      idle = State.stream_message(turn_one, {:phase, :idle}, 3_000)
      assert idle.stats.context_total == 28
      assert idle.stats.turn_total == nil

      # The next turn adds its own final total, whatever its provider's
      # reporting cadence.
      turn_two =
        idle
        |> Map.put(:phase, :streaming)
        |> State.stream_message(
          {:usage, %{prompt_tokens: 30, completion_tokens: 10, total_tokens: 10}}
        )

      assert State.stream_message(turn_two, {:phase, :idle}, 5_000).stats.context_total == 38
    end

    test "a usage frame after the turn finalized is ignored" do
      state =
        new_state()
        |> Map.put(:phase, :streaming)
        |> State.stream_message({:token, "t"}, 1_000)
        |> State.stream_message({:phase, :idle}, 2_000)

      late =
        State.stream_message(
          state,
          {:usage, %{prompt_tokens: 500, completion_tokens: 500, total_tokens: 1_000}},
          2_500
        )

      # Nothing from the finished turn may poison the next one's rate math.
      assert late.stats.tokens == 0
      assert late.stats.context_total == 0
      assert late.stats.turn_total == nil
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
        |> Map.put(:phase, :streaming)
        |> State.stream_message({:token, "a"}, 1_000)
        |> State.stream_message({:token, "b"}, 1_500)
        |> State.stream_message({:usage, usage}, 1_800)
        |> State.stream_message({:phase, :idle}, 2_000)

      assert State.rate_label(state) == "2.0"
      assert state.stats.context_total == 5

      # A usage frame arriving after the turn ended belongs to nobody.
      late = State.stream_message(state, {:usage, usage}, 2_100)
      assert late.stats.context_total == 5
      assert State.rate_label(late) == "2.0"
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

      # Finalize still renders the full text once — wrapped to the width.
      final = State.stream_message(over, {:phase, :idle}, 1_300)
      [entry] = final.entries
      assert entry.text == over_cap
      # blank separator + 64 KiB + 1 of x's at 78 columns (the padded width)
      # = 841 display rows
      assert length(entry.lines) == 1 + div(64 * 1024, 78) + 1
    end

    test "needs_tick?/1 is true only while active and unscheduled" do
      assert State.needs_tick?(new_state()) == false

      active = %{new_state() | phase: :streaming}
      assert State.needs_tick?(active)
      assert State.needs_tick?(%{new_state() | phase: :confirming})

      assert State.needs_tick?(%{active | tick_ref: make_ref()}) == false
    end

    # Regression (hostile review P1-3): wrapping an unbreakable run used to
    # re-measure the whole remainder per row (quadratic); a CJK reply near
    # the live cap drove one tick to 1.6 s — 13x the 125 ms tick budget.
    # The wrap is single-pass now; this guards the tick well inside budget.
    test "a tick wrapping a large unbreakable CJK reply stays well under budget" do
      cjk = String.duplicate("日本語の長い返事が続きます。", 1_500)

      state =
        new_state()
        |> Map.put(:phase, :streaming)
        |> State.stream_message({:token, cjk}, 1_000)

      {micros, {ticked, :cont}} = :timer.tc(State, :tick, [state, 1_100])
      assert div(micros, 1000) < 400
      assert State.log_line_count(ticked) > 100
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
      # The real idle viewport at 80x24 is 18 rows with the margin (issue #28);
      # 9 entries = blank + line each = exactly one viewport.
      base = full_state(9)
      assert State.log_line_count(base) == 18

      {paged, nil} = State.handle_key(base, "page_up", [])
      assert paged.follow?
      assert State.effective_scroll(paged, 18) == 0
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
      # 200 lines, 18-row viewport (the padded 80x24 layout) → bottom 182.
      base = full_state(100)
      {up_one, nil} = State.handle_key(base, "page_up", [])
      refute up_one.follow?
      assert State.effective_scroll(up_one, 18) == 164

      {up_two, nil} = State.handle_key(up_one, "page_up", [])
      assert State.effective_scroll(up_two, 18) == 146

      {down_one, nil} = State.handle_key(up_two, "page_down", [])
      assert State.effective_scroll(down_one, 18) == 164

      {down_two, nil} = State.handle_key(down_one, "page_down", [])
      assert down_two.follow?
      assert State.effective_scroll(down_two, 18) == 182
    end

    test "wheel_scroll: one notch is three lines; up unfollows, down re-pins at the bottom" do
      base = full_state(100)
      assert State.effective_scroll(base, 18) == 182

      wheeled = State.wheel_scroll(base, :up)
      refute wheeled.follow?
      assert State.effective_scroll(wheeled, 18) == 179

      again = State.wheel_scroll(wheeled, :up)
      assert State.effective_scroll(again, 18) == 176

      down = State.wheel_scroll(again, :down)
      refute down.follow?
      assert State.effective_scroll(down, 18) == 179

      pinned = State.wheel_scroll(down, :down)
      assert pinned.follow?
      assert State.effective_scroll(pinned, 18) == 182
    end

    test "wheel up on a viewport-sized log is a no-op (stays pinned)" do
      base = full_state(9)
      assert State.log_line_count(base) == 18
      assert State.wheel_scroll(base, :up) == base
    end

    test "wheel scrolling stays live while a confirm is pending (focus-free)" do
      base = full_state(100)

      state =
        State.stream_message(
          base,
          {:confirm, make_ref(), %{id: "c", name: "w", args: %{}, lines: ["+ x"]}}
        )

      assert state.phase == :confirming

      # The activity row is up while confirming: the viewport is 17 rows.
      bottom = State.effective_scroll(state, 17)
      wheeled = State.wheel_scroll(state, :up)
      refute wheeled.follow?
      assert State.effective_scroll(wheeled, 17) == bottom - 3
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

  describe "agent monitoring" do
    test "claim_agent stores the monitor ref" do
      base = new_state(agent: self())
      state = State.claim_agent(base)
      assert is_reference(state.agent_ref)
      Process.demonitor(state.agent_ref)
    end

    test "Esc cancels while streaming or executing a tool; a no-op otherwise" do
      streaming = %{new_state() | phase: :streaming}
      assert {^streaming, :cancel} = State.handle_key(streaming, "esc", [])

      tool = %{new_state() | phase: :executing_tool}
      assert {^tool, :cancel} = State.handle_key(tool, "esc", [])

      # Idle (and the post-decision confirming gap): no cancel, and the key
      # does not reach the textarea.
      assert {%{phase: :idle} = idle, nil} = State.handle_key(new_state(), "esc", [])
      assert State.input_text(idle) == ""

      gap = %{new_state() | phase: :confirming}
      assert {^gap, nil} = State.handle_key(gap, "esc", [])
    end

    test "a normal agent DOWN finalizes a partial reply, ensures idle, clears the ref" do
      ref = make_ref()

      state =
        new_state()
        |> Map.put(:agent_ref, ref)
        |> State.stream_message({:token, "partial"}, 1_000)

      {after_down, handled} = State.agent_down(state, ref, :normal)
      assert handled == :handled
      assert after_down.phase == :idle
      assert after_down.agent_ref == nil
      assert after_down.in_flight == nil
      assert {:assistant, "partial"} in pairs(after_down)
    end

    test "a :noproc DOWN (monitor attached to an already-dead name) is a success" do
      ref = make_ref()
      state = %{new_state() | agent_ref: ref}

      {after_down, handled} = State.agent_down(state, ref, :noproc)
      assert handled == :handled
      assert after_down.phase == :idle
      assert after_down.entries == []
      assert after_down.agent_ref == nil
    end

    test "an abnormal agent DOWN degrades to idle with an [agent failed] entry" do
      ref = make_ref()

      state =
        new_state()
        |> Map.put(:agent_ref, ref)
        |> State.stream_message({:token, "partial reply"}, 1_000)

      {after_down, handled} = State.agent_down(state, ref, :killed)
      assert handled == :handled
      assert after_down.agent_ref == nil
      assert after_down.phase == :idle

      # the partial reply is kept as an assistant entry, then explained
      assert {:assistant, "partial reply"} in pairs(after_down)
      assert {:system, "[agent failed: :killed]"} in pairs(after_down)
    end

    test "an agent DOWN mid-confirm disarms the modal so input keeps working" do
      ref = make_ref()

      state =
        new_state()
        |> Map.put(:agent_ref, ref)
        |> State.stream_message({:confirm, make_ref(), confirm_request(["+ x"])})

      assert state.confirm != nil

      {after_down, :handled} = State.agent_down(state, ref, :killed)
      assert after_down.confirm == nil
      assert after_down.phase == :idle

      # A phase transition alone (no agent death, no decision) disarms too.
      armed = State.stream_message(new_state(), {:confirm, make_ref(), confirm_request(["+ y"])})
      retired = State.stream_message(armed, {:phase, :idle})
      assert retired.confirm == nil
      assert retired.phase == :idle
    end

    test "the failure entry inspects the reason to a 120-char slice" do
      reason = {:boom, String.duplicate("x", 300)}
      state = %{new_state() | agent_ref: make_ref()}

      {after_down, :handled} = State.agent_down(state, state.agent_ref, reason)

      expected = "[agent failed: #{String.slice(inspect(reason), 0, 120)}]"
      assert {:system, expected} in pairs(after_down)
      assert String.length(expected) == 120 + String.length("[agent failed: ]")
    end

    test "a foreign DOWN ref is ignored" do
      state = %{new_state() | agent_ref: make_ref()}
      {after_down, handled} = State.agent_down(state, make_ref(), :killed)
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

    test "a whitespace run overflowing an empty row drops without a phantom blank" do
      # Regression (review N2): marking an empty row full used to push a
      # blank display row and inflate the log count.
      base = new_state(test_mode: {10, 24})
      text = String.duplicate(" ", 24) <> "x = 1"
      state = State.stream_message(base, {:entry, :system, text})

      [entry] = state.entries

      assert Enum.map(entry.lines, &flatten/1) == ["", "x = 1"]
      assert State.log_line_count(state) == 2
    end

    test "entries re-wrap to the new width without losing text" do
      text = "the quick brown fox jumps over the lazy dog"

      state =
        new_state()
        |> State.stream_message({:entry, :system, text})
        |> State.resize(20, 24)

      [entry] = state.entries
      assert entry.text == text

      # One logical line becomes wrapped display rows, blank separator first;
      # every word survives the wrap (spaces at break points are dropped by
      # design — comparing word sequences, not raw concatenation).
      pieces = Enum.map(entry.lines, &flatten/1)
      assert hd(pieces) == ""

      assert_words_survive(pieces, text)
      assert Enum.all?(tl(pieces), &(&1 == "" or String.length(&1) <= 18))
    end

    test "re-wrapping is exact in both directions" do
      text = Enum.map_join(1..15, fn _i -> "word " end)

      state =
        new_state()
        |> State.stream_message({:entry, :system, text})
        |> State.resize(16, 24)

      assert State.log_line_count(state) > 2

      widened = State.resize(state, 80, 24)
      [entry] = widened.entries

      # Back at the original width the display is the logical render again.
      assert State.log_line_count(widened) == 2
      assert Enum.map_join(entry.lines, &flatten/1) == text
    end

    test "a same-size or height-only resize re-wraps nothing" do
      state = State.stream_message(new_state(), {:entry, :system, "some long line here"})

      assert State.resize(state, 80, 24) == state
      assert State.resize(state, 80, 40).entries == state.entries
    end

    test "the in-flight reply re-renders to the new width immediately" do
      text = "one two three four five six seven eight nine ten"

      state =
        new_state()
        |> Map.put(:phase, :streaming)
        |> State.stream_message({:token, text}, 1_000)
        |> tick_once()

      narrow = State.resize(state, 15, 24)

      refute narrow.in_flight_lines == state.in_flight_lines
      assert State.log_line_count(narrow) > State.log_line_count(state)
      assert_words_survive(Enum.map(narrow.in_flight_lines, &flatten/1), text)
    end

    test "an above-cap in-flight reply clears its live view across a width change" do
      # Above the cap no fresh render is possible until finalize, and the
      # stale one is at the OLD width — rendering it into the narrower pane
      # would truncate at the edge (the #20 symptom). The live view clears
      # instead; the reply reappears when it finalizes.
      over_cap = String.duplicate("x", 64 * 1024) <> "y"

      state =
        new_state()
        |> Map.put(:phase, :streaming)
        |> State.stream_message({:token, over_cap}, 1_000)
        |> tick_once()

      assert state.in_flight_lines == nil
      assert State.resize(state, 40, 24).in_flight_lines == nil
    end

    test "resize tolerates entries built without logical lines" do
      hand_built = %{kind: :user, text: "hi", lines: Render.entry_lines(:user, "hi")}
      state = %{new_state() | entries: [hand_built]}

      resized = State.resize(state, 40, 24)
      [entry] = resized.entries
      assert length(entry.lines) >= 2
    end

    test "wrap accounting and the windowed view agree after resize (no drift)" do
      # 40 entries, each long enough to wrap several times at width 18.
      full =
        Enum.reduce(1..40, new_state(), fn i, acc ->
          State.stream_message(acc, {:entry, :system, "entry number #{i} with plenty of words"})
        end)

      state = State.resize(full, 18, 24)

      # The view's own log height drives both the offset math and the slice.
      log_height = View.regions(state.size, 1, false).log.height
      total = State.log_line_count(state)
      assert total > log_height

      # Follow: the bottom of the window is the last display row.
      {viewed, _widget} =
        state
        |> View.render(%ExRatatui.Frame{width: 18, height: 24})
        |> Enum.at(1)

      visible = Enum.map(viewed.text, &flatten/1)
      assert length(visible) == log_height
      assert State.effective_scroll(state, log_height) == total - log_height
      assert Enum.all?(visible, &(&1 == "" or String.length(&1) <= 18))

      # Paging up twice moves exactly two viewports up the display list, and
      # the shown rows are the accounting's rows — no gaps, no repeats.
      {paged, nil} = State.handle_key(state, "page_up", [])
      {paged2, nil} = State.handle_key(paged, "page_up", [])

      offset = State.effective_scroll(paged2, log_height)
      all = Enum.flat_map(paged2.entries, & &1.lines)

      {viewed2, _widget2} =
        paged2
        |> View.render(%ExRatatui.Frame{width: 18, height: 24})
        |> Enum.at(1)

      expected =
        all
        |> Enum.drop(offset)
        |> Enum.take(log_height)
        |> Enum.map(&flatten/1)

      assert Enum.map(viewed2.text, &flatten/1) == expected
    end

    test "follow stays pinned to the re-wrapped bottom across resize" do
      state =
        Enum.reduce(1..20, new_state(), fn i, acc ->
          State.stream_message(acc, {:entry, :system, "wrapped words number #{i} keep coming"})
        end)

      narrow = State.resize(state, 12, 24)
      assert narrow.follow?
      assert State.effective_scroll(narrow, 24) == State.log_line_count(narrow) - 24
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

  # Wrap drops whitespace at break points, so concatenation is width-luck;
  # word sequences are the honest no-loss assertion.
  defp assert_words_survive(pieces, text) do
    assert Enum.join(pieces, " ") |> String.split() == String.split(text)
  end

  # Runs one animation tick (rendering dirty in-flight lines), keeping state.
  defp tick_once(state), do: elem(State.tick(state, 1_100), 0)
end
