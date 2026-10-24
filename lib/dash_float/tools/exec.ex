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

  On timeout the command's whole process group is SIGKILLed before the port
  closes: `Port.close/1` only closes the pipes, and a program that never
  reads stdin (a busy shell loop) survives it — verified on this system,
  where it would spin at 100% CPU forever. Spawned children lead their own
  session, so killing the negative pid takes the entire tree.
  """

  @drain_grace 10
  @kill_executable "/bin/kill"

  @doc """
  Runs `command` in `cwd`, returning `%{ok, exit, output, truncated,
  total_bytes}` on exit, a `timed out after <ms>ms` map on timeout, or a
  `spawn failed` map when `cwd` is unusable.
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

        loop(port, deadline, timeout_ms, cap_bytes, "", 0, false)

      {:ok, _stat} ->
        %{ok: false, exit: nil, error: "spawn failed: not a directory: " <> cwd}

      {:error, reason} ->
        %{ok: false, exit: nil, error: "spawn failed: " <> to_string(:file.format_error(reason))}
    end
  end

  # The receive timeout is an absolute deadline (recomputed after every
  # message), so a producer that never idles still dies at timeout_ms.
  defp loop(port, deadline, timeout_ms, cap, output, total, truncated) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      timed_out(port, timeout_ms, output, total, truncated)
    else
      receive do
        {^port, {:data, data}} ->
          {output, total, truncated} = take(data, cap, output, total, truncated)
          loop(port, deadline, timeout_ms, cap, output, total, truncated)

        {^port, {:exit_status, status}} ->
          {output, truncated} = stamp(output, total, truncated)

          %{
            ok: status == 0,
            exit: status,
            output: output,
            truncated: truncated,
            total_bytes: total
          }
      after
        remaining ->
          timed_out(port, timeout_ms, output, total, truncated)
      end
    end
  end

  defp timed_out(port, timeout_ms, output, total, truncated) do
    # No Port.close here: the SIGKILL below terminates the program (and with
    # it the port) — closing a port the kill already ended raises. The drain
    # swallows whatever the dying program flushed, including its exit_status.
    kill_tree(port)
    drain(port)
    {output, truncated} = stamp(output, total, truncated)

    %{
      ok: false,
      exit: nil,
      error: "timed out after #{timeout_ms}ms",
      output: output,
      truncated: truncated,
      total_bytes: total
    }
  end

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

  defp kill_tree(port) do
    {:os_pid, os_pid} = Port.info(port, :os_pid)
    group = Integer.to_string(-os_pid)

    killer =
      Port.open(
        {:spawn_executable, @kill_executable},
        [:exit_status, {:args, ["-9", group]}]
      )

    # kill(1) only delivers a signal; it always exits promptly.
    receive do
      {^killer, {:exit_status, _status}} -> :ok
    end
  end

  # POSIX single-quote escaping: ' -> '\''
  defp shell(command), do: "/bin/sh -c '" <> String.replace(command, "'", "'\\''") <> "'"
end
