defmodule DashFloat.ApplicationTest do
  @moduledoc false
  # ADR 0009: the boot classification wiring. `Application.start/2`'s args
  # are the test seam for the non-test arms (MIX_ENV=test boots with
  # `test?: true`); production boots with `[]` and takes the defaults. The
  # named supervisor already runs under the test boot, so the started-children
  # path lands on the expected `{:already_started, _}` after the children
  # list is built — the wiring lines still execute. Placeholders only.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias DashFloat.Agent
  alias DashFloat.Application
  alias DashFloat.Config
  alias DashFloat.Session
  alias DashFloat.SSEServer

  @tmp_root "/tmp/opencode"

  defp tmp_dir do
    dir = Path.join(@tmp_root, "dashfloat-app-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp v3_dir do
    dir = tmp_dir()

    settings = Path.join(dir, "settings.json5")

    File.write!(settings, """
    {
      configVersion: 3,
      defaultProfile: 'work',
      profiles: [
        { name: 'work', providers: [
          { baseUrl: 'https://provider.example/v1', models: [{ model: 'm1' }] },
        ] },
      ],
    }
    """)

    keys = Path.join(dir, "keys.json5")
    File.write!(keys, "{work: {'https://provider.example/v1': 'PLACEHOLDER-k'}}")

    dir
  end

  test "a working v3 config boots the agent and the TUI with the resolver wired" do
    dir = v3_dir()

    # The supervisor is already running under the test boot; the children
    # (built with the real classification wiring) make the start fail with
    # already_started instead of a crash — every wiring line executed.
    assert {:error, {:already_started, _pid}} =
             Application.start(:normal,
               test?: false,
               config_dir: dir,
               env: %{},
               argv: [],
               interactive?: true
             )
  end

  test "the boot resolver the TUI receives reloads with the chosen profile" do
    dir = v3_dir()

    resolver = Application.boot_resolver(dir, %{}, [])
    assert {:ok, %DashFloat.Config{profile: "work"}} = resolver.("work")
    assert {:error, _missing} = resolver.("ghost")
    assert {:ok, %DashFloat.Config{profile: "work"}} = resolver.(nil)
  end

  test "a forced-selection boot wires the modal setup and the agent's error arm" do
    dir = tmp_dir()
    settings = Path.join(dir, "settings.json5")

    File.write!(settings, """
    {
      configVersion: 3,
      profiles: [
        { name: 'a', providers: [{ baseUrl: 'https://a.example/v1', models: [{ model: 'm1' }] }] },
        { name: 'b', providers: [{ baseUrl: 'https://b.example/v1', models: [{ model: 'm2' }] }] },
      ],
    }
    """)

    assert {:error, {:already_started, _pid}} =
             Application.start(:normal,
               test?: false,
               config_dir: dir,
               env: %{},
               argv: [],
               interactive?: true
             )
  end

  test "an unparseable settings boot wires the error classification into both children" do
    dir = tmp_dir()
    settings = Path.join(dir, "settings.json5")
    File.write!(settings, "{ broken")

    assert {:error, {:already_started, _pid}} =
             Application.start(:normal,
               test?: false,
               config_dir: dir,
               env: %{},
               argv: [],
               interactive?: false
             )
  end

  test "an onboarding boot with a terminal wires the wizard setup" do
    dir = tmp_dir()

    assert {:error, {:already_started, _pid}} =
             Application.start(:normal,
               test?: false,
               config_dir: dir,
               env: %{},
               argv: [],
               interactive?: true
             )
  end

  test "a headless setup boot without an explicit interactive override probes the tty" do
    dir = tmp_dir()
    parent = self()
    halt = fn code -> send(parent, {:halted, code}) end

    # Either arm is correct (the probe depends on this process's fds); the
    # PROBE itself is the covered behavior. The refusal arm now halts at the
    # boot boundary (ADR 0011), so the seam must be injected either way.
    result =
      Application.start(:normal,
        test?: false,
        config_dir: dir,
        env: %{},
        argv: [],
        interactive?: nil,
        halt: halt
      )

    assert result in [
             {:error, :interactive_setup_required},
             {:error, {:already_started, :unknown}}
           ] or
             match?({:error, {:already_started, _pid}}, result)

    if match?({:error, :interactive_setup_required}, result) do
      assert_received {:halted, 1}
    else
      refute_received {:halted, _}
    end
  end

  # ADR 0011: the headless refusal halts at the boot boundary, so the
  # {:error, _} return never reaches OTP (which is what terminates the kernel
  # and writes erl_crash.dump). The halt here THROWS: control must leave
  # Application.start/2 through the seam, so catching it proves the error
  # return was never produced. The no-dump assertion itself belongs to the
  # release smoke (.github/workflows/release.yml), the only place a real
  # start_permanent boot exists.
  test "a zero-profile headless boot refuses with instructions instead of a hung wizard" do
    dir = tmp_dir()
    halt = fn code -> throw({:halted, code}) end

    stderr =
      capture_io(:stderr, fn ->
        assert {:halted, 1} =
                 catch_throw(
                   Application.start(:normal,
                     test?: false,
                     config_dir: dir,
                     env: %{},
                     argv: [],
                     interactive?: false,
                     halt: halt
                   )
                 )
      end)

    assert stderr =~ "DashFloat needs an interactive terminal"
    assert stderr =~ "DASHFLOAT_API_KEY"
    # No files were written by the refused boot.
    settings = Path.join(dir, "settings.json5")
    refute File.exists?(settings)
  end

  # ADR 0011: the interactivity probe is the fd primitive (:prim_tty.isatty),
  # not :io.columns/1 — under a release's -noshell boot the latter is always
  # {:error, :enotsup} on stdin, tty or not. The mixed cases below are the
  # measured truths.
  describe "tty?/1" do
    test "true when only stdin is a tty" do
      isatty = fn
        :stdin -> true
        :stdout -> false
      end

      assert Application.tty?(isatty)
    end

    test "true when only stdout is a tty" do
      isatty = fn
        :stdin -> false
        :stdout -> true
      end

      assert Application.tty?(isatty)
    end

    test "false when neither fd is a tty" do
      isatty = fn _device -> false end
      refute Application.tty?(isatty)
    end
  end

  test "a headless boot with a complete env is fine — no setup needed" do
    dir = tmp_dir()

    env = %{
      "DASHFLOAT_BASE_URL" => "https://env.example/v1",
      "DASHFLOAT_MODEL" => "m",
      "DASHFLOAT_API_KEY" => "PLACEHOLDER-k"
    }

    assert {:error, {:already_started, _pid}} =
             Application.start(:normal,
               test?: false,
               config_dir: dir,
               env: env,
               argv: [],
               interactive?: false
             )
  end

  # ADR 0010: `--version` answers from the boot, before config load and
  # terminal setup, and exits. The exit is injected (`halt:`) because a real
  # `System.halt/1` would take the test VM with it; the rest of the path —
  # the NIF load, the write to stdout, the code — is the production code.
  describe "--version at boot (ADR 0010)" do
    test "writes the version to stdout and halts 0, before any config work" do
      parent = self()

      halt = fn code -> send(parent, {:halted, code}) end

      out =
        capture_io(fn ->
          # A config_dir that does not exist: classification would raise or
          # print setup instructions if the version path did NOT exit first.
          Application.start(:normal,
            test?: false,
            config_dir: "/nonexistent-dashfloat-version-#{System.unique_integer([:positive])}",
            env: %{},
            argv: ["--version"],
            interactive?: false,
            halt: halt
          )
        end)

      assert_received {:halted, 0}
      assert out == "dashfloat #{DashFloat.version()}\n"
    end

    test "a version query anywhere in argv still exits before config work" do
      parent = self()
      halt = fn code -> send(parent, {:halted, code}) end

      capture_io(fn ->
        Application.start(:normal,
          test?: false,
          config_dir: "/nonexistent-dashfloat-version-#{System.unique_integer([:positive])}",
          env: %{},
          argv: ["--profile", "work", "--version"],
          interactive?: false,
          halt: halt
        )
      end)

      assert_received {:halted, 0}
    end

    test "no version flag means no halt and the normal boot proceeds" do
      dir = v3_dir()
      parent = self()
      halt = fn code -> send(parent, {:halted, code}) end

      refute_received {:halted, _}

      Application.start(:normal,
        test?: false,
        config_dir: dir,
        env: %{},
        argv: [],
        interactive?: true,
        halt: halt
      )

      # The boot reached the supervisor and not the version exit.
      refute_received {:halted, _}
    end
  end

  # A release boots applications before Elixir parses `-extra` into
  # System.argv/0, so the plain init arguments are where the user's flags
  # actually appear (ADR 0010). Exercised through the plain_argv seam, which
  # stands in for them.
  describe "boot argv in a release (ADR 0010)" do
    test "the plain init arguments reach argv, so --version is seen" do
      parent = self()
      halt = fn code -> send(parent, {:halted, code}) end

      capture_io(fn ->
        Application.start(:normal,
          test?: false,
          config_dir: "/nonexistent-dashfloat-version-#{System.unique_integer([:positive])}",
          env: %{},
          plain_argv: ["--version"],
          system_argv: [],
          interactive?: false,
          halt: halt
        )
      end)

      assert_received {:halted, 0}
    end

    test "the launcher's own --no-halt is stripped from the plain arguments" do
      parent = self()
      halt = fn code -> send(parent, {:halted, code}) end

      capture_io(fn ->
        Application.start(:normal,
          test?: false,
          config_dir: "/nonexistent-dashfloat-version-#{System.unique_integer([:positive])}",
          env: %{},
          plain_argv: ["--no-halt", "--version"],
          system_argv: [],
          interactive?: false,
          halt: halt
        )
      end)

      # Reaching the version exit at all proves the plain arguments were
      # used; --no-halt was stripped rather than treated as a user flag.
      assert_received {:halted, 0}
    end
  end

  ## --resume at the boot seam (ADR 0014 §6)

  defp write_session_file(sessions, id, contents) do
    File.mkdir_p!(sessions)
    path = Path.join(sessions, id <> ".json")
    File.write!(path, contents)
    path
  end

  defp session_json(id, pin, messages) do
    Jason.encode!(%{
      version: 1,
      id: id,
      created_at: "2026-10-27T14:30:52Z",
      pin: pin,
      messages: messages
    })
  end

  # A titled session file as the store writes it (ADR 0014 §3's title field).
  defp titled_session_json(id, title, pin \\ %{profile: "work", model: "m1", base_url: nil}) do
    Jason.encode!(%{
      version: 1,
      id: id,
      created_at: "2026-10-27T14:30:52Z",
      title: title,
      pin: pin,
      messages: [%{"role" => "user", "content" => "hello"}]
    })
  end

  # Drives a real (non-test) boot with --resume. The halt is always the
  # recording seam: the refusal path halts at the boot boundary (ADR 0011),
  # and a real halt would take the test VM with it. The `:argv` opt
  # substitutes the flags wholesale (the --title boots).
  defp resume_boot(sessions, id, opts \\ []) do
    parent = self()
    halt = fn code -> send(parent, {:halted, code}) end

    stderr =
      capture_io(:stderr, fn ->
        result =
          Application.start(:normal,
            test?: false,
            config_dir: Keyword.get(opts, :config_dir, tmp_dir()),
            env: Keyword.get(opts, :env, %{}),
            argv: Keyword.get(opts, :argv, ["--resume", id]),
            sessions_dir: sessions,
            interactive?: true,
            halt: halt
          )

        send(parent, {:resume_boot, result})
      end)

    assert_received {:resume_boot, result}
    {result, stderr}
  end

  describe "--resume refusing the boot (ADR 0014 §6)" do
    test "an unknown id refuses on stderr naming the sessions dir, with no children" do
      sessions = tmp_dir()

      {result, stderr} = resume_boot(sessions, "0192aa01-2f3b-7c4d-9e5f-1a2b3c4d5e6f")

      assert {:error, :session_resume_failed} = result
      assert_received {:halted, 1}
      assert stderr =~ sessions
      assert stderr =~ "0192aa01-2f3b-7c4d-9e5f-1a2b3c4d5e6f"
      # The refusal returned before any child could start.
      refute Process.whereis(DashFloat.Agent)
      # A load never writes: the directory is still empty.
      assert File.ls!(sessions) == []
    end

    test "a missing sessions directory refuses the same way" do
      sessions = Path.join(tmp_dir(), "does-not-exist")

      {result, stderr} = resume_boot(sessions, "0192aa01-2f3b-7c4d-9e5f-1a2b3c4d5e6f")

      assert {:error, :session_resume_failed} = result
      assert_received {:halted, 1}
      assert stderr =~ sessions
      refute File.exists?(sessions)
    end

    test "a garbage file refuses loudly and stays byte-identical" do
      sessions = tmp_dir()
      id = "0192aa02-4a5b-7c6d-8e7f-2b3c4d5e6f7a"
      path = write_session_file(sessions, id, "definitely {{{ not json")
      before = File.read!(path)

      {result, stderr} = resume_boot(sessions, id)

      assert {:error, :session_resume_failed} = result
      assert_received {:halted, 1}
      assert stderr =~ path
      assert File.read!(path) == before
    end

    test "a truncated file refuses loudly and stays byte-identical" do
      sessions = tmp_dir()
      id = "0192aa03-6c7d-7c8e-9a9b-3c4d5e6f7a8b"

      path =
        write_session_file(
          sessions,
          id,
          ~s({"version": 1, "id": "0192aa03-6c7d-7c8e-9a9b-3c4d5e6f7a8b", "created_at": "2026-10-27T09:15:00Z", "mess)
        )

      before = File.read!(path)

      {result, stderr} = resume_boot(sessions, id)

      assert {:error, :session_resume_failed} = result
      assert_received {:halted, 1}
      assert stderr =~ path
      assert File.read!(path) == before
    end

    # A path that cannot be File.read is a deterministic refusal on every
    # filesystem when it is a directory — no chmod-000 and no root caveat
    # (the session_test pattern).
    test "a session path that is a directory refuses loudly and stays put" do
      sessions = tmp_dir()
      id = "0192aa04-8e9f-7c0a-8b8c-4d5e6f7a8b9c"
      path = Path.join(sessions, id <> ".json")
      File.mkdir!(path)

      {result, stderr} = resume_boot(sessions, id)

      assert {:error, :session_resume_failed} = result
      assert_received {:halted, 1}
      assert stderr =~ path
      assert File.dir?(path)
    end

    test "a version 2 file refuses naming the field and stays byte-identical" do
      sessions = tmp_dir()
      id = "0192aa05-a0b1-7c2b-9c9d-5e6f7a8b9c0d"

      contents =
        Jason.encode!(%{
          version: 2,
          id: id,
          created_at: "2026-10-27T09:45:00Z",
          pin: %{},
          messages: []
        })

      path = write_session_file(sessions, id, contents <> "\n")

      {result, stderr} = resume_boot(sessions, id)

      assert {:error, :session_resume_failed} = result
      assert_received {:halted, 1}
      assert stderr =~ ~s("version")
      assert File.read!(path) == contents <> "\n"
    end
  end

  describe "--resume handing off (ADR 0014 §6)" do
    test "a valid session boots to the children instead of refusing" do
      config_dir = v3_dir()
      sessions = tmp_dir()
      id = "0192aa06-c2d3-7c4c-8d8e-6f7a8b9c0d1e"

      write_session_file(
        sessions,
        id,
        session_json(id, %{profile: "work", model: "m1", base_url: nil}, [
          %{"role" => "user", "content" => "hello"}
        ])
      )

      {result, stderr} = resume_boot(sessions, id, config_dir: config_dir)

      assert {:error, {:already_started, _pid}} = result
      assert stderr == ""
      refute_received {:halted, _}
    end

    test "a pin mismatch warns naming both sides and rides to the TUI as the note" do
      config_dir = v3_dir()
      sessions = tmp_dir()
      id = "0192aa07-e4f5-7c5d-9e9f-7a8b9c0d1e2f"

      pin = %{profile: "personal", model: "glm-5.3", base_url: "https://elsewhere.example/v1"}

      write_session_file(
        sessions,
        id,
        session_json(id, pin, [%{"role" => "user", "content" => "hi"}])
      )

      {:ok, config} = Config.load(config_dir, %{}, [])

      logs =
        capture_log(fn ->
          {result, stderr} = resume_boot(sessions, id, config_dir: config_dir)
          assert {:error, {:already_started, _pid}} = result
          assert stderr == ""
        end)

      assert logs =~
               "resuming session pinned to profile personal, model glm-5.3 under active profile work, model m1"

      # The same note is what the boot hands the TUI, via the same pure
      # functions the boot composes.
      {:ok, session} = Session.load(sessions, id)
      note = Application.pin_note(session, {:ok, config})

      assert [{_task, _task_opts}, _agent, {DashFloat.TUI, tui_opts}] =
               Application.boot_children(
                 false,
                 {:ok, config},
                 config_dir,
                 %{},
                 [resume: id],
                 %{session: session, note: note},
                 sessions
               )

      assert tui_opts[:transcript] == session.messages
      assert tui_opts[:resume_note] == note
    end

    test "a matching pin hands off with no note, and the TUI mounts the transcript" do
      config_dir = v3_dir()
      sessions = tmp_dir()
      id = "0192aa08-0617-7c6e-8a8b-8b9c0d1e2f3a"
      messages = [%{"role" => "user", "content" => "picked up"}]

      write_session_file(
        sessions,
        id,
        session_json(id, %{profile: "work", model: "m1", base_url: nil}, messages)
      )

      {:ok, config} = Config.load(config_dir, %{}, [])

      assert {:ok, %{session: session, note: nil}} =
               Application.boot_resume([resume: id], {:ok, config}, sessions)

      assert [
               {Task.Supervisor, task_opts},
               {DashFloat.Agent, agent_opts},
               {DashFloat.TUI, tui_opts}
             ] =
               Application.boot_children(
                 false,
                 {:ok, config},
                 config_dir,
                 %{},
                 [resume: id],
                 %{session: session, note: nil},
                 sessions
               )

      assert task_opts == [name: DashFloat.TaskSupervisor]
      assert agent_opts[:provider] == {:ok, config}
      assert agent_opts[:session_dir] == sessions

      assert agent_opts[:resume] == %{
               id: id,
               pin: session.pin,
               messages: messages,
               created_at: session.created_at,
               context: session.context,
               compactions: session.compactions,
               title: session.title
             }

      assert agent_opts[:name] == DashFloat.Agent
      assert agent_opts[:supervisor] == DashFloat.TaskSupervisor
      assert tui_opts[:transcript] == messages
      assert tui_opts[:resume_note] == nil
    end

    test "a setup classification skips the pin compare but still hands the session off" do
      sessions = tmp_dir()
      id = "0192aa09-2839-7c7f-9b9c-9c0d1e2f3a4b"
      pin = %{profile: "personal", model: "glm-5.3", base_url: nil}

      write_session_file(
        sessions,
        id,
        session_json(id, pin, [%{"role" => "user", "content" => "hi"}])
      )

      assert {:ok, %{session: session, note: nil}} =
               Application.boot_resume([resume: id], {:select, ["a", "b"]}, sessions)

      assert session.pin == %{profile: "personal", model: "glm-5.3", base_url: nil}

      assert {:ok, %{note: nil}} = Application.boot_resume([resume: id], :onboard, sessions)
    end

    test "a hand-written dangling session hands off synthesized cancelled results" do
      config_dir = v3_dir()
      sessions = tmp_dir()
      id = "0192aa0a-4a5b-7c80-8c8d-0d1e2f3a4b5c"

      dangling =
        Jason.encode!(%{
          version: 1,
          id: id,
          created_at: "2026-10-27T15:00:00Z",
          pin: %{profile: "work", model: "m1", base_url: nil},
          messages: [
            %{"role" => "user", "content" => "start it"},
            %{
              "role" => "assistant",
              "content" => nil,
              "tool_calls" => [
                %{
                  "id" => "call_d1",
                  "type" => "function",
                  "function" => %{"name" => "write_file", "arguments" => "{}"}
                }
              ]
            }
          ]
        })

      path = write_session_file(sessions, id, dangling <> "\n")
      before = File.read!(path)

      {result, stderr} = resume_boot(sessions, id, config_dir: config_dir)

      assert {:error, {:already_started, _pid}} = result
      assert stderr == ""
      # The repair is in memory only: the file is untouched.
      assert File.read!(path) == before

      {:ok, session} = Session.load(sessions, id)
      {:ok, config} = Config.load(config_dir, %{}, [])

      assert [{_task, _task_opts}, {DashFloat.Agent, agent_opts}, _tui] =
               Application.boot_children(
                 false,
                 {:ok, config},
                 config_dir,
                 %{},
                 [resume: id],
                 %{session: session, note: nil},
                 sessions
               )

      assert [
               %{"role" => "user"},
               %{"role" => "assistant", "tool_calls" => [_call]},
               %{"role" => "tool", "tool_call_id" => "call_d1", "content" => repair}
             ] = agent_opts[:resume][:messages]

      assert Jason.decode!(repair) == %{"ok" => false, "cancelled" => true}
    end

    test "a boot without --resume mounts session_dir but no resume or transcript" do
      config_dir = v3_dir()
      {:ok, config} = Config.load(config_dir, %{}, [])

      assert [{_task, _task_opts}, {DashFloat.Agent, agent_opts}, {DashFloat.TUI, tui_opts}] =
               Application.boot_children(
                 false,
                 {:ok, config},
                 config_dir,
                 %{},
                 [],
                 nil,
                 "/tmp/opencode/some-sessions"
               )

      assert agent_opts[:session_dir] == "/tmp/opencode/some-sessions"
      assert agent_opts[:title] == nil
      refute Keyword.has_key?(agent_opts, :resume)
      refute Keyword.has_key?(tui_opts, :transcript)
      refute Keyword.has_key?(tui_opts, :resume_note)
    end
  end

  ## --title at the boot seam (ADR 0014 §6)

  describe "--title refusing the boot" do
    test "an empty or blank title refuses naming the flag, with no children" do
      sessions = tmp_dir()

      {result, stderr} = resume_boot(sessions, nil, argv: ["--title", "   "])

      assert {:error, :session_resume_failed} = result
      assert_received {:halted, 1}
      assert stderr =~ "--title may not be empty or blank"
      refute Process.whereis(DashFloat.Agent)
    end

    test "a title over 80 graphemes refuses" do
      sessions = tmp_dir()

      {result, stderr} = resume_boot(sessions, nil, argv: ["--title", String.duplicate("x", 81)])

      assert {:error, :session_resume_failed} = result
      assert_received {:halted, 1}
      assert stderr =~ "--title may not exceed 80 characters"
    end

    test "a UUID-shaped title refuses" do
      sessions = tmp_dir()

      {result, stderr} =
        resume_boot(sessions, nil, argv: ["--title", "0192ab4c-1e5f-7d3a-9b8c-2d4e6f8a1b3c"])

      assert {:error, :session_resume_failed} = result
      assert_received {:halted, 1}
      assert stderr =~ "--title may not look like a session id (UUID)"
    end

    test "a title another session holds refuses naming the holder and the remedy" do
      sessions = tmp_dir()
      holder = "0192aa10-8e2f-7c11-9a2b-1a2b3c4d5e01"
      write_session_file(sessions, holder, titled_session_json(holder, "My Title"))

      {result, stderr} = resume_boot(sessions, nil, argv: ["--title", "My Title"])

      assert {:error, :session_resume_failed} = result
      assert_received {:halted, 1}
      # The em dash double-encodes under capture_io (IO.binwrite sends latin1
      # data; the capture re-encodes), so the segments are asserted apart —
      # the same discipline as the unknown-id test above.
      assert stderr =~ ~s(title "My Title" is already taken by session #{holder})

      assert stderr =~
               "choose another title or resume that session; list sessions with: ls #{sessions}"

      refute Process.whereis(DashFloat.Agent)
    end
  end

  describe "--title with --resume: the boot-time rename" do
    test "the override threads to the agent opts while the resume map keeps the file's title" do
      config_dir = v3_dir()
      sessions = tmp_dir()
      id = "0192aa11-9031-7c22-8b3c-2b3c4d5e6f02"

      write_session_file(sessions, id, titled_session_json(id, "Old Name"))

      {result, stderr} =
        resume_boot(sessions, id,
          config_dir: config_dir,
          argv: ["--resume", id, "--title", "New Name"]
        )

      assert {:error, {:already_started, _pid}} = result
      assert stderr == ""
      refute_received {:halted, _}

      {:ok, session} = Session.load(sessions, id)
      {:ok, config} = Config.load(config_dir, %{}, [])

      assert [_task, {DashFloat.Agent, agent_opts}, _tui] =
               Application.boot_children(
                 false,
                 {:ok, config},
                 config_dir,
                 %{},
                 [resume: id, title: "New Name"],
                 %{session: session, note: nil},
                 sessions
               )

      assert agent_opts[:title] == "New Name"
      assert agent_opts[:resume][:title] == "Old Name"
    end

    test "a title another session holds refuses, naming that other session" do
      sessions = tmp_dir()
      target = "0192aa12-a254-7c33-9d4e-3c4d5e6f7a03"
      other = "0192aa13-b476-7c44-8f5f-4d5e6f7a8b04"

      write_session_file(sessions, target, titled_session_json(target, "Target"))
      write_session_file(sessions, other, titled_session_json(other, "Wanted"))

      {result, stderr} =
        resume_boot(sessions, target, argv: ["--resume", target, "--title", "Wanted"])

      assert {:error, :session_resume_failed} = result
      assert_received {:halted, 1}
      assert stderr =~ ~s(title "Wanted" is already taken by session #{other})
      refute Process.whereis(DashFloat.Agent)
    end

    test "re-taking the session's own current title proceeds" do
      sessions = tmp_dir()
      id = "0192aa14-c698-7d55-9170-5e6f7a8b9c05"

      write_session_file(sessions, id, titled_session_json(id, "Same"))

      {result, stderr} = resume_boot(sessions, id, argv: ["--resume", id, "--title", "Same"])

      assert {:error, {:already_started, _pid}} = result
      assert stderr == ""
      refute_received {:halted, _}
    end
  end

  describe "title threading to the agent opts" do
    test "a fresh --title boots and the built children carry the title opt" do
      config_dir = v3_dir()
      sessions = tmp_dir()

      {result, stderr} =
        resume_boot(sessions, nil, config_dir: config_dir, argv: ["--title", "Fresh Start"])

      assert {:error, {:already_started, _pid}} = result
      assert stderr == ""

      {:ok, config} = Config.load(config_dir, %{}, [])

      assert [_task, {DashFloat.Agent, agent_opts}, _tui] =
               Application.boot_children(
                 false,
                 {:ok, config},
                 config_dir,
                 %{},
                 [title: "Fresh Start"],
                 nil,
                 sessions
               )

      assert agent_opts[:title] == "Fresh Start"
      refute Keyword.has_key?(agent_opts, :resume)
    end

    test "a titled resume file carries its title in both the resume map and the opt" do
      config_dir = v3_dir()
      sessions = tmp_dir()
      id = "0192aa15-e1da-7d66-a281-6f7a8b9c0d06"

      write_session_file(sessions, id, titled_session_json(id, "The Title"))

      {:ok, session} = Session.load(sessions, id)
      {:ok, config} = Config.load(config_dir, %{}, [])

      assert [_task, {DashFloat.Agent, agent_opts}, _tui] =
               Application.boot_children(
                 false,
                 {:ok, config},
                 config_dir,
                 %{},
                 [resume: id],
                 %{session: session, note: nil},
                 sessions
               )

      assert agent_opts[:title] == "The Title"
      assert agent_opts[:resume][:title] == "The Title"
    end

    test "the storage form threads: a typed title arrives trimmed and collapsed" do
      config_dir = v3_dir()
      sessions = tmp_dir()

      # The gate (apply_title) normalizes only to refuse; the threading
      # normalizes again so the agent adopts the storage form, never the
      # typed form.
      {result, stderr} =
        resume_boot(sessions, nil,
          config_dir: config_dir,
          argv: ["--title", "  Spaced   Name  "]
        )

      assert {:error, {:already_started, _pid}} = result
      assert stderr == ""

      {:ok, config} = Config.load(config_dir, %{}, [])

      assert [_task, {DashFloat.Agent, agent_opts}, _tui] =
               Application.boot_children(
                 false,
                 {:ok, config},
                 config_dir,
                 %{},
                 [title: "  Spaced   Name  "],
                 nil,
                 sessions
               )

      assert agent_opts[:title] == "Spaced Name"
    end
  end

  describe "the legacy-id sweep at boot (ADR 0014 §6)" do
    test "a timestamp-named file is UUID-renamed before title resolution runs" do
      sessions = tmp_dir()
      legacy = "20261027-143052-a1b2c3"

      write_session_file(sessions, legacy, titled_session_json(legacy, "Legacy Title"))

      {result, stderr} =
        resume_boot(sessions, nil, argv: ["--resume", "Legacy Title"])

      assert {:error, {:already_started, _pid}} = result
      assert stderr == ""

      # The sweep ran before resolution: one UUID-named file, id field equal
      # to its name, title preserved — and resolution found it by title.
      [name] = File.ls!(sessions)
      new_id = Path.rootname(name)
      {:ok, session} = Session.load(sessions, new_id)
      assert session.id == new_id
      assert session.title == "Legacy Title"

      old_path = Path.join(sessions, legacy <> ".json")
      refute File.exists?(old_path)
    end

    test "a missing sessions directory sweeps as a silent no-op and the boot refuses on the id" do
      sessions = Path.join(tmp_dir(), "does-not-exist")
      id = "0192aa16-f3ec-7d77-b392-7a8b9c0d1e07"

      logs =
        capture_log(fn ->
          {result, stderr} = resume_boot(sessions, id)

          assert {:error, :session_resume_failed} = result
          assert_received {:halted, 1}
          assert stderr =~ "no session #{id} under #{sessions}"
        end)

      refute logs =~ "renamed"
      refute logs =~ "sweep skipped"
    end

    test "a sweep that cannot write warns and the boot continues" do
      config_dir = v3_dir()
      sessions = tmp_dir()
      legacy = "20261027-150000-abc123"

      write_session_file(sessions, legacy, titled_session_json(legacy, "Stuck"))

      # The write inside the sweep needs directory write permission (the
      # Posture staging file); read-only makes the rewrite fail. The warning
      # arm must not brick the boot — resume still works, the next boot
      # retries. Restored before the tmp cleanup (on_exit runs reversed).
      File.chmod!(sessions, 0o555)
      on_exit(fn -> File.chmod!(sessions, 0o755) end)

      id = "0192aa18-1a2b-7e99-d5b4-9c0d1e2f3a09"

      logs =
        capture_log(fn ->
          {result, stderr} =
            resume_boot(sessions, id, config_dir: config_dir, argv: ["--resume", id])

          # The boot ran to resolution (the unknown-id refusal, not a sweep
          # crash) — the sweep degraded to a warning.
          assert {:error, :session_resume_failed} = result
          assert_received {:halted, 1}
          assert stderr =~ "no session #{id} under #{sessions}"
        end)

      assert logs =~ "legacy session id sweep skipped"

      legacy_path = Path.join(sessions, legacy <> ".json")
      assert File.exists?(legacy_path)
    end
  end

  describe "--resume by title (ADR 0014 §6)" do
    test "a titled session resolves and the transcript threads to the TUI mount opts" do
      config_dir = v3_dir()
      sessions = tmp_dir()
      id = "0192aa17-05fd-7e88-c4a3-8b9c0d1e2f08"
      messages = [%{"role" => "user", "content" => "from the titled file"}]
      pin = %{profile: "work", model: "m1", base_url: nil}

      contents =
        Jason.encode!(%{
          version: 1,
          id: id,
          created_at: "2026-10-27T14:30:52Z",
          title: "My Title",
          pin: pin,
          messages: messages
        })

      write_session_file(sessions, id, contents)

      {result, stderr} =
        resume_boot(sessions, nil, argv: ["--resume", "My Title"], config_dir: config_dir)

      assert {:error, {:already_started, _pid}} = result
      assert stderr == ""

      {:ok, session} = Session.load(sessions, id)
      {:ok, config} = Config.load(config_dir, %{}, [])

      assert [_task, _agent, {DashFloat.TUI, tui_opts}] =
               Application.boot_children(
                 false,
                 {:ok, config},
                 config_dir,
                 %{},
                 [resume: "My Title"],
                 %{session: session, note: nil},
                 sessions
               )

      assert tui_opts[:transcript] == messages
    end

    test "a case- and whitespace-different title still resolves" do
      sessions = tmp_dir()
      id = "0192aa18-170e-7e99-d5b4-9c0d1e2f3a09"

      write_session_file(sessions, id, titled_session_json(id, "My Title"))

      {result, stderr} =
        resume_boot(sessions, nil, argv: ["--resume", "  my title "])

      assert {:error, {:already_started, _pid}} = result
      assert stderr == ""
    end

    test "an unknown title refuses naming the value as typed and the directory" do
      sessions = tmp_dir()

      {result, stderr} = resume_boot(sessions, nil, argv: ["--resume", "Ghost Title"])

      assert {:error, :session_resume_failed} = result
      assert_received {:halted, 1}
      # Segments apart — the em dash double-encodes under capture_io.
      assert stderr =~ ~s(no session titled "Ghost Title" under #{sessions})
      assert stderr =~ "list sessions with: ls #{sessions}"

      refute Process.whereis(DashFloat.Agent)
    end

    test "an ambiguous title refuses naming both ids, sorted" do
      sessions = tmp_dir()
      low = "0192aa20-3a30-7eaa-e6c5-0d1e2f3a4b20"
      high = "0192aa21-4b41-7fbb-f7d6-1e2f3a4b5c21"

      # Written high-first: the refusal must name them sorted.
      write_session_file(sessions, high, titled_session_json(high, "Dup"))
      write_session_file(sessions, low, titled_session_json(low, "Dup"))

      {result, stderr} = resume_boot(sessions, nil, argv: ["--resume", "Dup"])

      assert {:error, :session_resume_failed} = result
      assert_received {:halted, 1}
      # Segments apart — the em dash double-encodes under capture_io.
      assert stderr =~ ~s(multiple sessions are titled "Dup": #{low}, #{high})
      assert stderr =~ "resume one by its id; list sessions with: ls #{sessions}"
    end

    test "a legacy timestamp id takes the title path and refuses as a title" do
      sessions = tmp_dir()

      {result, stderr} =
        resume_boot(sessions, nil, argv: ["--resume", "20261027-143052-a1b2c3"])

      assert {:error, :session_resume_failed} = result
      assert_received {:halted, 1}

      assert stderr =~
               ~s(no session titled "20261027-143052-a1b2c3" under #{sessions})

      refute Process.whereis(DashFloat.Agent)
    end
  end

  # The kill round-trip, asserted through the boot seam (ADR 0014 §6). The
  # SSE framing mirrors agent_test's: the test process plays the UI and the
  # loopback server proves what the model receives.
  @headers "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\nconnection: close\r\n\r\n"

  defp frame(content) do
    ~s(data: {"choices":[{"index":0,"delta":{"content":"#{content}"}}]}\n\n)
  end

  defp tool_frames(id, name, arg_fragments) do
    opening =
      ~s(data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"#{id}","type":"function","function":{"name":"#{name}","arguments":""}}]}}]}\n\n)

    rest =
      for frag <- arg_fragments do
        ~s(data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":#{Jason.encode!(frag)}}}]}}]}\n\n)
      end

    [opening | rest]
  end

  defp call_tool_episode(id, name, args) do
    frames = tool_frames(id, name, [Jason.encode!(args)])
    [{:send, [@headers | frames]}, {:send, "data: [DONE]\n\n"}, :close]
  end

  defp final_episode(text) do
    [{:send, [@headers, frame(text)]}, {:send, "data: [DONE]\n\n"}, :close]
  end

  defp start_server(scripts) do
    {:ok, server} = SSEServer.start_link(:per_connection, scripts)
    on_exit(fn -> DashFloat.TestTeardown.stop(server) end)
    server
  end

  # Slice-2-shaped direct start for the kill phase; the resume phase starts
  # its agent with the boot's own agent opts.
  defp start_agent(server, cwd, sessions) do
    {:ok, sup} = Task.Supervisor.start_link()

    {:ok, agent} =
      Agent.start_link(
        provider:
          {:ok,
           %Config{
             base_url: SSEServer.base_url(server),
             model: "test-model",
             api_key: "test-key-123"
           }},
        cwd: cwd,
        exec_timeout: 500,
        supervisor: sup,
        session_dir: sessions,
        name: nil
      )

    on_exit(fn ->
      DashFloat.TestTeardown.stop(agent)
      if Process.alive?(sup), do: Process.exit(sup, :kill)
    end)

    {agent, sup}
  end

  defp session_id(dir) do
    [file] = File.ls!(dir)
    Path.rootname(file)
  end

  defp request_messages(body) do
    body
    |> Jason.decode!()
    |> Map.fetch!("messages")
  end

  test "the kill round-trip through the boot seam: --resume hands the repaired transcript to a fresh agent" do
    args = %{"path" => "out/booted.txt", "content" => "finished from the boot"}

    server =
      start_server([
        call_tool_episode("call_boot", "write_file", args),
        final_episode("finished from the resumed boot")
      ])

    sandbox = tmp_dir()
    sessions = Path.join(tmp_dir(), "sessions")
    {agent, sup} = start_agent(server, sandbox, sessions)

    send(agent, {:prompt, self(), "start the job"})
    assert_receive {:sse_request, "POST", _, _, _first}, 2_000
    assert_receive {:confirm, _ref, %{id: "call_boot"}}, 2_000

    # Uncatchable: no terminate runs, so the on-disk truth stays the dangling
    # batch (ADR 0014 test plan 2). Unlink first: this process started it.
    # The supervisor dies with the agent's tasks via on_exit — killing it
    # here would ride its link back into this process.
    Process.unlink(agent)
    Process.exit(agent, :kill)

    id = session_id(sessions)

    # A real --resume boot: parses the flag, loads the session, reaches the
    # children build (the named supervisor is already running under the test
    # boot, so the start lands on already_started — the wiring ran).
    env = %{
      "DASHFLOAT_BASE_URL" => SSEServer.base_url(server),
      "DASHFLOAT_MODEL" => "test-model",
      "DASHFLOAT_API_KEY" => "PLACEHOLDER-k"
    }

    {result, stderr} = resume_boot(sessions, id, config_dir: Path.dirname(sessions), env: env)

    assert {:error, {:already_started, _pid}} = result
    assert stderr == ""

    # The hand-off start/2 builds, instantiated through the same public
    # functions it calls.
    config_dir = Path.dirname(sessions)
    {:ok, config} = Config.load(config_dir, env, resume: id)

    {:ok, resume} = Application.boot_resume([resume: id], {:ok, config}, sessions)
    assert %{note: nil} = resume

    assert [_task, {DashFloat.Agent, agent_opts}, _tui] =
             Application.boot_children(
               false,
               {:ok, config},
               config_dir,
               env,
               [resume: id],
               resume,
               sessions
             )

    assert agent_opts[:session_dir] == sessions

    # A fresh agent on exactly the boot's agent opts (name and supervisor
    # re-pointed for the harness).
    {:ok, fresh_sup} = Task.Supervisor.start_link()

    fresh_opts = Keyword.merge(agent_opts, name: nil, supervisor: fresh_sup, cwd: sandbox)
    {:ok, resumed} = Agent.start_link(fresh_opts)

    on_exit(fn ->
      DashFloat.TestTeardown.stop(resumed)
      if Process.alive?(fresh_sup), do: Process.exit(fresh_sup, :kill)
    end)

    send(resumed, {:prompt, self(), "finish it"})
    assert_receive {:sse_request, "POST", _, _, body}, 2_000

    assert [
             %{"role" => "system"},
             %{"role" => "user", "content" => "start the job"},
             %{"role" => "assistant", "content" => nil, "tool_calls" => [call]},
             %{"role" => "tool", "tool_call_id" => "call_boot", "content" => content},
             %{"role" => "user", "content" => "finish it"}
           ] = request_messages(body)

    assert call["id"] == "call_boot"
    assert Jason.decode!(content) == %{"ok" => false, "cancelled" => true}

    assert_receive {:phase, :idle}, 2_000

    # The next save rewrites the same file under the same id.
    assert session_id(sessions) == id

    {:ok, next} = Session.load(sessions, id)
    assert length(next.messages) == 6
    assert List.last(next.messages)["content"] == "finished from the resumed boot"

    # The hand-off write chain never sees the key (env api_key above).
    bytes =
      sessions
      |> Path.join(id <> ".json")
      |> File.read!()

    refute bytes =~ "PLACEHOLDER-k"
  end
end
