defmodule DashFloat.TestTeardownTest do
  @moduledoc false
  # Regression guard for the teardown race: a process dying between
  # `Process.alive?/1` and `GenServer.stop/1` used to fail the test in its
  # on_exit handler, after the assertions had already passed.
  #
  # The tests below reach the race DETERMINISTICALLY rather than by looping:
  # a server parked inside a slow `terminate/2` is already terminating when
  # `stop/1` lands, which produces each payload shape reproducibly. A
  # "stop a fully-dead pid" test looks similar but always yields plain
  # `:noproc`, so it passes with the shutdown clauses deleted — it guards
  # nothing. That vacuity was caught by hostile review (mutation-proven).
  use ExUnit.Case, async: true

  test "stopping an already-dead process is success, not :noproc" do
    {:ok, pid} = Agent.start_link(fn -> :ok end)
    Agent.stop(pid)

    # The old shape raises; this is the mechanism, pinned.
    assert {:noproc, _call} = catch_exit(GenServer.stop(pid))
    assert DashFloat.TestTeardown.stop(pid) == :ok
  end

  test "a bare :shutdown caught mid-terminate is success" do
    pid = start_and_kill(:shutdown)
    assert DashFloat.TestTeardown.stop(pid) == :ok
  end

  test "a payloaded shutdown caught mid-terminate is success" do
    pid = start_and_kill({:shutdown, :done})
    assert DashFloat.TestTeardown.stop(pid) == :ok
  end

  # A crash is NOT swallowed: a server that died from a bug must keep failing
  # loudly rather than being swept up by teardown. Mid-terminate the payload
  # is `{{:boom, {:sys, :terminate, _}}, {GenServer, :stop, _}}` — the same
  # unwrapping that recognises the shutdown family must not absorb it.
  test "a crash reason still propagates, mid-terminate" do
    pid = start_and_kill(:boom)

    assert {{:boom, {:sys, :terminate, _call}}, {GenServer, :stop, _stop_call}} =
             catch_exit(DashFloat.TestTeardown.stop(pid))
  end

  test "a live process is still stopped" do
    {:ok, pid} = Agent.start_link(fn -> :ok end)
    ref = Process.monitor(pid)

    assert DashFloat.TestTeardown.stop(pid) == :ok
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000
  end

  # Park a server inside terminate/2, then call stop/1 so it lands mid-flight:
  # the server has begun terminating, so its own reason reaches the caller.
  defp start_and_kill(reason) do
    {:ok, pid} = __MODULE__.SlowTerminate.start_link(reason)
    Process.unlink(pid)
    send(pid, {:die, reason})
    # Land inside the terminate sleep, never before the system message.
    Process.sleep(20)
    pid
  end

  defmodule SlowTerminate do
    @moduledoc false
    # Terminates slowly on request, so a concurrent stop/1 lands mid-terminate.
    use GenServer

    @spec start_link(term()) :: GenServer.on_start()
    def start_link(reason), do: GenServer.start_link(__MODULE__, reason)

    @impl GenServer
    @spec init(term()) :: {:ok, term()}
    def init(reason), do: {:ok, reason}

    @impl GenServer
    @spec handle_info(term(), term()) :: {:stop, term(), term()}
    def handle_info({:die, reason}, state), do: {:stop, reason, state}

    @impl GenServer
    @spec terminate(term(), term()) :: :ok
    def terminate(_reason, _state) do
      Process.sleep(300)
      :ok
    end
  end
end
