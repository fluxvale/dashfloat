defmodule DashFloat.TestTeardown do
  @moduledoc """
  Teardown helpers for processes a test hands to `on_exit`.

  `if Process.alive?(pid), do: GenServer.stop(pid)` is a check-then-act race:
  a server that dies between the two calls makes `GenServer.stop` exit the
  on_exit handler, failing the test in teardown after its assertions passed
  with `:noproc`. Observed as a suite flake (chat_stream's malformed-usage
  cell, and on plain main).

  Race shapes measured on OTP 29 over ~32k aggressive iterations: a death
  concurrent with `stop/1` surfaces as `:noproc` (the common case) or, when
  the server began terminating first, as the process's own exit reason —
  `:shutdown` or `{:shutdown, term}`. `stop/1` therefore treats "already
  gone" and the shutdown family as success: both mean "not running, and not
  because it crashed". A genuine crash reason still propagates, so a
  server that died from a bug keeps failing the suite instead of being
  silently swept up.

  No hang risk is added: `GenServer.stop/1` here is the same call the old
  shape made, and ExUnit runs on_exit callbacks under the test timeout.
  """

  @doc "Stops `pid` if it is still running; an already-dead process is fine."
  @spec stop(pid()) :: :ok
  def stop(pid) when is_pid(pid) do
    GenServer.stop(pid)
  catch
    # GenServer.stop/1 exits with {reason, {GenServer, :stop, [pid, ...]}}.
    :exit, {:noproc, _call} -> :ok
    :exit, {:shutdown, _call} -> :ok
    :exit, {{:shutdown, _term}, _call} -> :ok
  end
end
