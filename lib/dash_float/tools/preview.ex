defmodule DashFloat.Tools.Preview do
  @moduledoc """
  Builds the confirmation preview content for a mutating tool call (ADR 0007).
  The engine truth is plain lines; the UI styles them.

  Every check the runner performs happens here first — a preview that cannot
  read or locate shows the runner-shaped error unchanged (there is nothing to
  confirm). Preview reads are bounded: an existing write_file target over
  256 KiB is not read at all.
  """

  alias DashFloat.Tools.Edit
  alias DashFloat.Tools.PathPolicy
  alias DashFloat.Tools.Runner

  @max_content_lines 50
  @existing_read_cap 256 * 1024
  @context_lines 3

  @doc """
  Builds `%{lines: lines}` for `write_file`, `edit_file`, and
  `execute_command`; read-only tools and unknown names return an error map.
  """
  @spec build(String.t(), map(), Path.t()) :: {:ok, %{lines: [String.t()]}} | {:error, map()}
  def build("write_file", args, cwd), do: write_preview(args, cwd)
  def build("edit_file", args, cwd), do: edit_preview(args, cwd)
  def build("execute_command", args, cwd), do: exec_preview(args, cwd)
  def build(name, _args, _cwd), do: {:error, %{ok: false, error: "no preview for " <> name}}

  ## write_file

  defp write_preview(args, cwd) do
    case PathPolicy.resolve(cwd, args["path"]) do
      {:error, message} ->
        {:error, %{ok: false, path: args["path"], error: message}}

      {:ok, resolved} ->
        {:ok, %{lines: [write_label(resolved, args["path"]) | content_lines(args["content"])]}}
    end
  end

  defp write_label(resolved, path) do
    case File.stat(resolved) do
      {:ok, %File.Stat{size: size}} when size > @existing_read_cap ->
        "overwrite: #{path} (too large to preview, #{size} bytes)"

      {:ok, %File.Stat{size: size}} ->
        "overwrite: #{path} (#{size} bytes)"

      {:error, _reason} ->
        "create: " <> path
    end
  end

  defp content_lines(content) do
    all = Edit.lines(content)
    shown = Enum.take(all, @max_content_lines)
    prefixed = Enum.map(shown, &("+ " <> &1))
    rest = length(all) - length(shown)

    if rest > 0, do: prefixed ++ ["+ … (#{rest} more lines)"], else: prefixed
  end

  ## edit_file

  defp edit_preview(args, cwd) do
    case Runner.prepare_edit(args, cwd) do
      {:error, result} ->
        {:error, result}

      {:ok, %{content: content, start: start}} ->
        {:ok, %{lines: hunk(content, start, args["search_block"], args["replace_block"])}}
    end
  end

  # A unified hunk: @context_lines lines around the match, "- " for the search
  # lines, "+ " for the replace lines, clamped to the file's bounds.
  defp hunk(content, start, search_block, replace_block) do
    lines = Edit.lines(content)
    search = Edit.lines(search_block)
    replace = Edit.lines(replace_block)

    match_line = newlines_before(content, start)
    first = max(match_line - @context_lines, 0)
    before_lines = Enum.slice(lines, first, match_line - first)
    after_from = match_line + length(search)
    after_lines = Enum.slice(lines, after_from, @context_lines)

    old_count = length(before_lines) + length(search) + length(after_lines)
    new_count = length(before_lines) + length(replace) + length(after_lines)

    [
      "@@ -#{first + 1},#{old_count} +#{first + 1},#{new_count} @@"
      | Enum.map(before_lines, &("  " <> &1))
    ] ++
      Enum.map(search, &("- " <> &1)) ++
      Enum.map(replace, &("+ " <> &1)) ++
      Enum.map(after_lines, &("  " <> &1))
  end

  defp newlines_before(content, start) do
    content
    |> binary_part(0, start)
    |> :binary.matches("\n")
    |> length()
  end

  ## execute_command

  defp exec_preview(args, cwd) do
    case PathPolicy.resolve(cwd, args["cwd"]) do
      {:ok, resolved} -> {:ok, %{lines: ["$ " <> args["command"], "cwd: " <> resolved]}}
      {:error, message} -> {:error, %{ok: false, path: args["cwd"], error: message}}
    end
  end
end
