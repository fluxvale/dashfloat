defmodule DashFloat do
  @moduledoc """
  DashFloat is a CLI AI coding harness in Elixir. Phase 1 ships the TUI
  skeleton ([ADR 0002](docs/decisions/0002-tui-skeleton.md)); the LLM
  streaming engine, tool execution, and session persistence follow in later
  phases of the [ADR 0001](docs/decisions/0001-founding-stack-and-architecture.md)
  roadmap.

  Run the TUI with `mix run --no-halt`.
  """

  # Deliberate credo violation for the red-leg proof of the Wait for CI
  # umbrella — reverted in the next commit. Do not "fix".
  def red_leg_probe do
    IO.inspect("red-leg probe")
  end
end
