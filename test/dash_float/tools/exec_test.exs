defmodule DashFloat.Tools.ExecTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias DashFloat.Tools.Exec

  defp sandbox(tag) do
    dir = Path.join(System.tmp_dir!(), "df-exec-#{tag}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  test "exit 0 with output" do
    result = Exec.run("echo hello", sandbox("ok"), 5_000, 4_096)

    assert result == %{ok: true, exit: 0, output: "hello\n", truncated: false, total_bytes: 6}
  end

  test "a :cancel mid-run kills the process group and reports the cancel" do
    dir = sandbox("cancel")
    parent = self()

    {:ok, task} =
      Task.start(fn ->
        send(parent, {:done, Exec.run("sleep 61", dir, 60_000, 4_096)})
      end)

    wait_for_process("sleep 61")
    send(task, :cancel)

    assert_receive {:done, result}, 5_000
    assert result.cancelled == true
    assert result.ok == false

    # The group SIGKILL ran: nothing survives (a bare Port.close would leak it).
    wait_for_gone("sleep 61")
  end

  # System.cmd returns {output, status}: pgrep exits 0 with matches, 1 without.
  defp wait_for_process(pattern) do
    if match?({_pids, 0}, System.cmd("pgrep", ["-f", pattern])) do
      :ok
    else
      Process.sleep(20)
      wait_for_process(pattern)
    end
  end

  defp wait_for_gone(pattern, tries \\ 100) do
    if match?({_pids, 1}, System.cmd("pgrep", ["-f", pattern])) do
      :ok
    else
      if tries > 0 do
        Process.sleep(20)
        wait_for_gone(pattern, tries - 1)
      else
        flunk("process #{pattern} survived the cancel")
      end
    end
  end

  test "a nonzero exit reports ok: false with the exact status" do
    result = Exec.run("echo hi; exit 3", sandbox("exit3"), 5_000, 4_096)

    assert result.ok == false
    assert result.exit == 3
    assert result.output == "hi\n"
  end

  test "stderr is merged into the output" do
    result = Exec.run("echo oops >&2", sandbox("stderr"), 5_000, 4_096)

    assert result.ok == true
    assert result.output == "oops\n"
  end

  test "full shell semantics: &&, quoting, builtins" do
    result = Exec.run("true && echo it\\'s \"quoted\"", sandbox("shell"), 5_000, 4_096)

    assert result.ok == true
    assert result.exit == 0
    assert result.truncated == false
    assert result.total_bytes == byte_size("it's quoted\n")
    assert result.output == "it's quoted\n"
  end

  test "timeout closes the port and reports the configured timeout" do
    result = Exec.run("sleep 5", sandbox("timeout"), 100, 4_096)

    assert result == %{
             ok: false,
             exit: nil,
             error: "timed out after 100ms",
             output: "",
             truncated: false,
             total_bytes: 0
           }
  end

  test "a never-idle producer still dies at the timeout, keeping partial output" do
    result = Exec.run("while true; do echo tick; done", sandbox("busy"), 150, 4_096)

    assert result.ok == false
    assert result.error == "timed out after 150ms"
    assert result.total_bytes > 0
    assert result.output =~ "tick"
  end

  test "a timeout mid-stream returns partial output and leaks no port messages" do
    result = Exec.run("while true; do echo tick; done", sandbox("drain"), 80, 4_096)

    assert result.ok == false
    assert result.error == "timed out after 80ms"
    assert result.total_bytes > 0

    # Whatever was in flight must have been drained, not left behind.
    refute_received {_port, _message}
  end

  test "a timed-out busy loop is killed dead, not leaked spinning" do
    marker = "df-exec-leak-#{System.unique_integer([:positive])}"
    result = Exec.run("while true; do echo #{marker}; done", sandbox("kill"), 80, 1_024)

    assert result.error == "timed out after 80ms"

    assert_eventually_gone(marker)
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

  test "output past the cap is truncated with a marker; bytes keep counting" do
    result = Exec.run("seq 1 200000", sandbox("cap"), 30_000, 4_096)

    expected_total = Enum.reduce(1..200_000, 0, &(&2 + byte_size(Integer.to_string(&1)) + 1))

    assert result.ok == true
    assert result.truncated == true
    assert result.total_bytes == expected_total
    assert String.starts_with?(result.output, "1\n2\n3\n")

    assert Regex.match?(
             ~r/\n… \[output truncated: showing 4096 of #{expected_total} bytes\]\z/,
             result.output
           )

    assert byte_size(result.output) > 4_096
  end

  test "a successful command reaps children it left behind" do
    # A per-run unique sleep DURATION, not a fixed "sleep 251": pgrep -f is a
    # substring match over every process on the machine, and on shared CI
    # runners an ambient process can carry the fixed string (two red runs
    # cited survivors at early-boot PIDs on different hosts). Unique markers
    # are the pattern the kill test below already uses.
    duration = 251_000 + System.unique_integer([:positive])
    marker = "sleep #{duration}"

    # A stale survivor from an earlier, broken run must not read as ours.
    System.cmd("pkill", ["-9", "-f", marker])
    :timer.sleep(50)

    result =
      Exec.run("sh -c '#{marker} >/dev/null 2>&1 & echo done'", sandbox("reap"), 5_000, 4_096)

    assert result.ok == true
    assert result.exit == 0
    assert result.output == "done\n"
    assert_eventually_gone(marker)
  end

  test "binary output is scrubbed to valid UTF-8" do
    result = Exec.run("printf a\\\\377b", sandbox("binary"), 5_000, 4_096)

    assert result.ok == true
    assert result.output == "a\uFFFDb"
    assert {:ok, _json} = Jason.encode(result)
  end

  test "a nonexistent cwd fails to spawn" do
    missing = Path.join(System.tmp_dir!(), "df-exec-nope-#{System.unique_integer([:positive])}")

    result = Exec.run("echo hi", missing, 5_000, 4_096)

    assert result.ok == false
    assert result.exit == nil
    assert result.error == "spawn failed: no such file or directory"
  end

  test "a cwd that is a file fails to spawn" do
    root = sandbox("filecwd")
    file = Path.join(root, "not-a-dir")
    File.write!(file, "x")

    result = Exec.run("echo hi", file, 5_000, 4_096)

    assert result == %{ok: false, exit: nil, error: "spawn failed: not a directory: " <> file}
  end
end
