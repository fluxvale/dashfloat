defmodule DashFloat.Tools.PreviewTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias DashFloat.Tools

  setup do
    tmp = System.tmp_dir!()
    root = Path.join(tmp, "df-prev-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root}
  end

  defp validate!(name, args), do: elem(Tools.validate(name, args), 1)

  defp build(name, args, root),
    do: Tools.Preview.build(name, validate!(name, args), root)

  ## write_file

  test "a new file previews as create with capped + lines", %{root: root} do
    args = %{"path" => "new.txt", "content" => "alpha\nbeta"}

    assert build("write_file", args, root) ==
             {:ok, %{lines: ["create: new.txt", "+ alpha", "+ beta"]}}
  end

  test "write_file content is capped at 50 lines with a more-lines marker", %{root: root} do
    content = Enum.map_join(1..60, &"line #{&1}\n")
    args = %{"path" => "n.txt", "content" => content}
    assert {:ok, %{lines: lines}} = build("write_file", args, root)

    assert length(lines) == 52
    assert List.first(lines) == "create: n.txt"
    assert Enum.at(lines, 50) == "+ line 50"
    assert Enum.at(lines, 51) == "+ … (10 more lines)"
  end

  test "an existing small target previews as overwrite with its size", %{root: root} do
    root
    |> Path.join("exists.txt")
    |> File.write!("abc")

    args = %{"path" => "exists.txt", "content" => "new"}

    assert build("write_file", args, root) ==
             {:ok, %{lines: ["overwrite: exists.txt (3 bytes)", "+ new"]}}
  end

  test "an existing oversized target is too large to preview", %{root: root} do
    size = 256 * 1024 + 1

    root
    |> Path.join("big.bin")
    |> File.write!(String.duplicate("x", size))

    expected = "overwrite: big.bin (too large to preview, #{size} bytes)"
    args = %{"path" => "big.bin", "content" => "new"}
    assert {:ok, %{lines: [^expected, "+ new"]}} = build("write_file", args, root)
  end

  test "a write path escaping the sandbox returns the runner-shaped error", %{root: root} do
    args = %{"path" => "../escape.txt", "content" => "x"}

    assert build("write_file", args, root) ==
             {:error,
              %{
                ok: false,
                path: "../escape.txt",
                error: "path escapes the working directory: ../escape.txt"
              }}
  end

  ## edit_file

  test "a unique match previews as a unified hunk with 3 context lines", %{root: root} do
    root
    |> Path.join("seven.txt")
    |> File.write!("one\ntwo\nthree\nfour\nfive\nsix\nseven\n")

    args = %{"path" => "seven.txt", "search_block" => "four", "replace_block" => "FOUR\nQUARTER"}
    assert {:ok, %{lines: lines}} = build("edit_file", args, root)

    assert lines == [
             "@@ -1,7 +1,8 @@",
             "  one",
             "  two",
             "  three",
             "- four",
             "+ FOUR",
             "+ QUARTER",
             "  five",
             "  six",
             "  seven"
           ]
  end

  test "context clamps at the start and end of the file", %{root: root} do
    root
    |> Path.join("three.txt")
    |> File.write!("a\nb\nc\n")

    first_args = %{"path" => "three.txt", "search_block" => "a", "replace_block" => "A"}
    assert {:ok, %{lines: first_lines}} = build("edit_file", first_args, root)
    assert first_lines == ["@@ -1,3 +1,3 @@", "- a", "+ A", "  b", "  c"]

    last_args = %{"path" => "three.txt", "search_block" => "c", "replace_block" => "C"}
    assert {:ok, %{lines: last_lines}} = build("edit_file", last_args, root)
    assert last_lines == ["@@ -1,3 +1,3 @@", "  a", "  b", "- c", "+ C"]
  end

  test "a multi-line search block counts its lines in the header", %{root: root} do
    file = "l1\nl2\nl3\nl4\nhead1\nhead2\naaa\nbbb\nfoot1\nfoot2\nl9\nl10\nl11\nl12\n"

    root
    |> Path.join("ctx.txt")
    |> File.write!(file)

    args = %{
      "path" => "ctx.txt",
      "search_block" => "head1\nhead2\naaa\nbbb\nfoot1\nfoot2\n",
      "replace_block" => "x"
    }

    assert {:ok, %{lines: lines}} = build("edit_file", args, root)

    assert lines == [
             "@@ -2,12 +2,7 @@",
             "  l2",
             "  l3",
             "  l4",
             "- head1",
             "- head2",
             "- aaa",
             "- bbb",
             "- foot1",
             "- foot2",
             "+ x",
             "  l9",
             "  l10",
             "  l11"
           ]
  end

  test "an ambiguous match returns the runner-shaped error unchanged", %{root: root} do
    root
    |> Path.join("dup.txt")
    |> File.write!("same\nsame\n")

    args = %{"path" => "dup.txt", "search_block" => "same", "replace_block" => "x"}

    assert build("edit_file", args, root) == {
             :error,
             Tools.Runner.run("edit_file", validate!("edit_file", args), root)
           }
  end

  test "a missing file returns the runner-shaped error unchanged", %{root: root} do
    args = %{"path" => "nope.txt", "search_block" => "a", "replace_block" => "b"}

    assert build("edit_file", args, root) == {
             :error,
             Tools.Runner.run("edit_file", validate!("edit_file", args), root)
           }
  end

  ## execute_command

  test "an execute_command preview shows the command line and resolved cwd", %{root: root} do
    sub = Path.join(root, "sub")
    File.mkdir_p!(sub)

    args = %{"command" => "mix test", "cwd" => "sub"}

    assert build("execute_command", args, root) == {:ok, %{lines: ["$ mix test", "cwd: " <> sub]}}
  end

  test "every line of a multi-line command gets the $ marker", %{root: root} do
    args = %{"command" => "echo safe\nrm -rf ~", "cwd" => "."}

    assert build("execute_command", args, root) ==
             {:ok, %{lines: ["$ echo safe", "$ rm -rf ~", "cwd: " <> root]}}
  end

  test "a broken preview degrades to an error result, never a raise", %{root: root} do
    result = Tools.Preview.build("execute_command", %{"command" => "ls"}, root)

    assert {:error, %{ok: false, error: message}} = result
    assert message =~ "preview crashed"

    partial = Tools.Preview.build("write_file", %{"content" => "x"}, root)

    assert {:error, %{ok: false, error: "preview crashed" <> _rest}} = partial
  end

  test "an execute_command cwd escaping the sandbox returns the runner-shaped error", %{
    root: root
  } do
    args = %{"command" => "ls", "cwd" => "../../etc"}

    assert build("execute_command", args, root) ==
             {:error,
              %{
                ok: false,
                path: "../../etc",
                error: "path escapes the working directory: ../../etc"
              }}
  end

  ## tools without a preview

  test "read-only and unknown tools have no preview", %{root: root} do
    args = %{"path" => "x"}

    assert build("read_file", args, root) ==
             {:error, %{ok: false, error: "no preview for read_file"}}

    list_args = %{"path" => "."}

    assert Tools.Preview.build("list_directory", list_args, root) ==
             {:error, %{ok: false, error: "no preview for list_directory"}}
  end
end
