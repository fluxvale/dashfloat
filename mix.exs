defmodule DashFloat.MixProject do
  use Mix.Project

  def project do
    [
      app: :dash_float,
      version: "0.0.0",
      elixir: "~> 1.20.0",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      aliases: aliases(),
      deps: deps(),
      # coveralls.multiple writes cover/excoveralls.json (Codecov) and
      # cover/excoveralls.html (CI artifact) from one suite run
      test_coverage: [tool: ExCoveralls],
      # PLT in priv/plts (gitignored), exact-version CI cache key. :mix — the
      # TUI guards a test-only path with Code.ensure_loaded?(Mix) + Mix.env/0,
      # which needs :mix in the PLT or dialyzer reports a false unknown function
      dialyzer: [
        plt_add_apps: [:mix],
        plt_file: {:no_warn, "priv/plts/project.plt"},
        list_unused_filters: true
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {DashFloat.Application, []}
    ]
  end

  def cli do
    [
      # excoveralls is only: :test, so its @preferred_cli_env can't be read
      # before the dep loads — pin here or a dev-env `mix ci` dies with
      # "task could not be found". `ci: :test` covers every task inside the
      # alias; the coveralls entries cover a direct invocation.
      preferred_envs: [
        ci: :test,
        coveralls: :test,
        "coveralls.multiple": :test
      ]
    ]
  end

  defp deps do
    [
      {:burrito, "~> 1.6"},
      {:ex_ratatui, "~> 0.17.1"},
      {:jason, "~> 1.4"},
      {:req, "~> 0.7.5"},
      # Dev/test-only analysis tools
      # Exact pin, matching the fleet reference — the enumerated .credo.exs
      # freezes the rule set; this freezes check implementations (ADR 0004).
      {:credo, "1.7.19", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: :test, runtime: false}
    ]
  end

  defp aliases do
    [
      # CI-grade gate: the one list CI and local devs run — no drift.
      # See ADR 0003.
      ci: [
        "deps.get --check-locked",
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --strict",
        "dialyzer",
        "coveralls.multiple --type json --type html"
      ]
    ]
  end

  # Test support modules (the loopback SSE server) compile only under :test.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]
end
