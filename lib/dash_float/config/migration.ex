defmodule DashFloat.Config.Migration do
  @moduledoc """
  One-time migration from the legacy single `config.json` to the single-file
  profile layout ([ADR 0008](../decisions/0008-config-layout-profiles-json5.md)).

  Runs as the first step of every `DashFloat.Config.load/2,3`. Migrates only
  when `dashfloat.json5` is absent and the legacy file exists;
  `dashfloat.json5`'s existence is the migration marker, which makes re-runs
  no-ops. The legacy file is renamed to a backup, never deleted, and a
  pre-existing backup is never clobbered. Malformed or incomplete legacy
  input fails with field names only — nothing is written, no value is ever
  echoed.
  """

  alias DashFloat.Config.JSON5

  require Logger

  @legacy_file "config.json"
  @backup_file "config.json.bak"
  @main_file "dashfloat.json5"
  @default_profile "default"
  @main_version 1
  @secret_mode 0o600

  @doc """
  `{:ok, :migrated}` after a migration, `{:ok, :not_needed}` when there is
  nothing to do, `{:error, message}` when the legacy file is unusable.
  """
  @spec maybe_migrate(Path.t()) :: {:ok, :migrated | :not_needed} | {:error, String.t()}
  def maybe_migrate(dir) do
    main = Path.join(dir, @main_file)
    legacy = Path.join(dir, @legacy_file)

    if File.exists?(main) or not File.exists?(legacy) do
      {:ok, :not_needed}
    else
      migrate(dir, legacy, main)
    end
  end

  defp migrate(dir, legacy, main) do
    with {:ok, map} <- read_legacy(legacy),
         {:ok, fields} <- legacy_fields(legacy, map) do
      File.mkdir_p!(dir)
      write_main(main, fields)
      backup_legacy(legacy)
      {:ok, :migrated}
    end
  end

  defp read_legacy(legacy) do
    case File.read(legacy) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, map} when is_map(map) -> {:ok, map}
          {:ok, _other} -> {:error, "#{legacy}: expected a JSON object"}
          {:error, _decode_error} -> {:error, "#{legacy}: invalid JSON"}
        end

      {:error, reason} ->
        {:error, "cannot read #{legacy}: #{:file.format_error(reason)}"}
    end
  end

  # Names only in errors — a legacy file's values are secrets like any other.
  defp legacy_fields(legacy, map) do
    base_url = blank_to_nil(map["base_url"])
    model = blank_to_nil(map["model"])
    api_key = blank_to_nil(map["api_key"])

    case Enum.reject([base_url: base_url, model: model, api_key: api_key], fn {_f, v} -> v end) do
      [] ->
        {:ok,
         %{
           base_url: base_url,
           model: model,
           api_key: api_key,
           context_tokens: positive_int(map["context_tokens"])
         }}

      missing ->
        {:error, "#{legacy}: missing fields " <> names(missing)}
    end
  end

  defp write_main(path, fields) do
    base = %{nickname: fields.model, model: fields.model}
    entry = maybe_put(base, :context, fields.context_tokens)

    main = %{
      configVersion: @main_version,
      profiles: [
        %{
          name: @default_profile,
          baseUrl: fields.base_url,
          apiKey: fields.api_key,
          models: [entry]
        }
      ]
    }

    # Content must never land in a world-readable file: create it empty under
    # 0600 first, then write (ADR 0008 security posture).
    File.touch!(path)
    File.chmod!(path, @secret_mode)
    File.write!(path, JSON5.encode(main) <> "\n")
  end

  # The rename is last: until it happens, a crash leaves the new layout
  # partial and the legacy file intact, so a re-run converges. An existing
  # backup is never clobbered — the legacy file then simply stays (inert once
  # dashfloat.json5 exists).
  defp backup_legacy(legacy) do
    backup =
      legacy
      |> Path.dirname()
      |> Path.join(@backup_file)

    if File.exists?(backup) do
      Logger.warning("#{backup} already exists — leaving the legacy config in place")
    else
      case File.rename(legacy, backup) do
        :ok ->
          :ok

        {:error, _reason} ->
          Logger.warning("cannot back up the legacy config — leaving it in place")
      end
    end
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim_trailing(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_other), do: nil

  defp positive_int(raw) when is_integer(raw) and raw in 1..1_000_000_000_000, do: raw
  defp positive_int(_other), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp names(fields), do: Enum.map_join(fields, ", ", fn {field, _v} -> Atom.to_string(field) end)
end
