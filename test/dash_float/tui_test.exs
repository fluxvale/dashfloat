defmodule DashFloat.TUITest do
  @moduledoc """
  App-level tests under `test_mode`: supervised lifecycle, teardown paths
  (including crashes), the synthetic-update demo, and the responsiveness
  proof. Not async: they measure timing and share telemetry handlers.
  """

  use ExUnit.Case, async: false

  alias DashFloat.TUI
  alias DashFloat.TUI.State
  alias ExRatatui.Runtime

  @opts [test_mode: {80, 24}, name: nil, demo_stream_opts: [interval_ms: 1, sentences: 1]]

  defp start_tui(opts \\ []) do
    opts = Keyword.merge(@opts, opts)

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

    [{TUI, pid, :worker, _args}] = Supervisor.which_children(sup)
    {:ok, pid}
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

  # The runtime's own state carries our user_state; no test backdoor needed.
  defp get_state(pid) do
    runtime_state = :sys.get_state(pid)
    Map.get(runtime_state, :user_state)
  end

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

  test "supervised start renders, typed input accumulates, and submit echoes to the log" do
    {:ok, pid} = start_tui()
    assert Runtime.snapshot(pid).render_count >= 1

    type(pid, "hello tui")
    typed = get_state(pid)
    assert State.input_text(typed) == "hello tui"

    press(pid, "enter")

    state =
      eventually(pid, fn s -> s.phase == :idle and s.entries != [{:user, "hello tui"}] end)

    assert {:user, "hello tui"} in state.entries
    assert state.history == ["hello tui"]

    # The synthetic demo lands an assistant reply plus the tool interlude.
    assert Enum.any?(state.entries, fn {k, text} -> k == :tool and text =~ "[tool]" end)
    assert match?({:assistant, _}, List.last(state.entries))
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
    type(pid, "first")
    press(pid, "enter")
    eventually(pid, &(&1.phase == :idle))
    type(pid, "second")
    press(pid, "enter")
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

  test "a dead producer degrades to idle instead of bricking input" do
    # Slow cadence so the producer is still alive when we kill it.
    {:ok, pid} = start_tui(demo_stream_opts: [interval_ms: 100, sentences: 3])
    type(pid, "hello")
    press(pid, "enter")

    [task] = Task.Supervisor.children(DashFloat.StreamSupervisor)
    Process.exit(task, :kill)

    state =
      eventually(pid, fn s ->
        s.phase == :idle and
          Enum.any?(s.entries, fn {k, t} -> k == :system and t =~ "stream failed" end)
      end)

    assert state.task_ref == nil
    assert {:user, "hello"} in state.entries

    # Input is usable again: submit works.
    type(pid, "again")
    press(pid, "enter")
    eventually(pid, fn s -> s.phase == :streaming and State.input_text(s) == "" end)
  end

  test "a fast producer never logs spurious stream failures (noproc race)" do
    # interval_ms: 0 finishes inside the start_child→monitor window — the
    # DOWN arrives as :noproc, which must be treated as success.
    {:ok, pid} = start_tui(demo_stream_opts: [interval_ms: 0, sentences: 1])

    Enum.each(1..3, fn i ->
      type(pid, "q#{i}")
      press(pid, "enter")

      eventually(pid, fn s ->
        s.phase == :idle and match?({:assistant, _}, List.last(s.entries))
      end)
    end)

    state = get_state(pid)
    assert state.task_ref == nil

    refute Enum.any?(state.entries, fn {kind, text} ->
             kind == :system and String.contains?(text, "stream failed")
           end)
  end

  @tag :capture_log
  test "the UI stays responsive while a stream lands at cadence into a large log" do
    {:ok, pid} = start_tui()

    # Preload a log far beyond the viewport (400 lines).
    Enum.each(1..400, fn i -> send(pid, {:entry, :system, "warm #{i}"}) end)
    eventually(pid, &(State.log_line_count(&1) == 400))

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

  test "exit_code/1 maps only an explicit quit to success" do
    assert TUI.exit_code(:normal) == 0
    assert TUI.exit_code(:shutdown) == 1
    assert TUI.exit_code({:error, :boom}) == 1
  end

  test "the TUI is absent from the application supervision tree in test env" do
    children = Supervisor.which_children(DashFloat.Supervisor)
    child_ids = Enum.map(children, &elem(&1, 0))
    # the stream supervisor is up; the TUI is gated out of :test
    assert DashFloat.StreamSupervisor in child_ids
    refute TUI in child_ids
  end

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
