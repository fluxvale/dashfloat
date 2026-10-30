defmodule DashFloat.SystemPromptTest do
  @moduledoc false
  # Pure renderer tests — no servers; the only process spawned is the git
  # probe (one real `git status`, plus one `git init` in the probe test).
  #
  # See ADR 0019.

  use ExUnit.Case, async: true

  alias DashFloat.SystemPrompt

  test "build carries identity, tool discipline, edit rules, and the cwd" do
    prompt = SystemPrompt.build("/tmp/sysprompt-fixture")

    assert prompt =~ "You are DashFloat"
    assert prompt =~ "wait for the user's approval"
    assert prompt =~ "/tmp/sysprompt-fixture"

    for tool <- ~w(read_file write_file edit_file execute_command list_directory) do
      assert prompt =~ tool
    end
  end

  test "sections compose in the specified order" do
    prompt = SystemPrompt.build("/tmp/sysprompt-fixture")

    needles = [
      "You are DashFloat",
      "# Tool calling",
      "# Editing code",
      "# Environment",
      "Working directory:"
    ]

    positions = Enum.map(needles, fn needle -> elem(:binary.match(prompt, needle), 0) end)
    assert positions == Enum.sort(positions)
  end

  test "git_info: dirty, clean, and explicit nil" do
    dirty = SystemPrompt.build("/tmp/sysprompt-fixture", git_info: %{branch: "main", dirty: true})

    clean =
      SystemPrompt.build("/tmp/sysprompt-fixture", git_info: %{branch: "main", dirty: false})

    none = SystemPrompt.build("/tmp/sysprompt-fixture", git_info: nil)

    assert dirty =~ "Git: main (uncommitted changes present)"
    assert clean =~ "Git: main (clean)"
    refute none =~ "Git:"
  end

  @tag :tmp_dir
  test "the live probe: a non-repo omits Git, a repo shows it", ctx do
    # ExUnit's tmp dir sits inside this repo's tree, so the walk-up probe
    # would find it — the non-repo half needs a dir outside any repo.
    outside = Path.join(System.tmp_dir!(), "sysprompt-nonrepo-#{System.unique_integer()}")
    File.mkdir_p!(outside)
    on_exit(fn -> File.rm_rf!(outside) end)

    assert SystemPrompt.build(outside) =~ "Working directory: #{outside}"
    refute SystemPrompt.build(outside) =~ "Git:"

    # A fresh init may warn about the default branch name on stderr; the
    # assertion is presence of the line, not the branch name.
    System.cmd("git", ["init", ctx.tmp_dir], stderr_to_stdout: true)
    assert SystemPrompt.build(ctx.tmp_dir) =~ "Git: "
  end

  test "the named seams are no-ops today" do
    assert SystemPrompt.mode_sections([]) == []
    assert SystemPrompt.skills_section([]) == ""

    refute SystemPrompt.build("/tmp/sysprompt-fixture") =~ "# Skills"
  end

  test "project instructions render provenance, verbatim content, and the conflict rule" do
    prompt =
      SystemPrompt.build("/tmp/sysprompt-fixture",
        project_instructions: [
          %{path: "/tmp/sysprompt-fixture/AGENTS.md", content: "be terse\n"},
          %{path: "/tmp/sysprompt-fixture/pkg/AGENTS.md", content: "subdir wins"}
        ]
      )

    assert prompt =~ "# Project instructions"
    assert prompt =~ "when they conflict, the later"
    assert prompt =~ "--- /tmp/sysprompt-fixture/AGENTS.md ---\nbe terse"
    assert prompt =~ "--- /tmp/sysprompt-fixture/pkg/AGENTS.md ---\nsubdir wins"
  end

  test "an empty project instructions list omits the section" do
    refute SystemPrompt.build("/tmp/sysprompt-fixture") =~ "# Project instructions"
  end
end
