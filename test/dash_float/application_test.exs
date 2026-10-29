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

  # chmod-000 assertions are meaningless for root.
  setup :skip_permission_test_for_root

  defp skip_permission_test_for_root(context) do
    if context[:skip_if_root] && root?() do
      {:skip, "chmod-000 is not a permission barrier for root"}
    else
      :ok
    end
  end

  defp root? do
    case System.cmd("id", ["-u"]) do
      {"0\n", 0} -> true
      _other -> false
    end
  end

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

  # Drives a real (non-test) boot with --resume. The halt is always the
  # recording seam: the refusal path halts at the boot boundary (ADR 0011),
  # and a real halt would take the test VM with it.
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
            argv: ["--resume", id],
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

      {result, stderr} = resume_boot(sessions, "20990101-000000-000000")

      assert {:error, :session_resume_failed} = result
      assert_received {:halted, 1}
      assert stderr =~ sessions
      assert stderr =~ "20990101-000000-000000"
      # The refusal returned before any child could start.
      refute Process.whereis(DashFloat.Agent)
      # A load never writes: the directory is still empty.
      assert File.ls!(sessions) == []
    end

    test "a missing sessions directory refuses the same way" do
      sessions = Path.join(tmp_dir(), "does-not-exist")

      {result, stderr} = resume_boot(sessions, "20990101-000000-000000")

      assert {:error, :session_resume_failed} = result
      assert_received {:halted, 1}
      assert stderr =~ sessions
      refute File.exists?(sessions)
    end

    test "a garbage file refuses loudly and stays byte-identical" do
      sessions = tmp_dir()
      id = "20261027-090000-abc123"
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
      id = "20261027-091500-bcd234"

      path =
        write_session_file(
          sessions,
          id,
          ~s({"version": 1, "id": "20261027-091500-bcd234", "created_at": "2026-10-27T09:15:00Z", "mess)
        )

      before = File.read!(path)

      {result, stderr} = resume_boot(sessions, id)

      assert {:error, :session_resume_failed} = result
      assert_received {:halted, 1}
      assert stderr =~ path
      assert File.read!(path) == before
    end

    @tag :skip_if_root
    test "an unreadable file refuses loudly and stays byte-identical" do
      sessions = tmp_dir()
      id = "20261027-093000-cde345"
      contents = session_json(id, %{}, [])
      path = write_session_file(sessions, id, contents)
      File.chmod!(path, 0)

      on_exit(fn -> File.chmod!(path, 0o600) end)

      if File.read(path) == {:error, :eacces} do
        {result, stderr} = resume_boot(sessions, id)

        assert {:error, :session_resume_failed} = result
        assert_received {:halted, 1}
        assert stderr =~ path

        File.chmod!(path, 0o600)
        assert File.read!(path) == contents
      end
    end

    test "a version 2 file refuses naming the field and stays byte-identical" do
      sessions = tmp_dir()
      id = "20261027-094500-def456"

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
      id = "20261027-140000-ef1234"

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
      id = "20261027-143000-cd9911"

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
      id = "20261027-141500-ab7712"
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
               created_at: session.created_at
             }

      assert agent_opts[:name] == DashFloat.Agent
      assert agent_opts[:supervisor] == DashFloat.TaskSupervisor
      assert tui_opts[:transcript] == messages
      assert tui_opts[:resume_note] == nil
    end

    test "a setup classification skips the pin compare but still hands the session off" do
      sessions = tmp_dir()
      id = "20261027-144500-ab5678"
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
      id = "20261027-150000-be6789"

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
      refute Keyword.has_key?(agent_opts, :resume)
      refute Keyword.has_key?(tui_opts, :transcript)
      refute Keyword.has_key?(tui_opts, :resume_note)
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
    assert length(next.messages) == 5
    assert List.last(next.messages)["content"] == "finished from the resumed boot"

    # The hand-off write chain never sees the key (env api_key above).
    bytes =
      sessions
      |> Path.join(id <> ".json")
      |> File.read!()

    refute bytes =~ "PLACEHOLDER-k"
  end
end
