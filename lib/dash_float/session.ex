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

  # Strict lowercase — we mint lowercase; a typed uppercase value fails this
  # check (and is handled as a title by the boot, a later slice). See #80.
  @id_shape ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  @id_example "0192ab4c-1e5f-7d3a-9b8c-2d4e6f8a1b3c"
  @id_shape_error "session ids look like #{@id_example}"

  @type pin :: %{
          profile: String.t() | nil,
          model: String.t() | nil,
          base_url: String.t() | nil
        }

  @type context :: %{prompt_tokens: non_neg_integer(), messages: non_neg_integer()}

  # The two compaction diagnostics are optional (ADR 0022 §6): a saved map
  # without them writes the pre-compaction shape byte-identically, and load
  # always fills them in (nil / []).
  @type t :: %{
          required(:version) => 1,
          required(:id) => String.t(),
          required(:created_at) => String.t(),
          required(:pin) => pin(),
          required(:messages) => [map()],
          optional(:title) => String.t(),
          optional(:context) => context() | nil,
          optional(:compactions) => [map()]
        }

  @doc "The sessions directory: `.../dashfloat/sessions` under the XDG data dir."
  @spec dir() :: String.t()
  def dir do
    data_dir = :filename.basedir(:user_data, "dashfloat")
    Path.join(data_dir, "sessions")
  end

  @doc """
  A fresh session id: UUIDv7 — a 48-bit unix-ms prefix plus 74 random bits,
  canonical lowercase. Name-sortable ≈ time-sortable (ADR 0014 §2) survives:
  the lexical order of ids is their recency order. Elixir 1.20 / OTP 29 ship
  no UUID module (#80), so v7 is minted here in a few lines — no dependency.
  """
  @spec new_id() :: String.t()
  def new_id do
    ts = System.system_time(:millisecond)
    <<rand_a::12, rand_b::62, _spare::22>> = :crypto.strong_rand_bytes(12)
    uuid_hex(<<ts::48, 7::4, rand_a::12, 2::2, rand_b::62>>)
  end

  @doc """
  Whether `id` is the canonical shape `new_id/0` mints (strict lowercase).
  The one source of the shape: `--resume`'s id-or-title routing (ADR 0023
  §5) and the title reservation (§3) ask here rather than keeping regex
  copies that could drift apart.
  """
  @spec valid_id?(String.t()) :: boolean()
  def valid_id?(id) when is_binary(id), do: Regex.match?(@id_shape, id)

  # RFC 9562: 48-bit unix ms, version 7, variant `10`, 62 random bits —
  # collision safety is those 62 bits per millisecond.
  defp uuid_hex(<<payload::binary-size(16)>>) do
    <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4),
      e::binary-size(12)>> = Base.encode16(payload, case: :lower)

    <<a::binary, ?-, b::binary, ?-, c::binary, ?-, d::binary, ?-, e::binary>>
  end

  @typedoc """
  One saved session's picker row data (issue #128): identity, the optional
  title, the creation stamp, the pin, and the first user message's text.
  """
  @type summary :: %{
          id: String.t(),
          title: String.t() | nil,
          created_at: String.t(),
          pin: pin(),
          preview: String.t()
        }

  @doc """
  The saved sessions' summaries, most recent first (issue #128): one
  fail-open pass over the store — the title scan's discipline
  ([ADR 0023](0023-session-titles-and-uuid-ids.md) §4) — never a write. A
  file that is not a decodable map whose `id` equals its UUID-shaped
  filename with a string `created_at` and a `messages` list is skipped
  silently: the load path stays the loud reporter of hand damage. Order is
  `created_at` descending with the id as the tiebreak — UUIDv7 keeps
  name-sortable ≈ time-sortable (ADR 0023 §1). A nil directory (the
  embedded/test default) lists nothing.
  """
  @spec summaries(Path.t() | nil) :: [summary()]
  def summaries(nil), do: []

  def summaries(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.flat_map(&summarize(dir, &1))
        |> Enum.sort_by(&{&1.created_at, &1.id}, :desc)

      {:error, _reason} ->
        []
    end
  end

  # Only a UUID-named, id-consistent, decodable session is pickable — it is
  # exactly what `--resume`/`Session.load/2` can open. The preview is the
  # first user message's text (a parts list joins its text parts, ADR 0018
  # §2) — display data, never validated here.
  defp summarize(dir, name) do
    id = String.replace_suffix(name, ".json", "")
    path = Path.join(dir, name)

    summary =
      with true <- valid_id?(id),
           {:ok, body} <- File.read(path),
           {:ok, decoded} when is_map(decoded) <- Jason.decode(body),
           %{"id" => ^id} <- decoded,
           %{"created_at" => created_at} when is_binary(created_at) <- decoded,
           %{"messages" => messages} when is_list(messages) <- decoded do
        %{
          id: id,
          title: string_or_nil(decoded["title"]),
          created_at: created_at,
          pin: build_pin(decoded),
          preview: preview(messages)
        }
      else
        _skipped -> nil
      end

    List.wrap(summary)
  end

  defp preview(messages) do
    Enum.find_value(messages, "", fn
      %{"role" => "user", "content" => content} -> user_text(content)
      _other -> nil
    end)
  end

  defp user_text(content) when is_binary(content), do: content

  defp user_text(parts) when is_list(parts) do
    Enum.map_join(parts, "", fn
      %{"type" => "text", "text" => text} when is_binary(text) -> text
      _other_part -> ""
    end)
  end

  defp user_text(_other), do: ""

  @doc """
  Writes the session as compact JSON + newline via
  `DashFloat.Config.Posture.write_private/2` (0600, atomic rename over a
  unique tmp staging name), creating `dir` on demand. Errors name paths only.
  """
  @spec save(Path.t(), t()) :: :ok | {:error, String.t()}
  def save(dir, session) do
    # The id names the file (ADR 0014 §2): only the minted shape ever
    # reaches the filesystem, so no hand-supplied id can carry a path.
    with :ok <- check_save_id(session.id) do
      do_save(dir, normalize(session))
    end
  end

  # The additive fields are written only once they exist (ADR 0022 §6, plus
  # the title — #80), so a loaded map re-saves byte-identically to a file
  # that never carried them (hostile review m3).
  defp normalize(session) do
    session
    |> drop_empty(:title, &is_nil/1)
    |> drop_empty(:context, &is_nil/1)
    |> drop_empty(:compactions, &(&1 == []))
  end

  defp drop_empty(session, key, empty?) do
    value = Map.get(session, key)

    if Map.has_key?(session, key) and empty?.(value) do
      Map.delete(session, key)
    else
      session
    end
  end

  @doc """
  One-shot legacy-id sweep (#80): rewrites timestamp-named session files
  under fresh UUIDv7 ids, preserving every other field verbatim, then
  removes the old file — write-before-delete, so a kill in the microsecond
  window can orphan a duplicate that a later sweep rewrites again
  (accepted). Only a fully-loading file is rewritten; one that refuses is
  hand damage the load path will report — skipped silently. A UUID-named
  file is exempt by name shape alone and never decoded. `{:ok, 0}` — zero
  writes — for a missing directory (creation belongs to save) and an
  all-UUID directory, so a steady-state boot touches no session files.
  """
  @spec migrate_legacy_ids(Path.t()) :: {:ok, non_neg_integer()} | {:error, String.t()}
  def migrate_legacy_ids(dir) do
    case File.ls(dir) do
      {:error, _reason} -> {:ok, 0}
      {:ok, names} -> migrate_names(dir, names)
    end
  end

  defp migrate_names(dir, names) do
    legacy =
      names
      |> Enum.filter(fn name -> json_name?(name) and not uuid_name?(name) end)
      |> Enum.sort()

    Enum.reduce_while(legacy, {:ok, 0}, fn name, {:ok, count} ->
      case rewrite_legacy(dir, name) do
        :ok -> {:cont, {:ok, count + 1}}
        :skipped -> {:cont, {:ok, count}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp json_name?(name), do: String.ends_with?(name, ".json")

  defp uuid_name?(name), do: Regex.match?(@id_shape, String.replace_suffix(name, ".json", ""))

  defp rewrite_legacy(dir, name) do
    case load_by_path(dir, String.replace_suffix(name, ".json", "")) do
      {:ok, session} -> rewrite(dir, session)
      {:error, _reason} -> :skipped
    end
  end

  defp rewrite(dir, session) do
    fresh_id = new_id()

    case save(dir, %{session | id: fresh_id}) do
      :ok -> remove_legacy(dir, session.id, path_for(dir, fresh_id))
      {:error, _reason} = error -> error
    end
  end

  # If the old name cannot be removed, remove the fresh copy instead: a
  # persistently un-removable legacy file must not mint one orphan UUID
  # duplicate per boot (ADR 0023 §2 accepts a ONE-TIME kill-window
  # duplicate, not a multiplier) — the next boot retries the rewrite whole.
  # Only the failure arm is ignore-marked: the success arm is exercised by
  # every sweep-migration test and must keep its coverage honest.
  defp remove_legacy(dir, old_id, new_path) do
    old_path = path_for(dir, old_id)

    case File.rm(old_path) do
      :ok ->
        :ok

      # coveralls-ignore-start
      # Deterministic rm-failure with a successful save needs a filesystem
      # condition the suite cannot produce unprivileged (immutable file —
      # a read-only directory fails the save first); probe-verified in
      # review, not suite-reachable.
      {:error, _reason} ->
        _removed = File.rm(new_path)
        {:error, "cannot remove #{old_path}"}
        # coveralls-ignore-stop
    end
  end

  defp do_save(dir, session) do
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

  @doc """
  Loads `<dir>/<id>.json`, never writing: unknown ids and missing directories
  name the directory; unreadable or undecodable files, schema violations, and
  orphaned tool results refuse naming the path, the message index, and the
  field; dangling tool calls gain synthesized cancelled results in memory.
  The requested id may carry the `.json` suffix `ls` prints; the strict id
  shape applies either way. The messages come back string-keyed as decoded
  (plus repairs). The compaction diagnostics come back tolerant (ADR 0022
  §6, the pin precedent): `context` is the atom-keyed anchor when well-shaped
  and nil otherwise; `compactions` is the eviction history verbatim when a
  list and [] otherwise.
  """
  @spec load(Path.t(), String.t()) :: {:ok, t()} | {:error, String.t()}
  def load(dir, requested) do
    with :ok <- check_load_id(dir, requested) do
      load_by_path(dir, String.replace_suffix(requested, ".json", ""))
    end
  end

  # The UUID gate lives in load/2; the legacy-id sweep (#80) reuses the
  # validation below — version, id-field-equals-filename, created_at,
  # messages shape — with the gate bypassed.
  defp load_by_path(dir, id) do
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
         title: build_title(decoded),
         pin: build_pin(decoded),
         messages: repair(messages),
         context: build_context(decoded),
         compactions: build_compactions(decoded)
       }}
    end
  end

  # Save keeps the shape-only message; load speaks the canonical unknown-id
  # refusal — directory and ls remedy — because a hand-typed `--resume` id
  # must land on the same remedy as `--resume does-not-exist` (ADR 0014 §4).
  # Only a string id can carry the shape; anything else refuses, never raises.
  defp check_save_id(id) when is_binary(id) do
    if Regex.match?(@id_shape, id), do: :ok, else: {:error, @id_shape_error}
  end

  defp check_save_id(_other), do: {:error, @id_shape_error}

  defp check_load_id(dir, requested) when is_binary(requested) do
    id = String.replace_suffix(requested, ".json", "")

    if Regex.match?(@id_shape, id) do
      :ok
    else
      {:error,
       "no session #{id} under #{dir} — session ids look like #{@id_example}; list sessions with: ls #{dir}"}
    end
  end

  defp check_load_id(dir, other) do
    # inspect, not interpolation: a pid/map/tuple id has no String.Chars and
    # the refusal must never itself raise.
    {:error,
     "no session #{inspect(other)} under #{dir} — session ids look like #{@id_example}; list sessions with: ls #{dir}"}
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
  # batch announced, the ids that block has already answered, and whether
  # the block is still open — the same block rule repair/1 applies, so
  # validation and repair agree on what a batch's block is (ADR 0014 §4).
  @type batch_state :: {MapSet.t(String.t()), MapSet.t(String.t()), boolean()}

  @spec check_messages(String.t(), list(), non_neg_integer(), batch_state()) ::
          {:ok, [map()]} | {:error, String.t()}
  defp check_messages(path, messages, index \\ 0, batch \\ {MapSet.new(), MapSet.new(), false})
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
    with :ok <- check_user_content(path, index, Map.get(message, "content")) do
      {:ok, close_block(batch)}
    end
  end

  defp check_message(path, index, %{"role" => "assistant"} = message, batch) do
    with :ok <- check_assistant_content(path, index, Map.get(message, "content")),
         :ok <- check_reasoning(path, index, Map.get(message, "reasoning_content")),
         :ok <- check_tool_calls(path, index, Map.get(message, "tool_calls")) do
      {:ok, announce(message, batch)}
    end
  end

  defp check_message(path, index, %{"role" => "tool"} = message, batch) do
    tool_call_id = Map.get(message, "tool_call_id")

    with :ok <- check_string(path, index, "tool_call_id", tool_call_id),
         :ok <- check_string(path, index, "content", Map.get(message, "content")) do
      check_answer(path, index, tool_call_id, batch)
    end
  end

  # The session-start system prompt (ADR 0019) persists with the transcript:
  # content must be a string, and it neither opens nor closes a tool-call
  # batch — the batch state passes through untouched.
  defp check_message(path, index, %{"role" => "system"} = message, batch) do
    with :ok <- check_string(path, index, "content", Map.get(message, "content")) do
      {:ok, batch}
    end
  end

  defp check_message(path, index, _message, _announced),
    do: {:error, "#{path}: message #{index} has no known \"role\""}

  defp check_assistant_content(_path, _index, content) when is_binary(content), do: :ok
  defp check_assistant_content(_path, _index, nil), do: :ok

  defp check_assistant_content(path, index, _other),
    do: {:error, "#{path}: message #{index} field \"content\" must be a string or null"}

  # The persisted thinking (issue #78): absent or null on every pre-reasoning
  # session, a string on reasoning ones; anything else is hand damage.
  defp check_reasoning(_path, _index, reasoning)
       when is_binary(reasoning) or is_nil(reasoning),
       do: :ok

  defp check_reasoning(path, index, _other),
    do: {:error, "#{path}: message #{index} field \"reasoning_content\" must be a string"}

  defp check_string(_path, _index, _field, value) when is_binary(value), do: :ok

  defp check_string(path, index, field, _value),
    do: {:error, "#{path}: message #{index} field \"#{field}\" must be a string"}

  # User content is a string — or, with image attachments (ADR 0018 §2), a
  # list of content parts, each exactly a text part or an image_url part.
  # Anything else refuses naming the index and the expected shape.
  defp check_user_content(_path, _index, content) when is_binary(content), do: :ok

  defp check_user_content(path, index, content) when is_list(content) do
    if Enum.all?(content, &part?/1) do
      :ok
    else
      {:error,
       "#{path}: message #{index} field \"content\" must be a list of parts — each " <>
         ~s({"type": "text", "text": string}) <>
         " or " <>
         ~s({"type": "image_url", "image_url": {"url": string}})}
    end
  end

  defp check_user_content(path, index, _other),
    do:
      {:error,
       "#{path}: message #{index} field \"content\" must be a string or a list of content parts"}

  defp part?(%{"type" => "text", "text" => text}) when is_binary(text), do: true

  defp part?(%{"type" => "image_url", "image_url" => %{"url" => url}}) when is_binary(url),
    do: true

  defp part?(_other), do: false

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
  # message closes the previous batch's block. The pending ids stay known
  # after the close so a later stray answer is named as detached, not
  # orphaned; the answered set resets with each batch.
  defp announce(message, {pending, _answered, _open?}) do
    case batch_calls(message) do
      nil -> {pending, MapSet.new(), false}
      calls -> {MapSet.new(calls), MapSet.new(), true}
    end
  end

  defp close_block({pending, _answered, _open?}), do: {pending, MapSet.new(), false}

  # Records the answer on the open block, or refuses: an id the block never
  # announced is orphaned, one announced but answered past the block is
  # detached, and one answered TWICE in the same block leaves the transcript
  # unbalanced — one call, two answers (ADR 0014 §4).
  defp check_answer(path, index, tool_call_id, {pending, answered, open?}) do
    cond do
      open? and MapSet.member?(pending, tool_call_id) and MapSet.member?(answered, tool_call_id) ->
        {:error,
         "#{path}: message #{index} is a duplicate answer for tool call \"#{tool_call_id}\""}

      open? and MapSet.member?(pending, tool_call_id) ->
        {:ok, {pending, MapSet.put(answered, tool_call_id), open?}}

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
        {block, tail} = Enum.split_while(rest, &block_member?/1)
        [message | block] ++ cancelled_for_missing(block, calls) ++ repair(tail)
    end
  end

  # A tool result is a batch member; so is a system message interleaved in
  # the block (ADR 0019: the validator's system clause passes batch state
  # through). Splitting the block AT one would synthesize a duplicate
  # answer for a call the file actually answers — and the rewritten
  # transcript would refuse its own next load.
  defp block_member?(%{"role" => "tool"}), do: true
  defp block_member?(%{"role" => "system"}), do: true
  defp block_member?(_other), do: false

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

  # The title rides along tolerantly (the pin precedent, #80): absent or not
  # a string it loads as nil — never a refusal.
  defp build_title(%{"title" => title}) when is_binary(title), do: title

  defp build_title(_decoded), do: nil

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

  # The context anchor rides along as diagnostics for a resumed estimate
  # (ADR 0022 §6); absent, or not a map of two non-negative integers, it
  # estimates from nothing — never a refusal, the `pin` precedent.
  defp build_context(%{"context" => %{"prompt_tokens" => prompt_tokens, "messages" => messages}})
       when is_integer(prompt_tokens) and prompt_tokens >= 0 and is_integer(messages) and
              messages >= 0 do
    %{prompt_tokens: prompt_tokens, messages: messages}
  end

  defp build_context(_decoded), do: nil

  # The eviction history is carried verbatim, string-keyed as decoded —
  # diagnostics, not conversation truth; only list-ness is checked.
  defp build_compactions(%{"compactions" => compactions}) when is_list(compactions),
    do: compactions

  defp build_compactions(_decoded), do: []
end
