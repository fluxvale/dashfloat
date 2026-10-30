defmodule DashFloat.ProjectInstructions do
  alias DashFloat.Tools.Edit

  @moduledoc """
  Discovers the project's AGENTS.md files for a session (ADR 0019): from `cwd`
  upward, every readable AGENTS.md is collected until the nearest ancestor
  carrying a `.git` marker — inclusive, so the repo root's own file counts.
  The marker may be a file (linked worktrees), so it is tested with
  `File.exists?/1`; with no marker anywhere the walk reaches the filesystem
  root. The list is most-general-first, and each file's content is capped at
  32 KiB (HEAD of the file) with a truncation marker — the whole budget
  policy. Pure reads only; nothing here raises.
  """

  # The per-file budget (ADR 0019): 32 KiB of the file's head — the whole
  # policy, no total cap, no file-count cap.
  @max_bytes 32_768

  @agents_file "AGENTS.md"

  @spec load(Path.t()) :: [%{path: String.t(), content: String.t()}]
  def load(cwd) do
    cwd
    |> Path.expand()
    |> walk([])
    |> Enum.map(fn {path, content} -> %{path: path, content: content} end)
  end

  # Discovery order: the directory itself, then each parent; the .git-marked
  # ancestor is examined too (the inclusive stop). No .git anywhere walks to
  # the filesystem root (dirname("/") == "/").
  defp walk(dir, acc) do
    acc = collect(dir, acc)
    marker = Path.join(dir, ".git")

    if File.exists?(marker) do
      acc
    else
      parent = Path.dirname(dir)
      if parent == dir, do: acc, else: walk(parent, acc)
    end
  end

  # Only a readable AGENTS.md is collected — a missing, unreadable, or
  # directory-shaped file is skipped, never an error. The content scrubs
  # through Edit.sanitize/1 after truncation: a byte-budget cut can split a
  # multibyte codepoint, and neither the JSON request body nor the session
  # file survives a raw binary tail (the fleet's every-byte-boundary rule).
  defp collect(dir, acc) do
    path = Path.join(dir, @agents_file)

    case File.read(path) do
      {:ok, content} -> [{path, content |> truncate() |> Edit.sanitize()} | acc]
      {:error, _reason} -> acc
    end
  end

  # At or under the budget a file passes through verbatim; anything longer
  # keeps its head and names the original size.
  defp truncate(content) do
    size = byte_size(content)

    if size <= @max_bytes do
      content
    else
      binary_part(content, 0, @max_bytes) <>
        "\n[AGENTS.md truncated: #{size} bytes total, first 32 KiB kept]"
    end
  end
end
