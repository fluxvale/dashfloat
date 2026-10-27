defmodule DashFloat.TestTeardown do
  @moduledoc """
  Teardown helpers for processes a test hands to `on_exit`.

  `if Process.alive?(pid), do: GenServer.stop(pid)` is a check-then-act race:
  a server that dies between the two calls (an SSE server finishing its
  script, an agent whose stream already degraded) makes `GenServer.stop`
  exit the on_exit handler — the test then fails in teardown, after passing,
  with `:noproc`. Observed as a suite flake (chat_stream's malformed-usage
  cell). `stop/1` treats an already-dead process as success, which is the
  intent: teardown guarantees "not running", not "we were the one who
  stopped it".
  """

  @doc "Stops `pid` if it is still running; an already-dead process is fine."
  @spec stop(pid()) :: :ok
  def stop(pid) when is_pid(pid) do
    GenServer.stop(pid)
  catch
    :exit, {:noproc, _} -> :ok
    :exit, {:normal, _} -> :ok
  end
end
