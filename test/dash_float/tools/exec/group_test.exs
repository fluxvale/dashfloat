defmodule DashFloat.Tools.Exec.GroupTest do
  @moduledoc false
  use ExUnit.Case, async: false

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

    assert Group.reap(tracker, port) == :ok
    refute File.exists?(tracker.path)
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
