defmodule DashFloat do
  @moduledoc """
  DashFloat is a CLI AI coding harness in Elixir. Phase 1 ships the TUI
  skeleton ([ADR 0002](docs/decisions/0002-tui-skeleton.md)); the LLM
  streaming engine, tool execution, and session persistence follow in later
  phases of the [ADR 0001](docs/decisions/0001-founding-stack-and-architecture.md)
  roadmap.

  Run the TUI with `mix run --no-halt`.
  """

  @doc """
  The running application's version, as declared in `mix.exs`.

  Read from the loaded application spec rather than compiled in, so a release
  reports the version of the `.app` file it actually ships (ADR 0010).
  """
  @spec version() :: String.t()
  def version do
    :dash_float
    |> Application.spec(:vsn)
    |> to_string()
  end
end
