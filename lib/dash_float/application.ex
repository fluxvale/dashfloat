defmodule DashFloat.Application do
  @moduledoc false

  use Application

  @impl Application
  def start(_type, _args) do
    children = [
      {Task.Supervisor, name: DashFloat.StreamSupervisor}
      | tui_child()
    ]

    opts = [strategy: :one_for_one, name: DashFloat.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # The TUI owns the real terminal; `mix test` must never start it. Releases
  # don't ship Mix, so the guard keeps working in production (ADR 0002).
  # Provider config is loaded here, once, so the UI process performs no file
  # I/O (ADR 0005).
  defp tui_child do
    if Code.ensure_loaded?(Mix) and function_exported?(Mix, :env, 0) and Mix.env() == :test do
      []
    else
      [{DashFloat.TUI, provider: DashFloat.Config.load()}]
    end
  end
end
