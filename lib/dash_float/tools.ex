defmodule DashFloat.Tools do
  @moduledoc """
  The tool catalogue: the OpenAI `tools` array the model sees, and argument
  validation with defaults. String keys throughout — arguments arrive as
  decoded JSON objects and results go back as JSON.

  One internal parameter table drives both `schema/1` and `validate/2`, so the
  advertised contract and the enforced one cannot drift.

  web_search rides the same table but is advertised only when the session
  carries a Synthetic context (ADR 0021 §6); `validate/2` stays total over the
  table on purpose — a model hallucinating web_search without a key gets a
  normal validation pass, then the runner errors honestly at run time.
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
    ],
    "question" => [
      %{
        name: "question",
        type: :string,
        required: true,
        nonempty: true,
        description: "The question to show the user.",
        minimum: nil,
        maximum: nil,
        default: :none
      },
      %{
        name: "options",
        type: :options,
        required: true,
        nonempty: false,
        description:
          "Answer options (1-10): objects with a nonempty label and an optional description.",
        minimum: nil,
        maximum: nil,
        default: :none
      },
      %{
        name: "multiple",
        type: :boolean,
        required: false,
        nonempty: false,
        description: "Allow multiple answers (the user toggles with space). Default false.",
        minimum: nil,
        maximum: nil,
        default: false
      }
    ],
    "web_search" => [
      %{
        name: "query",
        type: :string,
        required: true,
        nonempty: true,
        description: "The search query.",
        minimum: nil,
        maximum: nil,
        default: :none
      }
    ]
  }

  @descriptions %{
    "read_file" =>
      "Read a window of lines from a text file. Lines are 1-based; without offset or limit the first 2000 lines are returned. Output is byte-capped, so very long files come back truncated — re-read with offset/limit for the rest.",
    "write_file" =>
      "Create or overwrite a file with the given full content. Parent directories are created automatically. The user may confirm before it runs, depending on the session mode.",
    "edit_file" =>
      "Replace an exact block of text in a file. search_block must match the file exactly once — include surrounding lines to make it unique. The user may confirm before it runs, depending on the session mode.",
    "execute_command" =>
      "Run a shell command line and return its combined output (stdout and stderr, capped). Prefer it for builds, tests, and searches. The user may confirm before it runs, depending on the session mode.",
    "list_directory" =>
      "List a directory's entries: directories first, then files, each alphabetical.",
    "question" =>
      "Ask the user a direct question and wait for their answer. The question renders as a choice list in the input field: the user picks with arrows and Enter (space toggles answers when multiple is true) or dismisses with Esc, which answers cancelled. Use it whenever a decision or preference belongs to the user — never guess when you can ask.",
    "web_search" =>
      "Search the web. Use this to find information you are not sure about, to look up documentation, or to find data created after your training knowledge cutoff. Returns a list of results with url, title, and highlights."
  }

  @order [
    "read_file",
    "write_file",
    "edit_file",
    "execute_command",
    "list_directory",
    "question",
    "web_search"
  ]

  @classes %{
    "read_file" => :safe,
    "list_directory" => :safe,
    "write_file" => :mutating,
    "edit_file" => :mutating,
    "execute_command" => :risky,
    # The ask-user tool (#134, ADR 0028): asking is not an action — it is
    # safe in every mode, and the agent intercepts it before the gate.
    "question" => :safe,
    "web_search" => :safe
  }

  # Display excerpt for tool-result rows; the model gets the bounded full result.
  @display_lines 30
  # The question tool's option-count cap (#134, ADR 0028): bounds the choice
  # widget's height (the composer's replacement box).
  @max_options 10

  @doc "Risk class per ADR 0016 §2. Unknown names are :risky (fail closed)."
  @spec class(String.t()) :: :safe | :mutating | :risky
  def class(name), do: Map.get(@classes, name, :risky)

  @doc """
  The OpenAI `tools` array advertising the catalogue. web_search is
  advertised only when `synthetic` — the session's Synthetic context — is
  present (ADR 0021 §6); without one the array is the base six-tool list
  (the question tool rides every mode, ADR 0028).
  """
  @spec schema(term()) :: [map()]
  def schema(synthetic \\ nil) do
    order = if synthetic, do: @order, else: List.delete(@order, "web_search")

    Enum.map(order, fn name ->
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

  # The question tool's options (#134, ADR 0028): 1-10 maps, each with a
  # nonempty string label and an optional string description. Normalized to
  # exactly those two keys (a nil description kept for uniform rendering).
  defp check_value(tool, %{type: :options} = param, value)
       when is_list(value) and length(value) <= @max_options do
    if valid_options?(value) do
      {:ok, Enum.map(value, &normalize_option/1)}
    else
      {:error, options_message(tool, param)}
    end
  end

  defp check_value(tool, %{type: :options} = param, _value),
    do: {:error, options_message(tool, param)}

  defp check_value(_tool, %{type: :boolean}, value) when is_boolean(value),
    do: {:ok, value}

  defp check_value(tool, %{type: :boolean} = param, _value),
    do: {:error, "#{tool}: #{param.name} must be a boolean"}

  defp check_value(tool, %{type: :string, nonempty: true} = param, ""),
    do: {:error, "#{tool}: #{param.name} must not be empty"}

  defp check_value(_tool, %{type: :string} = _param, value) when is_binary(value),
    do: {:ok, value}

  defp check_value(tool, %{type: :string} = param, _value),
    do: {:error, "#{tool}: #{param.name} must be a string"}

  defp valid_options?([]), do: false

  defp valid_options?(options), do: Enum.all?(options, &valid_option/1)

  # The description is optional throughout (a model omits it when an option
  # needs no explaining) — Map.get, never a match.
  defp valid_option(%{"label" => label} = option)
       when is_binary(label) and label != "",
       do:
         match?(
           description when is_binary(description) or is_nil(description),
           option["description"]
         )

  defp valid_option(_other), do: false

  defp normalize_option(%{"label" => label} = option) do
    %{"label" => label, "description" => Map.get(option, "description")}
  end

  defp options_message(tool, param),
    do:
      "#{tool}: #{param.name} must be a list of 1-#{@max_options} objects, " <>
        "each with a nonempty string label and an optional string description"

  defp property(param) do
    base = %{"type" => type_name(param.type), "description" => param.description}
    min_length = if Map.get(param, :nonempty), do: 1, else: nil

    prop =
      base
      |> maybe_put("minimum", param.minimum)
      |> maybe_put("maximum", param.maximum)
      |> maybe_put("default", param.default)
      |> maybe_put("minLength", min_length)
      |> maybe_put("items", items(param.type))

    {param.name, prop}
  end

  # The question tool's options (#134): the item shape advertised exactly
  # as validation enforces it — the catalogue's advertised/enforced
  # no-drift rule (ADR 0016 §2's principle), so models do not guess.
  defp items(:options) do
    %{
      "type" => "object",
      "properties" => %{
        "label" => %{"type" => "string", "minLength" => 1},
        "description" => %{"type" => "string"}
      },
      "required" => ["label"]
    }
  end

  defp items(_type), do: nil

  defp maybe_put(prop, _json_key, :none), do: prop
  defp maybe_put(prop, _json_key, nil), do: prop
  defp maybe_put(prop, json_key, value), do: Map.put(prop, json_key, value)

  defp type_name(:string), do: "string"
  defp type_name(:integer), do: "integer"
  defp type_name(:boolean), do: "boolean"
  defp type_name(:options), do: "array"

  ## Result display derivation
  #
  # One derivation of tool-result display data, shared by the agent's
  # display messages and the session's replay paths. See ADR 0014.

  @doc "The result recorded for tool calls that never ran — what the agent's cancel path writes and what session load synthesizes for calls a crash left dangling."
  @spec cancelled_result() :: %{ok: false, cancelled: true}
  def cancelled_result, do: %{ok: false, cancelled: true}

  @doc """
  The tool-result row's status word: `"rejected"`, `"cancelled"`,
  `"proposed (plan)"`, `"auto-rejected: …"` (the AUTO safety check's binary
  reject, ADR 0028), `"answered: …"` (the question tool), `"ok"`, or
  `"error: …"` with the message capped at 160 characters.
  """
  @spec display_status(map()) :: String.t()
  def display_status(%{rejected: true}), do: "rejected"
  def display_status(%{cancelled: true}), do: "cancelled"
  def display_status(%{blocked: "plan"}), do: "proposed (plan)"

  def display_status(%{blocked: "auto", reason: reason}) when is_binary(reason) and reason != "",
    do: "auto-rejected: " <> String.slice(reason, 0, 160)

  def display_status(%{blocked: "auto"}), do: "auto-rejected"

  def display_status(%{ok: true, answers: answers}) when is_list(answers) do
    answers
    |> Enum.join(", ")
    |> String.slice(0, 160)
    |> then(&"answered: #{&1}")
  end

  def display_status(%{ok: true}), do: "ok"

  def display_status(%{error: error}) when is_binary(error),
    do: "error: " <> String.slice(error, 0, 160)

  def display_status(_other), do: "error"

  @doc """
  The tool-result row's display body: the result's `:output` (falling back to
  `:content`) capped at #{@display_lines} lines, or nil when the result
  carries neither.
  """
  @spec display_excerpt(map()) :: String.t() | nil
  def display_excerpt(result) do
    case result[:output] || result[:content] do
      nil ->
        nil

      body ->
        lines = String.split(body, "\n")

        if length(lines) <= @display_lines do
          body
        else
          lines
          |> Enum.take(@display_lines)
          |> Enum.join("\n")
        end
    end
  end
end
