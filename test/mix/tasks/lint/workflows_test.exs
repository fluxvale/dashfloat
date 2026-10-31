defmodule Mix.Tasks.Lint.WorkflowsTest do
  @moduledoc false
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias DashFloat.PinnedTool
  alias Mix.Tasks.Lint.Workflows

  # The task discovers workflows and scripts relative to the cwd and its
  # tool cache via DASHFLOAT_TOOL_ROOT, so each test runs inside a scratch
  # project (VM-global cwd: hence async: false) with a seeded cache of stub
  # binaries. A seeded cache means the suite never downloads anything —
  # only the real gate does that.
  setup do
    previous = System.get_env("DASHFLOAT_TOOL_ROOT")
    project = project_dir()

    on_exit(fn ->
      if previous,
        do: System.put_env("DASHFLOAT_TOOL_ROOT", previous),
        else: System.delete_env("DASHFLOAT_TOOL_ROOT")

      File.rm_rf(project)
    end)

    {:ok, project: project}
  end

  test "clean tools make the step clean", %{project: project} do
    seed_cache(actionlint: "exit 0", shellcheck: "exit 0")

    output =
      File.cd!(project, fn ->
        capture_io(fn -> assert Workflows.run([]) == :ok end)
      end)

    assert output =~ "actionlint: clean"
    assert output =~ "shellcheck: clean"
  end

  # The stub refuses to run (exit 3) unless a .yaml workflow is on its argv,
  # so a re-narrowed glob (back to *.yml) can never pass this test silently.
  test "a .yaml workflow reaches actionlint", %{project: project} do
    seed_cache(
      actionlint: ~s{case "$*" in *deploy.yaml*) exit 0;; *) exit 3;; esac},
      shellcheck: "exit 0"
    )

    output =
      File.cd!(project, fn ->
        capture_io(fn -> assert Workflows.run([]) == :ok end)
      end)

    assert output =~ "actionlint: clean"
  end

  test "actionlint findings red the step", %{project: project} do
    seed_cache(actionlint: "echo 'bad.yml:1:1: boom'; exit 1", shellcheck: "exit 0")

    File.cd!(project, fn ->
      assert_raise Mix.Error, ~r/actionlint found problems.*boom/s, fn ->
        capture_io(:stderr, fn -> Workflows.run([]) end)
      end
    end)
  end

  test "shellcheck findings red the step", %{project: project} do
    seed_cache(actionlint: "exit 0", shellcheck: "echo 'install.sh:3:1: bad'; exit 1")

    File.cd!(project, fn ->
      assert_raise Mix.Error, ~r/shellcheck found problems.*bad/s, fn ->
        capture_io(:stderr, fn -> Workflows.run([]) end)
      end
    end)
  end

  test "a tool refusing to run (not findings) reds the step with its status", %{project: project} do
    seed_cache(actionlint: "exit 3", shellcheck: "exit 0")

    File.cd!(project, fn ->
      assert_raise Mix.Error, ~r/actionlint exited with status 3/, fn ->
        capture_io(:stderr, fn -> Workflows.run([]) end)
      end
    end)
  end

  test "an unavailable tool cache reds the step instead of skipping", %{project: project} do
    blocker = tmp_path("blocker")
    File.write!(blocker, "a file where the cache root should be")
    System.put_env("DASHFLOAT_TOOL_ROOT", blocker)

    File.cd!(project, fn ->
      assert_raise Mix.Error, ~r/lint tools unavailable/, fn ->
        capture_io(:stderr, fn -> Workflows.run([]) end)
      end
    end)
  end

  defp project_dir do
    dir = tmp_path("project")
    workflows = Path.join([dir, ".github", "workflows"])
    File.mkdir_p!(workflows)
    ci_yml = Path.join(workflows, "ci.yml")
    File.write!(ci_yml, "on: push\n")
    deploy_yaml = Path.join(workflows, "deploy.yaml")
    File.write!(deploy_yaml, "on: push\n")
    install_sh = Path.join(dir, "install.sh")
    File.write!(install_sh, "#!/bin/sh\nexit 0\n")
    dir
  end

  # Seeds the default cache root with executable stubs whose markers name
  # the real pin for this host platform, exactly the state a previous real
  # run leaves behind.
  defp seed_cache(stubs) do
    root = tmp_path("toolroot")
    System.put_env("DASHFLOAT_TOOL_ROOT", root)

    {:ok, platform} = host_platform()

    for {tool, body} <- stubs do
      version = PinnedTool.version(tool)
      bin = Path.join([root, "#{tool}-#{version}", "bin", Atom.to_string(tool)])
      bin_dir = Path.dirname(bin)
      File.mkdir_p!(bin_dir)
      File.write!(bin, "#!/bin/sh\n#{body}\n")
      File.chmod!(bin, 0o755)
      File.write!(bin <> ".sha256", PinnedTool.expected_sha(tool, platform))
    end
  end

  defp host_platform do
    case PinnedTool.normalize(:os.type(), to_string(:erlang.system_info(:system_architecture))) do
      nil -> flunk("no supported platform on this test host")
      platform -> {:ok, platform}
    end
  end

  defp tmp_path(kind) do
    Path.join(
      System.tmp_dir!(),
      "dashfloat-lint-workflows-#{kind}-#{System.unique_integer([:positive])}"
    )
  end
end
