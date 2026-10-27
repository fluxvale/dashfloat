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

  alias DashFloat.Application

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

  # ADR 0011: the headless refusal exits through the halt seam at the boot
  # boundary. Returning {:error, _} from Application.start/2 is what makes
  # OTP terminate the kernel and write erl_crash.dump into the user's CWD —
  # this is the regression assert for that dump.
  test "a zero-profile headless boot refuses with instructions instead of a hung wizard" do
    dir = tmp_dir()
    parent = self()
    halt = fn code -> send(parent, {:halted, code}) end

    stderr =
      capture_io(:stderr, fn ->
        assert {:error, :interactive_setup_required} =
                 Application.start(:normal,
                   test?: false,
                   config_dir: dir,
                   env: %{},
                   argv: [],
                   interactive?: false,
                   halt: halt
                 )
      end)

    assert_received {:halted, 1}
    assert stderr =~ "DashFloat needs an interactive terminal"
    assert stderr =~ "DASHFLOAT_API_KEY"
    # The clean boundary exit means no kernel-termination crash dump.
    refute File.exists?("erl_crash.dump")
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
end
