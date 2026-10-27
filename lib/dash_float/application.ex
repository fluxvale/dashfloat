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

    argv =
      Keyword.get(
        args,
        :argv,
        boot_argv(Keyword.get(args, :plain_argv), Keyword.get(args, :system_argv))
      )

    # One halt seam for every boot-time exit; a real halt would take the
    # test VM down with it.
    halt = Keyword.get(args, :halt, &System.halt/1)

    # A version query must work with no TTY, no config, and no provider: the
    # installer and CI smoke a downloaded artifact this way (ADR 0010).
    if not test?, do: handle_version(argv, halt)

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

      # The {:error, _} return from Application.start/2 is what makes OTP
      # terminate the kernel and drop erl_crash.dump in the user's CWD, so
      # the refusal exits at the boundary instead. The return is unreachable
      # in production (the halt ends the VM) — it is the test seam's value.
      # See ADR 0011.
      halt.(1)

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

  # A version query must work with no TTY, no config, and no provider: the
  # installer and CI smoke a downloaded artifact this way (ADR 0010). The NIF
  # is forced to load first because a version query is the cheapest packaging
  # smoke — a NIF/host mismatch must fail loudly instead of answering 0.
  defp handle_version(argv, halt) do
    if DashFloat.CLI.version?(argv) do
      :ok = ExRatatui.Native.ensure_loaded()
      IO.binwrite(:stdio, "dashfloat #{DashFloat.version()}\n")
      halt.(0)
    end
  end

  # A release boots applications before Elixir's CLI parses `-extra` arguments
  # into System.argv/0, so at boot time System.argv/0 is empty and the plain
  # init arguments are the only place the user's flags appear. Fall back to
  # them (minus the launcher's own --no-halt) so `dashfloat --version` and the
  # selection flags work in a release as they do under `mix run` (ADR 0010).
  defp boot_argv(plain, system_argv) do
    plain = plain || Enum.map(:init.get_plain_arguments(), &List.to_string/1)
    system_argv = system_argv || System.argv()

    argv =
      case system_argv do
        [_some | _more] -> system_argv
        _no_argv -> plain
      end

    Enum.reject(argv, &(&1 == "--no-halt"))
  end

  # A forced selection or onboarding state needs the terminal; a headless or
  # piped stdin must get instructions instead of a hung wizard (ADR 0009).
  defp setup_stateful?({:select, _names}), do: true
  defp setup_stateful?(:onboard), do: true
  defp setup_stateful?(_other), do: false

  # :io.columns(:standard_input) is always {:error, :enotsup} under a
  # release's -noshell boot, even on a real pty — ask the fd primitive.
  # See ADR 0011.
  defp interactive?(nil), do: tty?()
  defp interactive?(override) when is_boolean(override), do: override

  @doc false
  @spec tty?((:stdin | :stdout -> term())) :: boolean()
  def tty?(isatty \\ &:prim_tty.isatty/1),
    do: isatty.(:stdin) == true or isatty.(:stdout) == true

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
       resolve: boot_resolver(config_dir, env, cli)}
    ]
  end

  defp setup_state({:select, names}), do: {:select, names, 0}
  defp setup_state(:onboard), do: Onboarding.new()
  defp setup_state(_other), do: nil

  @doc false
  # The setup phase's reload seam (ADR 0009): the completed selection (or the
  # wizard's finish) re-loads through exactly this closure — nil (the
  # wizard, defaultProfile decides) or a chosen profile name. Public so the
  # boot tests exercise the real resolver the TUI receives.
  @spec boot_resolver(String.t(), map(), keyword()) ::
          (String.t() | nil -> Config.classification())
  def boot_resolver(config_dir, env, cli) do
    fn name -> Config.load(config_dir, env, Keyword.put(cli, :profile, name)) end
  end

  defp test_env? do
    Code.ensure_loaded?(Mix) and function_exported?(Mix, :env, 0) and Mix.env() == :test
  end
end
