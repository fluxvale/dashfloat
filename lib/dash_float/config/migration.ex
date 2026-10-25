defmodule DashFloat.Config.Migration do
  @moduledoc """
  One-time migrations to the split credential layout
  ([ADR 0008](../decisions/0008-config-layout-profiles-json5.md) and its
  keys-split amendment): `settings.json5` carries no credential material and
  API keys live in `keys.json5`, keyed by profile name.

  Runs as the first step of every `DashFloat.Config.load/2,3`, two paths:

    * **legacy** — no (non-empty) `settings.json5`, a legacy `config.json`
      exists: the legacy triple becomes the `default` profile (de-secreted)
      plus `keys.json5` (`%{'default': <key>}`); the legacy file is renamed to
      `config.json.bak`, never deleted.
    * **in-place split** — a `settings.json5` older than `configVersion` 2
      carries inline `apiKey` fields: the file is copied byte-exact to
      `settings.json5.bak` (0600 — a copy, not a rename, so a crash mid-split
      leaves the original in place to re-trigger), `keys.json5` is written
      from the collected keys, then the settings file is rewritten de-secreted
      at `configVersion` 2. A v1 file with no inline credential field is
      byte-untouched.

  A pre-existing `keys.json5` WINS over collected keys (it is the user's
  explicit new home; the old values survive in the backup); a malformed one
  is an error — never destroy unreadable data. Every file that ever held
  credentials is 0600 wherever it lives (backups inherit sensitivity).
  Malformed or incomplete legacy input fails with field names only — nothing
  is written, no value is ever echoed.
  """

  alias DashFloat.Config.JSON5
  alias DashFloat.Config.Posture

  require Logger

  @legacy_file "config.json"
  @backup_file "config.json.bak"
  @main_file "settings.json5"
  @main_backup "settings.json5.bak"
  @keys_file "keys.json5"
  @tmp_suffix ".tmp"
  @default_profile "default"
  # The split marker: this and later versions carry no inline credentials.
  @main_version 2
  @secret_mode 0o600

  @doc """
  `{:ok, :migrated}` after a migration, `{:ok, :not_needed}` when there is
  nothing to do, `{:error, message}` when the source is unusable or a target
  cannot be written.
  """
  @spec maybe_migrate(Path.t()) :: {:ok, :migrated | :not_needed} | {:error, String.t()}
  def maybe_migrate(dir) do
    main = Path.join(dir, @main_file)

    # An EMPTY settings.json5 is not a marker: it can only be crash debris
    # (writes are tmp+rename atomic) or an empty user file — neither carries
    # data, so the legacy migration proceeds over it.
    if marker?(main) do
      split_inline(dir, main)
    else
      legacy = Path.join(dir, @legacy_file)

      if File.exists?(legacy), do: migrate_legacy(dir, legacy, main), else: {:ok, :not_needed}
    end
  end

  defp marker?(main) do
    case File.stat(main) do
      {:ok, %File.Stat{size: size}} when size > 0 -> true
      _other -> false
    end
  end

  ## In-place split (v1 inline keys → keys.json5 + de-secreted settings)

  # One read, two truths: the backup copies the RAW bytes byte-exact, the
  # rewrite renders the decoded map.
  defp split_inline(dir, main) do
    keys_path = Path.join(dir, @keys_file)

    case read_and_decode(main) do
      {:error, _message} = error -> error
      {:ok, raw, map} -> maybe_split(dir, main, keys_path, map, raw)
    end
  end

  defp read_and_decode(main) do
    case File.read(main) do
      {:ok, raw} ->
        case JSON5.decode_map(raw, main) do
          {:ok, map} -> {:ok, raw, map}
          {:error, _message} = error -> error
        end

      {:error, reason} ->
        {:error, "cannot read #{main}: #{:file.format_error(reason)}"}
    end
  end

  defp maybe_split(dir, main, keys_path, map, raw) do
    if split_pending?(map) and regular?(main, @main_file) and regular?(keys_path, @keys_file) do
      do_split(dir, main, keys_path, map, raw)
    else
      {:ok, :not_needed}
    end
  end

  # The split fires only when the file predates the split layout AND carries
  # an inline credential — a profile-level apiKey on a NAMED profile, or a
  # ROOT-level apiKey (hostile review P1-2: nothing credential-shaped may
  # ride into live v2 settings unwarned). A credential-free file of any
  # version stays byte-untouched (rewriting it churns user formatting for
  # nothing); a v2+ file's stray credentials are the loader's warning, not
  # a rewrite.
  defp split_pending?(map) do
    profiles = profiles_list(map)

    not version_two_or_newer?(map) and
      (Map.has_key?(map, "apiKey") or Enum.any?(profiles, &inline_key?/1))
  end

  defp version_two_or_newer?(%{"configVersion" => version})
       when is_integer(version) and version >= @main_version,
       do: true

  defp version_two_or_newer?(_map), do: false

  defp profiles_list(%{"profiles" => entries}) when is_list(entries), do: entries
  defp profiles_list(_map), do: []

  defp inline_key?(entry) when is_map(entry) do
    is_binary(entry["name"]) and Map.has_key?(entry, "apiKey")
  end

  defp inline_key?(_entry), do: false

  # tmp+rename would SEVER a symlink (or clobber a non-regular file's
  # semantics), replacing it with a regular file the user never made — the
  # split is left by hand instead.
  defp regular?(path, label) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        true

      {:ok, %File.Stat{type: other}} ->
        Logger.warning(
          "#{label} is a #{other}, not a regular file — not splitting; split it by hand"
        )

        false

      _missing ->
        true
    end
  end

  defp do_split(dir, main, keys_path, map, raw) do
    de_secreted =
      map
      |> de_secret()
      |> Map.put("configVersion", @main_version)

    collected = collect_keys(map)

    # Renders are pure and run before any write: an unrepresentable value
    # anywhere in the document (including tolerated extras) fails the split
    # with the whole directory untouched. The no-loss guard runs before them
    # all — a credential is NEVER silently lost, in every combination of
    # pre-existing state (hostile review P1-1).
    with {:ok, existing} <- read_existing_keys(keys_path),
         :ok <- ensure_no_loss(dir, map, collected, existing),
         {:ok, main_doc} <- render_doc(@main_file, de_secreted, "split it"),
         {:ok, keys_doc} <- render_collected_keys(collected) do
      # Leftover backups tighten like the rider does: an old config.json.bak
      # in this directory plausibly holds a credential (issue #28), and the
      # split is the one moment this directory's credentials move.
      repair_backup(dir)
      backup_main(dir, raw)

      # The credential must reach its new home before the old one is
      # emptied: a failed keys write aborts before the settings rewrite.
      with :ok <- write_keys(keys_path, keys_doc, existing),
           :ok <- write_private(main, main_doc <> "\n") do
        {:ok, :migrated}
      end
    end
  end

  # Every inline credential the split removes needs one of two homes: a
  # keys.json5 slot holding exactly that value (written fresh, or a
  # pre-existing file that already carries it), or the byte-exact backup
  # this split writes. When settings.json5.bak already exists (never
  # clobbered) there is no fresh backup — so a pre-existing keys.json5 that
  # lacks a collected name or carries a DIFFERENT value for it, or a
  # credential with no usable profile name to key it by (blank-name profile,
  # root-level apiKey), would leave the value in NO file. REFUSE the split
  # loudly; the user reconciles keys.json5 or splits by hand. Identical
  # values (the crash-recovery state: a partial run already wrote keys and
  # the backup) lose nothing and converge. Never proceed silently.
  defp ensure_no_loss(dir, map, collected, existing) do
    backup = Path.join(dir, @main_backup)
    profiles = profiles_list(map)

    lost? =
      File.exists?(backup) and
        (uncollectable?(profiles, map) or
           (existing != nil and
              Enum.any?(collected, fn {name, key} -> blank_to_nil(existing[name]) != key end)))

    if lost?,
      do:
        {:error,
         "cannot split #{@main_file}: an inline credential would have no home — " <>
           "#{@main_backup} is never clobbered and a pre-existing #{@keys_file} wins; " <>
           "add the keys to #{@keys_file} or split it by hand"},
      else: :ok
  end

  # Credentials collect_keys cannot key by profile name: a root-level
  # apiKey, or a profile apiKey whose name is blank/unusable — both are
  # deleted by de_secret, so with no fresh backup they would vanish.
  defp uncollectable?(profiles, map) do
    root_key?(map) or
      Enum.any?(profiles, fn
        %{"apiKey" => value} = entry -> usable?(value) and not usable?(entry["name"])
        _entry -> false
      end)
  end

  defp root_key?(map), do: usable?(map["apiKey"])

  defp usable?(value), do: blank_to_nil(value) != nil

  # A pre-existing keys.json5 WINS over collected inline keys — it is the
  # user's explicit new home; ensure_no_loss refuses the states where that
  # would actually drop a value. A malformed one is an error: never destroy
  # unreadable data. (The regular? guard already kept non-regular files out
  # of here.) The warning claims only what is true in every reachable
  # state: the backup clause holds because a pre-existing .bak plus a
  # losing keys.json5 is refused before this proceeds.
  defp read_existing_keys(keys_path) do
    if File.exists?(keys_path) do
      case JSON5.read_map(keys_path) do
        {:ok, keys} ->
          dir = Path.dirname(keys_path)
          backup = Path.join(dir, @main_backup)

          Logger.warning(
            "#{@keys_file} already exists — keeping it" <>
              backup_clause(File.exists?(backup))
          )

          {:ok, keys}

        {:error, _message} = error ->
          error
      end
    else
      {:ok, nil}
    end
  end

  defp backup_clause(false), do: "; the current #{@main_file} is backed up first"
  defp backup_clause(true), do: ""

  # No collected keys (every inline value was blank/unusable) → no keys file;
  # an existing keys.json5 is never rewritten (it wins over collected keys).
  defp render_collected_keys(collected) when map_size(collected) == 0, do: {:ok, nil}
  defp render_collected_keys(collected), do: render_doc(@keys_file, collected, "split it")

  defp write_keys(_keys_path, _doc, existing) when existing != nil, do: :ok
  defp write_keys(_keys_path, nil, nil), do: :ok
  defp write_keys(keys_path, doc, nil), do: write_private(keys_path, doc <> "\n")

  # The credential always has its new home before the old one is emptied.
  # The existing-.bak warning claims only the fact (kept, no new backup) —
  # ensure_no_loss has already refused every state where a value would
  # actually be lost here.
  defp backup_main(dir, raw) do
    backup = Path.join(dir, @main_backup)

    if File.exists?(backup) do
      Posture.tighten(backup, @main_backup)
      Logger.warning("#{@main_backup} already exists — keeping it; no new backup is written")
    else
      # Best effort: a failed backup is a warning, not an error — the keys
      # still land in keys.json5 before the settings file is emptied.
      case write_private(backup, raw) do
        :ok ->
          :ok

        {:error, _reason} ->
          Logger.warning("cannot write #{@main_backup} — splitting without a backup")
      end
    end
  end

  ## Legacy migration (config.json → default profile + keys.json5)

  defp migrate_legacy(dir, legacy, main) do
    # Tighten the legacy file BEFORE anything is written: it holds the
    # credential NOW, and a crash between the settings write and the backup
    # rename would otherwise leave a world-readable config.json beside a
    # complete layout forever (re-runs see the marker and stand down) —
    # hostile review P2-1.
    Posture.tighten(legacy, legacy)

    with {:ok, map} <- read_legacy(legacy),
         {:ok, fields} <- legacy_fields(legacy, map),
         :ok <- representable(fields),
         {:ok, keys_doc} <-
           render_doc(@keys_file, %{@default_profile => fields.api_key}, "migrate it"),
         {:ok, main_doc} <- render_doc(@main_file, legacy_main(fields), "migrate it"),
         :ok <- write_keys_unless_present(Path.join(dir, @keys_file), keys_doc),
         :ok <- write_private(main, main_doc <> "\n") do
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

  defp legacy_main(fields) do
    model_entry = %{"nickname" => fields.model, "model" => fields.model}

    entry =
      case fields.context_tokens do
        nil -> model_entry
        tokens -> Map.put(model_entry, "context", tokens)
      end

    %{
      "configVersion" => @main_version,
      "profiles" => [
        %{"name" => @default_profile, "baseUrl" => fields.base_url, "models" => [entry]}
      ]
    }
  end

  # Up-front, by field name — better than a renderer path for a file whose
  # fields the user knows by these exact names.
  defp representable(fields) do
    fields
    |> Map.take([:base_url, :model, :api_key])
    |> Enum.find_value(:ok, fn {field, value} ->
      case JSON5.quote_value(value) do
        {:ok, _quoted} -> nil
        {:error, :unrepresentable} -> {:error, unrepresentable(field)}
      end
    end)
  end

  defp unrepresentable(field) do
    "legacy #{@legacy_file}: #{field} contains characters the JSON5 dialect cannot " <>
      "represent (a backslash or both quote kinds) — migrate it by hand"
  end

  defp render_doc(label, document, action) do
    case JSON5.render(document) do
      {:ok, contents} ->
        {:ok, contents}

      {:error, path} ->
        {:error,
         "#{label}: #{path} contains characters the JSON5 dialect cannot represent " <>
           "(a backslash or both quote kinds) — #{action} by hand"}
    end
  end

  # The same merge rule as the split: an existing keys.json5 wins (and a
  # non-regular one is left entirely alone — replacing it would sever or
  # clobber what the user made). A malformed one is an error: never destroy
  # unreadable data.
  defp write_keys_unless_present(keys_path, doc) do
    case File.lstat(keys_path) do
      {:ok, %File.Stat{type: :regular}} ->
        case JSON5.read_map(keys_path) do
          {:ok, _keys} ->
            Logger.warning(
              "#{@keys_file} already exists — keeping it; the legacy key is not migrated"
            )

            :ok

          {:error, _message} = error ->
            error
        end

      {:ok, %File.Stat{type: other}} ->
        Logger.warning("#{@keys_file} is a #{other}, not a regular file — leaving it alone")
        :ok

      _missing ->
        write_private(keys_path, doc <> "\n")
    end
  end

  ## Shared writers and posture

  # Written tmp-then-rename (atomic on POSIX): no crash can leave a torn or
  # half-written file. The tmp file is created empty under 0600 before any
  # content lands in it — so every file this module writes, including
  # backups of secrets-bearing files, is 0600 from its first byte. Contents
  # are written EXACTLY as given — rendered documents get their trailing
  # newline from the caller; the split's backup copies the raw bytes
  # byte-exact. The tmp path is lstat-guarded like the destination: a
  # pre-planted .tmp symlink would otherwise be chmod'd and written THROUGH,
  # clobbering whatever it points at (hostile review P2-2).
  defp write_private(path, contents) do
    tmp = path <> @tmp_suffix

    with :ok <- guard_tmp(path, tmp),
         :ok <- File.touch(tmp),
         :ok <- File.chmod(tmp, @secret_mode),
         :ok <- File.write(tmp, contents),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      # guard_tmp's message is already user-shaped; filesystem reasons are
      # wrapped. The tmp debris of a failed write is removed either way.
      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} when is_atom(reason) ->
        File.rm(tmp)
        {:error, "cannot write #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp guard_tmp(path, tmp) do
    case File.lstat(tmp) do
      {:ok, %File.Stat{type: :regular}} ->
        :ok

      {:ok, %File.Stat{type: other}} ->
        {:error, "cannot write #{path}: #{tmp} is a #{other}, not a regular file"}

      _missing ->
        :ok
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

    Posture.tighten(legacy, legacy)

    if File.exists?(backup) do
      Posture.tighten(backup, backup)
      Logger.warning("#{backup} already exists — leaving the legacy config in place")
    else
      case File.rename(legacy, backup) do
        :ok ->
          Posture.tighten(backup, backup)

        {:error, _reason} ->
          Logger.warning("cannot back up the legacy config — leaving it in place")
      end
    end
  end

  @doc """
  Best-effort 0600 repair of leftover secrets-bearing files on the LOAD path
  (ADR 0008 posture, issue #28): beside an existing `settings.json5`, a
  `config.json.bak`, `settings.json5.bak`, or an inert never-renamed
  `config.json` (the legacy migration's crash window, or a #23-era partial
  run) may still hold a credential — an already-migrated directory never
  runs the migration that would have tightened it. Only regular files are
  repaired; symlinks are never chmod'd through.
  """
  @spec repair_backup(Path.t()) :: :ok
  def repair_backup(dir) do
    legacy = Path.join(dir, @legacy_file)
    backup = Path.join(dir, @backup_file)
    settings_backup = Path.join(dir, @main_backup)
    Posture.tighten(legacy, @legacy_file)
    Posture.tighten(backup, @backup_file)
    Posture.tighten(settings_backup, @main_backup)
    :ok
  end

  ## Split helpers

  defp de_secret(map) do
    # split_pending? guarantees profiles is a non-empty list here; a
    # ROOT-level apiKey is stripped too — nothing credential-shaped may ride
    # into live v2 settings (hostile review P1-2), and ensure_no_loss
    # guarantees it is preserved or the split refuses.
    list = profiles_list(map)
    profiles = Enum.map(list, &drop_api_key/1)

    map
    |> Map.delete("apiKey")
    |> Map.put("profiles", profiles)
  end

  defp drop_api_key(entry) when is_map(entry), do: Map.delete(entry, "apiKey")
  defp drop_api_key(entry), do: entry

  # First definition wins, matching the loader's duplicate-name rule; a
  # profile without a usable name is ignored, matching profile parsing.
  defp collect_keys(map) do
    profiles = profiles_list(map)

    Enum.reduce(profiles, %{}, fn
      %{"name" => name, "apiKey" => raw}, keys ->
        case {blank_to_nil(name), blank_to_nil(raw)} do
          {n, k} when is_binary(n) and is_binary(k) -> Map.put_new(keys, n, k)
          _other -> keys
        end

      _entry, keys ->
        keys
    end)
  end

  ## Legacy coercion (v1 rules)

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
