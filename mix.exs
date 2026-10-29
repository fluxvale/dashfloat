defmodule DashFloat.MixProject do
  use Mix.Project

  def project do
    [
      app: :dash_float,
      version: "0.2.0",
      elixir: "~> 1.20.0",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      aliases: aliases(),
      deps: deps(),
      # One release, named for the binary users type (the OTP app stays
      # :dash_float). Release packaging is core `mix release` per ADR 0010.
      # The steps after :assemble bundle libsctp for ERTS's dlopen (see
      # DashFloat.Release) and forward CLI arguments on `start` — the
      # generated launcher drops them, which would silently break --version
      # and the --profile/--model selection flags (see the function below).
      releases: [
        dashfloat: [
          include_executables_for: [:unix],
          steps: [:assemble, &DashFloat.Release.bundle_sctp/1, &patch_launcher/1]
        ]
      ],
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
      {:earmark_parser, "~> 1.4"},
      {:ex_ratatui, "~> 0.17.1"},
      {:jason, "~> 1.4"},
      # JSON5 config files (ADR 0008). json5 pins decimal ~2.0.0 — exactly
      # 2.0.0, which carries two MEDIUM DoS advisories; override to the fixed
      # 3.x line (verified: compiles and decodes identically). Drop the
      # override when json5 bumps its pin.
      {:json5, "~> 0.4"},
      {:decimal, "~> 3.2", override: true},
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

  # Test support modules (the loopback test seam) compile only under :test.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  # The generated `bin/<name>` launcher is operator-shaped: every argument is
  # a release command, `start` drops its own arguments, and a bare invocation
  # prints a command list. DashFloat's binary is user-shaped: `dashfloat`
  # starts the TUI, `dashfloat --version` answers, and the selection flags
  # reach the app. Two text edits to Elixir's own launcher do that, with the
  # build failing loudly if the template moves under us, instead of shipping a
  # binary that silently ignores what the user typed (ADR 0010).
  defp patch_launcher(release) do
    launcher = Path.join(release.path, "bin/#{release.name}")
    contents = File.read!(launcher)

    contents =
      replace_launcher!(
        launcher,
        contents,
        ~s{  start)\n    start "elixir" --no-halt\n},
        ~s{  start)\n    shift\n    start "elixir" --no-halt "$@"\n}
      )

    contents =
      replace_launcher!(
        launcher,
        contents,
        ~s{case $1 in\n  start)},
        ~s{case $1 in\n  "" | -*) set -- start "$@" ;;\nesac\n\ncase $1 in\n  start)}
      )

    File.write!(launcher, contents)
    release
  end

  defp replace_launcher!(launcher, contents, from, to) do
    if String.contains?(contents, from) do
      String.replace(contents, from, to)
    else
      Mix.raise(
        "release launcher #{launcher} does not contain the expected fragment — " <>
          "Elixir's launcher template changed; update patch_launcher/1 in mix.exs (ADR 0010)"
      )
    end
  end
end
