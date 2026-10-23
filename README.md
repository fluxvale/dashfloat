# DashFloat

A fast, robust CLI AI coding harness in Elixir — Octofriend's successor, owned
and built here.

DashFloat streams LLM responses, executes structured tool calls, and manages
coding sessions from the terminal. It is built on OTP concurrency — a pure
render-loop UI process, an agent-manager GenServer, stream-handler tasks, and
isolated subprocess execution — with an
[`ex_ratatui`](https://hex.pm/packages/ex_ratatui) TUI and
[`burrito`](https://hex.pm/packages/burrito) single-binary distribution.

## Status

**Pre-alpha — Phase 1.** The TUI skeleton is in ([ADR 0002](docs/decisions/0002-tui-skeleton.md)):
status bar, scrollable log, multi-line input with history, and a synthetic
streaming demo. Next up per the [ADR 0001](docs/decisions/0001-founding-stack-and-architecture.md)
roadmap: LLM streaming engine, tool call execution, context management &
history persistence.

## Run it

```sh
mix run --no-halt
```

Type a message and press Enter; a synthetic reply streams in. Shift+Enter
inserts a newline on terminals that report enhanced key events (kitty
protocol, modifyOtherKeys) — on others, use Alt+Enter. Up/Down walk input
history, PageUp/PageDown scroll the log, Ctrl+Q (or Ctrl+C) quits.

## Stack

- [Elixir](https://elixir-lang.org) 1.20 / Erlang/OTP 29
- [`ex_ratatui`](https://hex.pm/packages/ex_ratatui) — TUI (Rustler-backed
  ratatui bindings, precompiled NIFs)
- [`req`](https://hex.pm/packages/req) — HTTP / SSE streaming
- [`jason`](https://hex.pm/packages/jason) — JSON
- [`burrito`](https://hex.pm/packages/burrito) — single-binary releases

## Development

```sh
mix ci
```

`mix ci` is the whole gate — the same list CI runs, so local and CI cannot
drift ([ADR 0003](docs/decisions/0003-ci-gate-and-coverage-ratchet.md)):
format, compile with warnings as errors, `credo --strict`, `dialyzer`, and the
test suite under ExCoveralls with a coverage floor (`coveralls.json`). It
fetches any missing deps itself — there is deliberately no separate
`mix deps.get` first, as it would silently repair a stale lock before the gate
could catch it.

CI runs it on every pull request and every push to `main`, uploads the HTML
coverage report as an artifact, and sends the JSON report to Codecov. The
required branch-protection check is **Wait for CI**. See
[AGENTS.md](AGENTS.md) for the repository conventions.

## License

MIT — see [LICENSE](LICENSE).
