defmodule DashFloat.TUI.StateTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias DashFloat.Config.Onboarding
  alias DashFloat.Tools
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
    test "Ctrl+Q quits immediately; Ctrl+C needs a second press (issue #28)" do
      assert {_state, :quit} = State.handle_key(new_state(), "q", ["ctrl"])
      # One Ctrl+C only arms the guard — see the exit-guard describe block.
      {armed, nil} = State.handle_key(new_state(), "c", ["ctrl"], 1_000)
      assert armed.exit_guard_at == 1_000
    end

    test "plain c and q type" do
      state = type(new_state(), "cq")
      assert State.input_text(state) == "cq"
    end
  end

  # Issue #28 (ADR 0006 amendment): selection over display rows — anchor,
  # extend, copy on release; content-anchored so it survives scroll and
  # append; cleared by width resize and a count-changing finalize.
  describe "mouse selection" do
    # Two entries => display rows: 0 blank, 1 "alpha line", 2 blank, 3 "beta line".
    defp selected_state do
      new_state()
      |> State.stream_message({:entry, :system, "alpha line"})
      |> State.stream_message({:entry, :system, "beta line"})
    end

    defp drag(state, {x0, y0}, {x1, y1}) do
      {down, _action} = State.select_mouse(state, "down", x0, y0)
      {dragged, _action} = State.select_mouse(down, "drag", x1, y1)
      State.select_mouse(dragged, "up", x1, y1)
    end

    test "down anchors, drag extends, up copies; click-to-clear" do
      state = selected_state()

      {anchored, nil} = State.select_mouse(state, "down", 1, 3)
      assert anchored.selection.anchor == {1, 0}
      # The gesture snapshots the entries' display-row count as its base —
      # the finalize boundary (review P1).
      assert anchored.selection.base_rows == 4
      assert anchored.selection.head == {1, 0}

      {extended, nil} = State.select_mouse(anchored, "drag", 6, 5)
      assert extended.selection.head == {3, 5}

      {released, {:copy, text}} = State.select_mouse(extended, "up", 6, 5)
      assert match?(%{head: _}, released.selection)
      # Last row slices through col 5's cell ("beta l" — the pointed cell
      # is included; review P2a).
      assert text == "alpha line\n\nbeta l"

      # Press+release without extension clears…
      {cleared, nil} = State.select_mouse(anchored, "up", 1, 3)
      assert cleared.selection == nil
      # …and an empty selection copies nothing (the nil clause's contract).
      assert State.selection_text(cleared) == ""
    end

    test "an empty log selects nothing" do
      {state, action} = State.select_mouse(new_state(), "down", 1, 3)
      assert state.selection == nil
      assert action == nil
    end

    test "coordinates clamp into the log rect (status bar and input box)" do
      state = selected_state()

      # Above the log (the status row): clamps to display row 0, col 0.
      {above, nil} = State.select_mouse(state, "down", 0, 0)
      assert above.selection.anchor == {0, 0}

      # Below the log (over the input box): clamps to the last row, and the
      # column clamps to the padded width (one past the last column).
      {below, nil} = State.select_mouse(selected_state(), "down", 999, 23)
      assert below.selection.anchor == {3, 78}
    end

    test "a blank-only selection copies nothing and clears" do
      # An empty entry renders as blank separator + empty line: rows 0-1.
      state = State.stream_message(new_state(), {:entry, :system, ""})

      {anchored, nil} = State.select_mouse(state, "down", 1, 2)
      {released, action} = State.select_mouse(anchored, "up", 1, 3)

      assert action == nil
      assert released.selection == nil
    end

    test "the selection survives the wheel and page keys (content-anchored)" do
      state =
        Enum.reduce(1..50, selected_state(), fn i, acc ->
          State.stream_message(acc, {:entry, :system, "filler #{i}"})
        end)

      {anchored, nil} = State.select_mouse(state, "down", 1, 3)
      {dragged, nil} = State.select_mouse(anchored, "drag", 6, 5)
      {copied, {:copy, text}} = State.select_mouse(dragged, "up", 6, 5)
      assert text != ""

      # Wheel up unfollows; the selection stays anchored to the content.
      wheeled = State.wheel_scroll(copied, :up)
      refute wheeled.follow?
      assert wheeled.selection != nil
      assert State.selection_text(wheeled) == text

      {paged, nil} = State.handle_key(wheeled, "page_up", [])
      assert paged.selection != nil
      assert State.selection_text(paged) == text
    end

    test "coordinates clamp into the log rect in screen space (review P1)" do
      # A tall, scrolled-up log: the viewport shows rows far from either
      # content end, so an off-pane pointer must land on the viewport's
      # edge row — never on invisible rows beyond it.
      state =
        Enum.reduce(1..50, selected_state(), fn i, acc ->
          State.stream_message(acc, {:entry, :system, "filler #{i}"})
        end)

      scrolled = State.wheel_scroll(state, :up)
      refute scrolled.follow?
      top = State.effective_scroll(scrolled, 18)
      assert top > 0

      # Click on the status bar (screen row 0): anchors the viewport's
      # first visible display row, not `top - 2` above the viewport.
      {above, _nil} = State.select_mouse(scrolled, "down", 1, 0)
      assert above.selection.anchor == {top, 0}

      # Drag into the input pane (screen row 23): the viewport's last
      # visible row (18-row idle viewport: rows top..top + 17).
      {below, _nil} = State.select_mouse(scrolled, "down", 1, 23)
      assert below.selection.anchor == {top + 17, 0}
    end

    test "click jitter below the drag threshold clears instead of copying" do
      # Review contract: a deliberate 3-cell same-row selection MUST copy;
      # a ≤2-cell wobble MUST NOT. The extent is inclusive (distance + 1).
      state = selected_state()

      # Same cell (1-cell extent): a plain click.
      {anchored, _nil} = State.select_mouse(state, "down", 1, 3)
      {same, action} = State.select_mouse(anchored, "up", 1, 3)
      assert action == nil
      assert same.selection == nil

      # Adjacent cell (2-cell extent): still wobble.
      {anchored2, _nil} = State.select_mouse(state, "down", 1, 3)
      {wobbled, action2} = State.select_mouse(anchored2, "up", 2, 3)
      assert action2 == nil
      assert wobbled.selection == nil

      # Two cells away (3-cell extent): a deliberate selection — copies.
      {anchored3, _nil} = State.select_mouse(state, "down", 1, 3)
      {dragged3, {:copy, text}} = State.select_mouse(anchored3, "up", 3, 3)
      assert match?(%{head: _}, dragged3.selection)
      assert text == "alp"
    end

    test "shift-modified events are inert — native selection owns them" do
      # Review P2d: Shift+drag is the terminal's bypass; the app must not
      # select or copy underneath it.
      state = selected_state()

      for kind <- ["down", "drag", "up"] do
        {^state, nil} = State.select_mouse(state, kind, 1, 3, ["shift"])
      end
    end

    test "a gesture that starts shifted can never copy (latched at its down)" do
      # Review P2b (delta): releasing Shift before the button used to leak
      # a clipboard write from the stale anchor of an EARLIER selection.
      # The shifted down dismisses the old selection, so the later plain
      # up has nothing to copy from.
      state = selected_state()

      # An existing selection from a previous gesture…
      {anchored, _nil} = State.select_mouse(state, "down", 1, 3)
      {dragged, _nil} = State.select_mouse(anchored, "drag", 6, 5)
      {kept, {:copy, _text}} = State.select_mouse(dragged, "up", 6, 5)
      assert match?(%{head: _}, kept.selection)

      # …a native-selection gesture starts (shift+down): the old highlight
      # goes away…
      {native, nil} = State.select_mouse(kept, "down", 1, 3, ["shift"])
      assert native.selection == nil

      # …Shift is released, and the plain up at a distant cell still
      # cannot copy from the stale anchor.
      {leaked, action} = State.select_mouse(native, "up", 6, 5)
      assert action == nil
      assert leaked.selection == nil
    end

    test "shift mid-gesture only pauses extension; a plain-start gesture copies" do
      state = selected_state()

      {anchored, _nil} = State.select_mouse(state, "down", 1, 3)
      {paused, _nil} = State.select_mouse(anchored, "drag", 6, 5, ["shift"])
      {resumed, {:copy, _text}} = State.select_mouse(paused, "up", 6, 5)
      assert match?(%{head: _}, resumed.selection)
    end

    test "an over-cap selection reports its size instead of copying" do
      # Review P2d: the OSC 52 payload is bounded — a monster selection
      # drops with a log line at the TUI layer, and its bytes are reported.
      # The real full-log flow: anchor near the bottom, wheel up while the
      # button is held (the selection is content-anchored and survives
      # scrolling), extend, release — this is how a full-log selection is
      # actually made.
      huge = String.duplicate("word ", 20_000)

      state = State.stream_message(new_state(), {:entry, :system, huge})

      {anchored, _nil} = State.select_mouse(state, "down", 1, 3)

      # 400 notches = 1200 rows above the anchor: a genuine full-log span.
      scrolled =
        Enum.reduce(1..400, anchored, fn _i, acc -> State.wheel_scroll(acc, :up) end)

      {dragged, _nil} = State.select_mouse(scrolled, "drag", 1, 3)
      {selected, action} = State.select_mouse(dragged, "up", 1, 3)

      assert {:copy_too_large, bytes} = action

      # The build stopped AT the cap: the reported bytes are the
      # accumulated lower bound, not the full span's size (which never
      # materialises — that was the freeze).
      assert bytes > 64 * 1024
      text = State.selection_text(selected)
      assert byte_size(text) > bytes

      # The highlight stays — the user sees what was too big to copy.
      assert selected.selection != nil
    end

    test "the Esc-cancel contract: a selection into the reply clears despite appended rows" do
      # Review P1 (delta): the reply boundary must come from the gesture's
      # own base, not a finalize-time recount — the cancel contract's
      # system entry lands between the anchor and the idle, shifting the
      # live block 2 rows and drifting any recount.
      opened = new_state(test_mode: {20, 24})

      streaming =
        opened
        |> Map.put(:phase, :streaming)
        |> State.stream_message({:token, "one two three"}, 1_000)

      {ticked, :cont} = State.tick(streaming, 1_100)

      # Select into the live reply (rows 0-1; the base is 0 — no entries).
      {anchored, _nil} = State.select_mouse(ticked, "down", 1, 2)
      {dragged, _nil} = State.select_mouse(anchored, "drag", 10, 3)
      {selected, {:copy, _text}} = State.select_mouse(dragged, "up", 10, 3)
      assert selected.selection.base_rows == 0

      cancelled =
        selected
        |> State.stream_message({:entry, :system, "[cancelled]"})
        |> State.stream_message({:phase, :idle}, 1_200)

      assert cancelled.selection == nil
    end

    test "a selection referencing rows beyond the content copies nothing" do
      # Every current shrink path (width resize, count-changing finalize)
      # clears the selection first, so a stale selection this far out of
      # range cannot arise from an interaction today — but selection_text
      # is total: Phase 4's log trimming will be able to shrink the log
      # under one, and the clamp guard decides that day's answer now —
      # copy nothing, never crash, never wrap around.
      stale = %{selected_state() | selection: %{anchor: {500, 0}, head: {900, 0}}}
      assert State.selection_text(stale) == ""
    end

    test "a width-changing resize clears; a height-only resize keeps" do
      {state, {:copy, _text}} = drag(selected_state(), {1, 3}, {6, 5})

      narrowed = State.resize(state, 40, 24)
      assert narrowed.selection == nil

      {again, {:copy, _text}} = drag(selected_state(), {1, 3}, {6, 5})
      taller = State.resize(again, 80, 40)
      assert taller.selection != nil
    end

    test "a selection reaching into the reply clears at finalize; one above survives" do
      # Review P1: the live in-flight rows can be STALE (tokens arrived
      # after the last tick) and equal in count while differing in
      # content, so row counts cannot decide — the guard is positional.
      # Display rows: 0 blank, 1 "warm", then the reply's rows from 2.
      warm = new_state(test_mode: {20, 24})

      base = State.stream_message(warm, {:entry, :system, "warm"})

      streaming =
        base
        |> Map.put(:phase, :streaming)
        |> State.stream_message({:token, "one two three"}, 1_000)

      {ticked, :cont} = State.tick(streaming, 1_100)

      dirty = State.stream_message(ticked, {:token, " four"}, 1_200)
      assert dirty.in_flight_dirty

      # Above the reply (row 1): a real drag within "warm" that survives
      # the finalize untouched.
      {anchored, _no_copy} = State.select_mouse(dirty, "down", 1, 3)
      {dragged, _no_copy} = State.select_mouse(anchored, "drag", 4, 3)
      {selected, {:copy, _text}} = State.select_mouse(dragged, "up", 4, 3)

      finalized = State.stream_message(selected, {:phase, :idle}, 1_300)
      assert finalized.selection != nil

      # The P1 shape, pinned: the stale live rows and the final entry rows
      # are EQUAL in count while differing in content ("one two three" →
      # "one two three four" — both fit one padded row).
      reply = Enum.find(finalized.entries, &(&1.kind == :assistant))
      assert length(dirty.in_flight_lines) == length(reply.lines)
      assert reply.text == "one two three four"

      # Reaching into the reply (row 2, the reply's blank separator row)
      # clears even at that equal count.
      {into, _no_copy} = State.select_mouse(dirty, "down", 1, 4)
      {into_drag, _no_copy} = State.select_mouse(into, "drag", 6, 5)
      {into_selected, {:copy, _reply_text}} = State.select_mouse(into_drag, "up", 6, 5)
      assert match?(%{head: _}, into_selected.selection)

      replaced = State.stream_message(into_selected, {:phase, :idle}, 1_400)
      assert replaced.selection == nil
    end
  end

  # Issue #28 (ADR 0006 amendment): one accidental Ctrl+C must not kill a
  # live session. First press arms a 2 s window + prompt; a second press
  # inside quits; expiry resets; any other key disarms.
  describe "exit guard" do
    test "a single Ctrl+C arms the window and does not quit" do
      {armed, action} = State.handle_key(new_state(), "c", ["ctrl"], 1_000)

      assert action == nil
      assert armed.exit_guard_at == 1_000
      assert State.exit_guard_live?(armed, 1_000)
      assert State.exit_guard_delay(armed, 1_000) == 2_000
      # The delay floors at zero once the window has logically expired —
      # the timer fires immediately to clear a stale prompt.
      assert State.exit_guard_delay(armed, 1_000 + 3_000) == 0
    end

    test "a second Ctrl+C inside the window quits through the normal path" do
      {armed, nil} = State.handle_key(new_state(), "c", ["ctrl"], 1_000)
      {cleared, action} = State.handle_key(armed, "c", ["ctrl"], 2_999)

      assert action == :quit
      assert cleared.exit_guard_at == nil
    end

    test "the window boundary is inclusive at 2 s" do
      {armed, nil} = State.handle_key(new_state(), "c", ["ctrl"], 1_000)
      assert {_state, :quit} = State.handle_key(armed, "c", ["ctrl"], 3_000)
    end

    test "an expired window resets: a late press re-arms instead of quitting" do
      {armed, nil} = State.handle_key(new_state(), "c", ["ctrl"], 1_000)
      refute State.exit_guard_live?(armed, 1_000 + 2_001)

      {rearmed, action} = State.handle_key(armed, "c", ["ctrl"], 1_000 + 2_001)

      assert action == nil
      assert rearmed.exit_guard_at == 3_001

      # The fresh window is live and completes a quit of its own.
      {_state, :quit} = State.handle_key(rearmed, "c", ["ctrl"], 3_001 + 1_999)
    end

    test "any other key disarms the guard" do
      {armed, nil} = State.handle_key(new_state(), "c", ["ctrl"], 1_000)

      {typed, nil} = State.handle_key(armed, "x", [], 1_100)
      assert typed.exit_guard_at == nil

      # A follow-up Ctrl+C inside the original window re-arms, not quits.
      {rearmed, action} = State.handle_key(typed, "c", ["ctrl"], 1_200)
      assert action == nil
      assert rearmed.exit_guard_at == 1_200
    end

    test "Esc disarms too — it never becomes an exit key" do
      {armed, nil} = State.handle_key(new_state(), "c", ["ctrl"], 1_000)
      {escaped, nil} = State.handle_key(armed, "esc", [], 1_100)
      assert escaped.exit_guard_at == nil
    end

    test "overlay? is true for an active phase or an armed guard, else false" do
      refute State.overlay?(new_state())
      assert State.overlay?(%{new_state() | phase: :streaming})
      assert State.overlay?(%{new_state() | exit_guard_at: 1_000})
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
      # Ctrl+C mid-decision follows the guard like anywhere else: arm, quit.
      {armed, nil} = State.handle_key(state, "c", ["ctrl"], 1_000)
      assert {_state, :quit} = State.handle_key(armed, "c", ["ctrl"], 1_500)
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
    # The wrap is single-pass now.
    #
    # The guard is the scaling LAW, not a wall-clock budget (issue #51): a
    # single-run millisecond assert on a loaded runner is a false-red
    # generator — the original 400 ms bound fired at 418 ms on CI while the
    # same tree was green on a plain rerun. Work is measured in reductions,
    # which the BEAM counts deterministically per function call and which
    # therefore does not move with scheduler contention: doubling the input
    # doubles the work for a single pass (measured 1.97-2.01 over 10 runs
    # quiet and under 24 CPU hogs) and quadruples it for the quadratic shape
    # (measured 3.96 on a replica of the pre-fix wrap). The bound below
    # leaves room for constant overhead and still separates 2x from 4x.
    test "a tick wrapping a large unbreakable CJK reply stays linear in its input" do
      phrase = "日本語の長い返事が続きます。"
      small = String.duplicate(phrase, 500)
      large = String.duplicate(phrase, 1_000)

      assert byte_size(large) < 64 * 1024,
             "both inputs must stay under the live render cap or tick stops re-wrapping"

      {small_work, small_ticked} = tick_work(small)
      {large_work, large_ticked} = tick_work(large)

      assert State.log_line_count(small_ticked) > 100
      assert State.log_line_count(large_ticked) > 2 * State.log_line_count(small_ticked) - 10

      ratio = large_work / small_work

      assert ratio < 3.0,
             "tick work grew #{Float.round(ratio, 2)}x for a 2x input — the wrap is " <>
               "quadratic again (#{small_work} -> #{large_work} reductions)"
    end

    # Reductions the calling process spends inside one tick, and the ticked
    # state. Deterministic: no clock, no scheduler, no CPU contention.
    defp tick_work(text) do
      state =
        new_state()
        |> Map.put(:phase, :streaming)
        |> State.stream_message({:token, text}, 1_000)

      {:reductions, before} = Process.info(self(), :reductions)
      {ticked, :cont} = State.tick(state, 1_100)
      {:reductions, after_} = Process.info(self(), :reductions)

      {after_ - before, ticked}
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

      assert match?(%{ref: _}, state.confirm)

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
      tail = tl(pieces)
      assert Enum.all?(tail, &(&1 == "" or String.length(&1) <= 18))
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
    joined = Enum.join(pieces, " ")
    assert String.split(joined) == String.split(text)
  end

  describe "the startup phase (ADR 0009)" do
    test "setup_paste feeds wizard text steps and is inert on the selection modal" do
      started = Onboarding.new()
      {name_step, _nil} = Onboarding.handle_key(started, "enter")
      name_state = setup_state(setup: name_step)
      pasted = State.setup_paste(name_state, "PLACEHOLDER-key\r\n")
      assert pasted.setup.draft == "personalPLACEHOLDER-key"

      # The forced-selection modal owns no text input: a paste changes
      # nothing (P1-2 — it can never reach the composer instead).
      modal = setup_state(setup: {:select, ["a", "b"], 0})
      assert State.setup_paste(modal, "anything") == modal
    end

    test "P1-3 regression: Inspect never prints the wizard's key (crash-log leak)" do
      # The reviewer's 4-line crash-report repro: State.setup holds the
      # plaintext key (draft / pending.key); a TUI crash used to dump it
      # into the log. The derivations must redact — Config.ex is the house
      # reference pattern.
      wizard =
        Enum.reduce(
          ["enter", "enter", "enter", "enter", "k", "e", "y", "enter"],
          Onboarding.new(),
          fn key, wizard ->
            {wizard, _action} = Onboarding.handle_key(wizard, key)
            wizard
          end
        )

      assert wizard.pending.key == "key"

      state = setup_state(setup: wizard)
      refute inspect(state) =~ "key: \"key\""
      refute inspect(state) =~ ~s(pending: %{)
      assert inspect(state) =~ "..."

      # The wizard alone redacts too (standalone logs, IEx).
      refute inspect(wizard) =~ ~s(key: "key")
      refute inspect(wizard) =~ ~s(draft: "key")
    end

    defp setup_state(opts \\ []) do
      [test_mode: {80, 24}]
      |> Keyword.merge(opts)
      |> State.new()
    end

    test "the forced-selection modal moves with up/down and commits with Enter" do
      state = setup_state(setup: {:select, ["a", "b"], 0})

      moved_state = state

      {up, nil} = State.handle_key(moved_state, "up", [])
      assert up.setup == {:select, ["a", "b"], 1}

      {moved, nil} = State.handle_key(moved_state, "down", [])
      assert moved.setup == {:select, ["a", "b"], 1}

      {wrapped, nil} = State.handle_key(moved, "down", [])
      assert wrapped.setup == {:select, ["a", "b"], 0}

      {chosen, {:select_profile, "b"}} = State.handle_key(moved, "enter", [])
      assert chosen.setup == {:select, ["a", "b"], 1}
    end

    defp step_wizard(key, wizard) do
      {wizard, _action} = Onboarding.handle_key(wizard, key)
      wizard
    end

    test "the wizard routes through the setup branch: typing and stepping" do
      state = setup_state(setup: Onboarding.new())

      {welcome, nil} = State.handle_key(state, "enter", [])
      assert welcome.setup.step == :profile_name

      {named, nil} = State.handle_key(welcome, "w", [])
      assert named.setup.draft =~ "w"
    end

    test "other keys fall through the setup branch untouched" do
      state = setup_state(setup: {:select, ["a"], 0})
      {same, nil} = State.handle_key(state, "x", [])
      assert same.setup == {:select, ["a"], 0}
    end

    test "provider_resolved clears setup, sets the provider, and emits the agent handoff" do
      state = setup_state(setup: {:select, ["a"], 0})
      config = %DashFloat.Config{base_url: "https://x.example", model: "m", api_key: "k"}

      {resolved, {:agent_provider, {:ok, ^config}}} =
        State.provider_resolved(state, {:ok, config})

      assert resolved.setup == nil
      assert resolved.provider == {:ok, config}
    end

    test "models_arrived feeds a waiting wizard and ignores stale results" do
      start = Onboarding.new()
      keys = ["enter", "enter", "enter", "enter", "k", "enter", "enter"]

      wizard = Enum.reduce(keys, start, &step_wizard/2)

      state = setup_state(setup: wizard)

      fed = State.models_arrived(state, {:ok, [%{model: "m1", context: nil}]})
      assert fed.setup.step == :model_pick

      stale = State.models_arrived(setup_state(), {:ok, [%{model: "late"}]})
      assert stale.setup == nil
    end

    test "setup_write_failed bounces a waiting wizard and is inert elsewhere (issue #39)" do
      at_done =
        Enum.reduce(
          ["enter", "enter", "down", "down", "down", "enter", "down", "down", "enter"],
          Onboarding.new(),
          &step_wizard/2
        )

      assert at_done.step == :done

      state = setup_state(setup: at_done)

      bounced = State.setup_write_failed(state, "settings.json5 already exists")
      assert bounced.setup.step == :loop
      assert bounced.setup.error == "settings.json5 already exists"
      assert bounced.setup.choice == 2

      # Off the wizard (the modal, or no setup at all) the feedback is inert.
      modal = setup_state(setup: {:select, ["a"], 0})
      assert State.setup_write_failed(modal, "late") == modal
    end

    test "catalog_arrived stores the sweep and fills the context denominator (ADR 0009)" do
      base = "https://provider.example/v1"

      config = %DashFloat.Config{
        base_url: base,
        model: "glm-5.3",
        api_key: "k",
        context_tokens: nil
      }

      state = setup_state(provider: {:ok, config})
      assert State.provider_context_tokens(state) == nil

      landed = State.catalog_arrived(state, %{base => [%{model: "glm-5.3", context: 128_000}]})

      assert State.provider_context_tokens(landed) == 128_000
      assert landed.catalog == %{base => [%{model: "glm-5.3", context: 128_000}]}

      # A configured context always wins over the catalog's metadata.
      configured = setup_state(provider: {:ok, %{config | context_tokens: 64_000}})

      filled =
        State.catalog_arrived(configured, %{base => [%{model: "glm-5.3", context: 128_000}]})

      assert State.provider_context_tokens(filled) == 64_000

      # A catalog entry without usable context leaves the fallback nil.
      bare = setup_state(provider: {:ok, config})

      contextless =
        State.catalog_arrived(bare, %{
          base => [%{model: "glm-5.3", context: nil}]
        })

      assert State.provider_context_tokens(contextless) == nil
    end
  end

  # Runs one animation tick (rendering dirty in-flight lines), keeping state.
  defp tick_once(state), do: elem(State.tick(state, 1_100), 0)

  # ADR 0014 §6: the resumed log is derived by replaying the loaded transcript
  # through the exact render path live entries use — the differential tests
  # below build a live state through the contract messages and assert the
  # replayed entries match it.
  describe "transcript replay" do
    # The persisted transcript shape, exactly as Session.load returns it:
    # string-keyed messages, opaque `function.arguments` JSON.
    defp transcript do
      [
        %{"role" => "user", "content" => "fix the bug"},
        %{
          "role" => "assistant",
          "content" => "Reading the file.",
          "tool_calls" => [
            %{
              "id" => "t1",
              "type" => "function",
              "function" => %{"name" => "read_file", "arguments" => ~s({"path": "lib/foo.ex"})}
            },
            %{
              "id" => "t2",
              "type" => "function",
              "function" => %{
                "name" => "execute_command",
                "arguments" => ~s({"command": "mix test"})
              }
            }
          ]
        },
        %{
          "role" => "tool",
          "tool_call_id" => "t1",
          "content" => Jason.encode!(%{ok: true, output: "line one\nline two"})
        },
        %{
          "role" => "tool",
          "tool_call_id" => "t2",
          "content" => Jason.encode!(Tools.cancelled_result())
        },
        %{"role" => "assistant", "content" => "Done."}
      ]
    end

    # The same turn as `transcript/0`, built live through the contract
    # messages: the submit echo, tokens, phase transitions, tool rows.
    defp live_state(size \\ {80, 24}) do
      ok = %{ok: true, output: "line one\nline two"}
      cancelled = Tools.cancelled_result()
      base = new_state(test_mode: size)

      base
      |> idle_submit("fix the bug")
      |> Map.put(:phase, :streaming)
      |> State.stream_message({:token, "Reading the file."}, 1_000)
      |> State.stream_message({:phase, :executing_tool}, 1_100)
      |> State.stream_message(
        {:tool_call, %{id: "t1", name: "read_file", args: %{"path" => "lib/foo.ex"}}}
      )
      |> State.stream_message(
        {:tool_call, %{id: "t2", name: "execute_command", args: %{"command" => "mix test"}}}
      )
      |> State.stream_message({:tool_result, display_msg("t1", "read_file", ok)})
      |> State.stream_message({:tool_result, display_msg("t2", "execute_command", cancelled)})
      |> Map.put(:phase, :streaming)
      |> State.stream_message({:token, "Done."}, 2_000)
      |> State.stream_message({:phase, :idle}, 2_100)
    end

    # The tool_result message the agent derives from a result: status and
    # excerpt come from the same Tools helpers the replay uses (ADR 0014 §6).
    defp display_msg(id, name, result) do
      %{
        id: id,
        name: name,
        ok: result[:ok] == true,
        status: Tools.display_status(result),
        output: Tools.display_excerpt(result)
      }
    end

    test "replayed entries match the live contract kind-for-kind, text-for-text" do
      replayed = new_state(transcript: transcript())

      assert pairs(replayed) == pairs(live_state())
      # Same render pipeline at the same width: logical and wrapped lines too.
      assert replayed.entries == live_state().entries
    end

    test "entries wrap at the construction width, exactly like live entries" do
      wide = new_state(transcript: transcript())
      narrow = new_state(test_mode: {20, 24}, transcript: transcript())

      assert State.log_line_count(narrow) > State.log_line_count(wide)
      assert narrow.entries == live_state({20, 24}).entries
    end

    test "assistant rows ride the markdown path" do
      md = "# Title\n\nSome **bold** text."

      state = new_state(transcript: [%{"role" => "assistant", "content" => md}])

      live =
        new_state()
        |> Map.put(:phase, :streaming)
        |> State.stream_message({:token, md}, 1_000)
        |> State.stream_message({:phase, :idle}, 1_100)

      assert state.entries == live.entries
    end

    test "arguments that do not decode render the (invalid arguments) arm" do
      transcript = [
        %{
          "role" => "assistant",
          "content" => nil,
          "tool_calls" => [
            %{
              "id" => "t1",
              "type" => "function",
              "function" => %{"name" => "read_file", "arguments" => "{not json"}
            }
          ]
        }
      ]

      assert pairs(new_state(transcript: transcript)) == [
               {:tool, "⚙ read_file (invalid arguments)"}
             ]
    end

    test "a tool result that does not decode renders an error row, never a crash" do
      transcript = [
        %{
          "role" => "assistant",
          "content" => nil,
          "tool_calls" => [
            %{
              "id" => "t1",
              "type" => "function",
              "function" => %{"name" => "read_file", "arguments" => "{}"}
            }
          ]
        },
        %{"role" => "tool", "tool_call_id" => "t1", "content" => "garbage"}
      ]

      assert pairs(new_state(transcript: transcript)) == [
               {:tool, "⚙ read_file"},
               {:tool, "⚙ read_file → error"}
             ]
    end

    test "a nil-content assistant with calls produces no empty assistant entry" do
      transcript = [
        %{
          "role" => "assistant",
          "content" => nil,
          "tool_calls" => [
            %{
              "id" => "t1",
              "type" => "function",
              "function" => %{"name" => "list_directory", "arguments" => "{}"}
            }
          ]
        },
        %{"role" => "tool", "tool_call_id" => "t1", "content" => Jason.encode!(%{ok: true})}
      ]

      assert pairs(new_state(transcript: transcript)) == [
               {:tool, "⚙ list_directory"},
               {:tool, "⚙ list_directory → ok"}
             ]
    end

    test "the resumed log opens pinned at the bottom" do
      state = new_state(transcript: transcript())

      assert state.follow?
      assert state.scroll == 0

      height = 5
      bottom = State.effective_scroll(state, height)
      assert bottom == State.log_line_count(state) - height
      assert bottom > 0
    end

    test "the resume note lands last as a system entry" do
      note = "[resuming session pinned to a/m under b/m — continuing]"
      state = new_state(transcript: transcript(), resume_note: note)

      assert pairs(state) == pairs(new_state(transcript: transcript())) ++ [{:system, note}]
    end

    test "an empty transcript behaves exactly as today" do
      assert new_state().entries == []
      assert new_state(transcript: []).entries == []
      assert new_state(transcript: [], resume_note: nil).entries == []
    end
  end
end
