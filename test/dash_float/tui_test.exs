defmodule DashFloat.TUITest do
  @moduledoc """
  App-level tests under `test_mode`: supervised lifecycle, teardown paths
  (including crashes), the agent seam (fake agents are this test process or
  plain spawned processes — the TUI only ever sends
  `{:prompt, ui, text}` / `{:confirm_decision, ref, decision}` / `{:cancel}`
  and receives the frozen stream contract, ADR 0007), and the responsiveness
  proof. Not async: they measure timing, share telemetry handlers, and drive
  one supervised TUI per test.
  """

  use ExUnit.Case, async: false

  alias DashFloat.Config
  alias DashFloat.TUI
  alias DashFloat.TUI.State
  alias DashFloat.TUI.View
  alias ExRatatui.Runtime

  @opts [test_mode: {80, 24}, name: nil]

  defp start_tui(opts \\ []) do
    # The default fake agent is the test process: the TUI's sends land in
    # this mailbox and each test answers with contract messages.
    opts =
      @opts
      |> Keyword.merge(opts)
      |> Keyword.put_new(:agent, self())

    # A real supervisor, mirroring the Application wiring (restart: :temporary).
    {:ok, sup} =
      Supervisor.start_link(
        [%{id: TUI, start: {TUI, :start_link, [opts]}, type: :worker, restart: :temporary}],
        strategy: :one_for_one
      )

    # Unlink: the supervisor must outlive the test process so on_exit can
    # stop it (and the TUI) deterministically.
    Process.unlink(sup)
    on_exit(fn -> if Process.alive?(sup), do: Supervisor.stop(sup) end)

    [{TUI, pid, :worker, _modules}] = Supervisor.which_children(sup)
    {:ok, pid}
  end

  defp provider do
    {:ok, %Config{base_url: "http://localhost:1", model: "test-model", api_key: "test-key-123"}}
  end

  defp press(pid, code, modifiers \\ []) do
    Runtime.inject_event(pid, %ExRatatui.Event.Key{
      code: code,
      modifiers: modifiers,
      kind: "press"
    })
  end

  defp type(pid, text) do
    text
    |> String.codepoints()
    |> Enum.each(&press(pid, &1))
  end

  defp submit(pid, text) do
    type(pid, text)
    press(pid, "enter")
  end

  # The runtime's own state carries our user_state; no test backdoor needed.
  defp get_state(pid) do
    runtime_state = :sys.get_state(pid)
    Map.get(runtime_state, :user_state)
  end

  defp cursor(pid), do: ExRatatui.textarea_cursor(get_state(pid).input)

  defp eventually(pid, fun, tries \\ 200) do
    state = get_state(pid)

    if fun.(state) do
      state
    else
      true = tries > 0
      Process.sleep(15)
      eventually(pid, fun, tries - 1)
    end
  end

  defp system_entries(state), do: for(%{kind: :system, text: text} <- state.entries, do: text)

  defp entry?(state, kind, text),
    do: Enum.any?(state.entries, &(&1.kind == kind and &1.text == text))

  test "supervised start renders, typed input accumulates, and an agent stream lands" do
    {:ok, pid} = start_tui(provider: provider())
    assert Runtime.snapshot(pid).render_count >= 1

    type(pid, "hello tui")
    typed = get_state(pid)
    assert State.input_text(typed) == "hello tui"

    press(pid, "enter")

    # Submit is a plain send to the agent with our pid as the reply address.
    assert_receive {:prompt, ui_pid, "hello tui"}, 1_000
    assert ui_pid == pid

    # Mid-stream: the reply grows in flight (one token per message) and is
    # not finalized until the idle phase.
    send(ui_pid, {:token, "Hello"})
    streaming = eventually(pid, fn s -> s.in_flight == "Hello" end)
    assert streaming.phase == :streaming
    assert entry?(streaming, :user, "hello tui")

    send(ui_pid, {:token, " from the agent"})
    grown = eventually(pid, fn s -> s.in_flight == "Hello from the agent" end)
    assert grown.phase == :streaming

    send(ui_pid, {:phase, :idle})
    state = eventually(pid, fn s -> s.phase == :idle and s.in_flight == nil end)

    assert entry?(state, :assistant, "Hello from the agent")
    assert state.history == ["hello tui"]
    assert system_entries(state) == []

    # The status bar names the configured model and reports phase truth.
    assert State.provider_model(state) == "test-model"
    assert status_text(state) =~ "test-model"
    assert status_text(state) =~ "Idle"
  end

  test "Esc during streaming sends {:cancel} to the agent and the agent's ack lands" do
    {:ok, pid} = start_tui()
    submit(pid, "cancel me")

    assert_receive {:prompt, ui_pid, "cancel me"}, 1_000
    send(ui_pid, {:token, "partial"})
    eventually(pid, fn s -> s.in_flight == "partial" end)

    press(pid, "esc")
    assert_receive {:cancel}, 1_000

    # The agent's half of the cancel contract: explanation + idle.
    send(ui_pid, {:entry, :system, "[cancelled]"})
    send(ui_pid, {:phase, :idle})

    state =
      eventually(pid, fn s ->
        s.phase == :idle and "[cancelled]" in system_entries(s)
      end)

    assert entry?(state, :assistant, "partial")

    # Input is usable again.
    submit(pid, "again")
    assert_receive {:prompt, ^ui_pid, "again"}, 1_000
  end

  test "quit keys stop the supervised app with reason :normal" do
    {:ok, pid} = start_tui()
    attach_disconnect_listener()

    ref = Process.monitor(pid)
    press(pid, "q", ["ctrl"])

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
    assert_receive {:transport_disconnect, :normal}, 1_000
  end

  @tag :capture_log
  test "a crashing message tears the app down through the terminal-restore path" do
    {:ok, pid} = start_tui()
    attach_disconnect_listener()

    ref = Process.monitor(pid)

    # {:phase, :bogus} violates the stream contract; State.stream_message/2 has
    # no clause for it, so the callback raises like any real bug would.
    bogus = :bogus
    send(pid, {:phase, bogus})

    assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 1_000
    assert reason != :normal

    # The disconnect telemetry fires from ExRatatui.Server.terminate/2 — the
    # same path that restores the terminal and reattaches the BEAM reader.
    assert_receive {:transport_disconnect, _crash_reason}, 1_000
  end

  test "history is reachable through real key events" do
    {:ok, pid} = start_tui()

    submit(pid, "first")
    assert_receive {:prompt, ui_pid, "first"}, 1_000
    send(ui_pid, {:phase, :idle})
    eventually(pid, &(&1.phase == :idle))

    submit(pid, "second")
    assert_receive {:prompt, ^ui_pid, "second"}, 1_000
    send(ui_pid, {:phase, :idle})
    eventually(pid, &(&1.phase == :idle))

    press(pid, "up")
    latest = get_state(pid)
    assert State.input_text(latest) == "second"
    press(pid, "up")
    oldest = get_state(pid)
    assert State.input_text(oldest) == "first"
    press(pid, "down")
    press(pid, "down")
    restored = get_state(pid)
    assert State.input_text(restored) == ""
  end

  @tag :capture_log
  test "a dead agent degrades to idle with an explanation instead of bricking input" do
    agent =
      spawn(fn ->
        receive do
          {:prompt, ui, _text} -> send(ui, {:token, "slow"})
        end

        # Park until the test kills this process.
        :timer.sleep(:infinity)
      end)

    {:ok, pid} = start_tui(agent: agent)
    submit(pid, "hello")

    eventually(pid, fn s -> s.in_flight == "slow" end)
    Process.exit(agent, :kill)

    state =
      eventually(pid, fn s ->
        entries = system_entries(s)
        s.phase == :idle and Enum.any?(entries, &String.contains?(&1, "agent failed"))
      end)

    assert state.agent_ref == nil
    assert entry?(state, :user, "hello")
    assert entry?(state, :assistant, "slow")

    # Input is usable again: typing works and a fresh submit still flips to
    # :streaming optimistically (the dead agent just never answers).
    type(pid, "again")
    typed = get_state(pid)
    assert State.input_text(typed) == "again"

    press(pid, "enter")
    eventually(pid, &(&1.phase == :streaming))
  end

  test "a normally-exiting agent logs no failure (idle finalize only)" do
    agent =
      spawn(fn ->
        receive do
          {:prompt, ui, _text} ->
            send(ui, {:token, "done"})
            send(ui, {:phase, :idle})
        end
      end)

    {:ok, pid} = start_tui(agent: agent)
    submit(pid, "quick")

    # The agent answers then exits :normal; the DOWN must not read as failure.
    state =
      eventually(pid, fn s ->
        s.phase == :idle and s.agent_ref == nil and
          Enum.any?(s.entries, &(&1.kind == :assistant))
      end)

    assert entry?(state, :assistant, "done")
    assert system_entries(state) == []
  end

  @tag :capture_log
  test "the UI stays responsive while a stream lands at cadence into a large log" do
    {:ok, pid} = start_tui()

    # Preload a log far beyond the viewport (400 entries = 800 rendered lines
    # including their blank separators).
    Enum.each(1..400, fn i -> send(pid, {:entry, :system, "warm #{i}"}) end)
    eventually(pid, &(State.log_line_count(&1) == 800))

    # Burst coalescing with a big log: hundreds of messages, few frames.
    burst = Enum.map(1..300, &"b#{&1} ")
    burst_text = IO.iodata_to_binary(burst)
    before = Runtime.snapshot(pid).render_count
    Enum.each(burst, &send(pid, {:token, &1}))
    eventually(pid, &(&1.in_flight == burst_text))
    assert Runtime.snapshot(pid).render_count - before < 50

    # Cadence phase: tokens every 2ms while the user keeps typing.
    cadence_count = 200

    cadence =
      spawn(fn ->
        Enum.each(1..cadence_count, fn _i ->
          send(pid, {:token, "c"})
          Process.sleep(2)
        end)
      end)

    timings_ms =
      Enum.map(1..5, fn _i ->
        {micros, :ok} = :timer.tc(fn -> press(pid, "z") end)
        div(micros, 1000)
      end)

    max_ms = Enum.max(timings_ms)
    assert max_ms < 100, "input round-trips #{inspect(timings_ms)}ms while streaming at cadence"

    ref = Process.monitor(cadence)
    assert_receive {:DOWN, ^ref, :process, ^cadence, :normal}, 2_000

    # Exact count: every burst and cadence token landed, and every keystroke
    # was kept — a single dropped message fails this.
    expected = burst_text <> String.duplicate("c", cadence_count)

    state =
      eventually(pid, &(String.length(&1.in_flight || "") >= String.length(expected)))

    assert state.in_flight == expected
    assert State.input_text(state) == "zzzzz"
  end

  # Issue #20: a resize re-wraps the log to the new width live — no restart,
  # no restart of the turn, and nothing lost at the pane edge.
  test "a resize re-wraps the log live and follow stays pinned" do
    {:ok, pid} = start_tui()
    long = "the quick brown fox jumps over the lazy dog again and again"

    send(pid, {:entry, :system, long})
    state = eventually(pid, &(State.log_line_count(&1) == 2))
    assert State.log_line_count(state) == 2

    inject(pid, %ExRatatui.Event.Resize{width: 20, height: 24})
    narrowed = eventually(pid, &(State.log_line_count(&1) > 2))

    assert narrowed.size == {20, 24}
    assert narrowed.follow?
    # Content still fits the viewport at this size, so follow pins at 0; make
    # it overflow and confirm the pin moves with the wrapped bottom.
    Enum.each(1..20, fn i -> send(pid, {:entry, :system, "#{i} #{long}"}) end)

    full = eventually(pid, &(State.log_line_count(&1) > 24))
    assert State.effective_scroll(full, 20) == State.log_line_count(full) - 20

    # Full text survives the re-wrap, every row fits the new width.
    [entry] = narrowed.entries
    rows = Enum.map(entry.lines, &Enum.map_join(&1.spans, "", fn s -> s.content end))

    joined =
      rows
      |> Enum.join("")
      |> String.trim()

    assert joined == long
    assert Enum.all?(rows, &(&1 == "" or String.length(&1) <= 20))

    # And the drawn frame really carries the wrapped rows, not a truncation.
    term = ExRatatui.init_test_terminal(20, 24)
    widgets = View.render(narrowed, %ExRatatui.Frame{width: 20, height: 24})
    assert :ok = ExRatatui.draw(term, widgets)
    buffer = ExRatatui.get_buffer_content(term)

    for word <- ~w(jumps over lazy dog again) do
      assert buffer =~ word
    end
  end

  test "paste, resize, key releases, unknown events, and stray messages are handled" do
    {:ok, pid} = start_tui()

    inject(pid, %ExRatatui.Event.Paste{content: "pasted text"})
    pasted = get_state(pid)
    assert State.input_text(pasted) == "pasted text"

    inject(pid, %ExRatatui.Event.Resize{width: 100, height: 30})
    assert get_state(pid).size == {100, 30}

    # Key releases are ignored (kitty protocol).
    inject(pid, %ExRatatui.Event.Key{code: "x", modifiers: [], kind: "release"})
    released = get_state(pid)
    assert State.input_text(released) == "pasted text"

    # Events and messages we do not use are dropped, not crashes.
    inject(pid, %ExRatatui.Event.Mouse{kind: "down"})
    send(pid, :stray_message)
    after_stray = get_state(pid)
    assert State.input_text(after_stray) == "pasted text"
  end

  # ADR 0006 paste hardening: CRLF/lone-CR normalize to LF, insertion at the
  # cursor, and wrap stays visual (the draft keeps one logical line).
  test "a multi-line bracketed paste with CRLF normalizes to LF at the cursor" do
    {:ok, pid} = start_tui()

    type(pid, "ab")
    press(pid, "left")

    inject(pid, %ExRatatui.Event.Paste{content: "line one\r\nline two\r\rline three"})
    state = get_state(pid)

    assert State.input_text(state) == "aline one\nline two\n\nline threeb"
    assert State.input_line_count(state) == 4
  end

  # Input-box wrap re-check (issue #20): the textarea wraps the draft itself
  # (Rust-side, per frame at the area width), so a resize re-wraps it with no
  # help from us; the box height stays bound to LOGICAL lines by ADR 0002 —
  # wrapped overflow scrolls inside the box rather than growing it.
  test "a long draft renders and stays whole through a narrow resize" do
    {:ok, pid} = start_tui()
    long = "https://example.com/" <> String.duplicate("segment-", 40)

    inject(pid, %ExRatatui.Event.Paste{content: long})
    pasted = get_state(pid)
    assert State.input_text(pasted) == long
    assert State.input_line_count(pasted) == 1

    inject(pid, %ExRatatui.Event.Resize{width: 30, height: 12})
    state = eventually(pid, &(&1.size == {30, 12}))

    # One logical line still: the box keeps its idle height, wrap is visual.
    assert State.input_line_count(state) == 1
    assert State.input_text(state) == long

    widgets = View.render(state, %ExRatatui.Frame{width: 30, height: 12})
    {input_widget, input_rect} = Enum.at(widgets, 3)
    assert input_widget.wrap_mode == :word_or_glyph
    assert input_rect.height == View.input_height(1, 12)

    # The narrow frame draws whole without raising; the cursor row stays
    # visible (the textarea scrolls its own wrapped overflow).
    term = ExRatatui.init_test_terminal(30, 12)
    assert :ok = ExRatatui.draw(term, widgets)
    assert ExRatatui.get_buffer_content(term) =~ "❯"
  end

  test "a very long unbroken paste stays one logical line and does not grow the box" do
    {:ok, pid} = start_tui()
    long = "https://example.com/" <> String.duplicate("segment-", 200)

    inject(pid, %ExRatatui.Event.Paste{content: long})
    state = get_state(pid)

    # Wrap is visual: one logical line, so the input box keeps its idle height.
    assert State.input_text(state) == long
    assert State.input_line_count(state) == 1

    widgets = View.render(state, %ExRatatui.Frame{width: 80, height: 24})
    {widget, rect} = Enum.at(widgets, 3)

    assert widget.wrap_mode == :word_or_glyph
    assert rect.height == View.input_height(1, 24)
  end

  test "cursor movement within a pasted multi-line draft is row-aware" do
    {:ok, pid} = start_tui()

    submit(pid, "seed")
    assert_receive {:prompt, ui_pid, "seed"}, 1_000
    send(ui_pid, {:phase, :idle})
    eventually(pid, &(&1.phase == :idle))

    inject(pid, %ExRatatui.Event.Paste{content: "row one\nrow two\nrow three"})

    # The cursor lands at the end of the pasted draft (last row).
    assert cursor(pid) == {2, 9}

    # Not on a boundary row: Up/Down move between rows.
    press(pid, "up")
    assert cursor(pid) == {1, 7}
    row_state = get_state(pid)
    assert State.input_text(row_state) == "row one\nrow two\nrow three"
    assert row_state.history_index == nil

    # Left/right move within the row.
    press(pid, "left")
    assert cursor(pid) == {1, 6}
    press(pid, "right")
    assert cursor(pid) == {1, 7}

    # Vertical moves clamp to the target row's length, not a sticky column.
    press(pid, "down")
    assert cursor(pid) == {2, 7}
    press(pid, "up")
    press(pid, "up")
    assert cursor(pid) == {0, 7}

    # On the first row, Up navigates history instead of moving the cursor.
    press(pid, "up")
    state = get_state(pid)
    assert State.input_text(state) == "seed"
    assert state.history_index == 0
  end

  # The animation-discipline proof (ADR 0006): idle => no timers => no renders.
  test "an idle app renders nothing on a timer" do
    {:ok, pid} = start_tui()
    # Let mount's first frame land, then observe a quiet window.
    Process.sleep(50)
    before = Runtime.snapshot(pid).render_count

    Process.sleep(300)

    assert Runtime.snapshot(pid).render_count == before
    assert get_state(pid).tick_ref == nil
  end

  # ADR 0006 extension along ADR 0007: a confirm phase is active (it ticks),
  # and the tick must die again the moment the agent ends the turn.
  test "the tick dies again after a confirm phase resolves to idle" do
    {:ok, pid} = start_tui()

    send(pid, {:confirm, make_ref(), confirm_request(["+ x"])})
    eventually(pid, fn s -> s.phase == :confirming and s.tick_ref != nil end)

    send(pid, {:phase, :idle})
    state = eventually(pid, fn s -> s.phase == :idle and s.tick_ref == nil end)
    assert state.confirm == nil

    before = Runtime.snapshot(pid).render_count
    Process.sleep(300)
    assert Runtime.snapshot(pid).render_count == before
  end

  test "a stale tick is dropped: no double-step, no orphan timer, no frame" do
    # A tick with no timer pending (its timer was cancelled after firing, or the
    # message is a leftover) must not step the spinner, arm anything, or draw.
    idle = State.new(test_mode: {80, 24})
    assert {:noreply, ^idle, %{render?: false}} = TUI.handle_info(:dashfloat_tick, idle)

    # A tick whose tracked timer has not fired yet is stale too, and the live
    # timer is left alone.
    ref = Process.send_after(self(), :never, 10_000)
    active = %{idle | phase: :streaming, tick_ref: ref}

    assert {:noreply, ^active, %{render?: false}} = TUI.handle_info(:dashfloat_tick, active)
    assert is_integer(Process.read_timer(ref))

    Process.cancel_timer(ref)
  end

  test "a tick that finds idle halts and clears the timer (last-resort net)" do
    # schedule/1 cancels on any idle transition, so this state should be
    # unreachable; if it ever happens, the tick must still die here — and draw
    # nothing, since idle renders on no timer (ADR 0006).
    idle = State.new(test_mode: {80, 24})
    ref = Process.send_after(self(), :never, 10_000)
    # A fired timer: read_timer returns false, so the tick is not stale.
    Process.cancel_timer(ref)
    Process.sleep(5)

    leaked = %{idle | tick_ref: ref}
    assert {:noreply, cleared, %{render?: false}} = TUI.handle_info(:dashfloat_tick, leaked)
    assert cleared.tick_ref == nil
    assert cleared.phase == :idle
  end

  test "a stray tick while idle halts without rescheduling" do
    {:ok, pid} = start_tui()
    Process.sleep(50)

    send(pid, :dashfloat_tick)

    state = get_state(pid)
    assert state.phase == :idle
    assert state.tick_ref == nil
    assert state.anim_step == 0

    # The timer is not re-armed, so no further frames arrive.
    Process.sleep(50)
    settled = Runtime.snapshot(pid).render_count
    Process.sleep(300)
    assert Runtime.snapshot(pid).render_count == settled
  end

  test "a stale tick draining at idle draws no frame (render-suppressed)" do
    # The race this pins: a tick timer fires just as the terminal idle
    # message queues behind a backlog; cancel_timer cannot stop the already-
    # queued tick, so it drains at idle. Its callback has no state change —
    # and must draw no frame either (ADR 0006: idle renders nothing on a
    # timer). The render counter is the metric of record.
    {:ok, pid} = start_tui()
    :ok = Runtime.enable_trace(pid, limit: 200)
    Process.sleep(50)
    before_count = Runtime.snapshot(pid).render_count

    send(pid, :dashfloat_tick)

    # Wait until the server has processed the tick (it appears in the trace)…
    await_trace(pid, fn events ->
      Enum.any?(events, &tick_message?/1)
    end)

    # …then confirm the processed tick drew nothing. An unsuppressed return
    # would render immediately here: the mailbox is empty at idle.
    traced = Runtime.trace_events(pid)
    assert Enum.any?(traced, &tick_message?/1)
    assert Runtime.snapshot(pid).render_count == before_count
  end

  defp tick_message?(%{kind: :message, details: %{source: :info, payload: :dashfloat_tick}}),
    do: true

  defp tick_message?(_other), do: false

  defp await_trace(pid, predicate, tries \\ 100) do
    traced = Runtime.trace_events(pid)

    if predicate.(traced) or tries == 0 do
      :ok
    else
      Process.sleep(10)
      await_trace(pid, predicate, tries - 1)
    end
  end

  test "renders increase while a turn is live and freeze again after :idle" do
    {:ok, pid} = start_tui()

    submit(pid, "animate")
    assert_receive {:prompt, ui_pid, "animate"}, 1_000

    # While active there is always a tick pending and the frame counter climbs.
    eventually(pid, fn s -> s.phase == :streaming and s.tick_ref != nil end)
    during = Runtime.snapshot(pid).render_count
    Process.sleep(250)
    assert Runtime.snapshot(pid).render_count > during

    # The tick stepped the spinner while the turn was open.
    stepped = eventually(pid, fn s -> s.anim_step > 0 end)
    assert stepped.anim_step > 0

    send(ui_pid, {:phase, :idle})
    state = eventually(pid, fn s -> s.phase == :idle and s.tick_ref == nil end)
    assert state.tick_ref == nil

    # ...and the timer is gone: another quiet window changes nothing.
    frozen = Runtime.snapshot(pid).render_count
    Process.sleep(300)
    assert Runtime.snapshot(pid).render_count == frozen
  end

  test "the render counter is the metric of record: it ticks during activity only" do
    {:ok, pid} = start_tui()

    idle_before = Runtime.snapshot(pid).render_count
    submit(pid, "rate")
    assert_receive {:prompt, ui_pid, "rate"}, 1_000
    eventually(pid, fn s -> s.phase == :streaming end)

    # Sample across a quiet gap: the activity tick alone drives renders.
    start_count = Runtime.snapshot(pid).render_count
    Process.sleep(400)
    active_delta = Runtime.snapshot(pid).render_count - start_count
    assert active_delta >= 2, "expected tick-driven renders, saw #{active_delta}"

    send(ui_pid, {:phase, :idle})
    eventually(pid, fn s -> s.phase == :idle and s.tick_ref == nil end)
    idle_after = Runtime.snapshot(pid).render_count
    Process.sleep(300)
    assert Runtime.snapshot(pid).render_count == idle_after
    assert idle_after > idle_before
  end

  test "a usage frame reconciles token counts before the terminal idle phase" do
    {:ok, pid} = start_tui()
    :ok = Runtime.enable_trace(pid, limit: 500)

    submit(pid, "count me")
    assert_receive {:prompt, ui_pid, "count me"}, 1_000

    send(ui_pid, {:token, "Hello"})
    send(ui_pid, {:usage, %{prompt_tokens: 120, completion_tokens: 42, total_tokens: 162}})
    send(ui_pid, {:phase, :idle})

    state = eventually(pid, fn s -> s.phase == :idle and s.in_flight == nil end)

    assert state.stats.prompt_tokens == 120
    assert state.stats.completion_tokens == 42
    assert state.stats.context_total == 162
    assert entry?(state, :assistant, "Hello")

    # Ordering proof: the usage message is handled before the idle phase.
    traced = Runtime.trace_events(pid)
    payloads = for(%{kind: :message, details: %{payload: payload}} <- traced, do: payload)

    usage_at = Enum.find_index(payloads, &match?({:usage, _usage}, &1))
    idle_at = Enum.find_index(payloads, &(&1 == {:phase, :idle}))
    assert usage_at != nil and idle_at != nil
    assert usage_at < idle_at

    assert status_text(state) =~ "ctx 162"
  end

  test "tool rows land in the log and the executing_tool phase names itself" do
    {:ok, pid} = start_tui()

    send(pid, {:tool_call, %{id: "t1", name: "read_file", args: %{"path" => "lib/foo.ex"}}})

    state = eventually(pid, fn s -> s.entries != [] end)

    assert [%{kind: :tool, text: "⚙ read_file lib/foo.ex", lines: lines}] = state.entries
    assert flatten_lines(lines) == ["", "⚙ read_file lib/foo.ex"]

    send(
      pid,
      {:tool_result, %{id: "t1", name: "read_file", ok: true, status: "ok", output: "one\ntwo"}}
    )

    eventually(pid, fn s -> length(s.entries) == 2 end)

    send(pid, {:phase, :executing_tool})
    tool_phase = eventually(pid, fn s -> s.phase == :executing_tool end)
    assert status_text(tool_phase) =~ "Running tool"

    send(pid, {:phase, :idle})
    eventually(pid, &(&1.phase == :idle))
  end

  test "the full confirm round trip: preview, decision, and swallowed keys" do
    {:ok, pid} = start_tui()
    submit(pid, "edit that file")
    assert_receive {:prompt, ui_pid, "edit that file"}, 1_000

    ref = make_ref()

    send(
      ui_pid,
      {:confirm, ref,
       %{
         id: "call_1",
         name: "write_file",
         args: %{"path" => "lib/foo.ex"},
         lines: ["@@ -1,2 +1,3 @@", "- old line", "+ new line", "$ mix format lib/foo.ex"]
       }}
    )

    state = eventually(pid, fn s -> s.phase == :confirming end)
    assert state.confirm == %{ref: ref, id: "call_1", name: "write_file"}

    # The preview landed as a tool entry (blank separator + 4 preview rows).
    [preview] = for(%{kind: :tool} = entry <- state.entries, do: entry)
    assert preview.text == "@@ -1,2 +1,3 @@\n- old line\n+ new line\n$ mix format lib/foo.ex"

    assert flatten_lines(preview.lines) == [
             "",
             "@@ -1,2 +1,3 @@",
             "- old line",
             "+ new line",
             "$ mix format lib/foo.ex"
           ]

    # The activity line prompts the decision instead of offering interrupt.
    assert activity_text(state) =~ "Approve this change?"
    assert activity_text(state) =~ "⏎ approve · esc reject"

    # Everything but Enter/Esc is swallowed — keys and pastes alike, the
    # draft stays untouched.
    press(pid, "x")
    press(pid, "enter", ["shift"])
    inject(pid, %ExRatatui.Event.Paste{content: "pasted mid-decision"})
    swallowed = get_state(pid)
    assert State.input_text(swallowed) == ""

    # Enter approves: the decision carries the confirm ref to the agent.
    press(pid, "enter")
    assert_receive {:confirm_decision, ^ref, :approved}, 1_000

    decided = eventually(pid, fn s -> s.confirm == nil end)
    assert decided.phase == :confirming

    # The agent resumes — a tool result rows in, then the turn ends.
    send(
      ui_pid,
      {:tool_result,
       %{id: "call_1", name: "write_file", ok: true, status: "ok", output: "wrote 3 lines"}}
    )

    send(ui_pid, {:phase, :idle})
    approved = eventually(pid, fn s -> s.phase == :idle end)
    assert entry?(approved, :tool, "⚙ write_file → ok\nwrote 3 lines")

    # Second round: Esc rejects.
    ref2 = make_ref()
    send(ui_pid, {:confirm, ref2, confirm_request(["+ again"])})
    eventually(pid, fn s -> s.confirm != nil end)

    press(pid, "esc")
    assert_receive {:confirm_decision, ^ref2, :rejected}, 1_000

    send(
      ui_pid,
      {:tool_result,
       %{id: "call_2", name: "write_file", ok: false, status: "cancelled", output: nil}}
    )

    send(ui_pid, {:phase, :idle})
    rejected = eventually(pid, fn s -> s.phase == :idle end)
    assert entry?(rejected, :tool, "⚙ write_file → cancelled")
    assert State.input_text(rejected) == ""
  end

  test "child_spec/1 is temporary and a worker" do
    spec = TUI.child_spec([])
    assert spec.type == :worker
    assert spec.restart == :temporary
  end

  test "exit_code/1 maps only an explicit quit to success" do
    assert TUI.exit_code(:normal) == 0
    assert TUI.exit_code(:shutdown) == 1
    assert TUI.exit_code({:error, :boom}) == 1
  end

  test "the TUI and agent are absent from the application supervision tree in test env" do
    children = Supervisor.which_children(DashFloat.Supervisor)
    child_ids = Enum.map(children, &elem(&1, 0))
    # the task supervisor is up; the TUI and agent are gated out of :test
    assert DashFloat.TaskSupervisor in child_ids
    refute TUI in child_ids
    refute DashFloat.Agent in child_ids
  end

  defp confirm_request(lines), do: %{id: "c", name: "write_file", args: %{}, lines: lines}

  defp inject(pid, event) do
    GenServer.call(pid, {:ex_ratatui_runtime_inject_event, event})
  end

  defp status_text(state) do
    {widget, _rect} =
      state
      |> View.render(%ExRatatui.Frame{width: 80, height: 24})
      |> List.first()

    [line] = widget.text
    Enum.map_join(line.spans, "", & &1.content)
  end

  defp activity_text(state) do
    {widget, _rect} =
      state
      |> View.render(%ExRatatui.Frame{width: 80, height: 24})
      |> Enum.at(2)

    [line] = widget.text
    Enum.map_join(line.spans, "", & &1.content)
  end

  defp flatten_lines(lines),
    do: Enum.map(lines, &Enum.map_join(&1.spans, "", fn span -> span.content end))

  defp attach_disconnect_listener do
    handler_id = {:disconnect_test, make_ref()}
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:ex_ratatui, :transport, :disconnect],
      fn _event, _measurements, %{reason: reason}, _config ->
        # Runs inside the TUI process; send to the captured test pid.
        send(test_pid, {:transport_disconnect, reason})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end
end
