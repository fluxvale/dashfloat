defmodule DashFloat.SystemPrompt do
  @moduledoc """
  Assembles the session system prompt once, at session start: identity, tool
  discipline, edit rules, environment facts, and project instructions, with
  named seams for per-mode prompt sections and skills injection. The tool
  prose enumerates the registry's advertised names by derivation (ADR 0030).
  See ADR 0019.
  """

  alias DashFloat.Tools

  @identity """
  You are DashFloat, an AI coding assistant running in the user's terminal. You help
  with software tasks in the working directory below: reading and editing code,
  running commands, and answering questions about the project.
  """

  # The catalogue sentence and the approval grouping render from the
  # registry's advertised names (Tools.names, ADR 0007 / ADR 0030) — the
  # prose restates the schema by derivation, so adding or gating a tool
  # (web_search rides a Synthetic ctx, ADR 0021 §7) flows through with no
  # prompt edit. Behavior prose below still names always-present tools.
  defp tool_calling(opts) do
    names = Keyword.get(opts, :tools, Tools.names(nil))

    """
    # Tool calling

    You have #{length(names)} #{tool_noun(names)}: #{enumerate(names)}. All file paths are relative to the working
    directory.

    - Before calling a tool, say briefly what you plan to do and why, then call it
      right away — do not ask in chat whether you may proceed. The user approves or
      rejects mutations in the interface; a rejection or cancellation comes back to
      you as a result, so adjust your approach instead of repeating the same call.
    - #{approval_line(names)}
    - question asks the user directly: it renders as a choice list they answer
      with arrows and Enter (or dismisses, which answers cancelled). Use it
      whenever a decision or preference belongs to the user — never guess when
      you can ask, and never re-ask what they just answered.
    - Tool results are JSON objects. {"ok": false} is information, not a dead end:
      read the error and try a different approach.
    - edit_file replaces one exact text block that must match the file exactly once;
      read the file first and search for a unique anchor.
    """
  end

  # Safe tools (question excepted — the agent intercepts it before the gate,
  # ADR 0028) run on their own; mutating and risky ones wait for approval.
  # The grouping is derived per name from Tools.class, so a new tool's class
  # decides its sentence placement, not this module's memory.
  defp approval_line(names) do
    auto = for name <- names, name != "question" and Tools.class(name) == :safe, do: name
    confirm = for name <- names, Tools.class(name) != :safe, do: name

    [
      group(auto, "run", "runs", "automatically"),
      group(confirm, "wait", "waits", "for the user's approval")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp group([], _plural, _singular, _rest), do: nil
  defp group([name], _plural, singular, rest), do: "#{name} #{singular} #{rest}."
  defp group(names, plural, _singular, rest), do: "#{enumerate(names)} #{plural} #{rest}."

  defp tool_noun([_name]), do: "tool"
  defp tool_noun(_names), do: "tools"

  defp enumerate([name]), do: name
  defp enumerate([first, second]), do: "#{first} and #{second}"

  defp enumerate(names) do
    {init, [last]} = Enum.split(names, -1)
    Enum.join(init, ", ") <> ", and " <> last
  end

  @editing """
  # Editing code

  - Match each file's existing style, naming, and structure, and check that a
    library is already used in the codebase before writing code that depends on it.
  - Keep changes minimal: touch only what the task requires and leave unrelated
    code alone.
  - After changing code, run the project's own checks — compiler, linter, or the
    focused tests — with execute_command when they exist.
  """

  @doc """
  Builds the system prompt for the session rooted at `cwd`.

  Options:

    * `:git_info` — `nil | %{branch: String.t(), dirty: boolean()}`; overrides
      the live git probe (the deterministic test seam)
    * `:project_instructions` — a list of `%{path: String.t(), content:
      String.t()}` maps rendered as the project instructions section (default: none)
    * `:tools` — the ordered tool names the tool-discipline prose enumerates;
      defaults to `Tools.names(nil)` (the registry's base catalogue). A session
      carrying a Synthetic context passes `Tools.names(synthetic)` so web_search
      rides in (ADR 0021 §7), and tests inject hypothetical catalogues here
  """
  @spec build(Path.t(), keyword()) :: String.t()
  def build(cwd, opts \\ []) do
    sections =
      [@identity, tool_calling(opts), @editing] ++
        mode_sections(opts) ++
        [environment(Path.expand(cwd), opts), skills_section(opts), project_instructions(opts)]

    sections
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  @doc """
  Placeholder seam for the per-mode prompt sections (modes-design lane); returns
  [] until that lane specifies them. Entries join right after "Editing code".
  """
  @spec mode_sections(keyword()) :: [String.t()]
  def mode_sections(_opts), do: []

  @doc """
  Placeholder seam for skills injection (sibling design lane); "" contributes
  nothing to the joined prompt.
  """
  @spec skills_section(keyword()) :: String.t()
  def skills_section(_opts), do: ""

  defp environment(cwd, opts) do
    """
    # Environment

    Working directory: #{cwd}
    Platform: #{platform()}#{git_line(cwd, opts)}
    """
  end

  defp platform do
    {family, name} = :os.type()
    "#{family}/#{name}"
  end

  defp git_line(cwd, opts) do
    case git_info(cwd, opts) do
      nil -> ""
      %{branch: branch, dirty: true} -> "\nGit: #{branch} (uncommitted changes present)"
      %{branch: branch, dirty: false} -> "\nGit: #{branch} (clean)"
    end
  end

  # An explicit git_info opt wins (nil included — the deterministic test seam);
  # otherwise the probe decides.
  defp git_info(cwd, opts) do
    if Keyword.has_key?(opts, :git_info) do
      Keyword.fetch!(opts, :git_info)
    else
      probe_git(cwd)
    end
  end

  # ANY failure — missing git, non-zero exit, a raise — means "unknown": the
  # Git line is omitted, never an error (the cwd need not be a repo).
  defp probe_git(cwd) do
    args = ["-C", cwd, "--no-optional-locks", "status", "--porcelain=v1", "--branch"]

    case System.cmd("git", args, stderr_to_stdout: true) do
      {output, 0} -> parse_git(output)
      {_output, _exit_code} -> nil
    end
  rescue
    _error -> nil
  end

  # First line `## <branch>...[upstream]`; `## HEAD (no branch)` is detached.
  # Any status line after the header means uncommitted changes.
  defp parse_git(output) do
    [header | status_lines] =
      output
      |> String.trim_trailing()
      |> String.split("\n")

    case branch_of(header) do
      nil -> nil
      branch -> %{branch: branch, dirty: status_lines != []}
    end
  end

  defp branch_of("## HEAD (no branch)"), do: "HEAD (detached)"

  defp branch_of("## " <> rest) do
    rest
    |> String.split("...")
    |> hd()
  end

  defp branch_of(_header), do: nil

  # The AGENTS.md-discovery slice builds the list; this slot renders what it is
  # given — a provenance line, the content verbatim, one blank line between files.
  defp project_instructions(opts) do
    case Keyword.get(opts, :project_instructions, []) do
      [] ->
        ""

      entries ->
        rendered =
          Enum.map_join(entries, "\n\n", fn %{path: path, content: content} ->
            String.trim_trailing("--- #{path} ---\n#{content}")
          end)

        """
        # Project instructions

        These files are instructions the user left for agents working in this project,
        ordered from most general to most specific; when they conflict, the later
        (closer) file wins.

        #{rendered}
        """
    end
  end
end
