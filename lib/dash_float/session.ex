defmodule DashFloat.Session do
  @moduledoc """
  The transcript store ([ADR 0014](0014-session-persistence.md) §2–§4): one
  JSON file per session, `<dir>/<id>.json`, written atomically at 0600
  through `DashFloat.Config.Posture`, loaded with tolerance — errors name
  paths and fields, dangling tool calls are repaired in memory, and a load
  never writes. Message maps stay string-keyed as decoded; nothing is ever
  atomized.
  """

  alias DashFloat.Config.Posture
  alias DashFloat.Tools

  @version 1

  @id_shape ~r/\A[0-9]{8}-[0-9]{6}-[0-9a-f]{6}\z/

  @type pin :: %{
          profile: String.t() | nil,
          model: String.t() | nil,
          base_url: String.t() | nil
        }

  @type t :: %{
          version: 1,
          id: String.t(),
          created_at: String.t(),
          pin: pin(),
          messages: [map()]
        }

  @doc "The sessions directory: `.../dashfloat/sessions` under the XDG data dir."
  @spec dir() :: String.t()
  def dir do
    data_dir = :filename.basedir(:user_data, "dashfloat")
    Path.join(data_dir, "sessions")
  end

  @doc """
  A fresh session id: UTC `YYYYMMDD-HHMMSS` plus six random hex chars —
  name-sortable ≈ time-sortable, collision-safe in practice.
  """
  @spec new_id() :: String.t()
  def new_id do
    stamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d-%H%M%S")
    bytes = :crypto.strong_rand_bytes(3)
    rand = Base.encode16(bytes, case: :lower)
    stamp <> "-" <> rand
  end

  @doc """
  Writes the session as compact JSON + newline via
  `DashFloat.Config.Posture.write_private/2` (0600, atomic rename over a
  unique tmp staging name), creating `dir` on demand. Errors name paths only.
  """
  @spec save(Path.t(), t()) :: :ok | {:error, String.t()}
  def save(dir, session) do
    # The id names the file (ADR 0014 §2): only the minted shape ever
    # reaches the filesystem, so no hand-supplied id can carry a path.
    with :ok <- check_id_shape(session.id) do
      case ensure_dir(dir) do
        :ok ->
          path = path_for(dir, session.id)

          # A session the encoder refuses (a tool result carrying an invalid
          # byte, say) must degrade like any other failed save, never raise
          # out of the agent loop. The error names the path, never the bytes.
          case Jason.encode(session) do
            {:ok, contents} ->
              Posture.write_private(path, contents <> "\n")

            {:error, _reason} ->
              {:error, "cannot write #{path}: session is not encodable"}
          end

        {:error, _reason} = error ->
          error
      end
    end
  end

  @doc """
  Loads `<dir>/<id>.json`, never writing: unknown ids and missing directories
  name the directory; unreadable or undecodable files, schema violations, and
  orphaned tool results refuse naming the path, the message index, and the
  field; dangling tool calls gain synthesized cancelled results in memory.
  The requested id may carry the `.json` suffix `ls` prints; the strict id
  shape applies either way. The messages come back string-keyed as decoded
  (plus repairs).
  """
  @spec load(Path.t(), String.t()) :: {:ok, t()} | {:error, String.t()}
  def load(dir, requested) do
    id = String.replace_suffix(requested, ".json", "")

    with :ok <- check_id_shape(id) do
      do_load(dir, id)
    end
  end

  defp do_load(dir, id) do
    path = path_for(dir, id)

    with {:ok, body} <- read_file(path, dir, id),
         {:ok, decoded} <- decode(path, body),
         {:ok, decoded} <- top_level(decoded, path),
         :ok <- check_version(decoded, path),
         :ok <- check_id(decoded, path, id),
         {:ok, created_at} <- check_created_at(decoded, path),
         :ok <- check_messages_list(decoded, path),
         {:ok, messages} <- check_messages(path, Map.fetch!(decoded, "messages")) do
      {:ok,
       %{
         version: @version,
         id: id,
         created_at: created_at,
         pin: build_pin(decoded),
         messages: repair(messages)
       }}
    end
  end

  # The error names the expected shape, never the offending id (ADR 0014 §4).
  defp check_id_shape(id) do
    if Regex.match?(@id_shape, id),
      do: :ok,
      else: {:error, "session ids look like 20261027-143052-a1b2c3"}
  end

  defp path_for(dir, id), do: Path.join(dir, id <> ".json")

  defp ensure_dir(dir) do
    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> {:error, "cannot create #{dir}: #{:file.format_error(reason)}"}
    end
  end

  defp read_file(path, dir, id) do
    case File.read(path) do
      {:ok, body} ->
        {:ok, body}

      {:error, :enoent} ->
        {:error, "no session #{id} under #{dir} — list sessions with: ls #{dir}"}

      {:error, reason} ->
        {:error, "cannot read #{path}: #{:file.format_error(reason)}"}
    end
  end

  # The decode error's own message can quote file bytes — the refusal must
  # not echo contents (ADR 0014 §4).
  defp decode(path, body) do
    case Jason.decode(body) do
      {:ok, decoded} ->
        {:ok, decoded}

      {:error, %Jason.DecodeError{}} ->
        {:error, "#{path}: not valid session JSON"}
    end
  end

  defp top_level(decoded, _path) when is_map(decoded), do: {:ok, decoded}

  defp top_level(_other, path),
    do: {:error, "#{path}: not a session file — the top level must be an object"}

  defp check_version(%{"version" => @version}, _path), do: :ok

  defp check_version(%{"version" => version}, path) when is_integer(version) and version > 1,
    do:
      {:error,
       "#{path}: \"version\" is #{version} — written by a newer DashFloat (this one reads #{@version})"}

  defp check_version(_decoded, path),
    do: {:error, "#{path}: \"version\" must be the integer #{@version}"}

  defp check_id(%{"id" => id}, _path, id), do: :ok

  defp check_id(%{"id" => _other}, path, requested),
    do: {:error, "#{path}: \"id\" is not the requested session #{requested}"}

  defp check_id(_decoded, path, _requested),
    do: {:error, "#{path}: \"id\" must be a string naming the session"}

  defp check_created_at(%{"created_at" => created_at}, _path) when is_binary(created_at),
    do: {:ok, created_at}

  defp check_created_at(_decoded, path),
    do: {:error, "#{path}: \"created_at\" must be a string"}

  defp check_messages_list(%{"messages" => messages}, _path) when is_list(messages), do: :ok

  defp check_messages_list(_decoded, path),
    do: {:error, "#{path}: \"messages\" must be a list"}

  # The batch state threaded through validation: the ids the most recent
  # batch announced, and whether its contiguous tool block is still open —
  # the same block rule repair/1 applies, so validation and repair agree on
  # what a batch's block is (ADR 0014 §4).
  @type batch_state :: {MapSet.t(String.t()), boolean()}

  @spec check_messages(String.t(), list(), non_neg_integer(), batch_state()) ::
          {:ok, [map()]} | {:error, String.t()}
  defp check_messages(path, messages, index \\ 0, batch \\ {MapSet.new(), false})
  defp check_messages(_path, [], _index, _batch), do: {:ok, []}

  defp check_messages(path, [message | rest], index, batch) do
    with {:ok, batch} <- check_message(path, index, message, batch) do
      case check_messages(path, rest, index + 1, batch) do
        {:ok, tail} -> {:ok, [message | tail]}
        {:error, _reason} = error -> error
      end
    end
  end

  defp check_message(path, index, %{"role" => "user"} = message, batch) do
    with :ok <- check_string(path, index, "content", Map.get(message, "content")) do
      {:ok, close_block(batch)}
    end
  end

  defp check_message(path, index, %{"role" => "assistant"} = message, batch) do
    with :ok <- check_assistant_content(path, index, Map.get(message, "content")),
         :ok <- check_tool_calls(path, index, Map.get(message, "tool_calls")) do
      {:ok, announce(message, batch)}
    end
  end

  defp check_message(path, index, %{"role" => "tool"} = message, batch) do
    tool_call_id = Map.get(message, "tool_call_id")

    with :ok <- check_string(path, index, "tool_call_id", tool_call_id),
         :ok <- check_string(path, index, "content", Map.get(message, "content")),
         :ok <- check_announced(path, index, tool_call_id, batch) do
      {:ok, batch}
    end
  end

  defp check_message(path, index, _message, _announced),
    do: {:error, "#{path}: message #{index} has no known \"role\""}

  defp check_assistant_content(_path, _index, content) when is_binary(content), do: :ok
  defp check_assistant_content(_path, _index, nil), do: :ok

  defp check_assistant_content(path, index, _other),
    do: {:error, "#{path}: message #{index} field \"content\" must be a string or null"}

  defp check_string(_path, _index, _field, value) when is_binary(value), do: :ok

  defp check_string(path, index, field, _value),
    do: {:error, "#{path}: message #{index} field \"#{field}\" must be a string"}

  defp check_tool_calls(_path, _index, nil), do: :ok

  defp check_tool_calls(path, index, calls) when is_list(calls) do
    with :ok <- check_call_shapes(path, index, calls) do
      check_unique_ids(path, index, calls)
    end
  end

  defp check_tool_calls(path, index, _other),
    do: {:error, "#{path}: message #{index} field \"tool_calls\" must be a list"}

  defp check_call_shapes(path, index, calls) do
    Enum.reduce_while(calls, :ok, fn call, :ok ->
      case check_call(path, index, call) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  # A batch that repeats an id makes one answer cover two calls — the repair
  # would serve an unbalanced transcript (ADR 0014 §4). No write path of ours
  # produces one (the agent renames at the batch boundary), so it is hand
  # damage and the refusal names the index and the repeated id.
  defp check_unique_ids(path, index, calls) do
    seen =
      Enum.reduce_while(calls, MapSet.new(), fn call, seen ->
        id = call["id"]

        if MapSet.member?(seen, id) do
          {:halt,
           {:error,
            "#{path}: message #{index} repeats tool call id \"#{id}\" — a batch may not announce an id twice"}}
        else
          {:cont, MapSet.put(seen, id)}
        end
      end)

    case seen do
      {:error, _reason} = error -> error
      %MapSet{} -> :ok
    end
  end

  defp check_call(_path, _index, %{
         "id" => id,
         "type" => type,
         "function" => %{"name" => name, "arguments" => arguments}
       })
       when is_binary(id) and is_binary(type) and is_binary(name) and is_binary(arguments),
       do: :ok

  defp check_call(path, index, _call),
    do:
      {:error,
       "#{path}: message #{index} field \"tool_calls\" needs entries with string \"id\" and \"type\" and a \"function\" with string \"name\" and \"arguments\""}

  # A batch opens the contiguous tool block that follows it; any other
  # message closes the previous batch's block. The ids stay known after the
  # close so a later stray answer is named as detached, not orphaned.
  defp announce(message, {pending, _open?}) do
    case batch_calls(message) do
      nil -> {pending, false}
      calls -> {MapSet.new(calls), true}
    end
  end

  defp close_block({pending, _open?}), do: {pending, false}

  defp check_announced(path, index, tool_call_id, {pending, open?}) do
    cond do
      open? and MapSet.member?(pending, tool_call_id) ->
        :ok

      MapSet.member?(pending, tool_call_id) ->
        {:error,
         "#{path}: message #{index} answers a call detached from its batch — a tool message must sit in the tool block directly after the batch it answers"}

      true ->
        {:error,
         "#{path}: message #{index} answers a call no batch announced — \"tool_call_id\" is orphaned"}
    end
  end

  # Dangling repair, in memory (ADR 0014 §4): every id a batch announced but
  # its tool block never answered gains one synthesized cancelled result, in
  # call order, at the block's end — wherever the batch sits. The file on
  # disk is not rewritten; it converges on the next save.
  @spec repair([map()]) :: [map()]
  defp repair([]), do: []

  defp repair([message | rest]) do
    case batch_calls(message) do
      nil ->
        [message | repair(rest)]

      calls ->
        {block, tail} = Enum.split_while(rest, &tool_message?/1)
        [message | block] ++ cancelled_for_missing(block, calls) ++ repair(tail)
    end
  end

  defp batch_calls(%{"role" => "assistant", "tool_calls" => calls}) when is_list(calls),
    do: Enum.map(calls, & &1["id"])

  defp batch_calls(_message), do: nil

  defp cancelled_for_missing(block, calls) do
    answered = MapSet.new(block, & &1["tool_call_id"])

    calls
    |> Enum.reject(&MapSet.member?(answered, &1))
    |> Enum.map(&cancelled_tool/1)
  end

  defp cancelled_tool(tool_call_id) do
    %{
      "role" => "tool",
      "tool_call_id" => tool_call_id,
      "content" => Jason.encode!(Tools.cancelled_result())
    }
  end

  defp tool_message?(%{"role" => "tool"}), do: true
  defp tool_message?(_other), do: false

  # The pin rides along as diagnostics for the resume compare (ADR 0014 §6);
  # a missing or malformed pin compares nothing.
  defp build_pin(%{"pin" => pin}) when is_map(pin) do
    %{
      profile: string_or_nil(pin["profile"]),
      model: string_or_nil(pin["model"]),
      base_url: string_or_nil(pin["base_url"])
    }
  end

  defp build_pin(_decoded), do: %{profile: nil, model: nil, base_url: nil}

  defp string_or_nil(value) when is_binary(value), do: value
  defp string_or_nil(_other), do: nil
end
