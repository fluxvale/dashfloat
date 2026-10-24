defmodule DashFloat.Tools.Runner do
  @moduledoc """
  Executes one validated tool call against the working directory.

  Every path argument goes through `DashFloat.Tools.PathPolicy` first; on
  rejection the result is `%{ok: false, path: path, error: message}`. The
  rescue is a belt only — the per-tool clauses cover everything; if it ever
  fires, the result degrades to `%{ok: false, error: "tool crashed: ..."}`,
  never a raise into the caller.
  """

  alias DashFloat.Tools.Edit
  alias DashFloat.Tools.Exec
  alias DashFloat.Tools.PathPolicy

  @exec_output_cap 32 * 1024
  @read_byte_cap 64 * 1024
  @list_entry_cap 500
  @edit_byte_cap 8 * 1024 * 1024
  @default_exec_timeout 30_000

  @doc """
  Runs tool `name` with already-validated `args` (see `DashFloat.Tools.validate/2`)
  sandboxed at `cwd`. Options: `:exec_timeout` (default #{@default_exec_timeout} ms).
  """
  @spec run(String.t(), map(), Path.t(), keyword()) :: map()
  def run(name, args, cwd, opts \\ []) do
    case name do
      "read_file" ->
        unwrap(read_file(args, cwd))

      "write_file" ->
        write_file(args, cwd)

      "edit_file" ->
        unwrap(edit_file(args, cwd))

      "execute_command" ->
        execute_command(args, cwd, Keyword.get(opts, :exec_timeout, @default_exec_timeout))

      "list_directory" ->
        list_directory(args, cwd)
    end
  rescue
    exception -> %{ok: false, error: "tool crashed: " <> Exception.message(exception)}
  end

  # The `with` chains return {:error, result}; run/4's caller sees bare maps.
  defp unwrap({:error, result}), do: result
  defp unwrap(result), do: result

  @doc false
  # Shared with Preview: everything edit_file does before writing — resolve,
  # read, size cap, locate. Returns the match, or the runner-shaped error.
  @spec prepare_edit(map(), Path.t()) ::
          {:ok, %{resolved: Path.t(), content: String.t(), start: non_neg_integer()}}
          | {:error, map()}
  def prepare_edit(args, cwd) do
    with {:ok, resolved} <- resolve_path(cwd, args["path"]),
         {:ok, content} <- read_file_content(resolved, args["path"]),
         :ok <- check_edit_size(args["path"], content),
         {:ok, start} <- locate_unique(args, content) do
      {:ok, %{resolved: resolved, content: content, start: start}}
    end
  end

  defp check_edit_size(path, content) when byte_size(content) > @edit_byte_cap,
    do: {:error, %{ok: false, path: path, error: "file too large to edit"}}

  defp check_edit_size(_path, _content), do: :ok

  defp locate_unique(args, content) do
    case Edit.locate(content, args["search_block"]) do
      {:ok, %{start: start}} -> {:ok, start}
      {:error, reason} -> {:error, edit_error(args["path"], reason)}
    end
  end

  ## read_file

  defp read_file(args, cwd) do
    with {:ok, resolved} <- resolve_path(cwd, args["path"]),
         {:ok, content} <- read_file_content(resolved, args["path"]) do
      total_bytes = byte_size(content)
      all_lines = Edit.lines(content)
      total_lines = length(all_lines)

      window =
        all_lines
        |> Enum.drop(args["offset"] - 1)
        |> Enum.take(args["limit"])

      {shown, _bytes} = take_lines(window, @read_byte_cap)
      last_line = args["offset"] + length(shown) - 1
      truncated = last_line < total_lines

      shown_content =
        if truncated,
          do:
            Enum.join(shown, "\n") <>
              "\n… [truncated: showing #{length(shown)} of #{total_lines} lines]",
          else: Enum.join(shown, "\n")

      %{
        ok: true,
        path: args["path"],
        content: shown_content,
        lines: length(shown),
        total_lines: total_lines,
        total_bytes: total_bytes,
        truncated: truncated
      }
    end
  end

  ## write_file

  defp write_file(args, cwd) do
    case resolve_path(cwd, args["path"]) do
      {:error, result} -> result
      {:ok, resolved} -> write_resolved(args, resolved)
    end
  end

  defp write_resolved(args, resolved) do
    existed = File.exists?(resolved)
    parent = Path.dirname(resolved)

    case File.mkdir_p(parent) do
      :ok -> write_content(args, resolved, existed)
      {:error, reason} -> mkdir_error(args, reason)
    end
  end

  defp write_content(args, resolved, existed) do
    case File.write(resolved, args["content"]) do
      :ok ->
        %{ok: true, path: args["path"], bytes: byte_size(args["content"]), created: not existed}

      {:error, reason} ->
        write_error(args, reason)
    end
  end

  defp mkdir_error(args, reason),
    do: %{
      ok: false,
      path: args["path"],
      error: "could not create directory: " <> reason_string(reason)
    }

  defp write_error(args, reason),
    do: %{ok: false, path: args["path"], error: "could not write file: " <> reason_string(reason)}

  ## edit_file

  defp edit_file(args, cwd) do
    case prepare_edit(args, cwd) do
      {:error, result} ->
        result

      {:ok, %{resolved: resolved, content: content, start: start}} ->
        apply_edit(args, resolved, content, start)
    end
  end

  defp apply_edit(args, resolved, content, start) do
    if args["search_block"] == args["replace_block"] do
      %{ok: false, path: args["path"], error: "search and replace blocks are identical"}
    else
      write_edit(args, resolved, splice(content, start, args))
    end
  end

  defp write_edit(args, resolved, new_content) do
    case File.write(resolved, new_content) do
      :ok -> %{ok: true, path: args["path"], replaced: 1}
      {:error, reason} -> write_error(args, reason)
    end
  end

  ## execute_command

  defp execute_command(args, cwd, timeout) do
    case PathPolicy.resolve(cwd, args["cwd"]) do
      {:ok, resolved} -> Exec.run(args["command"], resolved, timeout, @exec_output_cap)
      {:error, message} -> %{ok: false, path: args["cwd"], error: message}
    end
  end

  ## list_directory

  defp list_directory(args, cwd) do
    case resolve_path(cwd, args["path"]) do
      {:error, result} ->
        result

      {:ok, resolved} ->
        case File.ls(resolved) do
          {:ok, names} ->
            entries =
              names
              |> Enum.map(&classify_entry(resolved, &1))
              |> Enum.sort()
              |> Enum.map(&render_entry/1)
              |> Enum.take(@list_entry_cap)

            %{
              ok: true,
              path: args["path"],
              entries: entries,
              count: length(names),
              truncated: length(names) > @list_entry_cap
            }

          {:error, :enoent} ->
            %{ok: false, path: args["path"], error: "directory not found"}

          {:error, reason} ->
            %{
              ok: false,
              path: args["path"],
              error: "could not list directory: " <> reason_string(reason)
            }
        end
    end
  end

  # {sort order, name, kind}: directories first, then everything else
  # alphabetical by name; the kind only picks the rendered marker.
  defp classify_entry(dir, name) do
    entry = Path.join(dir, name)

    case File.lstat(entry) do
      {:ok, %File.Stat{type: :directory}} -> {0, name, :dir}
      {:ok, %File.Stat{type: :symlink}} -> {1, name, :symlink}
      _other -> {1, name, :file}
    end
  end

  defp render_entry({0, name, :dir}), do: "d " <> name <> "/"
  defp render_entry({1, name, :symlink}), do: "@ " <> name
  defp render_entry({1, name, :file}), do: "- " <> name

  ## Shared helpers
  defp resolve_path(cwd, path) do
    case PathPolicy.resolve(cwd, path) do
      {:ok, resolved} -> {:ok, resolved}
      {:error, message} -> {:error, %{ok: false, path: path, error: message}}
    end
  end

  defp read_file_content(resolved, path) do
    case File.read(resolved) do
      {:ok, content} ->
        {:ok, content}

      {:error, :enoent} ->
        {:error, %{ok: false, path: path, error: "file not found"}}

      {:error, reason} ->
        {:error,
         %{ok: false, path: path, error: "could not read file: " <> reason_string(reason)}}
    end
  end

  defp edit_error(path, :empty_search),
    do: %{ok: false, path: path, error: "search block is empty"}

  defp edit_error(path, {:no_match, 0}),
    do: %{ok: false, path: path, error: "search block not found"}

  defp edit_error(path, {:ambiguous, n}),
    do: %{ok: false, path: path, error: "search block matches #{n} times; make it unique"}

  # Whole lines while the joined content stays within `cap` bytes.
  defp take_lines(lines, cap) do
    take_lines(lines, cap, [], 0)
  end

  defp take_lines([], _cap, acc, bytes), do: {Enum.reverse(acc), bytes}

  defp take_lines([line | rest], cap, acc, bytes) do
    joined = bytes + byte_size(line) + if(bytes == 0, do: 0, else: 1)

    if joined <= cap do
      take_lines(rest, cap, [line | acc], joined)
    else
      {Enum.reverse(acc), bytes}
    end
  end

  defp splice(content, start, args) do
    len = byte_size(args["search_block"])

    binary_part(content, 0, start) <>
      args["replace_block"] <>
      binary_part(content, start + len, byte_size(content) - start - len)
  end

  defp reason_string(reason), do: to_string(:file.format_error(reason))
end
