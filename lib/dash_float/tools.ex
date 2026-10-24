defmodule DashFloat.Tools do
  @moduledoc """
  The tool catalogue: the OpenAI `tools` array the model sees, and argument
  validation with defaults. String keys throughout — arguments arrive as
  decoded JSON objects and results go back as JSON.

  One internal parameter table drives both `schema/0` and `validate/2`, so the
  advertised contract and the enforced one cannot drift.
  """

  @params %{
    "read_file" => [
      %{
        name: "path",
        type: :string,
        required: true,
        nonempty: true,
        description: "File path, relative to the working directory or absolute inside it.",
        minimum: nil,
        maximum: nil,
        default: :none
      },
      %{
        name: "offset",
        type: :integer,
        required: false,
        description: "First line to return, counting from 1.",
        minimum: 1,
        maximum: nil,
        default: 1
      },
      %{
        name: "limit",
        type: :integer,
        required: false,
        description: "Maximum number of lines to return.",
        minimum: 1,
        maximum: 10_000,
        default: 2_000
      }
    ],
    "write_file" => [
      %{
        name: "path",
        type: :string,
        required: true,
        nonempty: true,
        description: "File path to write. Parent directories are created.",
        minimum: nil,
        maximum: nil,
        default: :none
      },
      %{
        name: "content",
        type: :string,
        required: true,
        description: "Full new content of the file.",
        minimum: nil,
        maximum: nil,
        default: :none
      }
    ],
    "edit_file" => [
      %{
        name: "path",
        type: :string,
        required: true,
        nonempty: true,
        description: "File path to edit.",
        minimum: nil,
        maximum: nil,
        default: :none
      },
      %{
        name: "search_block",
        type: :string,
        required: true,
        description: "Exact text to replace. Must match the file exactly once.",
        minimum: nil,
        maximum: nil,
        default: :none
      },
      %{
        name: "replace_block",
        type: :string,
        required: true,
        description: "Replacement text for the matched block.",
        minimum: nil,
        maximum: nil,
        default: :none
      }
    ],
    "execute_command" => [
      %{
        name: "command",
        type: :string,
        required: true,
        nonempty: true,
        description: "Shell command line to run.",
        minimum: nil,
        maximum: nil,
        default: :none
      },
      %{
        name: "cwd",
        type: :string,
        required: false,
        nonempty: true,
        description: "Directory to run the command in, relative to the working directory.",
        minimum: nil,
        maximum: nil,
        default: "."
      }
    ],
    "list_directory" => [
      %{
        name: "path",
        type: :string,
        required: false,
        nonempty: true,
        description: "Directory to list, relative to the working directory.",
        minimum: nil,
        maximum: nil,
        default: "."
      }
    ]
  }

  @descriptions %{
    "read_file" =>
      "Read a window of lines from a text file. Lines are 1-based; without offset or limit the first 2000 lines are returned. Output is byte-capped, so very long files come back truncated — re-read with offset/limit for the rest.",
    "write_file" =>
      "Create or overwrite a file with the given full content. Parent directories are created automatically. The user confirms before it runs.",
    "edit_file" =>
      "Replace an exact block of text in a file. search_block must match the file exactly once — include surrounding lines to make it unique. The user confirms before it runs.",
    "execute_command" =>
      "Run a shell command line and return its combined output (stdout and stderr, capped). Prefer it for builds, tests, and searches. The user confirms before it runs.",
    "list_directory" =>
      "List a directory's entries: directories first, then files, each alphabetical."
  }

  @order ["read_file", "write_file", "edit_file", "execute_command", "list_directory"]

  @doc "The OpenAI `tools` array advertising the catalogue."
  @spec schema() :: [map()]
  def schema do
    Enum.map(@order, fn name ->
      params = @params[name]

      %{
        "type" => "function",
        "function" => %{
          "name" => name,
          "description" => @descriptions[name],
          "parameters" => %{
            "type" => "object",
            "properties" => Map.new(params, &property/1),
            "required" => for(param <- params, param.required, do: param.name)
          }
        }
      }
    end)
  end

  @doc """
  Validates `args` against the catalogue: name known, every parameter present
  when required, correctly typed, and within range. Returns the arguments
  with string keys and defaults filled. Never raises.
  """
  @spec validate(String.t(), map() | nil) :: {:ok, map()} | {:error, String.t()}
  def validate(name, args) when is_binary(name) and is_map(args) do
    case @params[name] do
      nil ->
        {:error, "unknown tool " <> inspect(name)}

      params ->
        with :ok <- check_file_target(name, args) do
          validate_params(name, params, args, %{})
        end
    end
  end

  def validate(name, _args) when is_binary(name),
    do: {:error, "#{name}: arguments must be an object"}

  def validate(name, _args), do: {:error, "unknown tool " <> inspect(name)}

  # A trailing "/" on a file-write target names a directory; the OS would
  # silently strip it and create a FILE named "newdir" for "newdir/" — refuse.
  defp check_file_target(tool, %{"path" => path})
       when tool in ["write_file", "edit_file"] and is_binary(path) and path != "" and
              binary_part(path, byte_size(path), -1) == "/",
       do: {:error, tool <> ": path must name a file, not end in \"/\""}

  defp check_file_target(_tool, _args), do: :ok

  defp validate_params(_tool, [], _args, acc), do: {:ok, acc}

  defp validate_params(tool, [param | rest], args, acc) do
    case Map.fetch(args, param.name) do
      {:ok, value} ->
        case check_value(tool, param, value) do
          {:ok, value} -> validate_params(tool, rest, args, Map.put(acc, param.name, value))
          {:error, _message} = error -> error
        end

      :error ->
        if param.required do
          {:error, ~s(#{tool}: missing required argument "#{param.name}")}
        else
          validate_params(tool, rest, args, default(param, acc))
        end
    end
  end

  defp default(param, acc), do: Map.put(acc, param.name, param.default)

  # A ranged integer folds its range into the type message — the spec's
  # "limit must be an integer between 1 and 10000" covers wrong type and
  # out-of-range alike.
  defp check_value(tool, %{type: :integer, minimum: min, maximum: max} = param, value)
       when is_integer(min) and is_integer(max) do
    if is_integer(value) and value in min..max do
      {:ok, value}
    else
      {:error, "#{tool}: #{param.name} must be an integer between #{min} and #{max}"}
    end
  end

  defp check_value(tool, %{type: :integer, minimum: min} = param, value) when is_integer(min) do
    if is_integer(value) and value >= min do
      {:ok, value}
    else
      {:error, "#{tool}: #{param.name} must be an integer of at least #{min}"}
    end
  end

  defp check_value(tool, %{type: :string, nonempty: true} = param, ""),
    do: {:error, "#{tool}: #{param.name} must not be empty"}

  defp check_value(_tool, %{type: :string} = _param, value) when is_binary(value),
    do: {:ok, value}

  defp check_value(tool, %{type: :string} = param, _value),
    do: {:error, "#{tool}: #{param.name} must be a string"}

  defp property(param) do
    base = %{"type" => type_name(param.type), "description" => param.description}
    min_length = if Map.get(param, :nonempty), do: 1, else: nil

    prop =
      base
      |> maybe_put("minimum", param.minimum)
      |> maybe_put("maximum", param.maximum)
      |> maybe_put("default", param.default)
      |> maybe_put("minLength", min_length)

    {param.name, prop}
  end

  defp maybe_put(prop, _json_key, :none), do: prop
  defp maybe_put(prop, _json_key, nil), do: prop
  defp maybe_put(prop, json_key, value), do: Map.put(prop, json_key, value)

  defp type_name(:string), do: "string"
  defp type_name(:integer), do: "integer"
end
