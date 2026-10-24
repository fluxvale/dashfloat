defmodule DashFloat.Tools.Runner do
  @moduledoc """
  Executes one validated tool call against the working directory.

  Every path argument goes through `DashFloat.Tools.PathPolicy` first; on
  rejection the result is `%{ok: false, path: path, error: message}`. File
  writes go through a temp file + rename so a symlink swapped in after the
  policy check is replaced, not followed. The rescue is a belt only — the
  per-tool clauses cover everything; if it ever fires, the result degrades
  to `%{ok: false, error: "tool crashed: ..."}`, never a raise into the
  caller.
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
         :ok <- reject_root(cwd, resolved, args["path"]),
         :ok <- check_edit_size(resolved, args["path"]),
         {:ok, content} <- read_file_content(resolved, args["path"]),
         {:ok, start} <- locate_unique(args, content) do
      {:ok, %{resolved: resolved, content: content, start: start}}
    end
  end

  # The size gate stats before reading: an oversized artifact is refused
  # without ever landing whole in memory.
  defp check_edit_size(resolved, path) do
    case File.stat(resolved) do
      {:ok, %File.Stat{size: size}} when size > @edit_byte_cap ->
        {:error, %{ok: false, path: path, error: "file too large to edit"}}

      _other ->
        :ok
    end
  end

  defp locate_unique(args, content) do
    case Edit.locate(content, args["search_block"]) do
      {:ok, %{start: start}} -> {:ok, start}
      {:error, reason} -> {:error, edit_error(args["path"], reason)}
    end
  end

  ## read_file

  defp read_file(args, cwd) do
    with {:ok, resolved} <- resolve_path(cwd, args["path"]),
         {:ok, stat} <- stat_source(resolved, args["path"]),
         :ok <- reject_directory(stat, args["path"]) do
      read_window(args, resolved, stat)
    end
  end

  # File.stream! raises on directories (a big directory's inode size qualifies
  # for the streamed path) — refuse with the same shape as File.read would.
  defp reject_directory(%File.Stat{type: :directory}, path),
    do: {:error, read_error(path, :eisdir)}

  defp reject_directory(_stat, _path), do: :ok

  # Files above this size stream only the requested window instead of landing
  # whole in memory (the caps in the result must bound reads, not just output).
  @read_stream_floor 256 * 1024

  defp read_window(args, resolved, %File.Stat{size: size}) when size > @read_stream_floor do
    first = args["offset"] - 1
    last = args["offset"] + args["limit"] - 1

    case stream_lines(resolved, first, last) do
      {:error, reason} ->
        read_error(args["path"], reason)

      {:ok, window} ->
        wanted = Enum.take(window, args["limit"])

        {shown, _bytes} = take_lines(wanted, @read_byte_cap)

        # Honest AFTER the byte cap: the read is truncated if the window held
        # more lines than requested (past-the-end probe) OR the cap cut into it.
        truncated = length(window) > args["limit"] or length(shown) < length(wanted)

        joined =
          shown
          |> Enum.join("\n")
          |> Edit.sanitize()

        content =
          if truncated,
            do: joined <> "\n… [truncated: showing #{length(shown)} lines]",
            else: joined

        %{
          ok: true,
          path: args["path"],
          content: content,
          lines: length(shown),
          total_bytes: size,
          truncated: truncated
        }
    end
  end

  # Small files read whole: the exact line total makes the truncation report
  # honest (total_lines is unknown on the streamed path).
  defp read_window(args, resolved, %File.Stat{} = _stat) do
    case File.read(resolved) do
      {:ok, content} ->
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

        joined =
          shown
          |> Enum.join("\n")
          |> Edit.sanitize()

        content =
          if truncated,
            do: joined <> "\n… [truncated: showing #{length(shown)} of #{total_lines} lines]",
            else: joined

        %{
          ok: true,
          path: args["path"],
          content: content,
          lines: length(shown),
          total_lines: total_lines,
          total_bytes: total_bytes,
          truncated: truncated
        }

      {:error, reason} ->
        read_error(args["path"], reason)
    end
  end

  # The stat-then-stream race (file vanished or mutated between the calls)
  # raises; it must degrade to the same error shape as everything else.
  defp stream_lines(resolved, first, last) do
    window =
      resolved
      |> File.stream!()
      |> Stream.map(&String.trim_trailing(&1, "\n"))
      |> Enum.slice(first..last//1)

    {:ok, window}
  rescue
    e in File.Error -> {:error, e.reason}
  end

  defp stat_source(resolved, path) do
    case File.stat(resolved) do
      {:ok, stat} -> {:ok, stat}
      {:error, reason} -> {:error, read_error(path, reason)}
    end
  end

  ## write_file

  # Writes land via an exclusively-created temp file + rename. Rename
  # replaces the final path ENTRY (symlink included) instead of following it,
  # and O_CREAT|O_EXCL plus a crypto-random temp name mean a symlink
  # pre-planted at either name is never followed — together closing the
  # check-then-write races where a swapped or guessed symlink would redirect
  # the write outside the sandbox. The existing file's mode is preserved.
  defp write_file(args, cwd) do
    case resolve_path(cwd, args["path"]) do
      {:error, result} ->
        result

      {:ok, resolved} ->
        case reject_root(cwd, resolved, args["path"]) do
          :ok -> write_resolved(args, resolved)
          {:error, result} -> result
        end
    end
  end

  # A target that resolves ONTO the working directory would place the temp
  # file in the root's PARENT — outside the sandbox — before rename fails;
  # refuse instead.
  defp reject_root(cwd, resolved, path) do
    case PathPolicy.resolve(cwd, ".") do
      {:ok, root} when root == resolved ->
        {:error, %{ok: false, path: path, error: "path is the working directory itself"}}

      _other ->
        :ok
    end
  end

  defp write_resolved(args, resolved) do
    existed = File.exists?(resolved)
    parent = Path.dirname(resolved)

    case File.mkdir_p(parent) do
      :ok ->
        mode = if existed, do: perm_bits(resolved), else: nil
        write_atomically(args, resolved, args["content"], existed, mode)

      {:error, reason} ->
        mkdir_error(args, reason)
    end
  end

  defp write_atomically(args, resolved, content, existed, mode) do
    case write_atomic(resolved, content, mode) do
      :ok -> %{ok: true, path: args["path"], bytes: byte_size(content), created: not existed}
      {:error, reason} -> write_error(args, reason)
    end
  end

  defp write_atomic(resolved, content, mode) do
    tmp = temp_path(resolved)

    result =
      try do
        with {:ok, device} <- File.open(tmp, [:write, :exclusive]),
             :ok <- fill(device, tmp, content, mode),
             :ok <- File.rename(tmp, resolved) do
          :ok
        else
          {:error, reason} -> {:error, reason}
        end
      rescue
        # A mid-write I/O failure raises (ENOSPC, dead device): the write is
        # over either way — report it through the same error door.
        exception -> {:error, Exception.message(exception)}
      end

    case result do
      :ok -> :ok
      {:error, reason} -> discard_tmp(tmp, reason)
    end
  end

  defp discard_tmp(tmp, reason) do
    File.rm(tmp)
    {:error, reason}
  end

  # `mode` is nil for fresh files; over an existing entry the old
  # permissions carry over — a rename alone would reset them to 0644.
  defp fill(device, tmp, content, mode) do
    result =
      try do
        :ok = IO.binwrite(device, content)
        :ok
      after
        File.close(device)
      end

    case result do
      :ok when is_nil(mode) -> :ok
      :ok -> File.chmod(tmp, mode)
    end
  end

  defp perm_bits(resolved) do
    %File.Stat{mode: mode} = File.stat!(resolved)
    Bitwise.&&&(mode, 0o7777)
  end

  defp temp_path(resolved) do
    rand = :crypto.strong_rand_bytes(6)
    suffix = Base.url_encode64(rand, padding: false)
    resolved <> ".df-tmp-" <> suffix
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
    case write_atomic(resolved, new_content, perm_bits(resolved)) do
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
            # Sort the raw names first (no syscalls), then classify at most
            # cap+1 entries: the shown window is the true alphabetical head,
            # not readdir order pretending to be sorted. NB File.ls silently
            # skips non-UTF-8 names on this runtime — they are invisible to
            # the model; count reflects only the encodable names.
            window =
              names
              |> Enum.sort()
              |> Enum.take(@list_entry_cap + 1)

            entries =
              window
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

      {:error, reason} ->
        {:error, read_error(path, reason)}
    end
  end

  defp read_error(path, :enoent), do: %{ok: false, path: path, error: "file not found"}

  defp read_error(path, reason),
    do: %{ok: false, path: path, error: "could not read file: " <> reason_string(reason)}

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
