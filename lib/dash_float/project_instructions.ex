defmodule DashFloat.ProjectInstructions do
  alias DashFloat.Tools.Edit

  @moduledoc """
  Discovers the project's AGENTS.md files for a session (ADR 0019): from `cwd`
  upward, every readable AGENTS.md is collected until the nearest ancestor
  carrying a `.git` marker — inclusive, so the repo root's own file counts.
  The marker may be a file (linked worktrees), so it is tested with
  `File.lstat/1` — which, unlike `File.exists?/1`, also treats a dangling
  `.git` symlink as a marker; with no marker anywhere the walk reaches the
  filesystem root. Only REGULAR files are collected (an lstat, not a stat, so
  symlinks are rejected: a cloned repo must not be able to aim the discovery
  at files outside itself — the tool layer's sandbox rejects the same class,
  ADR 0007 — and a FIFO or device cannot hang or slurp the boot). The list
  is most-general-first, and each file's content is capped at 32 KiB (HEAD
  of the file, read bounded) with a truncation marker — the whole budget
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

    if match?({:ok, _}, File.lstat(marker)) do
      acc
    else
      parent = Path.dirname(dir)
      if parent == dir, do: acc, else: walk(parent, acc)
    end
  end

  # Only a regular, readable AGENTS.md is collected. The content scrubs
  # through Edit.sanitize/1 after truncation: a byte-budget cut can split a
  # multibyte codepoint, and neither the JSON request body nor the session
  # file survives a raw binary tail (the fleet's every-byte-boundary rule).
  defp collect(dir, acc) do
    path = Path.join(dir, @agents_file)

    with {:ok, %{type: :regular, size: size}} <- File.lstat(path),
         {:ok, content} <- read_bounded(path) do
      [{path, content |> truncate(size) |> Edit.sanitize()} | acc]
    else
      _other -> acc
    end
  end

  # Reads at most one byte past the budget: enough to know the file is over
  # it (and to build the head) without slurping a multi-GiB AGENTS.md into
  # memory at boot. Empty files read :eof and are skipped.
  defp read_bounded(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, io} ->
        try do
          :file.read(io, @max_bytes + 1)
        after
          File.close(io)
        end

      _error ->
        {:error, :unreadable}
    end
  end

  # At or under the budget a file passes through verbatim; anything longer
  # keeps its head and names the original size. A file that shrank between
  # the lstat and the read keeps whatever was read — never a raise.
  defp truncate(content, size) do
    cond do
      size <= @max_bytes ->
        content

      byte_size(content) > @max_bytes ->
        binary_part(content, 0, @max_bytes) <>
          "\n[AGENTS.md truncated: #{size} bytes total, first #{div(@max_bytes, 1024)} KiB kept]"

      true ->
        content
    end
  end
end
