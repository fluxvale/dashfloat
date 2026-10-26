defmodule DashFloat.Application do
  @moduledoc false

  use Application

  alias DashFloat.Config
  alias DashFloat.Config.Onboarding

  # `args` exists purely as the test seam for the non-test arms: MIX_ENV=test
  # boots with `test?: true` (below), so the real classification wiring —
  # load, setup states, the resolver — is only reachable in tests by passing
  # explicit overrides here. Production boots with `[]` and takes the
  # defaults; nothing else differs.
  @impl Application
  def start(_type, args) when is_list(args) do
    test? = Keyword.get(args, :test?, test_env?())
    argv = Keyword.get(args, :argv, System.argv())
    env = Keyword.get(args, :env, System.get_env())
    config_dir = Keyword.get(args, :config_dir, Config.config_dir())
    interactive? = Keyword.get(args, :interactive?)

    # Selection flags (--profile/--model) are parsed once here (ADR 0008);
    # both children below must agree on the same selection. Parsed only
    # outside test (mix's own argv must not produce warnings).
    cli = if test?, do: [], else: DashFloat.CLI.parse(argv)

    # The load happens once here (ADR 0005) and its classification (ADR
    # 0009) decides the startup shape: a resolved config boots straight, a
    # forced selection or onboarding state boots the TUI in setup mode, and
    # the completed choice re-loads through `resolve` — the UI process still
    # performs no chat-time file I/O.
    classification =
      if test?,
        do: {:error, "no provider configured in test"},
        else: Config.load(config_dir, env, cli)

    if not test? and setup_stateful?(classification) and not interactive?(interactive?) do
      IO.binwrite(:stderr, setup_instructions(config_dir))

      {:error, :interactive_setup_required}
    else
      children = [
        # Streams and tool runners: temporary tasks under one supervisor
        # (renamed from StreamSupervisor in ADR 0007 — it hosts both kinds).
        {Task.Supervisor, name: DashFloat.TaskSupervisor}
        | engine_children(test?, classification) ++
            tui_child(test?, classification, config_dir, env, cli)
      ]

      opts = [strategy: :one_for_one, name: DashFloat.Supervisor]
      Supervisor.start_link(children, opts)
    end
  end

  # A forced selection or onboarding state needs the terminal; a headless or
  # piped stdin must get instructions instead of a hung wizard (ADR 0009).
  defp setup_stateful?({:select, _names}), do: true
  defp setup_stateful?(:onboard), do: true
  defp setup_stateful?(_other), do: false

  defp interactive?(nil), do: match?({:ok, _}, :io.columns(:standard_input))
  defp interactive?(override) when is_boolean(override), do: override

  defp setup_instructions(config_dir) do
    """
    DashFloat needs an interactive terminal to finish setup.

      - Run it in a terminal to pick a profile (or run the first-time wizard).
      - Or configure by hand: create settings.json5 and keys.json5 under
        #{config_dir} (see the README), or set
        DASHFLOAT_BASE_URL, DASHFLOAT_MODEL, and DASHFLOAT_API_KEY.
    """
  end

  # The agent owns the conversation and the tool loop; it is started with the
  # boot-time classification outside test (tests start their own agents, ADR
  # 0007). Setup states boot it on the error arm — the setup completion
  # delivers the resolved provider via {:set_provider, _} (ADR 0009).
  defp engine_children(true, _classification), do: []

  defp engine_children(false, classification) do
    [
      {DashFloat.Agent,
       provider: agent_provider(classification),
       name: DashFloat.Agent,
       supervisor: DashFloat.TaskSupervisor}
    ]
  end

  defp agent_provider({:ok, config}), do: {:ok, config}
  defp agent_provider({:error, message}), do: {:error, message}

  defp agent_provider({:select, _names}),
    do: {:error, "no profile selected — choose one to start"}

  defp agent_provider(:onboard),
    do: {:error, "no profile configured — finish first-run setup"}

  # The TUI owns the real terminal; `mix test` must never start it. Releases
  # don't ship Mix, so the guard keeps working in production (ADR 0002).
  # Provider config is loaded once, here, so the UI process performs no file
  # I/O (ADR 0005); the agent name rides in as a mount opt (ADR 0007). Setup
  # states ride in as mount opts too (ADR 0009), with the resolver the setup
  # phase calls to deliver the completed selection.
  defp tui_child(true, _classification, _config_dir, _env, _cli), do: []

  defp tui_child(false, classification, config_dir, env, cli) do
    [
      {DashFloat.TUI,
       provider: agent_provider(classification),
       agent: DashFloat.Agent,
       config_dir: config_dir,
       setup: setup_state(classification),
       resolve: fn name -> Config.load(config_dir, env, put_profile(cli, name)) end}
    ]
  end

  defp setup_state({:select, names}), do: {:select, names, 0}
  defp setup_state(:onboard), do: Onboarding.new()
  defp setup_state(_other), do: nil

  defp put_profile(cli, nil), do: Keyword.put(cli, :profile, nil)
  defp put_profile(cli, name) when is_binary(name), do: Keyword.put(cli, :profile, name)

  defp test_env? do
    Code.ensure_loaded?(Mix) and function_exported?(Mix, :env, 0) and Mix.env() == :test
  end
end
