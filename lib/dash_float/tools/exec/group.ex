defmodule DashFloat.Tools.Exec.Group do
  @moduledoc """
  Owns the exec process group: arming the tracker file, wrapping the command
  in a wrapper shell that reports its own pid before exec, and reaping the
  group on every completion path.

  The pgid must be learned at spawn, not queried from the port at reap time:
  `Port.info(port, :os_pid)` returns nil once the program has exited and the
  port is gone, which used to skip the kill and let a fast-exiting command's
  background children survive (issue #59). A `{:spawn, …}` child is a session
  and group leader — its pid IS its pgid — so the wrapper's `$$` is the pgid
  of everything the command spawns. See ADR 0013.
  """

  require Logger

  defstruct [:path]

  @type t :: %__MODULE__{path: String.t()}

  @report_tries 3
  @report_grace_ms 15
  @shell "/bin/sh"
  @kill_executable "/bin/kill"

  @doc """
  Pre-writes the tracker file, holding the sentinel `"0\n"` until the wrapper
  reports. The path is absolute (a relative `TMPDIR` resolves differently in
  the wrapper, which runs under the command's cwd), the name is unguessable,
  and the create is exclusive with 0600 — the same hardening
  `Runner.write_file/3` applies to its temp files — so a pre-planted symlink
  is never followed and no other user can write the file. Fails rather than
  degrading: a spawn without a tracker would again learn its pgid from the
  port and leak on fast exit.
  """
  @spec arm() :: {:ok, t()} | {:error, String.t()}
  def arm do
    dir = Path.expand(System.tmp_dir())

    rand = :crypto.strong_rand_bytes(8)
    name = "dashfloat-exec-" <> Base.encode16(rand, case: :lower) <> ".pgid"
    path = Path.join(dir, name)

    case File.open(path, [:write, :exclusive], &IO.write(&1, "0\n")) do
      {:ok, :ok} ->
        case File.chmod(path, 0o600) do
          :ok -> {:ok, %__MODULE__{path: path}}
          {:error, reason} -> {:error, to_string(:file.format_error(reason))}
        end

      {:error, reason} ->
        {:error, to_string(:file.format_error(reason))}
    end
  end

  @doc """
  Wraps `command` for `{:spawn, …}`: the wrapper shell reports its pid (the
  pgid) into the tracker, then execs the user command. The `&&` is
  load-bearing — if the report fails, the user command never runs, which is
  what makes a tracker still holding the sentinel a positive proof in
  `reap/2`.
  """
  @spec wrap(String.t(), t()) :: String.t()
  def wrap(command, tracker) do
    inner = "echo $$ > " <> shquote(tracker.path) <> " && exec #{@shell} -c " <> shquote(command)
    "#{@shell} -c " <> shquote(inner)
  end

  @doc """
  Kills the command's group on every completion path, by the pgid the wrapper
  reported — the port being dead does not matter — then removes the tracker
  file.
  """
  @spec reap(t(), port()) :: :ok
  def reap(tracker, port) do
    case read_pgid(tracker.path, @report_tries) do
      {:ok, pgid} ->
        kill_group(pgid)

      :sentinel ->
        # Belt for a completion that beats the wrapper's report (a :cancel
        # landing inside the spawn window): a live port's os_pid is the pgid.
        case Port.info(port, :os_pid) do
          {:os_pid, os_pid} ->
            kill_group(os_pid)

          # Dead port AND the sentinel never left the tracker: the wrapper's
          # `&&` never passed, so the user command was never exec'd — the
          # group only ever held the wrapper itself. Provably nothing to kill;
          # this is the proof issue #59's silent skip cannot come back.
          _gone ->
            :ok
        end

      # The tracker is missing or its content is not a report the wrapper
      # could have written: the pgid may have been reported and then lost (a
      # tmp cleaner, or the command deleting its own tracker), so
      # nothing-to-kill cannot be proven. Kill by the belt if the port still
      # answers; otherwise say so instead of skipping silently (issue #59).
      :unknown ->
        case Port.info(port, :os_pid) do
          {:os_pid, os_pid} ->
            kill_group(os_pid)

          _gone ->
            Logger.warning(
              "exec tracker #{tracker.path} unreadable at reap: " <>
                "cannot verify the command's process group was killed"
            )

            :ok
        end
    end

    File.rm(tracker.path)
    :ok
  end

  # The wrapper reports a moment after the port opens; a :cancel landing in
  # that window can read the sentinel while the write is still in flight —
  # give it a moment before treating the sentinel as final. Anything else
  # that is not a well-formed report is final immediately.
  defp read_pgid(path, tries) do
    case parse_pgid(path) do
      {:ok, pgid} ->
        {:ok, pgid}

      :sentinel when tries > 1 ->
        Process.sleep(@report_grace_ms)
        read_pgid(path, tries - 1)

      final ->
        final
    end
  end

  # A report is digits + newline and names a real process group (≥ 2; group 1
  # would make the kill target -1, every process the uid can signal). The
  # trailing newline is required — a torn prefix would otherwise be signalled
  # as a live pgid — and a non-regular file (a swapped-in FIFO would hang the
  # read) is never trusted.
  defp parse_pgid(path) do
    with {:ok, %File.Stat{type: :regular}} <- File.stat(path),
         {:ok, content} <- File.read(path) do
      classify(content)
    else
      _unreadable -> :unknown
    end
  end

  defp classify("0\n"), do: :sentinel

  defp classify(content) do
    case Integer.parse(content) do
      {pgid, "\n"} when pgid >= 2 -> {:ok, pgid}
      _unparsed -> :unknown
    end
  end

  # Spawned children lead their own session, so the negative pid is the whole
  # process group — the program itself plus anything it left behind. The tiny
  # pid-reuse window between a group's death and this signal is accepted
  # (wrapping pid_max takes far longer than the run of a command). The
  # killer's stderr is silenced: after a clean exit the group is usually
  # already gone and kill(1) would otherwise complain on the BEAM's stderr.
  defp kill_group(pgid) do
    group = Integer.to_string(-pgid)

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
  defp shquote(s), do: "'" <> String.replace(s, "'", "'\\''") <> "'"
end
