defmodule DashFloat.Application do
  @moduledoc false

  use Application

  @impl Application
  def start(_type, _args) do
    # Selection flags (--profile/--model) are parsed once here (ADR 0008);
    # both children below must agree on the same selection. Parsed only
    # outside test (mix's own argv must not produce warnings).
    cli = if test_env?(), do: [], else: DashFloat.CLI.parse(System.argv())

    children = [
      # Streams and tool runners: temporary tasks under one supervisor
      # (renamed from StreamSupervisor in ADR 0007 — it hosts both kinds).
      {Task.Supervisor, name: DashFloat.TaskSupervisor}
      | engine_children(cli) ++ tui_child(cli)
    ]

    opts = [strategy: :one_for_one, name: DashFloat.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # The agent owns the conversation and the tool loop; it is started with the
  # loaded provider config outside test (tests start their own agents, ADR 0007).
  defp engine_children(cli) do
    if test_env?() do
      []
    else
      [
        {DashFloat.Agent,
         provider: DashFloat.Config.load(cli),
         name: DashFloat.Agent,
         supervisor: DashFloat.TaskSupervisor}
      ]
    end
  end

  # The TUI owns the real terminal; `mix test` must never start it. Releases
  # don't ship Mix, so the guard keeps working in production (ADR 0002).
  # Provider config is loaded here, once, so the UI process performs no file
  # I/O (ADR 0005); the agent name rides in as a mount opt (ADR 0007).
  defp tui_child(cli) do
    if test_env?() do
      []
    else
      [{DashFloat.TUI, provider: DashFloat.Config.load(cli), agent: DashFloat.Agent}]
    end
  end

  defp test_env? do
    Code.ensure_loaded?(Mix) and function_exported?(Mix, :env, 0) and Mix.env() == :test
  end
end
