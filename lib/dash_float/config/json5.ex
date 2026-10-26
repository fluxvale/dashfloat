defmodule DashFloat.Config.JSON5 do
  @moduledoc """
  JSON5 decoding, reading, and rendering for the config files
  ([ADR 0008](../decisions/0008-config-layout-profiles-json5.md)).

  Wraps hex `json5`'s Combine backend. Three decoding deviations from the raw
  library, all load-bearing:

    * numbers decode as `Decimal` (the library preserves precision); they are
      normalized to integers/floats here so config consumers never see one
    * parser errors are replaced with a bare `"invalid JSON5"` — the raw
      reason is position-only noise, and a fixed string guarantees no input
      content can ever leak into an error message next to secrets
    * a number literal the library cannot represent (e.g. `1e10000`) raises
      `Decimal.Error` instead of returning an error tuple — rescued here for
      the same reason (the exception's message quotes the literal, so it must
      never reach a log)

  ## Writing

  The Combine decoder does not process escape sequences (a backslash inside a
  string literal breaks its parsing), so no encoder — including Jason's
  escaped JSON — can round-trip arbitrary values through this dialect.
  `render/1` renders a whole decoded document by hand: 2-space indented,
  sorted keys, bare identifier keys, single-quoted strings (double-quoted when
  the value holds a single quote). A string with a backslash or both quote
  kinds is unrepresentable — the render fails naming the value's PATH (e.g.
  `profiles[0].apiKey`), never its content.
  """

  @indent "  "

  @doc """
  Decodes JSON5 `input`, normalizing numbers. `{:error, "invalid JSON5"}` on
  any parse failure — never the input's content.
  """
  @spec decode(binary()) :: {:ok, term()} | {:error, String.t()}
  def decode(input) when is_binary(input) do
    case Json5.decode(input) do
      {:ok, term} -> {:ok, normalize(term)}
      {:error, _reason} -> {:error, "invalid JSON5"}
    end
  rescue
    # Decimal.Error quotes the literal it cannot represent; invalid UTF-8
    # surfaces as a FunctionClauseError deep in Combine's char matcher.
    # Startup must always reach its config-error path, so the wrapper
    # degrades ANY parser crash to the fixed error string.
    _other -> {:error, "invalid JSON5"}
  end

  @doc """
  Reads `path` (a leading UTF-8 BOM is stripped — editors add one silently)
  and decodes it as a JSON5 OBJECT. A missing file is an empty map; so is a
  blank one — an empty `settings.json5`/`keys.json5` is crash debris or
  hand-emptied damage, not data (ADR 0009's tolerance principle), and the
  load path must read it as "no config", never as invalid JSON5. Every other
  failure names `path` and never the file's content.
  """
  @spec read_map(Path.t()) :: {:ok, map()} | {:error, String.t()}
  def read_map(path) do
    case File.read(path) do
      {:ok, contents} ->
        case blank?(contents) do
          true -> {:ok, %{}}
          false -> decode_map(contents, path)
        end

      {:error, :enoent} ->
        {:ok, %{}}

      {:error, reason} ->
        {:error, "cannot read #{path}: #{:file.format_error(reason)}"}
    end
  end

  @doc """
  Decodes already-read `contents` as a JSON5 object, naming `path` in errors.
  Migration uses this when it also needs the raw bytes (a byte-exact backup).
  """
  @spec decode_map(binary(), Path.t()) :: {:ok, map()} | {:error, String.t()}
  def decode_map(contents, path) do
    case decode(strip_bom(contents)) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, _other} -> {:error, "invalid JSON5 in #{path}: expected an object"}
      {:error, message} -> {:error, "#{message} in #{path}"}
    end
  end

  @doc """
  Renders a decoded document back to JSON5 text (sorted keys, bare identifier
  keys, 2-space indent, trailing commas). `{:error, path}` — never the value —
  when any string in the document is unrepresentable in the dialect.
  """
  @spec render(map()) :: {:ok, binary()} | {:error, String.t()}
  def render(document) when is_map(document) do
    case encode(document, "", 0) do
      {:ok, iodata} -> {:ok, IO.iodata_to_binary(iodata)}
      {:error, _path} = error -> error
    end
  end

  # Single-quoted, or double-quoted when the value contains a single quote;
  # a backslash or both quote kinds is unrepresentable (see the moduledoc).
  # Shared by the renderer and migration's up-front field checks.
  @spec quote_value(binary()) :: {:ok, binary()} | {:error, :unrepresentable}
  def quote_value(value) do
    cond do
      String.contains?(value, "\\") ->
        {:error, :unrepresentable}

      String.contains?(value, "'") and String.contains?(value, "\"") ->
        {:error, :unrepresentable}

      String.contains?(value, "'") ->
        {:ok, ~s("#{value}")}

      true ->
        {:ok, "'#{value}'"}
    end
  end

  ## Rendering — every clause returns {:ok, iodata} | {:error, path}

  defp encode(map, path, depth) when is_map(map) do
    case encode_entries(Enum.sort(map), path, depth) do
      {:ok, []} -> {:ok, "{}"}
      {:ok, iodata} -> {:ok, frame("{", "}", iodata, depth)}
      {:error, _path} = error -> error
    end
  end

  defp encode(list, path, depth) when is_list(list) do
    case encode_items(list, path, depth, 0) do
      {:ok, []} -> {:ok, "[]"}
      {:ok, iodata} -> {:ok, frame("[", "]", iodata, depth)}
      {:error, _path} = error -> error
    end
  end

  defp encode(value, path, _depth) when is_binary(value) do
    case quote_value(value) do
      {:ok, quoted} -> {:ok, quoted}
      {:error, :unrepresentable} -> {:error, path}
    end
  end

  defp encode(value, _path, _depth) when is_integer(value), do: {:ok, Integer.to_string(value)}

  defp encode(value, _path, _depth) when is_float(value), do: {:ok, Float.to_string(value)}
  defp encode(true, _path, _depth), do: {:ok, "true"}
  defp encode(false, _path, _depth), do: {:ok, "false"}
  defp encode(nil, _path, _depth), do: {:ok, "null"}

  defp frame(open, close, iodata, depth) do
    outer = String.duplicate(@indent, depth)
    [open, "\n", iodata, outer, close]
  end

  defp encode_entries([], _path, _depth), do: {:ok, []}

  defp encode_entries([{key, value} | rest], path, depth) do
    with {:ok, rendered} <- render_key(key, path),
         {:ok, item} <- encode(value, child_path(path, key), depth + 1),
         {:ok, rendered_rest} <- encode_entries(rest, path, depth) do
      {:ok, [line(depth), rendered, ": ", item, ",\n", rendered_rest]}
    end
  end

  defp encode_items([], _path, _depth, _index), do: {:ok, []}

  defp encode_items([item | rest], path, depth, index) do
    with {:ok, item_iodata} <- encode(item, child_path(path, index), depth + 1),
         {:ok, rendered_rest} <- encode_items(rest, path, depth, index + 1) do
      {:ok, [line(depth), item_iodata, ",\n", rendered_rest]}
    end
  end

  defp line(depth), do: String.duplicate(@indent, depth + 1)

  defp render_key(key, path) do
    if bare_key?(key) do
      {:ok, key}
    else
      case quote_value(key) do
        {:ok, quoted} -> {:ok, quoted}
        {:error, :unrepresentable} -> {:error, child_path(path, key)}
      end
    end
  end

  # Bare keys must ALSO dodge the parser's ECMA reserved words — the Combine
  # backend rejects `default:` as a bare key (verified against the dep), and
  # the legacy migration writes "default" as a keys.json5 key. The pattern is
  # fully anchored: `=~` with `$` lets a trailing newline through, and a bare
  # `a\n:` key would silently RENAME to `a` on rewrite (hostile review).
  defp bare_key?(key),
    do: Regex.match?(~r/\A[A-Za-z_$][A-Za-z0-9_$]*\z/, key) and not Json5.ECMA.reserved_word?(key)

  # Error paths name locations like `profiles[0].apiKey` — dot-joined map
  # keys, bracket-joined list indices, quoted when the key is not bare.
  defp child_path(path, key) when is_binary(key) do
    if bare_key?(key), do: path_prefix(path) <> key, else: ~s(#{path}["#{key}"])
  end

  defp child_path(path, index) when is_integer(index), do: path <> "[#{index}]"

  defp path_prefix(""), do: ""
  defp path_prefix(path), do: path <> "."

  ## Decoding helpers

  defp blank?(contents) do
    contents
    |> strip_bom()
    |> String.trim()
    |> Kernel.==("")
  end

  defp strip_bom("\xEF\xBB\xBF" <> rest), do: rest
  defp strip_bom(contents), do: contents

  defp normalize(%Decimal{} = decimal) do
    if Decimal.integer?(decimal), do: Decimal.to_integer(decimal), else: Decimal.to_float(decimal)
  end

  defp normalize(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {key, normalize(value)} end)

  defp normalize(list) when is_list(list), do: Enum.map(list, &normalize/1)
  defp normalize(other), do: other
end
