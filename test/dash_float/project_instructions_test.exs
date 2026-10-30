defmodule DashFloat.ProjectInstructionsTest do
  @moduledoc false
  # Pure discovery tests: file fixtures under tmp dirs, a plain empty `.git`
  # DIR (or a `.git` file) as the stop marker, no git binary. See ADR 0019.

  use ExUnit.Case, async: true

  alias DashFloat.ProjectInstructions

  @max_bytes 32_768

  @tag :tmp_dir
  test "nested files are discovered most-general-first, with absolute paths", ctx do
    root = Path.join(ctx.tmp_dir, "root")
    sub = Path.join(root, "sub")
    agents = Path.join(root, "AGENTS.md")
    inner_agents = Path.join(sub, "AGENTS.md")
    git_marker = Path.join(root, ".git")
    File.mkdir_p!(sub)
    File.write!(agents, "outer rules\n")
    File.write!(inner_agents, "inner rules\n")
    File.mkdir_p!(git_marker)

    assert ProjectInstructions.load(sub) == [
             %{path: agents, content: "outer rules\n"},
             %{path: inner_agents, content: "inner rules\n"}
           ]
  end

  @tag :tmp_dir
  test "an AGENTS.md above the .git-marker root is not found", ctx do
    outer = Path.join(ctx.tmp_dir, "outer")
    repo = Path.join(outer, "repo")
    above = Path.join(outer, "AGENTS.md")
    git_marker = Path.join(repo, ".git")
    File.mkdir_p!(repo)
    File.write!(above, "above the repo\n")
    File.mkdir_p!(git_marker)

    assert ProjectInstructions.load(repo) == []
  end

  @tag :tmp_dir
  test "a .git file marker (linked worktree) behaves like the dir marker", ctx do
    outer = Path.join(ctx.tmp_dir, "outer")
    repo = Path.join(outer, "repo")
    above = Path.join(outer, "AGENTS.md")
    agents = Path.join(repo, "AGENTS.md")
    git_file = Path.join(repo, ".git")
    File.mkdir_p!(repo)
    File.write!(above, "above the repo\n")
    File.write!(agents, "repo rules\n")
    File.write!(git_file, "gitdir: /somewhere/else\n")

    assert ProjectInstructions.load(repo) == [
             %{path: agents, content: "repo rules\n"}
           ]
  end

  @tag :tmp_dir
  test "a dangling .git symlink still stops the walk", ctx do
    outer = Path.join(ctx.tmp_dir, "outer")
    repo = Path.join(outer, "repo")
    above = Path.join(outer, "AGENTS.md")
    git_link = Path.join(repo, ".git")
    File.mkdir_p!(repo)
    File.write!(above, "above the repo\n")
    File.ln_s("/nonexistent/gitdir", git_link)

    assert ProjectInstructions.load(repo) == []
  end

  @tag :tmp_dir
  test "a symlinked AGENTS.md is rejected outright", ctx do
    # A cloned repo must not be able to aim the discovery at files outside
    # itself (the tool sandbox rejects the same class, ADR 0007) — so only
    # regular files count, dotfile-style symlinked AGENTS.md included.
    root = Path.join(ctx.tmp_dir, "root")
    sub = Path.join(root, "sub")
    target = Path.join(ctx.tmp_dir, "real-agents.md")
    outer_agents = Path.join(root, "AGENTS.md")
    agents_link = Path.join(sub, "AGENTS.md")
    File.mkdir_p!(sub)
    File.mkdir_p!(Path.join(root, ".git"))
    File.write!(target, "exfiltrated secrets\n")
    File.write!(outer_agents, "outer rules\n")
    File.ln_s(target, agents_link)

    assert ProjectInstructions.load(sub) == [
             %{path: outer_agents, content: "outer rules\n"}
           ]
  end

  test "with no .git anywhere the walk reaches the filesystem root" do
    base = Path.join(System.tmp_dir!(), "agents-discovery-#{System.unique_integer()}")
    inner = Path.join(base, "sub")
    agents = Path.join(base, "AGENTS.md")
    inner_agents = Path.join(inner, "AGENTS.md")
    File.mkdir_p!(inner)
    File.write!(agents, "outer rules\n")
    File.write!(inner_agents, "inner rules\n")
    on_exit(fn -> File.rm_rf!(base) end)

    # The walk must climb past the .git-less ancestors; stray AGENTS.md files
    # further up the system tmp tree would follow the two discovered ones, so
    # the first two entries decide.
    entries = ProjectInstructions.load(inner)

    assert Enum.take(entries, 2) == [
             %{path: agents, content: "outer rules\n"},
             %{path: inner_agents, content: "inner rules\n"}
           ]
  end

  @tag :tmp_dir
  test "a file over the budget keeps its head and names the original size", ctx do
    root = Path.join(ctx.tmp_dir, "root")
    agents = Path.join(root, "AGENTS.md")
    git_marker = Path.join(root, ".git")
    File.mkdir_p!(git_marker)

    # Exactly at the budget: verbatim.
    boundary = String.duplicate("a", @max_bytes)
    File.write!(agents, boundary)
    assert [%{content: ^boundary}] = ProjectInstructions.load(root)

    big = String.duplicate("abcdefgh", 5_000)
    File.write!(agents, big)
    head = binary_part(big, 0, @max_bytes)

    assert [%{path: ^agents, content: content}] = ProjectInstructions.load(root)
    assert content == head <> "\n[AGENTS.md truncated: 40000 bytes total, first 32 KiB kept]"
  end

  @tag :tmp_dir
  test "a truncation that splits a multibyte codepoint scrubs the tail", ctx do
    root = Path.join(ctx.tmp_dir, "root")
    agents = Path.join(root, "AGENTS.md")
    File.mkdir_p!(Path.join(root, ".git"))

    # The 4-byte emoji straddles the 32 KiB cut: the head cannot end on a
    # partial codepoint — neither the JSON request body nor the session file
    # survives a raw binary tail.
    big = String.duplicate("a", @max_bytes - 2) <> "😀" <> "tail"
    File.write!(agents, big)

    assert [%{content: content}] = ProjectInstructions.load(root)

    assert String.valid?(content)
    assert String.starts_with?(content, String.duplicate("a", @max_bytes - 2))
    assert content =~ "[AGENTS.md truncated: #{byte_size(big)} bytes total, first 32 KiB kept]"
  end

  @tag :tmp_dir
  test "an unreadable AGENTS.md is skipped without raising", ctx do
    root = Path.join(ctx.tmp_dir, "root")
    sub = Path.join(root, "sub")
    agents = Path.join(root, "AGENTS.md")
    inner_agents = Path.join(sub, "AGENTS.md")
    git_marker = Path.join(root, ".git")
    File.mkdir_p!(sub)
    File.write!(agents, "locked\n")
    File.write!(inner_agents, "readable\n")
    File.mkdir_p!(git_marker)
    File.chmod!(agents, 0)
    on_exit(fn -> File.chmod!(agents, 0o644) end)

    # A privileged user (e.g. root) reads a 000-mode file anyway; both arms
    # assert, so neither runner loses the coverage.
    if match?({:ok, _}, File.read(agents)) do
      assert ProjectInstructions.load(sub) == [
               %{path: agents, content: "locked\n"},
               %{path: inner_agents, content: "readable\n"}
             ]
    else
      assert ProjectInstructions.load(sub) == [
               %{path: inner_agents, content: "readable\n"}
             ]
    end
  end
end
