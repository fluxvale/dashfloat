defmodule DashFloat.TestTeardownTest do
  @moduledoc false
  # Regression guard for the teardown race: a process that dies between
  # `Process.alive?/1` and `GenServer.stop/1` used to fail the test in its
  # on_exit handler with :noproc, after the assertions had already passed.
  use ExUnit.Case, async: true

  test "stopping an already-dead process is success, not :noproc" do
    {:ok, pid} = Agent.start_link(fn -> :ok end)
    Agent.stop(pid)

    # The old shape raises; this is the mechanism, pinned.
    assert {:noproc, _call} = catch_exit(GenServer.stop(pid))
    assert DashFloat.TestTeardown.stop(pid) == :ok
  end

  test "a live process is still stopped" do
    {:ok, pid} = Agent.start_link(fn -> :ok end)
    ref = Process.monitor(pid)

    assert DashFloat.TestTeardown.stop(pid) == :ok
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000
  end
end
