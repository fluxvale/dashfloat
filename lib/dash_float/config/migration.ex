defmodule DashFloat.Config.Migration do
  @moduledoc """
  One-time migration from the legacy single `config.json` to the single-file
  profile layout ([ADR 0008](../decisions/0008-config-layout-profiles-json5.md)).

  Runs as the first step of every `DashFloat.Config.load/2,3`. Migrates only
  when a non-empty `settings.json5` is absent and the legacy file exists; a
  non-empty `settings.json5` is the migration marker, which makes re-runs
  no-ops. The new file is written to a private temp path and renamed into
  place, so a crash can never leave a torn or half-written marker. The legacy
  file is renamed to a backup, never deleted; every secrets-bearing file is
  tightened to 0600 — the legacy file, the backup it becomes, and a
  pre-existing backup as well (never clobbered, but it may hold an older
  credential). Malformed or incomplete legacy input fails with field names
  only — nothing is written, no value is ever echoed.
  """

  require Logger

  @legacy_file "config.json"
  @backup_file "config.json.bak"
  @main_file "settings.json5"
  @tmp_suffix ".tmp"
  @default_profile "default"
  @main_version 1
  @secret_mode 0o600

  @doc """
  `{:ok, :migrated}` after a migration, `{:ok, :not_needed}` when there is
  nothing to do, `{:error, message}` when the legacy file is unusable or the
  new one cannot be written.
  """
  @spec maybe_migrate(Path.t()) :: {:ok, :migrated | :not_needed} | {:error, String.t()}
  def maybe_migrate(dir) do
    main = Path.join(dir, @main_file)
    legacy = Path.join(dir, @legacy_file)

    # An EMPTY settings.json5 is not a marker: it can only be crash debris
    # (writes are tmp+rename atomic) or an empty user file — neither carries
    # data, so migration proceeds over it.
    if marker?(main) or not File.exists?(legacy) do
      {:ok, :not_needed}
    else
      migrate(dir, legacy, main)
    end
  end

  defp marker?(main) do
    case File.stat(main) do
      {:ok, %File.Stat{size: size}} when size > 0 -> true
      _other -> false
    end
  end

  defp migrate(_dir, legacy, main) do
    with {:ok, map} <- read_legacy(legacy),
         {:ok, fields} <- legacy_fields(legacy, map),
         {:ok, contents} <- render_main(fields),
         :ok <- write_main(main, contents) do
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

  # Written tmp-then-rename (atomic on POSIX): no crash can leave a torn or
  # zero-byte marker. The tmp file is created empty under 0600 before any
  # content lands in it (ADR 0008 security posture).
  defp write_main(path, contents) do
    tmp = path <> @tmp_suffix

    with :ok <- File.touch(tmp),
         :ok <- File.chmod(tmp, @secret_mode),
         :ok <- File.write(tmp, contents <> "\n"),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} when is_atom(reason) ->
        File.rm(tmp)
        {:error, "cannot write #{path}: #{:file.format_error(reason)}"}
    end
  end

  # The one place DashFloat WRITES json5: a fixed document shape rendered by
  # hand with octofriend-style quoting. Values are single-quoted, or
  # double-quoted when they contain a single quote; the Combine decoder
  # cannot process escapes (hostile-review P1: the json5 encoder corrupts
  # quote-containing values), so a value holding a backslash or BOTH quote
  # kinds is unrepresentable — the migration fails naming the field instead
  # of writing a file that cannot be read back.
  defp render_main(fields) do
    with {:ok, name} <- field_value("name", @default_profile),
         {:ok, base_url} <- field_value("base_url", fields.base_url),
         {:ok, api_key} <- field_value("api_key", fields.api_key),
         {:ok, model} <- field_value("model", fields.model) do
      context =
        case fields.context_tokens do
          nil -> ""
          tokens -> ",\n            context: #{tokens}"
        end

      contents = """
      {
        configVersion: #{@main_version},
        profiles: [
          {
            name: #{name},
            baseUrl: #{base_url},
            apiKey: #{api_key},
            models: [
              {
                nickname: #{model},
                model: #{model}#{context},
              },
            ],
          },
        ],
      }
      """

      {:ok, contents}
    else
      {:unrepresentable, field} ->
        {:error,
         "legacy config.json: #{field} contains characters the settings.json5 dialect cannot " <>
           "represent (a backslash or both quote kinds) — migrate it by hand"}
    end
  end

  defp field_value(field, value) do
    case quote_value(value) do
      {:ok, _quoted} = ok -> ok
      {:error, :unrepresentable} -> {:unrepresentable, field}
    end
  end

  defp quote_value(value) do
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

  # The rename is last: until it happens, a crash leaves the new layout
  # partial and the legacy file intact, so a re-run converges. An existing
  # backup is never clobbered — the legacy file then simply stays (inert
  # once settings.json5 exists). Either way every secrets-bearing file is
  # tightened to 0600: the legacy file (before the rename, so whichever
  # name the credential ends up under is already private), the backup it
  # becomes, and a pre-existing backup too — it plausibly holds an older
  # credential, and secrets are 0600 wherever they live (ADR 0008).
  defp backup_legacy(legacy) do
    backup =
      legacy
      |> Path.dirname()
      |> Path.join(@backup_file)

    tighten(legacy)

    if File.exists?(backup) do
      tighten(backup)
      Logger.warning("#{backup} already exists — leaving the legacy config in place")
    else
      case File.rename(legacy, backup) do
        :ok ->
          tighten(backup)

        {:error, _reason} ->
          Logger.warning("cannot back up the legacy config — leaving it in place")
      end
    end
  end

  # Best effort, failures ignored: the file is inert after migration, this
  # only keeps its secret private. lstat, not stat: chmod must never follow
  # a symlink out of the config directory onto a file the loader does not
  # own (ADR 0008's rule, applied here too — review probe).
  defp tighten(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} ->
        Logger.warning("#{path} is a symlink — not tightening permissions")

      {:ok, %File.Stat{}} ->
        File.chmod(path, @secret_mode)

      _missing ->
        :ok
    end
  end

  @doc """
  Best-effort 0600 repair of a leftover legacy backup on the LOAD path
  (ADR 0008 posture, issue #28): beside an existing `settings.json5` a
  `config.json.bak` is inert to the loader but still holds a credential —
  an already-migrated directory never runs the migration that would have
  tightened it. Symlinks are skipped, never chmod'd through.
  """
  @spec repair_backup(Path.t()) :: :ok
  def repair_backup(dir) do
    backup = Path.join(dir, @backup_file)

    case File.lstat(backup) do
      {:ok, %File.Stat{type: :symlink}} ->
        Logger.warning("#{@backup_file} is a symlink — not repairing permissions")

      {:ok, %File.Stat{mode: mode}} ->
        if Bitwise.band(mode, 0o077) != 0 do
          Logger.warning("#{@backup_file} is too permissive — repairing to 0600")
          File.chmod(backup, @secret_mode)
        end

      _missing ->
        :ok
    end

    :ok
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim_trailing(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_other), do: nil

  # v1 accepted a decimal STRING in context_tokens (its loader parsed both
  # shapes); the migration accepts what v1 accepted, so the context window
  # survives the boundary instead of silently disappearing.
  defp positive_int(raw) when is_binary(raw) do
    trimmed = String.trim(raw)

    case Integer.parse(trimmed) do
      {n, ""} when n in 1..1_000_000_000_000 -> n
      _other -> nil
    end
  end

  defp positive_int(raw) when is_integer(raw) and raw in 1..1_000_000_000_000, do: raw
  defp positive_int(_other), do: nil

  defp names(fields), do: Enum.map_join(fields, ", ", fn {field, _v} -> Atom.to_string(field) end)
end
