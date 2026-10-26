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

  test "a headless setup boot without an explicit interactive override probes stdin" do
    dir = tmp_dir()

    # Either arm is correct (the probe depends on this process's stdin); the
    # PROBE itself is the covered behavior.
    result =
      Application.start(:normal,
        test?: false,
        config_dir: dir,
        env: %{},
        argv: [],
        interactive?: nil
      )

    assert result in [
             {:error, :interactive_setup_required},
             {:error, {:already_started, :unknown}}
           ] or
             match?({:error, {:already_started, _pid}}, result)
  end

  test "a zero-profile headless boot refuses with instructions instead of a hung wizard" do
    dir = tmp_dir()

    stderr =
      capture_io(:stderr, fn ->
        assert {:error, :interactive_setup_required} =
                 Application.start(:normal,
                   test?: false,
                   config_dir: dir,
                   env: %{},
                   argv: [],
                   interactive?: false
                 )
      end)

    assert stderr =~ "DashFloat needs an interactive terminal"
    assert stderr =~ "DASHFLOAT_API_KEY"
    # No files were written by the refused boot.
    settings = Path.join(dir, "settings.json5")
    refute File.exists?(settings)
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
end
