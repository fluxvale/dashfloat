defmodule DashFloat.TestTeardownTest do
  @moduledoc false
  # Regression guard for the teardown race: a process that dies between
  # `Process.alive?/1` and `GenServer.stop/1` used to fail the test in its
  # on_exit handler, after the assertions had already passed.
  use ExUnit.Case, async: true

  test "stopping an already-dead process is success, not :noproc" do
    {:ok, pid} = Agent.start_link(fn -> :ok end)
    Agent.stop(pid)

    # The old shape raises; this is the mechanism, pinned.
    assert {:noproc, _call} = catch_exit(GenServer.stop(pid))
    assert DashFloat.TestTeardown.stop(pid) == :ok
  end

  # The shutdown family is the second race shape: the server had already
  # begun terminating when stop/1 landed, so the caller sees the process's
  # own reason. Measured on OTP 29 (see the moduledoc); pinned here so a
  # refactor cannot drop the catches.
  test "the shutdown family is also success" do
    for reason <- [:shutdown, {:shutdown, :done}] do
      {:ok, pid} = Agent.start_link(fn -> :ok end)
      # Unlinked: the point is the exit reason `stop/1` observes, not a
      # linked crash taking the test down with it.
      Process.unlink(pid)
      Agent.stop(pid, reason)

      assert {_reason, _call} = catch_exit(GenServer.stop(pid))
      assert DashFloat.TestTeardown.stop(pid) == :ok
    end
  end

  # A crash is NOT swallowed: a server that died from a bug must keep
  # failing loudly rather than being swept up by teardown. A terminate
  # callback that exits surfaces as the bare reason (`:boom`), unlike the
  # shutdown family's `{reason, {GenServer, :stop, ...}}` — which is exactly
  # the line the helper draws.
  test "a crash reason still propagates" do
    {:ok, pid} = __MODULE__.CrashyServer.start_link(:ok)
    Process.unlink(pid)

    assert {:boom, _call} = catch_exit(DashFloat.TestTeardown.stop(pid))
  end

  test "a live process is still stopped" do
    {:ok, pid} = Agent.start_link(fn -> :ok end)
    ref = Process.monitor(pid)

    assert DashFloat.TestTeardown.stop(pid) == :ok
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000
  end

  defmodule CrashyServer do
    @moduledoc false
    # Exits from terminate/2 — the shape that must keep failing loudly.
    use GenServer

    @spec start_link(term()) :: GenServer.on_start()
    def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok)

    @impl GenServer
    @spec init(term()) :: {:ok, :ok}
    def init(:ok), do: {:ok, :ok}

    @impl GenServer
    @spec terminate(term(), term()) :: no_return()
    def terminate(_reason, :ok), do: exit(:boom)
  end
end
