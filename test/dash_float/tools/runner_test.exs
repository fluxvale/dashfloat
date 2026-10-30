defmodule DashFloat.Tools.RunnerTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias DashFloat.SSEServer
  alias DashFloat.Tools

  setup do
    tmp = System.tmp_dir!()
    root = Path.join(tmp, "df-run-#{System.unique_integer([:positive])}")
    # A killed run can leave its sandbox behind and unique_integer can collide
    # with it; start from a clean slate.
    File.rm_rf(root)
    src = Path.join(root, "src")
    docs = Path.join(root, "docs")
    readme = Path.join(root, "readme.md")
    a_ex = Path.join(src, "a.ex")

    File.mkdir_p!(src)
    File.mkdir_p!(docs)
    File.write!(readme, "one\ntwo\nthree\nfour\nfive\n")
    File.write!(a_ex, "defmodule A do\nend\n")
    File.ln_s!(src, Path.join(root, "srclink"))
    on_exit(fn -> File.rm_rf(root) end)

    %{root: root, src: src, docs: docs, readme: readme}
  end

  # chmod-000 assertions are meaningless for root.
  setup :skip_permission_test_for_root

  defp skip_permission_test_for_root(context) do
    if context[:skip_if_root] && root?() do
      {:skip, "chmod-000 is not a permission barrier for root"}
    else
      :ok
    end
  end

  defp root? do
    case System.cmd("id", ["-u"]) do
      {"0\n", 0} -> true
      _other -> false
    end
  end

  defp validate!(name, args), do: elem(Tools.validate(name, args), 1)

  defp run(name, args, root, opts \\ []),
    do: Tools.Runner.run(name, validate!(name, args), root, opts)

  ## read_file

  test "read_file returns the whole small file", %{root: root} do
    assert run("read_file", %{"path" => "readme.md"}, root) == %{
             ok: true,
             path: "readme.md",
             content: "one\ntwo\nthree\nfour\nfive",
             lines: 5,
             total_lines: 5,
             total_bytes: 24,
             truncated: false
           }
  end

  test "read_file windows by offset and limit, marking the tail truncated", %{root: root} do
    result = run("read_file", %{"path" => "readme.md", "offset" => 2, "limit" => 2}, root)

    assert result.content == "two\nthree\n… [truncated: showing 2 of 5 lines]"
    assert result.lines == 2
    assert result.truncated == true
    assert result.total_lines == 5
  end

  test "read_file to the end of the file is not truncated", %{root: root} do
    result = run("read_file", %{"path" => "readme.md", "offset" => 3}, root)

    assert result.content == "three\nfour\nfive"
    assert result.truncated == false
  end

  test "read_file past the end returns an empty window without a marker", %{root: root} do
    result = run("read_file", %{"path" => "readme.md", "offset" => 9, "limit" => 5}, root)

    assert result.content == ""
    assert result.lines == 0
    assert result.truncated == false
  end

  test "read_file byte-caps whole lines and reports the marker", %{root: root} do
    long = Enum.map_join(1..100, &(String.duplicate("x", 1_500) <> Integer.to_string(&1) <> "\n"))

    root
    |> Path.join("big.txt")
    |> File.write!(long)

    result = run("read_file", %{"path" => "big.txt"}, root)

    assert result.truncated == true
    assert result.lines < 100
    assert result.lines > 0
    assert result.content =~ "… [truncated: showing #{result.lines} of 100 lines]"

    marker = "\n… [truncated: showing #{result.lines} of 100 lines]"
    shown = String.replace_suffix(result.content, marker, "")
    assert byte_size(shown) <= 64 * 1024
  end

  test "read_file on a missing file", %{root: root} do
    assert run("read_file", %{"path" => "nope.txt"}, root) == %{
             ok: false,
             path: "nope.txt",
             error: "file not found"
           }
  end

  test "read_file streams only the window of a large file", %{root: root} do
    # > 256 KiB trips the streamed path: nothing reads the whole file, and the
    # +1 probe line learns `truncated` without a full scan.
    big = Enum.map_join(1..40_000, &"row #{&1}\n")
    path = Path.join(root, "big.log")
    File.write!(path, big)

    tail = run("read_file", %{"path" => "big.log", "offset" => 39_998, "limit" => 3}, root)

    assert tail.ok == true
    assert tail.total_bytes == byte_size(big)
    assert tail.truncated == false
    assert tail.content == "row 39998\nrow 39999\nrow 40000"
    refute Map.has_key?(tail, :total_lines)

    window = run("read_file", %{"path" => "big.log", "offset" => 2, "limit" => 2}, root)
    assert window.truncated == true
    assert window.content =~ "… [truncated: showing 2 lines]"
  end

  test "a streamed read cut by the byte cap reports truncated honestly", %{root: root} do
    # 300 lines of ~1 KiB: the window asks for all of them, the 64 KiB cap
    # keeps only ~64 — the result must say truncated, not claim completeness.
    big = Enum.map_join(1..300, &(String.pad_trailing("line #{&1}", 1000) <> "\n"))
    wide = Path.join(root, "wide.log")
    File.write!(wide, big)

    result = run("read_file", %{"path" => "wide.log", "offset" => 1, "limit" => 300}, root)

    assert result.ok == true
    assert result.truncated == true
    assert result.lines < 300
    assert result.content =~ "… [truncated: showing #{result.lines} lines]"
  end

  test "a single over-cap line reports zero lines shown without a stray newline", %{root: root} do
    # One 300 KiB line: the byte cap keeps none of it — the marker must still
    # read cleanly and say what happened.
    blob = String.duplicate("x", 300 * 1024) <> "\n"
    one = Path.join(root, "one.log")
    File.write!(one, blob)

    result = run("read_file", %{"path" => "one.log", "offset" => 1, "limit" => 10}, root)

    assert result.ok == true
    assert result.truncated == true
    assert result.lines == 0

    assert result.content ==
             "… [truncated: showing 0 of 1 lines — line exceeds the byte cap]"
  end

  test "read_file on a large directory degrades to the read error, not a raise", %{root: root} do
    dir = Path.join(root, "many")
    File.mkdir_p!(dir)
    # 30_000 entries push the directory's inode past the streamed-path floor.
    Enum.each(1..30_000, &File.touch!(Path.join(dir, "f#{&1}")))

    result = run("read_file", %{"path" => "many"}, root)

    assert result.ok == false
    assert result.error =~ "illegal operation on a directory"
  end

  @tag :skip_if_root
  test "unreadable files degrade to permission errors on both read paths", %{root: root} do
    big = Path.join(root, "big-secret.log")
    File.write!(big, String.duplicate("x", 300 * 1024))
    small = Path.join(root, "small-secret.txt")
    File.write!(small, "x")
    File.chmod!(big, 0)
    File.chmod!(small, 0)

    streamed = run("read_file", %{"path" => "big-secret.log"}, root)

    assert streamed == %{
             ok: false,
             path: "big-secret.log",
             error: "could not read file: permission denied"
           }

    buffered = run("read_file", %{"path" => "small-secret.txt"}, root)

    assert buffered == %{
             ok: false,
             path: "small-secret.txt",
             error: "could not read file: permission denied"
           }
  after
    big = Path.join(root, "big-secret.log")
    small = Path.join(root, "small-secret.txt")
    File.chmod(big, 0o600)
    File.chmod(small, 0o600)
  end

  test "read_file on a directory degrades to an error, not a raise", %{root: root} do
    result = run("read_file", %{"path" => "src"}, root)

    assert result.ok == false
    assert result.error =~ "could not read file"
  end

  test "read_file through a sandboxed symlink resolves to the real file", %{root: root} do
    result = run("read_file", %{"path" => "srclink/a.ex"}, root)

    assert result.ok == true
    assert result.content == "defmodule A do\nend"
  end

  test "a path escaping the working directory is rejected with the given path", %{root: root} do
    assert run("read_file", %{"path" => "../../etc/passwd"}, root) == %{
             ok: false,
             path: "../../etc/passwd",
             error: "path escapes the working directory: ../../etc/passwd"
           }

    assert run("read_file", %{"path" => "/etc/passwd"}, root) == %{
             ok: false,
             path: "/etc/passwd",
             error: "path is outside the working directory: /etc/passwd"
           }

    assert run("write_file", %{"path" => "../escape.txt", "content" => "x"}, root) == %{
             ok: false,
             path: "../escape.txt",
             error: "path escapes the working directory: ../escape.txt"
           }

    assert run("list_directory", %{"path" => "../"}, root) == %{
             ok: false,
             path: "../",
             error: "path escapes the working directory: ../"
           }

    edit_args = %{"path" => "/etc/hosts", "search_block" => "a", "replace_block" => "b"}

    assert run("edit_file", edit_args, root) == %{
             ok: false,
             path: "/etc/hosts",
             error: "path is outside the working directory: /etc/hosts"
           }
  end

  ## write_file

  test "write_file creates parent directories", %{root: root} do
    result = run("write_file", %{"path" => "lib/deep/new.ex", "content" => ":ok"}, root)

    assert result == %{ok: true, path: "lib/deep/new.ex", bytes: 3, created: true}

    written =
      root
      |> Path.join("lib/deep/new.ex")
      |> File.read!()

    assert written == ":ok"
  end

  test "write_file over an existing file reports created: false", %{root: root} do
    run("write_file", %{"path" => "a.txt", "content" => "one"}, root)
    result = run("write_file", %{"path" => "a.txt", "content" => "longer"}, root)

    assert result == %{ok: true, path: "a.txt", bytes: 6, created: false}

    written =
      root
      |> Path.join("a.txt")
      |> File.read!()

    assert written == "longer"
  end

  test "write_file preserves the permissions of an existing file and leaves no temp litter", %{
    root: root
  } do
    secret = Path.join(root, "secret.env")
    File.write!(secret, "old\n")
    File.chmod!(secret, 0o600)

    assert {:ok, _result} =
             Tools.validate("write_file", %{"path" => "secret.env", "content" => "new\n"})

    run("write_file", %{"path" => "secret.env", "content" => "new\n"}, root)

    mode = File.stat!(secret).mode
    assert Bitwise.&&&(mode, 0o7777) == 0o600
    assert File.read!(secret) == "new\n"

    leftovers = File.ls!(root)
    refute Enum.any?(leftovers, &String.starts_with?(&1, "secret.env.df-tmp-"))
  end

  test "edit_file preserves the permissions of the file it edits", %{root: root} do
    script = Path.join(root, "script.sh")
    File.write!(script, "#!/bin/sh\necho old\n")
    File.chmod!(script, 0o755)

    args = %{"path" => "script.sh", "search_block" => "old", "replace_block" => "new"}
    assert run("edit_file", args, root).ok == true

    mode = File.stat!(script).mode
    assert Bitwise.&&&(mode, 0o7777) == 0o755
    assert File.read!(script) == "#!/bin/sh\necho new\n"
  end

  test "write_file into a path blocked by a file fails cleanly", %{root: root} do
    root
    |> Path.join("blocked")
    |> File.write!("file")

    result = run("write_file", %{"path" => "blocked/sub.txt", "content" => "x"}, root)

    assert result.ok == false
    assert result.error =~ "could not create directory"
  end

  test "write_file onto a directory path fails cleanly", %{root: root} do
    result = run("write_file", %{"path" => "src", "content" => "x"}, root)

    assert result.ok == false
    assert result.error =~ "could not write file"
  end

  test "writes onto the working directory itself are refused before any temp", %{root: root} do
    for {tool, extra} <- [
          {"write_file", %{"content" => "x"}},
          {"edit_file", %{"search_block" => "a", "replace_block" => "b"}}
        ] do
      result = run(tool, Map.merge(%{"path" => "."}, extra), root)

      assert result == %{
               ok: false,
               path: ".",
               error: "path is the working directory itself"
             }
    end

    # The parent of the sandbox stays clean: no temp file ever crossed out.
    parent = Path.dirname(root)
    {:ok, siblings} = File.ls(parent)
    refute Enum.any?(siblings, &String.contains?(&1, ".df-tmp-"))
  end

  ## edit_file

  test "edit_file replaces a unique block exactly once", %{root: root} do
    args = %{
      "path" => "readme.md",
      "search_block" => "two\nthree",
      "replace_block" => "TWO\nTHREE"
    }

    result = run("edit_file", args, root)

    assert result == %{ok: true, path: "readme.md", replaced: 1}

    written =
      root
      |> Path.join("readme.md")
      |> File.read!()

    assert written == "one\nTWO\nTHREE\nfour\nfive\n"
  end

  test "edit_file rejects a block that does not match", %{root: root} do
    args = %{"path" => "readme.md", "search_block" => "absent", "replace_block" => "x"}
    result = run("edit_file", args, root)

    assert result == %{ok: false, path: "readme.md", error: "search block not found"}
  end

  test "edit_file rejects an ambiguous block with its match count", %{root: root} do
    root
    |> Path.join("dup.txt")
    |> File.write!("same\nsame\n")

    args = %{"path" => "dup.txt", "search_block" => "same", "replace_block" => "x"}
    result = run("edit_file", args, root)

    assert result == %{
             ok: false,
             path: "dup.txt",
             error: "search block matches 2 times; make it unique"
           }

    unchanged =
      root
      |> Path.join("dup.txt")
      |> File.read!()

    assert unchanged == "same\nsame\n"
  end

  test "edit_file rejects an empty search block", %{root: root} do
    args = %{"path" => "readme.md", "search_block" => "", "replace_block" => "x"}
    result = run("edit_file", args, root)

    assert result == %{ok: false, path: "readme.md", error: "search block is empty"}
  end

  test "edit_file rejects identical search and replace blocks", %{root: root} do
    args = %{"path" => "readme.md", "search_block" => "two", "replace_block" => "two"}
    result = run("edit_file", args, root)

    assert result == %{
             ok: false,
             path: "readme.md",
             error: "search and replace blocks are identical"
           }

    unchanged =
      root
      |> Path.join("readme.md")
      |> File.read!()

    assert unchanged == "one\ntwo\nthree\nfour\nfive\n"
  end

  test "edit_file on a missing file", %{root: root} do
    args = %{"path" => "nope.txt", "search_block" => "a", "replace_block" => "b"}
    result = run("edit_file", args, root)

    assert result == %{ok: false, path: "nope.txt", error: "file not found"}
  end

  test "edit_file refuses files over the 8 MiB cap", %{root: root} do
    root
    |> Path.join("huge.txt")
    |> File.write!(String.duplicate("a", 8 * 1024 * 1024 + 1))

    args = %{"path" => "huge.txt", "search_block" => "a", "replace_block" => "b"}
    result = run("edit_file", args, root)

    assert result == %{ok: false, path: "huge.txt", error: "file too large to edit"}
  end

  test "edit_file reports a write failure cleanly", %{root: root} do
    locked_dir = Path.join(root, "locked")
    target = Path.join(locked_dir, "target.txt")
    File.mkdir_p!(locked_dir)
    File.write!(target, "target\n")
    File.chmod!(locked_dir, 0o555)
    on_exit(fn -> File.chmod(locked_dir, 0o755) end)

    args = %{"path" => "locked/target.txt", "search_block" => "target", "replace_block" => "new"}
    result = run("edit_file", args, root)

    assert result.ok == false
    assert result.error =~ "could not write file"
  end

  test "write_file onto a swapped symlink replaces the entry, never the target", %{root: root} do
    outside = Path.join(System.tmp_dir!(), "df-run-outside-#{System.unique_integer([:positive])}")
    File.mkdir_p!(outside)
    on_exit(fn -> File.rm_rf(outside) end)

    victim = Path.join(outside, "victim.txt")
    File.write!(victim, "original\n")
    link = Path.join(root, "swapme")
    File.ln_s!(victim, link)

    # Race the writer: flip the final entry between file and symlink while
    # writes land. With rename-based writes the entry is replaced at worst —
    # the victim outside the sandbox is never touched.
    flipper =
      Task.async(fn ->
        for _i <- 1..200 do
          File.rm(link)
          File.ln_s(victim, link)
        end
      end)

    for _i <- 1..100 do
      run("write_file", %{"path" => "swapme", "content" => "PWNED"}, root)
    end

    Task.await(flipper)

    # The invariant: whatever the interleaving, the file OUTSIDE the sandbox
    # was never written through the swapped symlink.
    assert File.read!(victim) == "original\n"
  end

  test "read_file scrubs invalid UTF-8 so the result stays JSON-encodable", %{root: root} do
    root
    |> Path.join("blob.bin")
    |> File.write!(<<0xFF, 0xFE, 0x01>>)

    result = run("read_file", %{"path" => "blob.bin"}, root)

    assert result.ok == true
    assert String.valid?(result.content)
    assert result.content == "\uFFFD\uFFFD\u0001"
    assert {:ok, _json} = Jason.encode(result)
  end

  ## execute_command

  test "execute_command runs in the resolved cwd", %{root: root, src: src} do
    result = run("execute_command", %{"command" => "pwd", "cwd" => "src"}, root)

    assert result.ok == true
    assert result.exit == 0
    assert result.output == src <> "\n"
  end

  test "execute_command defaults cwd to the working directory", %{root: root} do
    result = run("execute_command", %{"command" => "basename $(pwd)"}, root)

    assert result.ok == true
    assert result.output == Path.basename(root) <> "\n"
  end

  test "execute_command reports nonzero exit, timeout, and cwd escape", %{root: root} do
    failed = run("execute_command", %{"command" => "sh -c 'exit 4'"}, root)
    assert failed.ok == false
    assert failed.exit == 4

    timed = run("execute_command", %{"command" => "sleep 5"}, root, exec_timeout: 100)
    assert timed.ok == false
    assert timed.error == "timed out after 100ms"

    escaped = run("execute_command", %{"command" => "pwd", "cwd" => "../elsewhere"}, root)

    assert escaped == %{
             ok: false,
             path: "../elsewhere",
             error: "path escapes the working directory: ../elsewhere"
           }
  end

  ## list_directory

  test "list_directory orders directories first, then files and symlinks, alphabetically", %{
    root: root
  } do
    root
    |> Path.join("zeta.txt")
    |> File.write!("")

    root
    |> Path.join("alpha.txt")
    |> File.write!("")

    root
    |> Path.join("zed")
    |> File.mkdir_p!()

    alpha = Path.join(root, "alpha.txt")
    mlink = Path.join(root, "mlink")
    File.ln_s!(alpha, mlink)

    result = run("list_directory", %{"path" => "."}, root)

    assert Enum.take(result.entries, 3) == ["d docs/", "d src/", "d zed/"]

    assert Enum.drop(result.entries, 3) == [
             "- alpha.txt",
             "@ mlink",
             "- readme.md",
             "@ srclink",
             "- zeta.txt"
           ]

    assert result.count == 8
    assert result.truncated == false
  end

  test "list_directory caps at 500 entries with truncated: true", %{root: root} do
    dir = Path.join(root, "many")
    File.mkdir_p!(dir)

    # Created in REVERSE so readdir order differs from alphabetical: the shown
    # window must be the true alphabetical head, not creation order sorted.
    Enum.each(501..1//-1, fn i ->
      digits = Integer.to_string(i)
      padded = String.pad_leading(digits, 4, "0")
      File.write!(Path.join(dir, "f" <> padded), "x")
    end)

    result = run("list_directory", %{"path" => "many"}, root)

    assert length(result.entries) == 500
    assert result.count == 501
    assert result.truncated == true
    assert List.first(result.entries) == "- f0001"
    assert List.last(result.entries) == "- f0500"
  end

  test "list_directory on a missing directory", %{root: root} do
    assert run("list_directory", %{"path" => "nope"}, root) == %{
             ok: false,
             path: "nope",
             error: "directory not found"
           }
  end

  test "list_directory on a file degrades to an error", %{root: root} do
    result = run("list_directory", %{"path" => "readme.md"}, root)

    assert result.ok == false
    assert result.error =~ "could not list directory"
  end

  ## the rescue belt

  test "a broken call degrades to tool crashed, never a raise", %{root: root} do
    broken = %{"path" => nil, "offset" => 1, "limit" => 2_000}
    result = Tools.Runner.run("read_file", broken, root)

    assert result.ok == false
    assert result.error =~ "tool crashed"

    unknown = Tools.Runner.run("not_a_tool", %{}, root)
    assert unknown.ok == false
    assert unknown.error =~ "tool crashed"
  end

  ## web_search (ADR 0021 §6)

  test "web_search dispatches through the loopback search endpoint" do
    entries = [%{"url" => "https://example.com/a", "title" => "A"}]
    body = Jason.encode!(%{"results" => entries})

    {:ok, server} =
      SSEServer.start_link([
        {:send,
         "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\n" <>
           "content-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n" <> body},
        :close
      ])

    on_exit(fn -> DashFloat.TestTeardown.stop(server) end)

    search = %{url: SSEServer.base_url(server) <> "/v2/search", api_key: "test-key-123"}

    assert run("web_search", %{"query" => "dashfloat"}, "unused-cwd",
             search: search,
             search_timeout: 2_000
           ) == %{
             ok: true,
             query: "dashfloat",
             content: Enum.map_join(entries, "\n", &Jason.encode!/1),
             count: 1
           }

    assert_receive {:sse_request, "POST", "/v2/search", headers, request_body}, 2_000
    assert headers["authorization"] == "Bearer test-key-123"
    assert Jason.decode!(request_body) == %{"query" => "dashfloat"}
  end
end
