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
  defp assert_eventually_gone(marker) do
    {matches, _status} = System.cmd("pgrep", ["-f", marker])

    if matches == "" do
      assert true
    else
      :timer.sleep(50)

      {matches, _status} = System.cmd("pgrep", ["-f", marker])
      assert matches == ""
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
