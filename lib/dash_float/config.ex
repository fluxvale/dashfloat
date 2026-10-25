defmodule DashFloat.Config do
  @moduledoc """
  Provider configuration for the LLM streaming engine: one JSON5 file,
  profiles, and per-field env overrides
  ([ADR 0008](../decisions/0008-config-layout-profiles-json5.md)).

  Reads `~/.config/dashfloat/settings.json5` (`XDG_CONFIG_HOME` respected) —
  profiles with their endpoint, credential, optional open settings map, and
  model menu; the file contains secrets, so it is repaired to 0600 on load. A
  legacy `config.json` is migrated once, automatically, with a backup.

  The active profile is the `--profile` flag, else `DASHFLOAT_PROFILE`, else
  the first profile. The selected model is the `--model` flag's entry (by
  nickname, then id), else the profile's `settings.defaultModel`, else the
  first menu entry. Environment variables overlay per field — file < env,
  blank env = absent. Loading happens once in `DashFloat.Application` and
  rides into the TUI as a mount opt; the UI process performs no file I/O
  (ADR 0005's contract, unchanged). The status bar shows the selected entry's
  nickname and profile via `DashFloat.TUI.State.provider_label/1`.
  """

  alias DashFloat.Config.JSON5
  alias DashFloat.Config.Migration

  require Logger

  @fields [
    base_url: "DASHFLOAT_BASE_URL",
    model: "DASHFLOAT_MODEL",
    api_key: "DASHFLOAT_API_KEY"
  ]

  @context_var "DASHFLOAT_CONTEXT_TOKENS"
  @profile_var "DASHFLOAT_PROFILE"

  @main_file "settings.json5"
  @secret_mode 0o600
  @main_version 1
  # The one settings key selection reads today; everything else is tolerated
  # with a warning so future dimensions need no migration (ADR 0008).
  @known_settings ["defaultModel"]

  # The provider rides in the TUI state, and a UI crash logs that state: never
  # let the key into a log line (ADR 0005).
  @derive {Inspect, except: [:api_key]}
  defstruct [:base_url, :model, :api_key, :context_tokens, :nickname, :profile]

  @type t :: %__MODULE__{
          base_url: String.t(),
          model: String.t(),
          api_key: String.t(),
          context_tokens: pos_integer() | nil,
          nickname: String.t() | nil,
          profile: String.t() | nil
        }

  @doc """
  Loads the config from the default directory, the real environment, and CLI
  overrides parsed by `DashFloat.CLI.parse/1`.
  """
  @spec load(keyword()) :: {:ok, t()} | {:error, String.t()}
  def load(cli \\ []) do
    load(config_dir(), System.get_env(), cli)
  end

  @doc "The per-user config directory (`XDG_CONFIG_HOME` respected)."
  @spec config_dir() :: String.t()
  def config_dir do
    :filename.basedir(:user_config, "dashfloat")
  end

  @doc """
  Testable core: loads `settings.json5` in `dir` (missing file = empty),
  overlaid with `env` (a map of variable names to values) and `cli` (the
  `profile:`/`model:` keywords from `DashFloat.CLI.parse/1`; flag beats env,
  env beats file). Blank fields after the merge yield an error naming only
  the missing field names — values are never echoed. `context_tokens` is
  optional: env wins over the file, and anything that is not a positive
  integer is nil — never an error (ADR 0006).
  """
  @spec load(Path.t(), map(), keyword()) :: {:ok, t()} | {:error, String.t()}
  def load(dir, env, cli) when is_binary(dir) and is_map(env) and is_list(cli) do
    main_path = Path.join(dir, @main_file)

    # Repair runs BEFORE the parse: a hand-made file is most likely both
    # malformed and too permissive, and the security posture must not depend
    # on the file also being valid JSON5 (hostile-review finding). A
    # leftover legacy backup repairs too — an already-migrated directory
    # never runs the migration that would have tightened it (issue #28).
    with {:ok, _migration} <- Migration.maybe_migrate(dir),
         :ok <- repair_perms(main_path),
         :ok <- Migration.repair_backup(dir),
         {:ok, main} <- read_map(main_path) do
      check_version(main)

      main
      |> parse_profiles()
      |> select(env, cli)
    end
  end

  ## Selection (ADR 0008: profiles, menus, first-entry default)

  defp select(profiles, env, cli) do
    active = active_profile(profiles, env, cli)
    profile = Enum.find(profiles, fn parsed -> parsed.name == active end)
    warn_unknown_profile(active, profiles, env, cli)
    entry = select_entry(entry_menu(profile), profile_settings(profile), cli)

    build(effective(profile, entry, env), context(env, entry), entry && entry.nickname, active)
  end

  defp entry_menu(nil), do: []
  defp entry_menu(profile), do: profile.models

  defp profile_settings(nil), do: nil
  defp profile_settings(profile), do: profile.settings

  # Effective fields: the file's source (profile, selected entry) under
  # per-field env overrides (file < env, ADR 0008).
  defp effective(profile, entry, env) do
    %{
      base_url: env_value(env, @fields[:base_url]) || (profile && profile.base_url),
      model: env_value(env, @fields[:model]) || (entry && entry.model),
      api_key: env_value(env, @fields[:api_key]) || (profile && profile.api_key)
    }
  end

  # Env wins over the file; a blank env var counts as absent (like every other
  # field), but a value present and unusable is simply nil (ADR 0006).
  defp context(env, entry) do
    case env_value(env, @context_var) do
      nil -> entry && positive_int(entry.context)
      raw -> positive_int(raw)
    end
  end

  defp build(values, context_tokens, nickname, profile) do
    case Enum.reject(@fields, fn {field, _var} -> value(values[field]) end) do
      [] ->
        config =
          struct!(
            __MODULE__,
            Map.new(values, fn {field, raw} -> {field, value(raw)} end)
          )

        {:ok,
         %{config | context_tokens: context_tokens, nickname: value(nickname), profile: profile}}

      missing ->
        {:error, "missing provider config: " <> field_names(missing)}
    end
  end

  ## Active profile and entry selection (flag > env > file)

  defp active_profile(profiles, env, cli) do
    case cli_value(cli, :profile) || env_value(env, @profile_var) do
      name when is_binary(name) -> name
      nil -> first_profile_name(profiles)
    end
  end

  defp first_profile_name([profile | _rest]), do: profile.name
  defp first_profile_name([]), do: nil

  # A flag/env profile that matches no definition warns and is used anyway —
  # the other env vars can still complete the config.
  defp warn_unknown_profile(active, profiles, env, cli) do
    chosen = cli_value(cli, :profile) || env_value(env, @profile_var)

    if is_binary(chosen) and chosen == active and
         not Enum.any?(profiles, fn profile -> profile.name == chosen end) do
      Logger.warning(
        "profile \"#{chosen}\" (flag or DASHFLOAT_PROFILE) matches no profile in #{@main_file}"
      )
    end
  end

  defp select_entry([], _settings, cli) do
    warn_dropped_model(cli)
    nil
  end

  defp select_entry(menu, settings, cli) do
    case cli_value(cli, :model) do
      nil ->
        default_entry(menu, settings)

      wanted ->
        # A --model miss falls back to the profile's own default
        # (defaultModel, then first entry) — a typo'd flag leaves the profile
        # on its default, the least surprising outcome.
        named_entry(menu, "--model", wanted, fn -> default_entry(menu, settings) end)
    end
  end

  # A discarded --model deserves a diagnostic, not a bare "model is missing".
  defp warn_dropped_model(cli) do
    case cli_value(cli, :model) do
      nil ->
        :ok

      wanted ->
        Logger.warning(~s(--model "#{wanted}" has no models to select from — ignored))
    end
  end

  defp default_entry(menu, settings) do
    case settings && default_model(settings) do
      nil -> hd(menu)
      wanted -> named_entry(menu, "defaultModel", wanted, fn -> hd(menu) end)
    end
  end

  # A present-but-unusable defaultModel (a number, a blank) warns: the key is
  # documented to be honored, and silently falling back hides the mistake.
  defp default_model(settings) do
    wanted = value(settings["defaultModel"])

    if is_nil(wanted) and Map.has_key?(settings, "defaultModel") do
      Logger.warning("defaultModel is not a usable nickname — using the first entry")
    end

    wanted
  end

  # Two passes — nickname first, then model id — so a collision (entry A's
  # id equals entry B's nickname) resolves to B: the nickname is the
  # user-facing address (ADR 0008).
  defp named_entry(menu, via, wanted, fallback) do
    by_nickname = Enum.find(menu, fn model -> model.nickname == wanted end)

    by_nickname || Enum.find(menu, fn model -> model.model == wanted end) ||
      miss(via, wanted, fallback)
  end

  defp miss(via, wanted, fallback) do
    Logger.warning(
      ~s(#{via} "#{wanted}" matches no model in this profile — using the profile default)
    )

    fallback.()
  end

  ## File schema

  defp parse_profiles(main) do
    case main["profiles"] do
      nil ->
        []

      entries when is_list(entries) ->
        entries
        |> Enum.map(&parse_profile/1)
        |> Enum.reject(&is_nil/1)
        |> drop_duplicate_names()

      _other ->
        Logger.warning("#{@main_file}: profiles must be a list — ignored")
        []
    end
  end

  # Profile names are the addressing vocabulary: a duplicate warns and the
  # later definition is dropped — the first block wins (ADR 0008).
  defp drop_duplicate_names(parsed) do
    {kept_reversed, _seen} =
      Enum.reduce(parsed, {[], MapSet.new()}, fn profile, {acc, seen} ->
        if MapSet.member?(seen, profile.name) do
          Logger.warning(
            ~s(#{@main_file}: duplicate profile "#{profile.name}" — keeping the first)
          )

          {acc, seen}
        else
          {[profile | acc], MapSet.put(seen, profile.name)}
        end
      end)

    Enum.reverse(kept_reversed)
  end

  defp parse_profile(entry) when is_map(entry) do
    case value(entry["name"]) do
      nil ->
        Logger.warning("#{@main_file}: a profile without a name is ignored")
        nil

      name ->
        %{
          name: name,
          base_url: value(entry["baseUrl"]),
          api_key: value(entry["apiKey"]),
          settings: parse_settings(name, entry["settings"]),
          models: parse_models(name, entry["models"])
        }
    end
  end

  defp parse_profile(_other) do
    Logger.warning("#{@main_file}: a profile entry that is not an object is ignored")
    nil
  end

  defp parse_settings(_name, nil), do: nil

  defp parse_settings(_name, settings) when is_map(settings) do
    warn_unknown_settings(settings)
    settings
  end

  defp parse_settings(name, _other) do
    Logger.warning(~s(#{@main_file}: profile "#{name}": settings must be an object — ignored))
    nil
  end

  defp warn_unknown_settings(settings) do
    case Map.keys(settings) -- @known_settings do
      [] ->
        :ok

      unknown ->
        Logger.warning(
          "#{@main_file}: unknown profile settings ignored: #{Enum.join(unknown, ", ")}"
        )
    end
  end

  defp parse_models(_name, nil), do: []

  defp parse_models(_name, entries) when is_list(entries) do
    entries
    |> Enum.map(&parse_model/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_models(name, _other) do
    Logger.warning(~s(#{@main_file}: profile "#{name}": models must be a list — ignored))
    []
  end

  # Extra keys (octofriend files carry modalities/reasoning/type) are
  # tolerated silently: forward compatibility by design (ADR 0008).
  defp parse_model(entry) when is_map(entry) do
    case value(entry["model"]) do
      nil ->
        Logger.warning("#{@main_file}: a models entry without a model id is ignored")
        nil

      model ->
        %{
          nickname: value(entry["nickname"]) || model,
          model: model,
          context: entry["context"]
        }
    end
  end

  defp parse_model(_other) do
    Logger.warning("#{@main_file}: a models entry that is not an object is ignored")
    nil
  end

  ## File reading and posture

  defp read_map(path) do
    case File.read(path) do
      {:ok, contents} ->
        stripped = strip_bom(contents)

        case JSON5.decode(stripped) do
          {:ok, map} when is_map(map) -> {:ok, map}
          {:ok, _other} -> {:error, "invalid JSON5 in #{path}: expected an object"}
          {:error, message} -> {:error, "#{message} in #{path}"}
        end

      {:error, :enoent} ->
        {:ok, %{}}

      {:error, reason} ->
        {:error, "cannot read #{path}: #{:file.format_error(reason)}"}
    end
  end

  # Several editors prepend a UTF-8 BOM on save; the parser rejects it with
  # an opaque error, and hand-editing is the primary workflow.
  defp strip_bom("\xEF\xBB\xBF" <> rest), do: rest
  defp strip_bom(contents), do: contents

  defp check_version(main) do
    case main["configVersion"] do
      version when is_integer(version) and version > @main_version ->
        Logger.warning(
          "#{@main_file} configVersion #{version} is newer than supported #{@main_version} — fields may be misread"
        )

      _other ->
        :ok
    end
  end

  # The file holds secrets (ADR 0008): it is created 0600 by migration;
  # repair a hand-made or tool-mangled one back to 0600 (best effort — a
  # repair failure warns, and load proceeds). lstat, not stat: chmod must
  # never follow a symlink out of the config directory onto a file the
  # loader does not own — a symlinked config warns and is loaded as-is.
  defp repair_perms(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} ->
        Logger.warning("#{@main_file} is a symlink — not repairing permissions")

      {:ok, %File.Stat{mode: mode}} ->
        tighten(path, mode)

      _missing ->
        :ok
    end
  end

  defp tighten(path, mode) do
    if Bitwise.band(mode, 0o077) != 0 do
      Logger.warning("#{@main_file} is too permissive — repairing to 0600")
      # Best effort; the result is ignored — repair never blocks a load, and
      # chmod by the file's owner fails only in exotic states.
      File.chmod(path, @secret_mode)
    else
      :ok
    end
  end

  ## Value coercion (v1 rules, unchanged)

  # Only a non-blank string is a usable value; everything else is missing.
  # Trailing whitespace is dropped (a pasted newline in a config file is a
  # common accident).
  defp value(v) when is_binary(v) do
    case String.trim_trailing(v) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp value(_other), do: nil

  defp env_value(env, var) do
    env
    |> Map.get(var)
    |> value()
  end

  defp cli_value(cli, key) do
    cli
    |> Keyword.get(key)
    |> value()
  end

  defp positive_int(raw) when is_binary(raw) do
    trimmed = String.trim(raw)

    case Integer.parse(trimmed) do
      {n, ""} when n in 1..1_000_000_000_000 -> n
      _other -> nil
    end
  end

  defp positive_int(raw) when is_integer(raw) and raw in 1..1_000_000_000_000, do: raw
  defp positive_int(_raw), do: nil

  defp field_names(fields),
    do: Enum.map_join(fields, ", ", fn {field, _var} -> Atom.to_string(field) end)
end
