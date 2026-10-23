defmodule DashFloat.MixProject do
  use Mix.Project

  def project do
    [
      app: :dash_float,
      version: "0.0.0",
      elixir: "~> 1.20.0",
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      # coveralls.multiple writes cover/excoveralls.json (Codecov) and
      # cover/excoveralls.html (CI artifact) from one suite run
      test_coverage: [tool: ExCoveralls],
      # PLT in priv/plts (gitignored), exact-version CI cache key
      dialyzer: [
        plt_add_apps: [:ex_unit],
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
      # "task could not be found"
      preferred_envs: [
        ci: :test,
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.json": :test,
        "coveralls.html": :test,
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
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: :test}
    ]
  end

  defp aliases do
    [
      # CI-grade gate: the one list CI and local devs run (#5) — no drift.
      # The coverage floor lives in coveralls.json. One suite run produces
      # both artifacts: Codecov reads the JSON, CI ships the HTML (the
      # pair of coveralls tasks would skip the second suite and emit no
      # HTML).
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
end
