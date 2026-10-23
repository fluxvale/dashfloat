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

**Pre-alpha — bootstrap.** The founding decisions are recorded in
[ADR 0001](docs/decisions/0001-founding-stack-and-architecture.md); its roadmap
(TUI skeleton → LLM streaming engine → tool call execution → context management
& history persistence) is the build order. There is no product code yet.

## Stack

- [Elixir](https://elixir-lang.org) 1.20 / Erlang/OTP 29
- [`ex_ratatui`](https://hex.pm/packages/ex_ratatui) — TUI (Rustler-backed
  ratatui bindings, precompiled NIFs)
- [`req`](https://hex.pm/packages/req) — HTTP / SSE streaming
- [`jason`](https://hex.pm/packages/jason) — JSON
- [`burrito`](https://hex.pm/packages/burrito) — single-binary releases

## Development

```sh
mix deps.get
mix test --warnings-as-errors
```

CI runs `mix format --check-formatted`, `mix compile --warnings-as-errors`, and
`mix test --warnings-as-errors` on every push to `main`. See
[AGENTS.md](AGENTS.md) for the repository conventions.
