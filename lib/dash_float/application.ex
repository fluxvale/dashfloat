defmodule DashFloat.Application do
  @moduledoc false

  use Application

  alias DashFloat.Config
  alias DashFloat.Config.Onboarding
  alias DashFloat.Session
  alias DashFloat.Session.Title

  require Logger

  # The resume hand-off (ADR 0014 §6): one load, two consumers — the agent
  # adopts the transcript, the TUI replays it.
  @typep resume :: %{session: Session.t(), note: String.t() | nil} | nil

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

    # Mirrors :config_dir — a test must never touch the real XDG data dir
    # (ADR 0014 §5).
    sessions_dir = Keyword.get(args, :sessions_dir, Session.dir())

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
      case boot_resume(cli, classification, sessions_dir, test?) do
        {:error, message} ->
          # The user named a conversation or a title; silently starting blank
          # is the one outcome a named request must never produce (ADR 0014
          # §6). Same refusal shape as the interactive-setup refusal above:
          # stderr, then the boundary halt, with the error tuple as the test
          # seam's value.
          IO.binwrite(:stderr, message <> "\n")
          halt.(1)

          {:error, :session_resume_failed}

        {:ok, resume} ->
          children =
            boot_children(test?, classification, config_dir, env, cli, resume, sessions_dir)

          opts = [strategy: :one_for_one, name: DashFloat.Supervisor]
          Supervisor.start_link(children, opts)
      end
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

  # ADR 0014 §6: after classification, before children — the user asked for a
  # specific conversation, so every load failure is a loud refusal and a
  # successful load is handed to both children. Under a setup classification
  # the session still hands off; the pin compare is skipped (nothing to
  # compare yet) and setup proceeds as today. The refused file is untouched:
  # a load never writes.
  @doc false
  # Public so the boot tests drive the real load-and-compare the boot runs
  # (see boot_resolver). The typed value routes on shape: a UUID (today's `ls`
  # tolerance — one `.json` suffix, which `Session.load/2` also strips) is the
  # id path verbatim; anything else is a title to resolve.
  @spec boot_resume(keyword(), Config.classification(), Path.t()) ::
          {:ok, resume()} | {:error, String.t()}
  def boot_resume(cli, classification, sessions_dir) do
    case Keyword.get(cli, :resume) do
      nil ->
        {:ok, nil}

      requested ->
        id = String.replace_suffix(requested, ".json", "")

        if Session.valid_id?(id) do
          resume_session(Session.load(sessions_dir, requested), classification)
        else
          resume_by_title(requested, classification, sessions_dir)
        end
    end
  end

  # The title path (ADR 0014 §6): the value names a session's unique title;
  # the refusals name it as typed and carry the same ls remedy as the
  # unknown-id arm.
  defp resume_by_title(value, classification, sessions_dir) do
    case Title.find_by_title(sessions_dir, value) do
      {:ok, id} ->
        resume_session(Session.load(sessions_dir, id), classification)

      :none ->
        {:error,
         "no session titled \"#{value}\" under #{sessions_dir} — list sessions with: ls #{sessions_dir}"}

      {:ambiguous, ids} ->
        {:error,
         "multiple sessions are titled \"#{value}\": #{Enum.join(ids, ", ")} — resume one by its " <>
           "id; list sessions with: ls #{sessions_dir}"}
    end
  end

  defp resume_session({:ok, session}, classification) do
    # Warnings the user must see ride both surfaces: the alt screen swallows
    # Logger, so the note also mounts on the replayed log (ADR 0014 §6).
    note = pin_note(session, classification)
    if note, do: Logger.warning(note)

    {:ok, %{session: session, note: note}}
  end

  defp resume_session({:error, message}, _classification), do: {:error, message}

  # The boot-time session flow (ADR 0014 §6): the legacy-id sweep first — a
  # timestamp-named file must be UUID-named before any resolution can name it
  # — then resume resolution, then the --title checks (a rename needs the
  # loaded session's id, and every refusal must land before any child starts).
  defp boot_resume(_cli, _classification, _sessions_dir, true), do: {:ok, nil}

  defp boot_resume(cli, classification, sessions_dir, false) do
    with :ok <- migrate_sweep(sessions_dir),
         {:ok, resume} <- boot_resume(cli, classification, sessions_dir),
         :ok <- apply_title(cli, resume, sessions_dir) do
      {:ok, resume}
    end
  end

  # The one-shot legacy-id sweep (ADR 0014 §2): a failed sweep warns and
  # continues — resume-by-UUID still works and the next boot retries — and a
  # steady-state boot (missing or all-UUID directory) logs nothing.
  defp migrate_sweep(sessions_dir) do
    case Session.migrate_legacy_ids(sessions_dir) do
      {:ok, 0} ->
        :ok

      {:ok, count} ->
        Logger.info("renamed #{count} legacy session file(s) to UUID ids")
        :ok

      {:error, message} ->
        Logger.warning("legacy session id sweep skipped: #{message}")
        :ok
    end
  end

  # The --title checks (ADR 0014 §6): the value must normalize and the title
  # must be free — silently starting untitled is the blank-session outcome
  # the refusal exists to prevent. A resume is exempt from its own current
  # title (the boot-time rename); any other holder refuses.
  defp apply_title(cli, resume, sessions_dir) do
    case Keyword.get(cli, :title) do
      nil -> :ok
      raw -> check_title(raw, resume, sessions_dir)
    end
  end

  defp check_title(raw, resume, sessions_dir) do
    case Title.normalize(raw) do
      {:ok, _title} -> title_free(raw, resume, sessions_dir)
      {:error, reason} -> {:error, title_refusal(reason)}
    end
  end

  defp title_refusal(:empty), do: "--title may not be empty or blank"
  defp title_refusal(:too_long), do: "--title may not exceed 80 characters"

  defp title_refusal(:reserved),
    do: "--title may not look like a session id (UUID)"

  defp title_free(raw, resume, sessions_dir) do
    case Title.title_holder(sessions_dir, raw, session_id(resume)) do
      nil ->
        :ok

      holder ->
        {:error,
         "title \"#{raw}\" is already taken by session #{holder} — choose another title " <>
           "or resume that session; list sessions with: ls #{sessions_dir}"}
    end
  end

  defp session_id(%{session: %{id: id}}), do: id
  defp session_id(nil), do: nil

  # ADR 0014 §6: warn, never refuse, never rewrite. A field compares only
  # when both sides are non-nil (an env-only session pins nil profile fields
  # and compares nothing); the note names both sides of every mismatched
  # field, omitting the ones that matched or are nil-pinned.
  @doc false
  @spec pin_note(%{pin: Session.pin()} | Session.t(), Config.classification()) ::
          String.t() | nil
  def pin_note(%{pin: pin}, {:ok, config}) do
    mismatched =
      for {field, pinned, active} <- [
            {:profile, Map.get(pin, :profile), config.profile},
            {:model, Map.get(pin, :model), config.model}
          ],
          pinned != nil and active != nil and pinned != active do
        {field, pinned, active}
      end

    case mismatched do
      [] ->
        nil

      mismatched ->
        pinned =
          Enum.map_join(mismatched, ", ", fn {field, value, _active} -> "#{field} #{value}" end)

        active =
          Enum.map_join(mismatched, ", ", fn {field, _pinned, value} -> "#{field} #{value}" end)

        "[resuming session pinned to #{pinned} under active #{active} — continuing; the session keeps its pin]"
    end
  end

  def pin_note(_session, _classification), do: nil

  # The full child list the boot starts. Public so the boot tests instantiate
  # the exact mount opts the children start with (see boot_resolver).
  @doc false
  @spec boot_children(
          boolean(),
          Config.classification(),
          Path.t(),
          map(),
          keyword(),
          resume(),
          Path.t()
        ) ::
          [:supervisor.child_spec() | {module(), keyword()}]
  def boot_children(true, _classification, _config_dir, _env, _cli, _resume, _sessions_dir) do
    # Streams and tool runners: temporary tasks under one supervisor
    # (renamed from StreamSupervisor in ADR 0007 — it hosts both kinds).
    [{Task.Supervisor, name: DashFloat.TaskSupervisor}]
  end

  def boot_children(false, classification, config_dir, env, cli, resume, sessions_dir) do
    [
      {Task.Supervisor, name: DashFloat.TaskSupervisor}
      | engine_children(classification, resume, cli, sessions_dir) ++
          tui_child(classification, config_dir, env, cli, resume)
    ]
  end

  # The agent owns the conversation and the tool loop; it is started with the
  # boot-time classification outside test (tests start their own agents, ADR
  # 0007). Setup states boot it on the error arm — the setup completion
  # delivers the resolved provider via {:set_provider, _} (ADR 0009).
  # Persistence is always on outside test (ADR 0014 §5); a resume additionally
  # carries the loaded id/pin/messages/created_at/title, so the next save
  # rewrites the same file under the same id with its title (ADR 0014 §6),
  # plus the ADR 0022 §6 diagnostics (the persisted context anchor and the
  # eviction history). `title:` threads the boot's `--title` — the override
  # wins over the loaded file's title.
  # The storage form of --title: normalized at the threading point so the
  # agent adopts trim/scrub/collapse output, never the typed form (the gate
  # above already refused the invalid loud, naming the typed value; its
  # error arm here — tests bypassing the gate — threads nil, never a raw
  # invalid string).
  defp boot_title(cli) do
    case Keyword.get(cli, :title) do
      nil ->
        nil

      raw ->
        case Title.normalize(raw) do
          {:ok, title} -> title
          {:error, _reason} -> nil
        end
    end
  end

  defp engine_children(classification, resume, cli, sessions_dir) do
    resume_opts =
      case resume do
        nil ->
          [title: boot_title(cli)]

        %{session: session} ->
          [
            resume: %{
              id: session.id,
              pin: session.pin,
              messages: session.messages,
              created_at: session.created_at,
              context: session.context,
              compactions: session.compactions,
              title: session.title
            },
            title: boot_title(cli) || session.title
          ]
      end

    [
      {DashFloat.Agent,
       [provider: agent_provider(classification), session_dir: sessions_dir] ++
         resume_opts ++ [name: DashFloat.Agent, supervisor: DashFloat.TaskSupervisor]}
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
  # phase calls to deliver the completed selection. A resumed boot mounts the
  # loaded transcript and the pin warning, if any (ADR 0014 §6).
  defp tui_child(classification, config_dir, env, cli, resume) do
    resume_opts =
      case resume do
        nil ->
          []

        %{session: session, note: note} ->
          [transcript: session.messages, resume_note: note]
      end

    [
      {DashFloat.TUI,
       [
         provider: agent_provider(classification),
         agent: DashFloat.Agent,
         config_dir: config_dir,
         setup: setup_state(classification),
         resolve: boot_resolver(config_dir, env, cli)
       ] ++ resume_opts}
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
