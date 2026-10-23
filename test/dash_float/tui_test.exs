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

  defp start_tui(opts \\ @opts) do
    # Unlink: the supervisor must outlive the test process so on_exit can
    # stop it (and the TUI) deterministically.
    {:ok, sup} =
      Supervisor.start_link(
        [%{id: TUI, start: {TUI, :start_link, [opts]}, type: :worker, restart: :temporary}],
        strategy: :one_for_one
      )

    Process.unlink(sup)

    on_exit(fn -> if Process.alive?(sup), do: Supervisor.stop(sup) end)

    [{TUI, pid, :worker, _}] = Supervisor.which_children(sup)
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
    Enum.each(String.codepoints(text), &press(pid, &1))
  end

  defp get_state(pid) do
    send(pid, {:inspect_state, self()})

    receive do
      {:tui_state, state} -> state
    after
      1_000 -> flunk("no state reply from #{inspect(pid)}")
    end
  end

  defp eventually(pid, fun, tries \\ 100) do
    state = get_state(pid)

    if fun.(state) do
      state
    else
      true = tries > 0

      receive do
        _ -> :ok
      after
        20 -> :ok
      end

      eventually(pid, fun, tries - 1)
    end
  end

  test "supervised start renders, typed input accumulates, and submit echoes to the log" do
    {:ok, pid} = start_tui()
    assert Runtime.snapshot(pid).render_count >= 1

    type(pid, "hello tui")
    assert State.input_text(get_state(pid)) == "hello tui"

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
    send(pid, {:phase, :bogus})

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
    assert State.input_text(get_state(pid)) == "second"
    press(pid, "up")
    assert State.input_text(get_state(pid)) == "first"
    press(pid, "down")
    press(pid, "down")
    assert State.input_text(get_state(pid)) == ""
  end

  @tag :capture_log
  test "the UI stays responsive while a flood of updates lands" do
    {:ok, pid} = start_tui()
    flood_size = 500

    flooder =
      spawn(fn ->
        Enum.each(1..flood_size, fn i -> send(pid, {:token, "w#{i} "}) end)
      end)

    ref = Process.monitor(flooder)
    before = Runtime.snapshot(pid).render_count

    # A key event routed through the same mailbox as the token flood: the
    # round-trip includes draining whatever arrived before it.
    {micros, :ok} = :timer.tc(fn -> press(pid, "z") end)
    millis = div(micros, 1000)
    assert millis < 1_000, "input round-trip took #{millis}ms under a #{flood_size}-message flood"

    assert_receive {:DOWN, ^ref, :process, ^flooder, :normal}, 1_000

    # Every token landed and the typed character was kept — nothing dropped,
    # nothing blocked.
    state =
      eventually(pid, fn s -> String.contains?(s.in_flight || "", "w#{flood_size} ") end)

    assert State.input_text(state) =~ "z"

    # Frame coalescing: hundreds of messages produced few frames, so the loop
    # is not doing per-message work.
    assert Runtime.snapshot(pid).render_count - before < 200
  end

  test "the app is absent from the application supervision tree in test env" do
    assert Process.whereis(DashFloat.StreamSupervisor) != nil
    # Live mode registers the TUI under its module name; in :test it must
    # not be there.
    assert Process.whereis(DashFloat.TUI) == nil
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
