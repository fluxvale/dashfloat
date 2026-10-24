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

  On completion — normal exit OR timeout — the command's process group is
  SIGKILLed: `Port.close/1` only closes the pipes, and a program that
  never reads stdin (a busy shell loop) survives it — verified on this
  system, where it would spin at 100% CPU forever. Group-killing the normal
  path also reaps same-group children the command left behind (a child that
  escapes via `setsid` survives this — closing that needs a process-level
  sandbox). Spawned children lead their own session, so killing the
  negative pid takes the entire group; the killer runs with its stderr
  silenced because after a clean exit the group is usually already gone and
  kill(1) would otherwise complain on the BEAM's stderr.
  """

  alias DashFloat.Tools.Edit

  @drain_grace 10
  @shell "/bin/sh"
  @kill_executable "/bin/kill"

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
        deadline = System.monotonic_time(:millisecond) + timeout_ms

        port =
          Port.open(
            {:spawn, shell(command)},
            [:binary, :stream, :use_stdio, :stderr_to_stdout, :exit_status, {:cd, cwd}]
          )

        loop(port, birth_pid(port), deadline, timeout_ms, cap_bytes, "", 0, false)

      {:ok, _stat} ->
        %{ok: false, exit: nil, error: "spawn failed: not a directory: " <> cwd}

      {:error, reason} ->
        %{ok: false, exit: nil, error: "spawn failed: " <> to_string(:file.format_error(reason))}
    end
  end

  # Captured at birth: once the program exits, Port.info returns nil and the
  # group id (== the program's pid) would be unfindable. A program that dies
  # within the Port.open window (echo) can already be gone here — nothing to
  # signal, the exit_status still arrives.
  defp birth_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> pid
      # Belt: same race window as signal_group/2's nil clause.
      # coveralls-ignore-next-line
      _already_gone -> nil
    end
  end

  # The receive timeout is an absolute deadline (recomputed after every
  # message), so a producer that never idles still dies at timeout_ms.
  defp loop(port, os_pid, deadline, timeout_ms, cap, output, total, truncated) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      timed_out(port, os_pid, timeout_ms, output, total, truncated)
    else
      receive do
        # The user's Esc: kill the group (a bare Port.close would leak the
        # program spinning), swallow the dying output, report the cancel.
        :cancel ->
          cancelled(port, os_pid, output, total, truncated)

        {^port, {:data, data}} ->
          {output, total, truncated} = take(data, cap, output, total, truncated)
          loop(port, os_pid, deadline, timeout_ms, cap, output, total, truncated)

        {^port, {:exit_status, status}} ->
          signal_group(port, os_pid)
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
          timed_out(port, os_pid, timeout_ms, output, total, truncated)
      end
    end
  end

  defp cancelled(port, os_pid, output, total, truncated) do
    signal_group(port, os_pid)
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

  defp timed_out(port, os_pid, timeout_ms, output, total, truncated) do
    # No Port.close here: the SIGKILL below terminates the program (and with
    # it the port) — closing a port the kill already ended raises. The drain
    # swallows whatever the dying program flushed, including its exit_status.
    signal_group(port, os_pid)
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

  # Spawned children lead their own session, so the negative pid is the whole
  # process group — the program itself plus anything it left behind. The tiny
  # pid-reuse window between a group's death and this signal is accepted
  # (wrapping pid_max takes far longer than the run of a command). The
  # killer's stderr is silenced: after a clean exit the group is usually
  # already gone and kill(1) would otherwise complain on the BEAM's stderr.
  #
  # Belt for the instant-death window between Port.open and Port.info: only
  # observed under scheduler load (a coverage-instrumented run), never
  # deterministic in a test. A nil birth pid may just mean the handshake was
  # slow — re-query while the program lives; only a truly dead program (or a
  # fast one whose children already died with it) yields nil again.
  # coveralls-ignore-start
  defp signal_group(port, nil) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> kill_group(os_pid)
      _gone -> :ok
    end
  end

  # coveralls-ignore-stop
  defp signal_group(_port, os_pid), do: kill_group(os_pid)

  defp kill_group(os_pid) do
    group = Integer.to_string(-os_pid)

    killer =
      Port.open(
        {:spawn_executable, @shell},
        [:exit_status, {:args, ["-c", "exec #{@kill_executable} -9 #{group} 2>/dev/null"]}]
      )

    # kill(1) only delivers a signal; it always exits promptly.
    receive do
      {^killer, {:exit_status, _status}} -> :ok
    end
  end

  # POSIX single-quote escaping: ' -> '\''
  defp shell(command), do: "/bin/sh -c '" <> String.replace(command, "'", "'\\''") <> "'"
end
