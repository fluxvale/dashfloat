defmodule DashFloat.Config do
  @moduledoc """
  Provider configuration for the LLM streaming engine: JSON5 files, persona
  profiles, and per-field env overrides
  ([ADR 0009](../decisions/0009-config-v3-persona-profiles.md)).

  Reads `~/.config/dashfloat/settings.json5` (`XDG_CONFIG_HOME` respected) —
  profiles are personas bundling several providers (each an endpoint with its
  own model menu) and their own MCP setup; `defaultProfile` names the
  startup default. The settings file is credential-free by construction:
  API keys live in a sibling `keys.json5`, nested per profile and keyed by
  the provider's `baseUrl` — a provider finds its key at
  `keys[profile][baseUrl]`; a value may instead be a `$ENV_VAR` reference
  resolved at load. `oauth.json5` is reserved for a future OAuth flow
  (absence-tolerant; 0600 when present, never read). settings.json5 stays
  0600 as free hardening. Legacy layouts (v1 `config.json`, v1 inline keys,
  v2 flat keys) migrate once, automatically, with 0600 backups under the
  no-loss invariant (backups inherit the source's sensitivity).

  Profile selection is deliberate (ADR 0009): the `--profile` flag, else
  `DASHFLOAT_PROFILE`, else `defaultProfile`; an explicit name matching no
  profile is a hard error listing the valid names; with no explicit name and
  no usable default, one profile auto-selects, two or more force a selection
  modal (`{:select, names}`), and zero profiles hand off to the onboarding
  wizard (`:onboard`) unless env vars complete the config. Within the active
  profile, the provider is `defaultProvider`, else the first; the selected
  model is the `--model` flag's entry (by nickname, then id), else the
  profile's `settings.defaultModel`, else the provider's first menu entry.
  Environment variables overlay per field — file < env, blank env = absent;
  the effective API key is `DASHFLOAT_API_KEY`, else `keys[profile]
  [baseUrl]` after `$REF` resolution. Loading happens once in
  `DashFloat.Application` and rides into the TUI as a mount opt; the UI
  process performs no file I/O (ADR 0005's contract, unchanged — the
  startup wizard/modal is the sanctioned exception, ADR 0009). The status
  footer names the provider and model via
  `DashFloat.TUI.State.provider_label/1` (ADR 0015 §2's amendment).

  Malformed config degrades to the least-surprising working state with a
  warning naming the field or profile — never a crash, never silent
  misbehavior (ADR 0009's tolerance principle). A file unparseable as JSON5
  is a loud error naming the path; it is never auto-overwritten.
  """

  alias DashFloat.Config.JSON5
  alias DashFloat.Config.Migration
  alias DashFloat.Config.Posture
  alias DashFloat.Config.Presets

  require Logger

  @fields [
    base_url: "DASHFLOAT_BASE_URL",
    model: "DASHFLOAT_MODEL",
    api_key: "DASHFLOAT_API_KEY"
  ]

  @context_var "DASHFLOAT_CONTEXT_TOKENS"
  @suggest_var "DASHFLOAT_SUGGEST"
  @auto_title_var "DASHFLOAT_AUTO_TITLE"
  @profile_var "DASHFLOAT_PROFILE"

  @main_file "settings.json5"
  @keys_file "keys.json5"
  @oauth_file "oauth.json5"
  @main_version 3
  # The settings keys selection reads today; everything else is tolerated
  # with a warning so future dimensions need no migration (ADR 0008).
  # "compaction" is known and deliberately inert — the stage-2 seam (ADR 0022 §8).
  @known_settings ["defaultModel", "suggest", "autoTitle", "compaction"]
  # keys.json5 values and mcp tokens may be env references instead of
  # literals — the strict shape is what disambiguates a literal key that
  # merely starts with `$` (ADR 0009).
  @env_ref ~r/\A\$[A-Z_][A-Z0-9_]*\z/

  # The provider rides in the TUI state, and a UI crash logs that state: never
  # let a key into a log line (ADR 0005) — including the per-provider keys.
  @derive {Inspect, except: [:api_key, :providers]}
  defstruct [
    :base_url,
    :model,
    :api_key,
    :context_tokens,
    # The ghost-text suggestion's model tri-state (ADR 0015 §3): `false`
    # opts out entirely, a string pins that exact model id, `nil` enables
    # with the provider's default cheap model.
    :suggest,
    # The auto-title side-request's model tri-state (#80), threaded exactly
    # like :suggest: `false` opts out, a string pins that id, `nil` enables
    # with the provider's default cheap model.
    :auto_title,
    :nickname,
    :profile,
    providers: [],
    # The active provider's settings-side model menu (ADR 0018 §1): each
    # parsed entry carries its own `images` flag, so the runtime /model
    # switch can resolve the picked id's capability — catalog ids default
    # to not capable.
    model_menu: [],
    # The selected entry's image-capability flag (ADR 0018 §1): a strict
    # boolean — true means the model accepts image attachments.
    images: false
  ]

  @type provider :: %{
          label: String.t(),
          base_url: String.t(),
          api_key: String.t() | nil
        }

  @type t :: %__MODULE__{
          base_url: String.t(),
          model: String.t(),
          api_key: String.t(),
          context_tokens: pos_integer() | nil,
          images: boolean(),
          suggest: false | String.t() | nil,
          auto_title: false | String.t() | nil,
          nickname: String.t() | nil,
          profile: String.t() | nil,
          providers: [provider()]
        }

  @typedoc """
  The load outcome: a resolved config, an error (never echoing values), the
  forced-selection modal state (no explicit choice, no usable default, two or
  more profiles), or the onboarding wizard (zero profiles and env cannot
  complete the config) — ADR 0009's classification.
  """
  @type classification ::
          {:ok, t()} | {:error, String.t()} | {:select, [String.t()]} | :onboard

  @doc """
  Loads the config from the default directory, the real environment, and CLI
  overrides parsed by `DashFloat.CLI.parse/1`.
  """
  @spec load(keyword()) :: classification()
  def load(cli \\ []) do
    load(config_dir(), System.get_env(), cli)
  end

  @doc "The per-user config directory (`XDG_CONFIG_HOME` respected)."
  @spec config_dir() :: String.t()
  def config_dir do
    :filename.basedir(:user_config, "dashfloat")
  end

  @doc """
  The context window and its source (issue #111, ADR 0022 §2 amendment):
  the explicit value (`context_tokens` — env or the entry's `context`)
  wins; else the standard presets' seeded window for this base URL + model
  id; else the documented 128 Ki default. Never nil on a resolved config —
  a `:default` result must be surfaced with the visible note (`~` footer
  marker, the note in `/compact`'s reply), never silently. The `/models`
  observed layer sits BETWEEN explicit and seed and lives in the TUI
  (`State.provider_context_tokens/1`), which is where the catalog lands.
  """
  @spec context_window(t()) :: {pos_integer(), :configured | :seeded | :default}
  def context_window(%__MODULE__{context_tokens: n}) when is_integer(n) and n > 0,
    do: {n, :configured}

  def context_window(%__MODULE__{base_url: base_url, model: model})
      when is_binary(base_url) and is_binary(model) do
    case Presets.context_window(base_url, model) do
      nil -> {Presets.default_window(), :default}
      seeded -> {seeded, :seeded}
    end
  end

  # A hand-built config with no usable base URL or model (test scaffolding,
  # the Accounting.trust precedent): nothing is knowable — the documented
  # default, visibly.
  def context_window(%__MODULE__{}), do: {Presets.default_window(), :default}

  ## Onboarding writes (ADR 0009: the startup wizard's sanctioned writers)

  # All writes ride the migration machinery's posture: atomic tmp-0600+
  # rename through DashFloat.Config.Posture, merges never clobber. The
  # directory is created on demand — a first run has no config dir yet.
  @doc """
  Merges one credential into `keys.json5` at `keys[profile][baseUrl]`,
  atomically at 0600 (ADR 0009 — the wizard writes each key IMMEDIATELY, so
  an aborted run resumes with its keys already homed). An existing
  unparseable keys.json5 refuses: never clobber what might hold keys. A
  `$ENV_VAR`-shaped `value` is stored verbatim as a reference.
  """
  @spec write_keys_entry(Path.t(), String.t(), String.t(), String.t()) ::
          :ok | {:error, String.t()}
  def write_keys_entry(dir, profile, base_url, value)
      when is_binary(dir) and is_binary(profile) and is_binary(base_url) and is_binary(value) do
    keys_path = Path.join(dir, @keys_file)

    with :ok <- ensure_dir(dir),
         {:ok, keys} <- JSON5.read_map(keys_path),
         {:ok, merged} <- nest_key(keys, profile, base_url, value),
         {:ok, doc} <- render_keys(merged, profile, base_url, value) do
      Posture.write_private(keys_path, doc <> "\n")
    end
  end

  # A string the JSON5 dialect cannot quote (a backslash, or both quote
  # kinds) refuses with the remedy in the message — never the value (issue
  # #39: the wizard surfaces this on screen). The strings the user JUST
  # entered (key value, profile name, endpoint) are checked up front, each
  # with its own refusal. Everything else in the merged document is
  # pre-existing text from the file on disk (backslash strings decode —
  # only escaped quotes fail decode — so it can hold a name or value the
  # render cannot re-emit), so a render failure past the up-front checks is
  # exactly that stored text, and its refusal blames the file, not fields
  # the user cannot fix (issue #42).
  defp render_keys(merged, profile, base_url, value) do
    with :ok <- quotable(value),
         :ok <- quotable_name(profile),
         :ok <- quotable_name(base_url),
         {:ok, doc} <- JSON5.render(merged) do
      {:ok, doc}
    else
      {:error, :unrepresentable} -> {:error, unquotable_key_message()}
      {:error, :name} -> {:error, unquotable_name_message()}
      {:error, _path} -> {:error, unquotable_stored_message()}
    end
  end

  defp quotable(value) do
    case JSON5.quote_value(value) do
      {:ok, _quoted} -> :ok
      {:error, :unrepresentable} -> {:error, :unrepresentable}
    end
  end

  defp quotable_name(name) do
    case quotable(name) do
      :ok -> :ok
      {:error, :unrepresentable} -> {:error, :name}
    end
  end

  defp render_with_remedy(document, message) do
    case JSON5.render(document) do
      {:ok, doc} -> {:ok, doc}
      {:error, _path} -> {:error, message}
    end
  end

  defp unquotable_key_message,
    do:
      "#{@keys_file} cannot store that key — it contains a backslash or " <>
        "both quote kinds; re-enter it without the character, or store a $ENV_VAR reference instead"

  defp unquotable_name_message,
    do:
      "#{@keys_file} cannot store the profile name or endpoint — one contains " <>
        "a backslash or both quote kinds; rename the profile or re-enter the URL"

  defp unquotable_stored_message,
    do:
      "#{@keys_file} already holds a name or value it cannot re-write — one " <>
        "contains a backslash or both quote kinds; fix or remove it by hand, then retry the key"

  defp unquotable_settings_message,
    do:
      "#{@main_file} cannot store that text — a profile name, label, URL, model " <>
        "id, nickname, or MCP field contains a backslash or both quote kinds; " <>
        "remove the character and run setup again"

  # A profile slot that is not an object is pre-v3 damage holding who-knows-
  # what — refuse rather than clobber it; nil and nested maps merge cleanly.
  defp nest_key(keys, profile, base_url, value) do
    case keys[profile] do
      nil ->
        {:ok, Map.put(keys, profile, %{base_url => value})}

      %{} = nested ->
        {:ok, Map.put(keys, profile, Map.put(nested, base_url, value))}

      _other ->
        {:error,
         ~s(#{@keys_file}: "#{profile}" holds a bare value instead of an object ) <>
           "— fix or remove it by hand, then re-enter the key"}
    end
  end

  @doc """
  Writes the wizard's settings document to `settings.json5`, atomically at
  0600 (ADR 0009 — settings land once, at done; keys landed per step).
  """
  @spec write_settings(Path.t(), map()) :: :ok | {:error, String.t()}
  def write_settings(dir, document) when is_binary(dir) and is_map(document) do
    main_path = Path.join(dir, @main_file)

    with :ok <- empty_or_absent(main_path),
         :ok <- ensure_dir(dir),
         {:ok, doc} <- render_with_remedy(document, unquotable_settings_message()) do
      Posture.write_private(main_path, doc <> "\n")
    end
  end

  # A NON-EMPTY settings.json5 already in place is never overwritten (P2-1,
  # hostile review — the #31 never-clobber rule): the wizard runs on
  # absent/empty/zero-profile shapes, and a hand-made or unparseable file is
  # the user's to move aside, not ours to replace.
  defp empty_or_absent(path) do
    case File.read(path) do
      {:ok, contents} ->
        if String.trim(contents) == "" do
          :ok
        else
          {:error,
           "#{@main_file} already exists and is not empty — rename it aside " <>
             "(mv #{path} #{path}.old) and re-run setup to write a fresh one"}
        end

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, "cannot read #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp ensure_dir(dir) do
    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> {:error, "cannot create #{dir}: #{:file.format_error(reason)}"}
    end
  end

  @doc """
  Testable core: loads `settings.json5` + `keys.json5` in `dir` (a missing
  or empty file = empty map), overlaid with `env` (a map of variable names
  to values) and `cli` (the `profile:`/`model:` keywords from
  `DashFloat.CLI.parse/1`; flag beats env, env beats file). See the module
  doc for the selection semantics and the classification arms. Blank fields
  after the merge yield an error naming only the missing field names —
  values are never echoed. `context_tokens` is optional: env wins over the
  file, and anything that is not a positive integer is nil — never an error
  (ADR 0006). `suggest` (ADR 0015) and `autoTitle` (#80) flow the same way:
  `false` opts the side-request out, a string pins that model id, and absent
  or unusable is nil — the provider's default cheap model, never an error.
  `images` (ADR 0018) rides the selected entry: a strict boolean, absent or
  unusable means not image-capable — warned, never an error.
  """
  @spec load(Path.t(), map(), keyword()) :: classification()
  def load(dir, env, cli) when is_binary(dir) and is_map(env) and is_list(cli) do
    main_path = Path.join(dir, @main_file)
    keys_path = Path.join(dir, @keys_file)
    oauth_path = Path.join(dir, @oauth_file)

    # Repairs run BEFORE everything that parses: a hand-made file is most
    # likely both malformed and too permissive, and the security posture
    # must not depend on the file also being valid JSON5 (hostile-review
    # finding) — including when the migration itself fails parsing it.
    # oauth.json5 is posture-only — never read, absence silent. Leftover
    # backups repair too: an already-migrated directory never runs the
    # migration that would have tightened them (issue #28).
    with :ok <- Posture.tighten(main_path, @main_file),
         :ok <- Posture.tighten(keys_path, @keys_file),
         :ok <- Posture.tighten(oauth_path, @oauth_file),
         :ok <- Migration.repair_backup(dir),
         {:ok, _migration} <- Migration.maybe_migrate(dir),
         {:ok, main} <- JSON5.read_map(main_path),
         {:ok, keys} <- JSON5.read_map(keys_path) do
      check_version(main)
      warn_stray_root_key(main)

      profiles = parse_profiles(main)
      warn_unkeyed_profiles(main, profiles, keys, keys_path, env, cli)
      classify(main, profiles, keys, env, cli)
    end
  end

  @doc """
  Profile names in a config dir, read-only (`[]` when the dir is nil or
  settings.json5 is unreadable/unparseable). The /profile picker's list
  (ADR 0020).
  """
  @spec profile_names(String.t() | nil) :: [String.t()]
  def profile_names(nil), do: []

  def profile_names(dir) when is_binary(dir) do
    main_path = Path.join(dir, @main_file)

    case JSON5.read_map(main_path) do
      {:ok, main} ->
        main
        |> parse_profiles()
        |> Enum.map(& &1.name)

      {:error, _reason} ->
        []
    end
  end

  ## Classification — the deliberate-selection state machine (ADR 0009)

  defp classify(main, profiles, keys, env, cli) do
    explicit = cli_value(cli, :profile) || env_value(env, @profile_var)

    if is_binary(explicit) do
      explicit_profile(explicit, profiles, keys, env, cli)
    else
      case default_profile_name(main, profiles) do
        nil -> implicit_classification(profiles, keys, env, cli)
        name -> default_result(profiles, name, keys, env, cli)
      end
    end
  end

  defp default_result(profiles, name, keys, env, cli) do
    profile = Enum.find(profiles, fn parsed -> parsed.name == name end)
    build_result(profiles, profile, keys, env, cli)
  end

  # An explicit --profile/DASHFLOAT_PROFILE that matches nothing is a HARD
  # ERROR listing the valid names (ADR 0009): deliberate selection means a
  # typo must not silently boot the wrong persona. The one survivor of v2's
  # warn-and-continue is the zero-profiles env-only regime, where there is
  # nothing to mistype into and the env vars complete everything.
  defp explicit_profile(name, profiles, keys, env, cli) do
    case Enum.find(profiles, fn profile -> profile.name == name end) do
      nil when profiles == [] ->
        Logger.warning(
          "profile \"#{name}\" (flag or DASHFLOAT_PROFILE) matches no profile in #{@main_file}"
        )

        build_result(profiles, nil, keys, env, cli)

      nil ->
        {:error, unknown_profile_error(name, profiles)}

      profile ->
        build_result(profiles, profile, keys, env, cli)
    end
  end

  defp implicit_classification(profiles, keys, env, cli) do
    case profiles do
      [only] ->
        build_result(profiles, only, keys, env, cli)

      [_head | _tail] ->
        {:select, Enum.map(profiles, & &1.name)}

      [] ->
        case build_result([], nil, keys, env, cli) do
          {:ok, _config} = ok -> ok
          {:error, _missing} -> :onboard
        end
    end
  end

  defp unknown_profile_error(name, profiles) do
    valid = Enum.map_join(profiles, ", ", & &1.name)
    "profile \"#{name}\" matches no profile in #{@main_file} — valid profiles: #{valid}"
  end

  # defaultProfile is optional: absent is silent. Present but unusable — a
  # non-string, blank, or unknown name — warns and counts as unset, landing
  # in the classification arms (ADR 0009's tolerance principle: Terence's
  # deleted-defaultProfile scenario).
  defp default_profile_name(main, profiles) do
    case main["defaultProfile"] do
      nil -> nil
      name when is_binary(name) -> named_default(name, profiles)
      _other -> non_string_default()
    end
  end

  defp named_default(name, profiles) do
    case value(name) do
      nil -> blank_default()
      trimmed -> known_default(trimmed, profiles)
    end
  end

  defp known_default(trimmed, profiles) do
    if Enum.any?(profiles, &(&1.name == trimmed)) do
      trimmed
    else
      unknown_default_warning(trimmed)
    end
  end

  defp blank_default do
    Logger.warning("defaultProfile is blank — ignoring it")
    nil
  end

  defp non_string_default do
    Logger.warning("defaultProfile is not a string — ignoring it")
    nil
  end

  defp unknown_default_warning(trimmed) do
    Logger.warning(
      ~s(defaultProfile "#{trimmed}" matches no profile in #{@main_file} — ignoring it)
    )

    nil
  end

  # Surfaces HISTORICAL loss at startup (hostile review, incident-hiding
  # note): a provider with no key under its endpoint in an existing
  # keys.json5 is exactly the shape a lost credential leaves behind. The
  # warning respects the loader's own precedence (DASHFLOAT_API_KEY keys the
  # active provider); profile and provider NAMES only, never values or
  # endpoints; silent when keys.json5 is absent (env-keyed setups are
  # legitimate). An unset $ENV_VAR reference names the variable — env var
  # names are addresses, not secrets (ADR 0009).
  # P3-4 (hostile review): the warning fires for the ACTIVE profile's
  # providers only — a fully-keyed default must not be nagged about another
  # persona's unkeyed provider. The active profile is resolved exactly as
  # classify/5 resolves it (flag > env > valid defaultProfile > the sole
  # profile); when no profile can be active yet (zero profiles, or a forced
  # selection with no default), nobody is warned — the modal decides first.
  defp warn_unkeyed_profiles(main, profiles, keys, keys_path, env, cli) do
    case active_profile_name(main, profiles, env, cli) do
      nil -> :ok
      name -> warn_unkeyed_profile(Enum.find(profiles, &(&1.name == name)), keys, keys_path, env)
    end
  end

  defp active_profile_name(main, profiles, env, cli) do
    explicit = cli_value(cli, :profile) || env_value(env, @profile_var)

    cond do
      is_binary(explicit) -> explicit
      match?([_only], profiles) -> hd(profiles).name
      true -> default_profile_name(main, profiles)
    end
  end

  defp warn_unkeyed_profile(nil, _keys, _keys_path, _env), do: :ok

  defp warn_unkeyed_profile(profile, keys, keys_path, env) do
    if File.exists?(keys_path) and not env_key?(env) do
      for provider <- profile.providers, do: warn_if_unkeyed(profile, provider, keys, env)
    end

    :ok
  end

  defp warn_if_unkeyed(profile, provider, keys, env) do
    # A binding inside a `for` clause list would act as a FILTER (a nil raw
    # key would silently stop iteration) — compute in the body.
    raw = raw_key(keys, profile, provider)

    if resolve_key(raw, env) == nil do
      warn_unkeyed_provider(profile, provider, raw, env)
    end
  end

  defp warn_unkeyed_provider(profile, provider, raw, env) do
    case unset_ref(raw, env) do
      nil ->
        Logger.warning(
          ~s(provider "#{provider.label}" in profile "#{profile.name}" has no key in #{@keys_file})
        )

      var ->
        Logger.warning(
          ~s(provider "#{provider.label}" in profile "#{profile.name}" references ) <>
            "unset environment variable #{var}"
        )
    end
  end

  defp raw_key(keys, profile, provider) do
    keys
    |> profile_keys_quiet(profile.name)
    |> Map.get(provider.base_url)
  end

  defp profile_keys_quiet(keys, name) do
    case keys[name] do
      %{} = nested -> nested
      _other -> %{}
    end
  end

  # The variable name when raw is a strict $REF the environment lacks.
  defp unset_ref(raw, env) do
    case value(raw) do
      trimmed when is_binary(trimmed) ->
        var = String.slice(trimmed, 1..-1//1)

        if Regex.match?(@env_ref, trimmed) and is_nil(value(Map.get(env, var))) do
          var
        else
          nil
        end

      _other ->
        nil
    end
  end

  ## Selection (ADR 0009: profiles → providers → models)

  # The build used when no profile matched at all (the env-only regime):
  # every effective field comes from env; the provider set is empty.
  defp build_result(_profiles, nil, _keys, env, cli) do
    entry = select_entry([], nil, cli)

    build(
      effective(nil, nil, nil, nil, env),
      context(env, entry),
      false,
      tri_state(env, @suggest_var, nil, "suggest"),
      tri_state(env, @auto_title_var, nil, "autoTitle"),
      nil,
      nil,
      []
    )
  end

  defp build_result(_profiles, profile, keys, env, cli) do
    provider = select_provider(profile)
    menu = entry_menu(provider)
    entry = select_entry(menu, profile.settings, cli)
    providers = resolved_providers(profile, keys, env, provider)

    built =
      build(
        effective(provider, entry, keys, profile, env),
        context(env, entry),
        entry && entry.images,
        tri_state(env, @suggest_var, profile.settings, "suggest"),
        tri_state(env, @auto_title_var, profile.settings, "autoTitle"),
        entry && entry.nickname,
        profile.name,
        providers
      )

    with_model_menu(built, menu)
  end

  # The active provider's parsed menu rides the config (ADR 0018 §1) for
  # the runtime /model switch's capability re-resolution — set after the
  # shared build so its signature stays at the settled arity.
  defp with_model_menu({:ok, %__MODULE__{} = config}, menu),
    do: {:ok, %{config | model_menu: menu}}

  defp with_model_menu(error, _menu), do: error

  defp entry_menu(nil), do: []

  defp entry_menu(provider), do: provider.models

  # The active provider: the profile's defaultProvider label, else the
  # first. An unknown label warns and falls back to the first; duplicate
  # labels resolve first-wins (Enum.find) like duplicate profile names.
  defp select_provider(profile) do
    case profile.providers do
      [] -> nil
      providers -> named_or_first(profile, providers)
    end
  end

  defp named_or_first(profile, providers) do
    case profile.default_provider do
      nil ->
        hd(providers)

      wanted ->
        find_named(profile, wanted, providers)
    end
  end

  defp find_named(profile, wanted, providers) do
    case Enum.find(providers, fn provider -> provider.label == wanted end) do
      nil ->
        Logger.warning(
          ~s(#{@main_file}: defaultProvider "#{wanted}" matches no provider in profile ) <>
            ~s("#{profile.name}" — using the first)
        )

        hd(providers)

      found ->
        found
    end
  end

  # Effective fields: the file's source (active provider, selected entry)
  # under per-field env overrides (file < env, ADR 0009). The key's file
  # source is keys.json5 BY ENDPOINT — settings.json5 cannot supply one.
  defp effective(provider, entry, keys, profile, env) do
    %{
      base_url: env_value(env, @fields[:base_url]) || (provider && provider.base_url),
      model: env_value(env, @fields[:model]) || (entry && entry.model),
      api_key: env_value(env, @fields[:api_key]) || provider_key(keys, profile, provider, env)
    }
  end

  # keys[profile][baseUrl] with $ENV_REF resolution. Hand damage degrades to
  # a missing key with a warning (ADR 0009 tolerance): a profile's entry
  # that is not an object, or an endpoint's value that is not a string, is
  # never a crash and never a refusal of the whole file — keys.json5 only
  # refuses when unparseable.
  defp provider_key(_keys, _profile, nil, _env), do: nil

  defp provider_key(keys, profile, provider, env) do
    keys
    |> profile_keys(profile.name)
    |> Map.get(provider.base_url)
    |> resolve_key(env)
  end

  defp profile_keys(keys, name) do
    case keys[name] do
      %{} = nested ->
        nested

      nil ->
        %{}

      _other ->
        Logger.warning(~s(#{@keys_file}: "#{name}" is not an object — its keys are unusable))

        %{}
    end
  end

  # A strict-shape `$ENV_VAR` value resolves from the environment; anything
  # else (including a literal that merely starts with `$`) is the literal
  # key. An unset reference resolves to nil — the field reads as missing and
  # the unkeyed warning names the variable.
  defp resolve_key(nil, _env), do: nil

  defp resolve_key(raw, env) do
    case value(raw) do
      nil ->
        nil

      trimmed when is_binary(trimmed) ->
        if Regex.match?(@env_ref, trimmed) do
          trimmed
          |> String.slice(1..-1//1)
          |> then(&Map.get(env, &1))
          |> value()
        else
          trimmed
        end
    end
  end

  defp env_key?(env), do: env_value(env, @fields[:api_key]) != nil

  # The active profile's providers with each provider's EFFECTIVE key
  # (DASHFLOAT_API_KEY applies to the active provider; the others read
  # keys[profile][baseUrl]) — the catalog refresh's fetch set (ADR 0009).
  defp resolved_providers(profile, keys, env, active) do
    nested = profile_keys_quiet(keys, profile.name)

    for provider <- profile.providers do
      key =
        if active && provider.base_url == active.base_url do
          env_value(env, @fields[:api_key]) ||
            resolve_key(Map.get(nested, provider.base_url), env)
        else
          resolve_key(Map.get(nested, provider.base_url), env)
        end

      %{label: provider.label, base_url: provider.base_url, api_key: key}
    end
  end

  # Env wins over the file; a blank env var counts as absent (like every other
  # field), but a value present and unusable is simply nil (ADR 0006).
  defp context(env, entry) do
    case env_value(env, @context_var) do
      nil -> entry && positive_int(entry.context)
      raw -> positive_int(raw)
    end
  end

  # The side-request tri-states (`suggest`: ADR 0015 §3, `autoTitle`: #80),
  # threaded exactly like context_tokens: env wins over the active profile's
  # settings key; a blank/absent env var falls to the file; blank/absent
  # everywhere is nil (the provider's default cheap model).
  defp tri_state(env, var, settings, key) do
    case env_value(env, var) do
      nil -> parse_tri_state(settings && Map.get(settings, key), key)
      raw -> parse_tri_state(tri_state_env_keyword(raw), key)
    end
  end

  # The env spellings normalize onto the shared parser's boolean arms; any
  # other non-blank string is the model id verbatim (never downcased, never
  # trimmed — the id arm passes the raw value through). The boolean match
  # trims BOTH ends: an env `" false"` must stay the opt-out, not become a
  # model id with a leading space.
  defp tri_state_env_keyword(raw) do
    keyword =
      raw
      |> String.trim()
      |> String.downcase()

    case keyword do
      kw when kw in ["false", "0"] -> false
      kw when kw in ["true", "1"] -> true
      _other -> raw
    end
  end

  # ONE shared parser: `false` opts out, `true` is the default cheap model
  # (nil), a usable non-blank string is that exact model id, absent/blank is
  # nil. Anything else warns naming the field and degrades to the default —
  # never a load error (ADR 0009's tolerance principle).
  defp parse_tri_state(nil, _key), do: nil
  defp parse_tri_state(false, _key), do: false
  defp parse_tri_state(true, _key), do: nil

  defp parse_tri_state(raw, _key) when is_binary(raw) do
    case String.trim_trailing(raw) do
      "" -> nil
      id -> id
    end
  end

  defp parse_tri_state(_other, key) do
    Logger.warning("#{key} is not a usable value — using the provider's default cheap model")
    nil
  end

  defp build(values, context_tokens, images, suggest, auto_title, nickname, profile, providers) do
    case Enum.reject(@fields, fn {field, _var} -> value(values[field]) end) do
      [] ->
        config =
          struct!(
            __MODULE__,
            Map.new(values, fn {field, raw} -> {field, value(raw)} end)
          )

        {:ok,
         %{
           config
           | context_tokens: context_tokens,
             # nil (no selected entry) is not capable (ADR 0018 §1).
             images: images || false,
             suggest: suggest,
             auto_title: auto_title,
             nickname: value(nickname),
             profile: profile,
             providers: providers
         }}

      missing ->
        {:error, "missing provider config: " <> field_names(missing)}
    end
  end

  ## Model selection (v2 rules, scoped to the active provider's menu)

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

  ## File schema (ADR 0009)

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
        warn_stray_key(name, entry)
        warn_stray_base_url(name, entry)

        %{
          name: name,
          default_provider: value(entry["defaultProvider"]),
          providers: parse_providers(name, entry["providers"]),
          settings: parse_settings(name, entry["settings"]),
          mcp: parse_mcp(name, entry["mcp"]),
          models: []
        }
    end
  end

  defp parse_profile(_other) do
    Logger.warning("#{@main_file}: a profile entry that is not an object is ignored")
    nil
  end

  # Tolerate-and-warn, value IGNORED — never a fallback: using a stray inline
  # key would defeat the structural guarantee that settings.json5 cannot
  # hold a credential (ADR 0008 keys-split amendment).
  defp warn_stray_key(name, entry) do
    if Map.has_key?(entry, "apiKey") do
      Logger.warning(
        ~s(#{@main_file}: profile "#{name}": apiKey is ignored ) <>
          "— API keys live in #{@keys_file}, keyed by provider baseUrl"
      )
    end
  end

  # A v3 file with a v2-shaped profile baseUrl can only be hand damage; the
  # profile would otherwise silently degrade to provider-less (ADR 0009
  # tolerance: name the field, never silent misbehavior).
  defp warn_stray_base_url(name, entry) do
    if Map.has_key?(entry, "baseUrl") do
      Logger.warning(
        ~s(#{@main_file}: profile "#{name}": baseUrl at the profile level is v2 shape ) <>
          "— move it into a providers[] entry"
      )
    end
  end

  defp parse_providers(_name, nil), do: []

  defp parse_providers(_name, entries) when is_list(entries) do
    entries
    |> Enum.map(&parse_provider/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_providers(name, _other) do
    Logger.warning(~s(#{@main_file}: profile "#{name}": providers must be a list — ignored))
    []
  end

  # Label optional, defaulting to the URL host (ADR 0009); extras tolerated
  # silently for forward compatibility.
  defp parse_provider(entry) when is_map(entry) do
    case value(entry["baseUrl"]) do
      nil ->
        Logger.warning("#{@main_file}: a providers entry without a baseUrl is ignored")
        nil

      base_url ->
        %{
          label: value(entry["label"]) || host_label(base_url),
          base_url: base_url,
          models: parse_models(entry["models"])
        }
    end
  end

  defp parse_provider(_other) do
    Logger.warning("#{@main_file}: a providers entry that is not an object is ignored")
    nil
  end

  @doc """
  The URL's host as a label — `URI.parse`'s host, else the raw string. The
  settings label default (ADR 0009) and the footer's host degrade (ADR 0015
  §2's amendment, issue #109) share this one rule.
  """
  @spec host_label(String.t()) :: String.t()
  def host_label(base_url) do
    case URI.parse(base_url) do
      %URI{host: nil} -> base_url
      %URI{host: host} -> host
    end
  end

  defp parse_models(nil), do: []

  defp parse_models(entries) when is_list(entries) do
    entries
    |> Enum.map(&parse_model/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_models(_other) do
    Logger.warning("#{@main_file}: models must be a list — ignored")
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
          context: entry["context"],
          images: parse_images(entry["images"])
        }
    end
  end

  defp parse_model(_other) do
    Logger.warning("#{@main_file}: a models entry that is not an object is ignored")
    nil
  end

  # The image-capability flag is a strict boolean (ADR 0018 §1): true means
  # capable, absent or false means not; anything else warns naming the field
  # and means not — ADR 0009's tolerance principle, the context shape.
  defp parse_images(true), do: true
  defp parse_images(false), do: false
  defp parse_images(nil), do: false

  defp parse_images(_other) do
    Logger.warning(
      "#{@main_file}: images is not a boolean — treating the model as not image-capable"
    )

    false
  end

  # MCP entries are storage shape only (no client yet, ADR 0009): name and
  # command are required, token must be a strict $ENV_REF — a literal token
  # would put a secret into the secret-free settings file, so the entry is
  # ignored with a warning instead.
  defp parse_mcp(_name, nil), do: []

  defp parse_mcp(name, entries) when is_list(entries) do
    entries
    |> Enum.map(&parse_mcp_entry(name, &1))
    |> Enum.reject(&is_nil/1)
  end

  defp parse_mcp(name, _other) do
    Logger.warning(~s(#{@main_file}: profile "#{name}": mcp must be a list — ignored))
    []
  end

  defp parse_mcp_entry(_name, entry) when is_map(entry) do
    with name when is_binary(name) <- value(entry["name"]) || :missing,
         command when is_binary(command) <- value(entry["command"]) || :missing,
         token when token in [nil, :ref] <- mcp_token(entry["token"]),
         args when is_list(args) <- valid_args(entry["args"]) do
      %{name: name, command: command, args: args, token: token}
    else
      :missing ->
        Logger.warning("#{@main_file}: an mcp entry without a name or command is ignored")
        nil

      :literal_token ->
        Logger.warning(
          "#{@main_file}: an mcp entry with a literal token is ignored — " <>
            "token must be a $ENV_VAR reference"
        )

        nil

      :bad_args ->
        Logger.warning("#{@main_file}: an mcp entry with a non-list args is ignored")
        nil

      :bad_arg_element ->
        Logger.warning("#{@main_file}: an mcp entry with a non-scalar arg is ignored")
        nil
    end
  end

  defp parse_mcp_entry(_name, _other) do
    Logger.warning("#{@main_file}: an mcp entry that is not an object is ignored")
    nil
  end

  defp mcp_token(nil), do: nil

  defp mcp_token(token) when is_binary(token) do
    if Regex.match?(@env_ref, token), do: :ref, else: :literal_token
  end

  defp mcp_token(_other), do: :literal_token

  # `args` must be a list of scalars — to_string/1 on a map or nested list
  # raises Protocol.UndefinedError straight out of load (P2-2, hostile
  # review). Shape junk NEVER crashes the loader: the entry skips with a
  # warning.
  defp valid_args(nil), do: []

  defp valid_args(entries) when is_list(entries) do
    if Enum.all?(entries, &scalar?/1) do
      Enum.map(entries, &to_string/1)
    else
      :bad_arg_element
    end
  end

  defp valid_args(_other), do: :bad_args

  defp scalar?(value), do: is_binary(value) or is_number(value) or is_boolean(value)

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

  # The profile-level stray warning's root twin (hostile review P1-2): a
  # root-level apiKey is ignored exactly like a profile-level one — warned,
  # never a fallback, never silently tolerated.
  defp warn_stray_root_key(main) do
    if Map.has_key?(main, "apiKey") do
      Logger.warning(
        "#{@main_file}: top-level apiKey is ignored — API keys live in #{@keys_file}"
      )
    end
  end

  ## Version check

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
