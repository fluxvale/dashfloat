defmodule DashFloat.SystemPromptTest do
  @moduledoc false
  # Pure renderer tests — no servers; the only process spawned is the git
  # probe (one real `git status`, plus one `git init` in the probe test).
  #
  # See ADR 0019.

  use ExUnit.Case, async: true

  alias DashFloat.Synthetic
  alias DashFloat.SystemPrompt
  alias DashFloat.Tools

  # The drift pin (#101, ADR 0030): the prose's tool enumeration is extracted
  # from the rendered text and compared against the schema's advertised
  # names — the prompt restates the catalogue by derivation, never by
  # hardcoding, so the two cannot disagree.

  # Parses "You have N tools: a, b, and c." into {n, [names]}.
  defp enumerated(prompt) do
    case Regex.run(~r/You have (\d+) tools?: ([^.]+)\./, prompt) do
      [_match, count, list] ->
        {String.to_integer(count), Regex.split(~r/, and | and |, /, list)}

      nil ->
        flunk("tool enumeration sentence missing from prompt")
    end
  end

  # What the model is actually advertised for this ctx.
  defp advertised(synthetic) do
    schema = Tools.schema(synthetic)
    Enum.map(schema, & &1["function"]["name"])
  end

  test "the tool enumeration is the registry's advertised set, never hardcoded" do
    {base_count, base_names} = enumerated(SystemPrompt.build("/tmp/sysprompt-fixture"))
    assert base_count == length(advertised(nil))
    assert base_names == advertised(nil)

    # A Synthetic ctx rides web_search into the schema — the prose follows.
    prompt = SystemPrompt.build("/tmp/sysprompt-fixture", tools: advertised(%Synthetic{}))
    {count, names} = enumerated(prompt)
    assert count == length(advertised(%Synthetic{}))
    assert names == advertised(%Synthetic{})
    assert "web_search" in names
  end

  test "a registry addition flows into the prose with no other edit" do
    names = advertised(nil) ++ ["hypothetical_tool"]
    prompt = SystemPrompt.build("/tmp/sysprompt-fixture", tools: names)

    {count, listed} = enumerated(prompt)
    assert count == length(names)
    assert listed == names
  end

  test "the approval grouping derives from the catalogue's risk classes" do
    assert SystemPrompt.build("/tmp/sysprompt-fixture") =~
             "read_file and list_directory run automatically. write_file, edit_file, and execute_command wait for the user's approval."

    assert SystemPrompt.build("/tmp/sysprompt-fixture", tools: advertised(%Synthetic{})) =~
             "read_file, list_directory, and web_search run automatically."
  end

  test "single- and two-tool catalogues render grammatical prose" do
    one = SystemPrompt.build("/tmp/sysprompt-fixture", tools: ["read_file"])
    assert one =~ "You have 1 tool: read_file."
    assert one =~ "read_file runs automatically."
    refute one =~ "wait for the user's approval"

    two = SystemPrompt.build("/tmp/sysprompt-fixture", tools: ["read_file", "write_file"])
    assert two =~ "You have 2 tools: read_file and write_file."
    assert two =~ "read_file runs automatically. write_file waits for the user's approval."
  end

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
