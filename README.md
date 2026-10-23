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
mix deps.get --check-locked
mix test --warnings-as-errors
```

CI runs `mix format --check-formatted`, `mix compile --warnings-as-errors`, and
`mix test --warnings-as-errors` on every pull request and every push to `main`.
See [AGENTS.md](AGENTS.md) for the repository conventions.
