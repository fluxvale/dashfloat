defmodule DashFloat.TestTeardown do
  @moduledoc """
  Teardown helpers for processes a test hands to `on_exit`.

  `if Process.alive?(pid), do: GenServer.stop(pid)` is a check-then-act race:
  a server that dies between the two calls makes `GenServer.stop` exit the
  on_exit handler, failing the test in teardown after its assertions passed
  with `:noproc`. Observed as a suite flake (chat_stream's malformed-usage
  cell, and on plain main).

  A concurrent death reaches the caller as `{reason, {GenServer, :stop, _}}`,
  where `reason` is `:noproc` for an already-dead process or the dying
  process's own exit reason. `reason` is itself `{inner, {:sys, :terminate,
  _}}` when the server was already inside `terminate/2` — so one level of
  both wrappers is unwrapped before deciding.

  The rule is about the INNER reason: "already gone" (`:noproc`) and the
  `:shutdown` family mean "not running, and not because it crashed";
  everything else propagates. The family's term payload is deliberately not
  inspected — OTP reserves `:shutdown`/`{:shutdown, term}` for controlled
  termination (supervisors do not count it toward restart intensity, and a
  supervisor stopping a child is exactly the case teardown wants), so it
  cannot hide a crash. A genuine crash surfaces as its own reason and still
  fails the suite loudly.

  No hang risk is added: this is the same `GenServer.stop/1` call the old
  shape made, and ExUnit runs on_exit callbacks under the test timeout.
  """

  @doc "Stops `pid` if it is still running; an already-dead process is fine."
  @spec stop(pid()) :: :ok
  def stop(pid) when is_pid(pid) do
    GenServer.stop(pid)
  catch
    :exit, payload ->
      if controlled_exit?(payload), do: :ok, else: :erlang.raise(:exit, payload, [])
  end

  # GenServer.stop/1 raises `{reason, {GenServer, :stop, _}}`; `reason` gains
  # another `{_inner, {:sys, :terminate, _}}` wrap when the server had already
  # begun terminating. Unwrap both, then judge the innermost reason.
  defp controlled_exit?({reason, {GenServer, :stop, _call}}), do: shutdown_family?(unwrap(reason))
  defp controlled_exit?(_payload), do: false

  defp unwrap({inner, {:sys, :terminate, _call}}), do: inner
  defp unwrap(reason), do: reason

  defp shutdown_family?(:noproc), do: true
  defp shutdown_family?(:shutdown), do: true
  defp shutdown_family?({:shutdown, _term}), do: true
  defp shutdown_family?(_other), do: false
end
