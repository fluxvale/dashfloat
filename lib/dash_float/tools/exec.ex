defmodule DashFloat.Tools.Exec do
  @moduledoc """
  Port-based shell command execution with a total wall-clock timeout and a
  head cap on output.

  Erlang's `{:spawn, command}` runs `sh -c "exec <command>"`, which silently
  drops everything after a `;` or `&&` and rejects shell builtins — so the
  command is POSIX-single-quote-wrapped for `/bin/sh -c` first, giving true
  shell-line semantics (verified: `echo hi; exit 3` exits 3, not 0).

  A missing or unusable `cwd` fails before the port opens (the port itself
  reports a bad `cd` as exit status 2, indistinguishable from a command that
  exits 2). Output past the cap is still consumed and counted, never
  accumulated.

  On completion — normal exit OR timeout OR cancel — the command's process
  group is SIGKILLed: `Port.close/1` only closes the pipes, and a program that
  never reads stdin (a busy shell loop) survives it — verified on this
  system, where it would spin at 100% CPU forever. Group-killing the normal
  path also reaps same-group children the command left behind (a child that
  escapes via `setsid` survives this — closing that needs a process-level
  sandbox). The group id is learned at spawn, not from the port: a wrapper
  shell writes its own pid — as the spawned child's session leader, the pid
  IS the pgid — into a tracker file before exec'ing the command, so the kill
  never depends on the port being alive (`Port.info/2` returns nil once a
  fast-exiting program is gone, which used to skip the kill and leak its
  background children — issue #59). Spawned children lead their own session,
  so killing the negative pid takes the entire group; the killer runs with
  its stderr silenced because after a clean exit the group is usually already
  gone and kill(1) would otherwise complain on the BEAM's stderr.
  """

  alias DashFloat.Tools.Edit
  alias DashFloat.Tools.Exec.Group

  @drain_grace 10

  @doc """
  Runs `command` in `cwd`, returning `%{ok, exit, output, truncated,
  total_bytes}` on exit, a `timed out after <ms>ms` map on timeout, or a
  `spawn failed` map when `cwd` is unusable. A `:cancel` message delivered to
  the caller mid-run (the agent's Esc interrupt) kills the process group and
  returns `%{ok: false, cancelled: true, …}` with the partial output.
  """
  @spec run(String.t(), Path.t(), pos_integer(), non_neg_integer()) :: map()
  def run(command, cwd, timeout_ms, cap_bytes)
      when is_binary(command) and is_binary(cwd) and is_integer(timeout_ms) and timeout_ms > 0 and
             is_integer(cap_bytes) and cap_bytes >= 0 do
    case File.stat(cwd) do
      {:ok, %File.Stat{type: :directory}} ->
        spawn_tracked(command, cwd, timeout_ms, cap_bytes)

      {:ok, _stat} ->
        %{ok: false, exit: nil, error: "spawn failed: not a directory: " <> cwd}

      {:error, reason} ->
        %{ok: false, exit: nil, error: "spawn failed: " <> to_string(:file.format_error(reason))}
    end
  end

  # No fallback when arming fails: without a tracker the group kill would
  # again depend on the port's lifetime, so an unusable tmp dir refuses the
  # spawn honestly (see ADR 0013).
  defp spawn_tracked(command, cwd, timeout_ms, cap_bytes) do
    case Group.arm() do
      {:ok, tracker} ->
        deadline = System.monotonic_time(:millisecond) + timeout_ms

        port =
          Port.open(
            {:spawn, Group.wrap(command, tracker)},
            [:binary, :stream, :use_stdio, :stderr_to_stdout, :exit_status, {:cd, cwd}]
          )

        loop(port, tracker, deadline, timeout_ms, cap_bytes, "", 0, false)

      {:error, reason} ->
        %{
          ok: false,
          exit: nil,
          error: "spawn failed: cannot arm the process-group tracker: " <> reason
        }
    end
  end

  # The receive timeout is an absolute deadline (recomputed after every
  # message), so a producer that never idles still dies at timeout_ms.
  defp loop(port, tracker, deadline, timeout_ms, cap, output, total, truncated) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      timed_out(port, tracker, timeout_ms, output, total, truncated)
    else
      receive do
        # The user's Esc: kill the group (a bare Port.close would leak the
        # program spinning), swallow the dying output, report the cancel.
        :cancel ->
          cancelled(port, tracker, output, total, truncated)

        {^port, {:data, data}} ->
          {output, total, truncated} = take(data, cap, output, total, truncated)
          loop(port, tracker, deadline, timeout_ms, cap, output, total, truncated)

        {^port, {:exit_status, status}} ->
          Group.reap(tracker, port)
          {output, truncated} = stamp(output, total, truncated)

          %{
            ok: status == 0,
            exit: status,
            output: sanitize(output),
            truncated: truncated,
            total_bytes: total
          }
      after
        remaining ->
          timed_out(port, tracker, timeout_ms, output, total, truncated)
      end
    end
  end

  defp cancelled(port, tracker, output, total, truncated) do
    Group.reap(tracker, port)
    drain(port)
    {output, truncated} = stamp(output, total, truncated)

    %{
      ok: false,
      cancelled: true,
      exit: nil,
      output: sanitize(output),
      truncated: truncated,
      total_bytes: total
    }
  end

  defp timed_out(port, tracker, timeout_ms, output, total, truncated) do
    # No Port.close here: the SIGKILL below terminates the program (and with
    # it the port) — closing a port the kill already ended raises. The drain
    # swallows whatever the dying program flushed, including its exit_status.
    Group.reap(tracker, port)
    drain(port)
    {output, truncated} = stamp(output, total, truncated)

    %{
      ok: false,
      exit: nil,
      error: "timed out after #{timeout_ms}ms",
      output: sanitize(output),
      truncated: truncated,
      total_bytes: total
    }
  end

  # Tool output goes back to the model as JSON: replace invalid UTF-8 bytes
  # (a partial cap split, or binary command output) so encoding cannot fail.
  defp sanitize(binary), do: Edit.sanitize(binary)

  defp take(data, cap, output, total, truncated) do
    total = total + byte_size(data)
    room = cap - byte_size(output)
    size = byte_size(data)

    cond do
      room >= size -> {output <> data, total, truncated}
      room > 0 -> {output <> binary_part(data, 0, room), total, true}
      true -> {output, total, true}
    end
  end

  defp stamp(output, _total, false), do: {output, false}

  defp stamp(output, total, true) do
    {output <> "\n… [output truncated: showing #{byte_size(output)} of #{total} bytes]", true}
  end

  # After a timeout close, messages already in flight must not linger in the
  # caller's mailbox; each surviving message extends the grace period.
  defp drain(port) do
    receive do
      {^port, _message} -> drain(port)
    after
      @drain_grace -> :ok
    end
  end
end
