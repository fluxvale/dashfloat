defmodule DashFloat.Config.Migration do
  @moduledoc """
  One-time migrations to the split, endpoint-keyed credential layout
  ([ADR 0008](../decisions/0008-config-layout-profiles-json5.md) and its
  keys-split amendment; [ADR 0009](../decisions/0009-config-v3-persona-profiles.md)
  for the v3 step): `settings.json5` carries no credential material and API
  keys live in `keys.json5`, nested per profile and keyed by provider
  `baseUrl`.

  Runs as the first step of every `DashFloat.Config.load/2,3`, three chained
  paths:

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
    * **v3 reshape** — a `settings.json5` older than `configVersion` 3
      becomes the persona layout: each profile's `baseUrl`+`models` move into
      `providers[0]`, `keys[profile]` becomes `keys[profile][baseUrl]`, and
      `defaultProfile` is set to the first profile (preserving v2's effective
      default). Refuses loudly — with remedies, nothing written — on the
      shapes it cannot move unambiguously (ADR 0009's catalog).

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
  @keys_backup "keys.json5.bak"
  @default_profile "default"
  # The split marker: this and later versions carry no inline credentials.
  @main_version 2
  # The persona-profiles marker (ADR 0009): providers live inside profiles
  # and keys.json5 is endpoint-keyed (nested per provider baseUrl).
  @v3_version 3

  @doc """
  `{:ok, :migrated}` after a migration, `{:ok, :not_needed}` when there is
  nothing to do, `{:error, message}` when the source is unusable or a target
  cannot be written. The three paths chain in order: legacy → split → v3
  reshape, so a v1 directory reaches v3 in one load.
  """
  @spec maybe_migrate(Path.t()) :: {:ok, :migrated | :not_needed} | {:error, String.t()}
  def maybe_migrate(dir) do
    main = Path.join(dir, @main_file)

    # An EMPTY settings.json5 is not a marker: it can only be crash debris
    # (writes are tmp+rename atomic) or an empty user file — neither carries
    # data, so the legacy migration proceeds over it (and load treats it as
    # no config, ADR 0009's tolerance principle).
    if marker?(main) do
      chain(split_inline(dir, main), fn -> reshape_v3(main) end)
    else
      legacy_branch(dir, main)
    end
  end

  defp legacy_branch(dir, main) do
    legacy = Path.join(dir, @legacy_file)

    if File.exists?(legacy) do
      chain(migrate_legacy(dir, legacy, main), fn -> reshape_v3(main) end)
    else
      reshape_v3(main)
    end
  end

  # The chain composes outcomes: an error stops the chain and surfaces
  # verbatim (refusals keep their no-write guarantee); a `:migrated` from
  # EITHER step reports as migrated — a later step standing down must not
  # mask that a migration actually happened (idempotence tests depend on
  # distinguishing the first run from re-runs).
  defp chain({:error, _reason} = error, _next), do: error

  defp chain({:ok, first}, next) do
    case next.() do
      {:ok, :migrated} -> {:ok, :migrated}
      {:ok, :not_needed} -> {:ok, first}
      {:error, _reason} = error -> error
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
    cond do
      not split_pending?(map) ->
        {:ok, :not_needed}

      # P1-1 (hostile review), the split-side arm: de_secret/collect_keys
      # read through profiles_list/1 too — a not-a-list `profiles` beside a
      # root-level key would have the SPLIT write `profiles: []` over the
      # file (same gutting as the reshape's, one stage earlier). Unshapeable
      # input refuses before any write, byte-unchanged.
      unshapeable?(map) ->
        {:error, unshapeable_message(main)}

      regular?(main, @main_file) and regular?(keys_path, @keys_file) ->
        do_split(dir, main, keys_path, map, raw)

      true ->
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
    # with the whole directory untouched.
    with {:ok, existing} <- read_existing_keys(keys_path),
         {:ok, main_doc} <- render_doc(@main_file, de_secreted, "split it"),
         {:ok, keys_doc} <- render_collected_keys(collected) do
      # The backup is written (or provably already on disk) BEFORE the
      # no-loss decision, and its ACTUAL outcome feeds the decision — a
      # best-effort write that silently failed is exactly the loss window
      # the first fix round missed. The backup itself is never destructive
      # (it only adds a file); the destructive step — the settings rewrite —
      # happens only after the decision passes.
      backup_state = backup_main(dir, raw)

      case ensure_no_loss(map, collected, existing, backup_state) do
        :ok ->
          finalize_split(dir, main, keys_path, keys_doc, existing, main_doc, backup_state)

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp finalize_split(dir, main, keys_path, keys_doc, existing, main_doc, backup_state) do
    warn_existing_keys(existing, backup_state)

    # Leftover backups tighten like the rider does: an old config.json.bak
    # plausibly holds a credential (issue #28), and the split is the one
    # moment this directory's credentials move.
    repair_backup(dir)

    # The credential must reach its new home before the old one is emptied:
    # a failed keys write aborts before the settings rewrite.
    with :ok <- write_keys(keys_path, keys_doc, existing),
         :ok <- write_private(main, main_doc <> "\n") do
      {:ok, :migrated}
    end
  end

  # THE INVARIANT: every inline credential VALUE the split removes must land
  # in at least one file on disk — a keys.json5 slot holding exactly that
  # value, or the byte-exact backup — or the split refuses with no
  # destructive step taken. Decided from the backup's actual outcome, never
  # from a prediction; pinned cell-by-cell by the table-driven sweep test.
  defp ensure_no_loss(map, collected, existing, backup_state) do
    preserved? = backup_state in [:written, :identical]

    if preserved? or at_risk_values(map, collected, existing) == [] do
      :ok
    else
      {:error,
       "cannot split #{@main_file}: an inline credential would have no home — " <>
         "#{@main_backup} is never clobbered and a pre-existing #{@keys_file} wins; " <>
         "add the keys to #{@keys_file}, or move a stale #{@main_backup} aside so a fresh " <>
         "backup can be written, or split it by hand"}
    end
  end

  # Values this split cannot home in keys.json5:
  #   * collected entries whose name in a pre-existing keys.json5 carries a
  #     different value — the pre-existing file wins and is never rewritten;
  #   * duplicate-name losers that differ from the first-wins value —
  #     keys.json5 is keyed by NAME, so only the first definition's value
  #     can live there (the loader tolerates duplicates, so the migration
  #     must account for every one);
  #   * credentials with no usable profile name at all (root-level apiKey,
  #     blank-name profile).
  # A value already present in the pre-existing keys.json5 (under its name,
  # or anywhere for the nameless ones) is NOT at risk. Blank values are not
  # credentials.
  defp at_risk_values(map, collected, existing) do
    existing_values = if existing, do: Map.values(existing), else: []

    named_risk =
      if existing do
        for {name, key} <- collected, blank_to_nil(existing[name]) != key, do: key
      else
        []
      end

    at_risk = duplicate_orphan_values(map) ++ unnameable_values(map)
    unnamed_risk = Enum.reject(at_risk, &(&1 in existing_values))
    Enum.uniq(named_risk ++ unnamed_risk)
  end

  # Second-and-later duplicate-name keys that differ from the first-wins
  # value (first-wins matches collect_keys and the loader's duplicate rule).
  defp duplicate_orphan_values(map) do
    map
    |> profiles_list()
    |> Enum.flat_map(&name_key_pair/1)
    |> Enum.group_by(fn {name, _key} -> name end, fn {_name, key} -> key end)
    |> Enum.flat_map(fn {_name, [winner | losers]} ->
      Enum.filter(losers, &(&1 != winner))
    end)
  end

  defp name_key_pair(%{"name" => name, "apiKey" => key} = entry)
       when is_map(entry),
       do:
         if(usable?(name) and usable?(key),
           do: [{blank_to_nil(name), blank_to_nil(key)}],
           else: []
         )

  defp name_key_pair(_entry), do: []

  defp unnameable_values(map) do
    root = if usable?(map["apiKey"]), do: [blank_to_nil(map["apiKey"])], else: []
    profiles = profiles_list(map)

    nameless =
      Enum.flat_map(profiles, fn
        %{"apiKey" => key} = entry ->
          if usable?(key) and not usable?(entry["name"]), do: [blank_to_nil(key)], else: []

        _entry ->
          []
      end)

    root ++ nameless
  end

  defp usable?(value), do: blank_to_nil(value) != nil

  # A pre-existing keys.json5 WINS over collected inline keys — it is the
  # user's explicit new home; ensure_no_loss refuses the states where that
  # would actually drop a value, and the unblock is real: adding the key
  # under its name clears the refusal (name present ⇒ no value at risk). A
  # malformed one is an error: never destroy unreadable data. No warning
  # here — warn_existing_keys speaks once the backup outcome is known, so
  # every claim is about something that already happened.
  defp read_existing_keys(keys_path) do
    if File.exists?(keys_path) do
      JSON5.read_map(keys_path)
    else
      {:ok, nil}
    end
  end

  # Outcome-truthful messaging for a pre-existing keys.json5: the "backed up
  # first" clause may only ever follow an actual backup write.
  defp warn_existing_keys(nil, _backup_state), do: :ok

  defp warn_existing_keys(_existing, :written) do
    Logger.warning(
      "#{@keys_file} already exists — keeping it; the current #{@main_file} is backed up first"
    )
  end

  defp warn_existing_keys(_existing, :identical) do
    Logger.warning(
      "#{@keys_file} already exists — keeping it; #{@main_backup} already holds the current #{@main_file}"
    )
  end

  defp warn_existing_keys(_existing, _no_backup) do
    Logger.warning("#{@keys_file} already exists — keeping it")
  end

  # No collected keys (every inline value was blank/unusable) → no keys file;
  # an existing keys.json5 is never rewritten (it wins over collected keys).
  defp render_collected_keys(collected) when map_size(collected) == 0, do: {:ok, nil}
  defp render_collected_keys(collected), do: render_doc(@keys_file, collected, "split it")

  defp write_keys(_keys_path, _doc, existing) when existing != nil, do: :ok
  defp write_keys(_keys_path, nil, nil), do: :ok
  defp write_keys(keys_path, doc, nil), do: write_private(keys_path, doc <> "\n")

  # Returns the backup's ACTUAL outcome — the no-loss decision is made from
  # this, never from a prediction:
  #
  #   :written    fresh byte-exact backup written now (every value preserved)
  #   :identical  a pre-existing .bak already holds this exact file — the
  #               crash-recovery state between our backup write and the
  #               settings rewrite; every value is already on disk, so the
  #               split converges instead of refusing
  #   :kept       a pre-existing .bak differs from the current file — or is
  #               a symlink/non-regular file (delta-2 P2: reading through a
  #               self-referential link would "prove" the values preserved
  #               while the rewrite empties the only real copy) — kept
  #               (never clobbered); it preserves nothing from THIS file
  #   :failed     the write failed (best effort); the decision below refuses
  #               unless every at-risk value is homed in keys.json5
  defp backup_main(dir, raw) do
    backup = Path.join(dir, @main_backup)

    cond do
      kept_dangling_link?(backup) ->
        :kept

      not File.exists?(backup) ->
        case write_private(backup, raw) do
          :ok ->
            :written

          {:error, _reason} ->
            Logger.warning("cannot write #{@main_backup} — splitting without a backup")
            :failed
        end

      not regular_file?(backup) ->
        # lstat, not the read: File.read FOLLOWS the link, and a symlink to
        # the settings file itself would otherwise masquerade as a real
        # byte-exact backup while the rewrite empties the only real copy
        # (delta-2 P2). A non-regular .bak is KEPT — never clobbered, never
        # chmod'd, never read through — and feeds the loss decision as a
        # backup that preserves nothing from this file.
        Logger.warning("#{@main_backup} is not a regular file — keeping it; not read through")

        :kept

      true ->
        Posture.tighten(backup, @main_backup)

        case File.read(backup) do
          {:ok, contents} when contents == raw ->
            :identical

          _other ->
            Logger.warning(
              "#{@main_backup} already exists — keeping it; no new backup is written"
            )

            :kept
        end
    end
  end

  defp regular_file?(path) do
    match?({:ok, %File.Stat{type: :regular}}, File.lstat(path))
  end

  # P2-4 (hostile review, issue #33's class with a live consequence): a
  # DANGLING .bak symlink answers File.exists? == false, so the
  # not-regular-file guard is never reached and the write replaces the
  # user's link with a regular file — silently, against the docs' "never
  # replaced". lstat sees the link itself: dangling or not, a .bak symlink
  # is KEPT with a warning and counts as no backup for the loss decision.
  defp kept_dangling_link?(path) do
    if not File.exists?(path) and match?({:ok, %File.Stat{type: :symlink}}, File.lstat(path)) do
      warn_kept_link(path)
      true
    else
      false
    end
  end

  defp warn_kept_link(path) do
    Logger.warning(
      "#{Path.basename(path)} is a symlink (dangling or not) — keeping it, never replacing it"
    )
  end

  ## v3 reshape (v2 profiles → one-provider profiles, endpoint-keyed keys)

  # Settings v2 (or v1-without-inline-keys) → v3 (ADR 0009): each profile's
  # baseUrl+models move into providers[0], keys[profile] → keys[profile]
  # [baseUrl]. Writes order settings-FIRST: a crash after the settings write
  # leaves keys.json5 flat and intact — the exact state finish_partial/1
  # converges on the next load. A dead keys.json5 entry is dropped only when
  # the keys backup provably holds it (decision from the backup's actual
  # outcome, #31 rule); movable values land by construction.
  #
  # A non-regular settings.json5 or keys.json5 is left ENTIRELY by hand —
  # tmp+rename would sever a symlink or clobber the file's semantics, the
  # split's own rule (the completion path below warns instead of reading
  # through a non-regular keys file).
  defp reshape_v3(main) do
    dir = Path.dirname(main)

    if marker?(main) and regular?(main, @main_file) and
         regular?(Path.join(dir, @keys_file), @keys_file) do
      # Total match: the split arm (which ran first, same file) already
      # decoded these bytes successfully or errored before us — a failure
      # here is not a reachable state.
      {:ok, map} = JSON5.read_map(main)
      maybe_reshape(main, map)
    else
      {:ok, :not_needed}
    end
  end

  defp maybe_reshape(main, map) do
    cond do
      version?(map, @v3_version) -> finish_partial(main, map)
      v3_or_newer?(map) -> {:ok, :not_needed}
      unshapeable?(map) -> {:error, unshapeable_message(main)}
      v3_tripwire?(map) -> {:error, tripwire_message(main)}
      true -> full_reshape(main, map)
    end
  end

  # P1-1 (hostile review): a `profiles` field that is not a list — or a list
  # holding non-object entries, or a profile-level `providers`/`mcp` that is
  # not a list — is UNSHAPEABLE: `profiles_list/1` would read it as empty
  # and the reshape would write `configVersion: 3, profiles: []` over the
  # file, deleting the provider/menu/MCP tree (and any inline keys inside
  # it) from every file on disk. Malformed tolerance is degradation at
  # LOAD; the migration's rule for what it cannot represent is REFUSAL,
  # byte-unchanged, with the field named (ADR 0009 refusal catalog).
  defp unshapeable?(map) do
    case map["profiles"] do
      nil ->
        false

      entries when is_list(entries) ->
        Enum.any?(entries, fn
          entry when is_map(entry) -> bad_list?(entry, "providers") or bad_list?(entry, "mcp")
          _not_an_object -> true
        end)

      _not_a_list ->
        true
    end
  end

  defp bad_list?(entry, key) do
    case entry[key] do
      nil -> false
      value when is_list(value) -> false
      _not_a_list -> true
    end
  end

  defp unshapeable_message(main) do
    "#{main}: the profiles field is not a shape the v3 migration can represent " <>
      "(profiles must be a list of objects, providers/mcp lists) — nothing was " <>
      "written; fix the file by hand (or set configVersion: 3 if it is already v3)"
  end

  defp version?(%{"configVersion" => version}, version) when is_integer(version), do: true
  defp version?(_map, _version), do: false

  defp v3_or_newer?(%{"configVersion" => version})
       when is_integer(version) and version >= @v3_version,
       do: true

  defp v3_or_newer?(_map), do: false

  # A v3-shaped document predating its marker would be silently gutted by the
  # reshape (its provider trees read as unknown keys) — refuse and say what
  # to set instead of guessing (ADR 0009 refusal catalog).
  defp v3_tripwire?(map) do
    # Non-map entries never reach the tripwire: unshapeable? refuses them
    # first (same file, earlier arm), so the filter is total here.
    profiles =
      map
      |> profiles_list()
      |> Enum.filter(&is_map/1)

    Map.has_key?(map, "defaultProfile") or
      Enum.any?(profiles, fn entry ->
        Map.has_key?(entry, "providers") or Map.has_key?(entry, "mcp")
      end)
  end

  defp tripwire_message(main) do
    "#{main} already has the v3 shape (providers, mcp, or defaultProfile) " <>
      "but no configVersion: 3 — set configVersion: 3 by hand and re-run"
  end

  # The crash-debris completion path: settings is v3 but keys.json5 may
  # still hold FLAT values (settings was written first; the process died
  # before the keys rewrite). A flat value under an existing profile with
  # exactly one provider baseUrl moves up; nested values are the finished
  # shape and stay; anything else warns and stays verbatim — no value is
  # dropped here, so no loss decision is needed.
  defp finish_partial(main, map) do
    keys_path = sibling(main, @keys_file)

    if File.exists?(keys_path) do
      complete_partial(keys_path, map)
    else
      {:ok, :not_needed}
    end
  end

  defp complete_partial(keys_path, map) do
    case JSON5.read_map(keys_path) do
      {:ok, keys} -> apply_partial_moves(keys_path, map, keys)
      {:error, _message} = error -> error
    end
  end

  defp apply_partial_moves(keys_path, map, keys) do
    {moves, warnings} = partial_moves(map, keys)

    if moves == [] do
      Enum.each(warnings, &Logger.warning/1)
      {:ok, :not_needed}
    else
      write_partial_moves(keys_path, keys, moves, warnings)
    end
  end

  defp write_partial_moves(keys_path, keys, moves, warnings) do
    merged = merge_partial_keys(keys, moves)

    with {:ok, doc} <- render_doc(@keys_file, merged, "move it") do
      write_completed_moves(keys_path, doc, moves, warnings)
    end
  end

  defp write_completed_moves(keys_path, doc, moves, warnings) do
    case write_private(keys_path, doc <> "\n") do
      :ok ->
        Enum.each(warnings, &Logger.warning/1)

        Logger.warning(
          "#{@keys_file}: completed an interrupted v3 migration — " <>
            "#{length(moves)} key(s) moved to their provider endpoints"
        )

        {:ok, :migrated}

      {:error, _message} = error ->
        error
    end
  end

  # Per profile NAME: a flat usable value moves when the named profile has
  # exactly one provider with a usable baseUrl (the only unambiguous join).
  # Nested values are the finished shape; non-string and blank values are
  # inert damage, not credentials — they warn and stay (ADR 0009's tolerance
  # principle).
  defp partial_moves(map, keys) do
    profiles = v3_named_profiles(map)

    Enum.flat_map_reduce(keys, [], fn {name, value}, warnings ->
      profile = profile_by_name(profiles, name)

      cond do
        is_map(value) ->
          {[], warnings}

        profile == nil ->
          {[],
           [bare_key_warning(name, "no profile is named \"#{name}\" — it is unused") | warnings]}

        not is_binary(value) or blank_to_nil(value) == nil ->
          {[],
           [
             ~s(#{@keys_file}: "#{name}" holds a bare non-string or blank value — it is unused)
             | warnings
           ]}

        length(profile.base_urls) != 1 ->
          {[],
           [
             ~s(#{@keys_file}: "#{name}" holds a bare key but profile "#{name}" has no single provider endpoint — nest it under the baseUrl by hand)
             | warnings
           ]}

        true ->
          {[{name, hd(profile.base_urls), blank_to_nil(value)}], warnings}
      end
    end)
  end

  defp bare_key_warning(name, reason),
    do: ~s(#{@keys_file}: "#{name}" holds a bare key but #{reason})

  defp merge_partial_keys(keys, moves) do
    # One flat value per name (duplicate keys last-win at decode), so each
    # move owns its name's nest outright.
    Enum.reduce(moves, keys, fn {name, base_url, value}, acc ->
      Map.put(acc, name, %{base_url => value})
    end)
  end

  defp full_reshape(main, map) do
    keys_path = sibling(main, @keys_file)

    with {:ok, keys} <- read_flat_keys(keys_path),
         {:ok, {new_map, moved, dead, junk}} <- plan_reshape(map, keys) do
      Enum.each(junk, &Logger.warning/1)

      keys_backup = backup_bytes(keys_path, @keys_backup)

      case ensure_no_v3_loss(dead, keys_backup) do
        :ok -> commit_reshape(main, keys_path, new_map, keys, moved, dead)
        {:error, _reason} = error -> error
      end
    end
  end

  defp commit_reshape(main, keys_path, new_map, keys, moved, dead) do
    _settings_backup = backup_bytes(main, @main_backup)

    with {:ok, settings_text} <- render_doc(@main_file, new_map, "reshape it"),
         :ok <- write_private(main, settings_text <> "\n"),
         :ok <- write_v3_keys(keys_path, keys, moved, dead) do
      repair_backup(Path.dirname(main))
      {:ok, :migrated}
    end
  end

  # The keys rewrite: nothing to do when no keys file existed; every other
  # state rewrites the nested shape (a moved map of zero entries renders as
  # `{}` — exactly the cleanup a blanks-only or dead-only file deserves).
  defp write_v3_keys(_keys_path, nil, _moved, _dead), do: :ok

  defp write_v3_keys(keys_path, _keys, moved, _dead) do
    with {:ok, doc} <- render_doc(@keys_file, moved, "reshape it") do
      write_private(keys_path, doc <> "\n")
    end
  end

  # Reads keys.json5 when present: every value must be a FLAT string (the v2
  # shape) — a nested map is already endpoint-keyed and refuses (the shape
  # ambiguity this migration must not guess through). `nil` when the file is
  # absent; an unparseable file is an error (never destroy unreadable data).
  defp read_flat_keys(keys_path) do
    if File.exists?(keys_path) do
      case JSON5.read_map(keys_path) do
        {:ok, keys} -> reject_endpoint_keyed(keys)
        {:error, _message} = error -> error
      end
    else
      {:ok, nil}
    end
  end

  defp reject_endpoint_keyed(keys) do
    if Enum.any?(keys, fn {_name, value} -> is_map(value) end) do
      {:error,
       "#{@keys_file} is already endpoint-keyed (per-provider URLs) but " <>
         "#{@main_file} predates v3 — set configVersion: 3 in #{@main_file} or fix #{@keys_file} by hand"}
    else
      {:ok, keys}
    end
  end

  # Validates the v2 directory against the refusal catalog and computes both
  # documents plus the inert-junk warnings. No write happens until this
  # returns ok (ADR 0009).
  defp plan_reshape(map, keys) do
    with :ok <- check_dup_names(map, keys),
         :ok <- check_joinable(map, keys),
         {:ok, new_map} <- reshape_map(map),
         {:ok, {moved, dead, junk}} <- split_keys(map, keys) do
      {:ok, {new_map, moved, dead, junk}}
    end
  end

  defp check_dup_names(map, keys) do
    names =
      map
      |> profiles_list()
      |> Enum.flat_map(&usable_name/1)

    dup = List.first(names -- Enum.uniq(names))

    if dup && is_map(keys) && usable?(keys[dup]) do
      {:error,
       ~s(#{@main_file}: duplicate profile "#{dup}" with a key in #{@keys_file} ) <>
         "— rename one by hand so the key can move to its provider endpoint, then re-run"}
    else
      :ok
    end
  end

  # A key without a baseUrl has no endpoint to nest under; models without a
  # baseUrl have no provider to live in (env-completed v2 endpoints cannot be
  # resolved by a file transform that never reads env).
  defp check_joinable(map, keys) do
    map
    |> named_profiles()
    |> Enum.find_value(:ok, fn profile ->
      cond do
        is_map(keys) and usable?(keys[profile.name]) and profile.base_url == nil ->
          {:error,
           ~s(#{@main_file}: profile "#{profile.name}" has a key but no baseUrl ) <>
             "— add the baseUrl so the key can move to keys[profile][baseUrl], or move the key by hand"}

        movable_models?(profile) and profile.base_url == nil ->
          {:error,
           ~s(#{@main_file}: profile "#{profile.name}" has models but no baseUrl ) <>
             "— add the baseUrl so the models can move into a provider, or reshape it by hand"}

        true ->
          nil
      end
    end)
  end

  defp movable_models?(%{models: models}), do: is_list(models) and models != []

  defp reshape_map(map) do
    profiles =
      map
      |> profiles_list()
      |> Enum.map(&reshape_profile/1)

    base = Map.merge(map, %{"configVersion" => @v3_version, "profiles" => profiles})

    case first_profile_name(profiles) do
      nil -> {:ok, base}
      name -> {:ok, Map.put(base, "defaultProfile", name)}
    end
  end

  # A named profile with a baseUrl becomes a one-provider profile; its
  # settings map and unknown extras ride verbatim. A profile without a
  # baseUrl keeps everything but gains no providers (it may still carry a
  # name and settings). Non-map entries pass through untouched.
  # Non-map entries cannot reach here (unshapeable? refuses them first);
  # there is deliberately NO fallback — a violation crashes loudly rather
  # than passing junk through, which is the bug class this guard ends.
  defp reshape_profile(entry) when is_map(entry) do
    case {value_of(entry["name"]), value_of(entry["baseUrl"])} do
      {name, base_url} when is_binary(name) and is_binary(base_url) ->
        provider = %{"baseUrl" => base_url, "models" => Map.get(entry, "models", [])}

        entry
        |> Map.drop(["baseUrl", "models"])
        |> Map.put("providers", [provider])

      _other ->
        entry
    end
  end

  defp first_profile_name([%{"name" => name} | _rest]) when is_binary(name), do: name
  defp first_profile_name([_other | rest]), do: first_profile_name(rest)
  defp first_profile_name([]), do: nil

  # keys[profile] = K → keys[profile][baseUrl] = K. Entries under names with
  # no movable profile are DEAD: kept out of the new document, they may only
  # drop when the backup holds them (ensure_no_v3_loss decides from the
  # backup's actual outcome). Non-string values are inert junk — warned and
  # dropped, never treated as credentials (ADR 0009 tolerance).
  defp split_keys(_map, nil), do: {:ok, {%{}, [], []}}

  defp split_keys(map, keys) do
    movable = movable_profiles(map)

    {moved_pairs, dead_pairs} =
      Enum.split_with(keys, fn {name, value} ->
        usable?(value) and profile_by_name(movable, name) != nil
      end)

    moved =
      Map.new(moved_pairs, fn {name, value} ->
        %{base_url: base_url} = profile_by_name(movable, name)
        {name, %{base_url => blank_to_nil(value)}}
      end)

    dead = for {name, value} <- dead_pairs, usable?(value), do: {name, blank_to_nil(value)}

    junk =
      for {name, value} <- dead_pairs,
          not is_binary(value),
          do: ~s(#{@keys_file}: "#{name}" holds a non-string value — dropping it as junk)

    {:ok, {moved, dead, junk}}
  end

  # THE INVARIANT (v3 arm): a dead keys.json5 value may only be dropped when
  # the keys backup provably holds it on disk — :written or :identical — the
  # same actual-outcome rule as the split's ensure_no_loss. Every movable
  # value lands in the new keys.json5 by construction (the refusal catalog
  # blocked everything that could not move).
  defp ensure_no_v3_loss([], _keys_backup), do: :ok

  defp ensure_no_v3_loss(_dead, keys_backup) when keys_backup in [:written, :identical], do: :ok

  defp ensure_no_v3_loss(_dead, _keys_backup) do
    {:error,
     "cannot reshape to v3: #{@keys_file} holds keys for profiles that no longer " <>
       "exist and #{@keys_backup} cannot be written — move a stale #{@keys_backup} aside " <>
       "so a fresh backup can hold them, or nest the keys by hand"}
  end

  # The named, addressable v2 profiles (first-wins on duplicate names,
  # matching the loader's rule and collect_keys).
  defp named_profiles(map) do
    # Non-map entries cannot reach here (unshapeable? refuses them before
    # the reshape runs), so the map filter is total — the old pass-through
    # arm was the junk-riding class the review closed.
    map
    |> profiles_list()
    |> Enum.filter(&is_map/1)
    |> Enum.flat_map(fn entry ->
      case value_of(entry["name"]) do
        nil -> []
        name -> [%{name: name, base_url: value_of(entry["baseUrl"]), models: entry["models"]}]
      end
    end)
    |> dedup_first_wins()
  end

  defp movable_profiles(map) do
    map
    |> named_profiles()
    |> Enum.reject(&(&1.base_url == nil))
  end

  defp dedup_first_wins(profiles) do
    {kept, _seen} =
      Enum.reduce(profiles, {[], MapSet.new()}, fn profile, {acc, seen} ->
        if MapSet.member?(seen, profile.name) do
          {acc, seen}
        else
          {[profile | acc], MapSet.put(seen, profile.name)}
        end
      end)

    Enum.reverse(kept)
  end

  defp profile_by_name(profiles, name),
    do: Enum.find(profiles, fn profile -> profile.name == name end)

  # finish_partial reads V3-shaped maps: names plus each profile's provider
  # baseUrls (usable ones, in order).
  defp v3_named_profiles(map) do
    map
    |> profiles_list()
    |> Enum.flat_map(fn
      entry when is_map(entry) ->
        case value_of(entry["name"]) do
          nil -> []
          name -> [%{name: name, base_urls: v3_base_urls(entry)}]
        end

      _entry ->
        []
    end)
    |> dedup_first_wins()
  end

  defp v3_base_urls(%{"providers" => providers}) when is_list(providers) do
    Enum.flat_map(providers, fn
      entry when is_map(entry) ->
        case value_of(entry["baseUrl"]) do
          nil -> []
          base_url -> [base_url]
        end

      _entry ->
        []
    end)
  end

  defp v3_base_urls(_entry), do: []

  defp usable_name(entry) when is_map(entry) do
    case value_of(entry["name"]) do
      nil -> []
      name -> [name]
    end
  end

  defp usable_name(_entry), do: []

  defp value_of(value), do: blank_to_nil(value)

  defp sibling(main, name) do
    main
    |> Path.dirname()
    |> Path.join(name)
  end

  # Byte-exact backup with the split's outcome vocabulary: :written /
  # :identical / :kept / :failed — never clobbered, never read through a
  # symlink (lstat first), 0600 whenever written, :absent when there is no
  # source file to back up. Callers guarantee a REGULAR, just-read file
  # (the reshape guards both before getting here), so the read is total.
  defp backup_bytes(path, label) do
    if File.exists?(path) do
      {:ok, raw} = File.read(path)
      place_backup(raw, sibling(path, label), label)
    else
      :absent
    end
  end

  defp place_backup(raw, backup, label) do
    cond do
      kept_dangling_link?(backup) ->
        :kept

      not File.exists?(backup) ->
        case write_private(backup, raw) do
          :ok ->
            :written

          {:error, _reason} ->
            Logger.warning("cannot write #{label} — migrating without a fresh backup")
            :failed
        end

      not regular_file?(backup) ->
        Logger.warning("#{label} is not a regular file — keeping it; not read through")
        :kept

      true ->
        Posture.tighten(backup, label)

        case File.read(backup) do
          {:ok, contents} when contents == raw ->
            :identical

          _other ->
            Logger.warning("#{label} already exists — keeping it; no new backup is written")
            :kept
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
           render_doc(
             @keys_file,
             %{@default_profile => %{fields.base_url => fields.api_key}},
             "migrate it"
           ),
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
      "configVersion" => @v3_version,
      "defaultProfile" => @default_profile,
      "profiles" => [
        %{
          "name" => @default_profile,
          "providers" => [%{"baseUrl" => fields.base_url, "models" => [entry]}]
        }
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

  # All writes go through Posture.write_private (atomic tmp-0600+rename,
  # lstat-guarded) — shared with the v3 reshape and the onboarding wizard
  # (ADR 0009). Contents are written EXACTLY as given — rendered documents
  # get their trailing newline from the caller; the split's backup copies the
  # raw bytes byte-exact.
  defp write_private(path, contents), do: Posture.write_private(path, contents)

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
  (ADR 0008 posture, issue #28; the v3 arm adds `keys.json5.bak` — ADR 0009):
  beside an existing `settings.json5`, a `config.json.bak`,
  `settings.json5.bak`, `keys.json5.bak`, an inert never-renamed
  `config.json` (the legacy migration's crash window, or a #23-era partial
  run), or the DOCUMENTED refusal-unblock sidecar `settings.json5.bak.old`
  (`mv settings.json5.bak settings.json5.bak.old` — delta-2 P3b: the remedy
  must not be able to strand a world-readable credential copy no path ever
  tightens) may still hold a credential — an already-migrated directory
  never runs the migration that would have tightened it. Only regular files
  are repaired; symlinks are never chmod'd through.
  """
  @spec repair_backup(Path.t()) :: :ok
  def repair_backup(dir) do
    legacy = Path.join(dir, @legacy_file)
    backup = Path.join(dir, @backup_file)
    settings_backup = Path.join(dir, @main_backup)
    keys_backup = Path.join(dir, @keys_backup)
    sidecar = Path.join(dir, @main_backup <> ".old")
    Posture.tighten(legacy, @legacy_file)
    Posture.tighten(backup, @backup_file)
    Posture.tighten(settings_backup, @main_backup)
    Posture.tighten(keys_backup, @keys_backup)
    Posture.tighten(sidecar, "#{@main_backup}.old")
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
  defp positive_int(_raw), do: nil

  defp names(fields), do: Enum.map_join(fields, ", ", fn {field, _v} -> Atom.to_string(field) end)
end
