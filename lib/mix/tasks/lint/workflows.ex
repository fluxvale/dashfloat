defmodule Mix.Tasks.Lint.Workflows do
  @shortdoc "Lints GitHub workflow files and shell scripts (actionlint + shellcheck)"

  @moduledoc """
  The repo-lint step of `mix ci` ([ADR 0030](../../../docs/decisions/0030-actionlint-inside-the-ci-gate.md)):
  actionlint over every `.github/workflows/*.yml` — with shellcheck
  integration on each `run:` block — and shellcheck over the repo's own
  scripts (`install.sh` and `scripts/*.sh`). Both binaries are pinned and
  fetched by `DashFloat.PinnedTool`: the gate never lints with whatever
  happens to be on PATH, and it never skips — a tool that cannot be
  obtained, or a file with findings, reds `mix ci` instead of passing
  through a silent gap.
  """

  use Mix.Task
  alias DashFloat.PinnedTool

  @impl Mix.Task
  @spec run([String.t()]) :: :ok | no_return()
  def run(_argv) do
    with {:ok, actionlint} <- PinnedTool.fetch(:actionlint),
         {:ok, shellcheck} <- PinnedTool.fetch(:shellcheck) do
      workflows = Path.wildcard(".github/workflows/*.yml")
      scripts = Enum.filter(["install.sh" | Path.wildcard("scripts/*.sh")], &File.exists?/1)

      run!(actionlint, ["-shellcheck", shellcheck | workflows], "actionlint")
      run!(shellcheck, scripts, "shellcheck")
    else
      {:error, reason} -> Mix.raise("lint tools unavailable: #{reason}")
    end
  end

  # Both tools exit 1 for findings and 0 clean; anything else is the tool
  # itself refusing to run (actionlint, e.g., exits 3 on unreadable input).
  defp run!(bin, args, label) do
    case System.cmd(bin, args, stderr_to_stdout: true) do
      {_out, 0} ->
        Mix.shell().info("#{label}: clean")

      {out, 1} ->
        Mix.raise("#{label} found problems:\n\n#{out}")

      {out, code} ->
        Mix.raise("#{label} exited with status #{code}:\n\n#{out}")
    end
  end
end
