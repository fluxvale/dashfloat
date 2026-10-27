defmodule DashFloat.Tools.Exec.GroupTest do
  @moduledoc false
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias DashFloat.Tools.Exec
  alias DashFloat.Tools.Exec.Group

  # The deterministic window proof of issue #59: the wrapper reported its pgid,
  # then the command exited 0 leaving a background child — the port is dead
  # (Port.info would answer nil) and the child survives until reap kills the
  # reported group.
  test "wrap reports the pgid before exec and reap kills a surviving group with the port already dead" do
    {:ok, tracker} = Group.arm()

    duration = 300_000 + System.unique_integer([:positive])
    marker = "sleep #{duration}"

    port =
      Port.open(
        {:spawn, Group.wrap("#{marker} >/dev/null 2>&1 & exit 0", tracker)},
        [:exit_status, {:cd, System.tmp_dir!()}]
      )

    assert_receive {^port, {:exit_status, 0}}, 5_000

    assert Group.reap(tracker, port) == :ok

    assert_eventually_gone(marker)
    refute File.exists?(tracker.path)
  end

  test "reap with an unwritten tracker and a dead port is a proven no-op" do
    {:ok, tracker} = Group.arm()

    port = Port.open({:spawn, "/bin/sh -c 'true'"}, [:exit_status, {:cd, System.tmp_dir!()}])
    assert_receive {^port, {:exit_status, 0}}, 5_000

    # The proof is silent: the wrapper's `&&` never passed, so the command
    # never ran — no warning, no kill, no leftover file.
    assert capture_log(fn -> assert Group.reap(tracker, port) == :ok end) == ""
    refute File.exists?(tracker.path)
  end

  # A tracker that vanished (a tmp cleaner, or the command deleting it) leaves
  # the pgid unknown with the port dead: reap must not crash, must not skip
  # silently, and must say it could not verify the kill.
  test "reap with a deleted tracker and a dead port warns instead of a silent skip" do
    {:ok, tracker} = Group.arm()
    File.rm!(tracker.path)

    port = Port.open({:spawn, "/bin/sh -c 'true'"}, [:exit_status, {:cd, System.tmp_dir!()}])
    assert_receive {^port, {:exit_status, 0}}, 5_000

    assert capture_log(fn -> assert Group.reap(tracker, port) == :ok end) =~
             "cannot verify the command's process group was killed"
  end

  # Hostile-content guards: a well-formed report is the ONLY thing that may
  # carry a kill. "1\n" would make the kill target -1 (every process the uid
  # can signal), and a torn prefix without the newline would kill a wrong
  # group — both must read as unknown and warn, killing nothing.
  test "reap never kills on tracker content the wrapper could not have written" do
    for hostile <- ["1\n", "123456", "garbage\n", "0"] do
      {:ok, tracker} = Group.arm()
      File.write!(tracker.path, hostile)

      port = Port.open({:spawn, "/bin/sh -c 'true'"}, [:exit_status, {:cd, System.tmp_dir!()}])
      assert_receive {^port, {:exit_status, 0}}, 5_000

      assert capture_log(fn -> assert Group.reap(tracker, port) == :ok end) =~
               "cannot verify the command's process group was killed"

      refute File.exists?(tracker.path)
    end
  end

  # The belt: a :cancel landing inside the spawn window reaps before the
  # wrapper's report lands — sentinel unwritten, port alive, so the live
  # port's os_pid (== the pgid) carries the kill.
  test "reap falls back to the live port's os_pid when the report has not landed" do
    {:ok, tracker} = Group.arm()
    duration = 300_000 + System.unique_integer([:positive])
    marker = "sleep #{duration}"

    port = Port.open({:spawn, "/bin/sh -c '#{marker}'"}, [:exit_status, {:cd, System.tmp_dir!()}])
    assert Group.reap(tracker, port) == :ok

    assert_eventually_gone(marker)
    refute File.exists?(tracker.path)
  end

  # A relative TMPDIR resolves against the BEAM cwd at arm/reap but against
  # the COMMAND's cwd inside the wrapper: an unexpanded tracker path diverges,
  # the sentinel is read where the report never landed, and the kill is
  # "proven" unnecessary while the group survives. The tracker must be
  # absolute (ADR 0013).
  test "a relative TMPDIR does not diverge between the wrapper and the reaper" do
    rel = "df-rel-tmp-#{System.unique_integer([:positive])}"
    base = Path.join(System.tmp_dir!(), "df-group-rel-#{System.unique_integer([:positive])}")
    tool_cwd = Path.join(base, "tool")
    rel_dir = Path.join(base, rel)
    File.mkdir_p!(rel_dir)
    File.mkdir_p!(tool_cwd)
    File.mkdir_p!(rel)
    on_exit(fn -> File.rm_rf(rel) end)

    duration = 300_000 + System.unique_integer([:positive])
    marker = "sleep #{duration}"

    old = System.get_env("TMPDIR")
    System.put_env("TMPDIR", rel)

    try do
      result = Exec.run("sh -c '#{marker} >/dev/null 2>&1 & echo done'", tool_cwd, 5_000, 4_096)

      assert result[:ok] == true
      assert result[:output] == "done\n"
      assert_eventually_gone(marker)
    after
      if old, do: System.put_env("TMPDIR", old), else: System.delete_env("TMPDIR")
      File.rm_rf(base)
    end
  end

  test "arm fails cleanly when no tmp dir is writable" do
    # 0o200 (write-only, no search bit): System.tmp_dir/0 itself skips dirs
    # whose access is not :read_write/:write, so a 0o500 dir never reaches
    # arm — this mode passes that filter and still fails the write.
    dir = Path.join(System.tmp_dir!(), "df-group-arm-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o200)

    old = System.get_env("TMPDIR")
    System.put_env("TMPDIR", dir)

    try do
      assert {:error, reason} = Group.arm()
      assert is_binary(reason)
    after
      if old, do: System.put_env("TMPDIR", old), else: System.delete_env("TMPDIR")
      File.chmod!(dir, 0o700)
      File.rm_rf(dir)
    end
  end

  # The honest refusal through the public API: without a tracker the group
  # kill would again depend on the port's lifetime (issue #59), so an
  # unusable tmp dir refuses the spawn instead of running untracked.
  test "Exec.run refuses the spawn when the tracker cannot be armed" do
    dir = Path.join(System.tmp_dir!(), "df-group-refuse-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o200)
    cwd = Path.join(System.tmp_dir!(), "df-group-cwd-#{System.unique_integer([:positive])}")
    File.mkdir_p!(cwd)

    old = System.get_env("TMPDIR")
    System.put_env("TMPDIR", dir)

    try do
      result = Exec.run("echo hi", cwd, 5_000, 4_096)

      assert result[:ok] == false
      assert result[:exit] == nil
      assert result[:error] =~ "spawn failed: cannot arm the process-group tracker"
    after
      if old, do: System.put_env("TMPDIR", old), else: System.delete_env("TMPDIR")
      File.chmod!(dir, 0o700)
      File.rm_rf(dir)
      File.rm_rf(cwd)
    end
  end

  # pgrep exits 1 on no matches — which is exactly what we want to see.
  # A deadline loop, not a single retry: under CI runner contention the
  # child IS reaped, just later than any fixed window — poll to a bound and
  # fail with the survivors named when the deadline hits (self-diagnosing).
  defp assert_eventually_gone(marker, deadline_ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms

    do_assert_eventually_gone(marker, deadline)
  end

  defp do_assert_eventually_gone(marker, deadline) do
    {matches, _status} = System.cmd("pgrep", ["-f", marker])

    if matches == "" do
      assert true
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("process matching #{inspect(marker)} still alive at the deadline: #{matches}")
      else
        :timer.sleep(100)
        do_assert_eventually_gone(marker, deadline)
      end
    end
  end
end
