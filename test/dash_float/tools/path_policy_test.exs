defmodule DashFloat.Tools.PathPolicyTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias DashFloat.Tools.PathPolicy

  defp sandbox(tag) do
    tmp = System.tmp_dir!()
    dir = Path.join(tmp, "df-pp-#{tag}-#{System.unique_integer([:positive])}")
    sub = Path.join(dir, "sub")
    File.mkdir_p!(sub)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  test "a relative path inside root resolves onto it" do
    root = sandbox("inside")
    expected = Path.join(root, "sub/a.txt")
    assert PathPolicy.resolve(root, "sub/a.txt") == {:ok, expected}
  end

  test "an absolute path inside root is fine" do
    root = sandbox("abs")
    absolute = Path.join(root, "sub/a.txt")
    assert PathPolicy.resolve(root, absolute) == {:ok, absolute}
  end

  test "dot and doubled separators normalize to the root itself" do
    root = sandbox("dot")
    expected = Path.join(root, "sub/x")
    assert PathPolicy.resolve(root, ".") == {:ok, root}
    assert PathPolicy.resolve(root, "sub/../sub//x") == {:ok, expected}
  end

  test "a deep non-existent remainder resolves to the join" do
    root = sandbox("deep")
    expected = Path.join(root, "a/b/c/d.txt")
    assert PathPolicy.resolve(root, "a/b/c/d.txt") == {:ok, expected}
  end

  test "a relative escape is rejected" do
    root = sandbox("esc")

    assert PathPolicy.resolve(root, "../../etc/passwd") ==
             {:error, "path escapes the working directory: ../../etc/passwd"}
  end

  test "an absolute path outside root is rejected" do
    root = sandbox("absout")

    assert PathPolicy.resolve(root, "/etc/passwd") ==
             {:error, "path is outside the working directory: /etc/passwd"}
  end

  test "a sibling with a shared prefix is rejected (root-evil trick)" do
    root = sandbox("prefix")
    tmp = System.tmp_dir!()
    evil = Path.join(tmp, Path.basename(root) <> "-evil")
    File.mkdir_p!(evil)
    on_exit(fn -> File.rm_rf(evil) end)

    evil_path = Path.join(evil, "x")

    assert PathPolicy.resolve(root, evil_path) ==
             {:error, "path is outside the working directory: #{evil_path}"}
  end

  test "a symlink inside root pointing outside is rejected" do
    root = sandbox("symfile")
    outside = sandbox("symfile-out")
    target = Path.join(outside, "secret.txt")
    leak = Path.join(root, "leak.txt")
    File.write!(target, "secret")
    File.ln_s!(target, leak)

    assert PathPolicy.resolve(root, "leak.txt") ==
             {:error, "path escapes the working directory: leak.txt"}
  end

  test "a symlinked intermediate directory escaping root is rejected" do
    root = sandbox("symdir")
    tmp = System.tmp_dir!()
    outside = Path.join(tmp, "df-pp-symdir-out-#{System.unique_integer([:positive])}")
    data = Path.join(outside, "data")
    File.mkdir_p!(data)
    on_exit(fn -> File.rm_rf(outside) end)

    linkdir = Path.join(root, "linkdir")
    File.ln_s!(data, linkdir)

    assert PathPolicy.resolve(root, "linkdir/x.txt") ==
             {:error, "path escapes the working directory: linkdir/x.txt"}
  end

  test "a symlink inside root pointing inside root resolves through" do
    root = sandbox("symin")
    sub = Path.join(root, "sub")
    real = Path.join(sub, "real.txt")
    alias_ = Path.join(root, "alias")
    File.write!(real, "ok")
    File.ln_s!(sub, alias_)

    assert PathPolicy.resolve(root, "alias/real.txt") == {:ok, real}
  end

  test "a dangling symlink is rejected, not written through" do
    root = sandbox("dangling")
    dangling = Path.join(root, "dangling")
    File.ln_s!("/nonexistent-df-target", dangling)

    assert PathPolicy.resolve(root, "dangling") ==
             {:error, "path escapes the working directory: dangling"}
  end

  test "a symlink loop is rejected, not chased forever" do
    root = sandbox("loop")
    a = Path.join(root, "a")
    b = Path.join(root, "b")
    File.ln_s!("b", a)
    File.ln_s!("a", b)

    assert PathPolicy.resolve(root, "a/x") == {:error, "path escapes the working directory: a/x"}
  end

  test "a missing working directory is an error" do
    tmp = System.tmp_dir!()
    missing = Path.join(tmp, "df-pp-missing-#{System.unique_integer([:positive])}")

    assert PathPolicy.resolve(missing, "a.txt") == {:error, "working directory does not exist"}
  end
end
