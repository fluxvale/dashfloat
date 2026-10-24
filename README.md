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

**Pre-alpha — Phase 2.** The LLM streaming engine is in
([ADR 0005](docs/decisions/0005-llm-streaming-engine.md)): an OpenAI-compatible
SSE client streams tokens into the existing TUI
([ADR 0002](docs/decisions/0002-tui-skeleton.md)). Next up per the
[ADR 0001](docs/decisions/0001-founding-stack-and-architecture.md) roadmap: tool
call execution, context management & history persistence.

## Run it

Configure your provider — any OpenAI-compatible endpoint, one profile per
subscription — in `~/.config/dashfloat/settings.json5` (created 0600; it holds
credentials). The first profile is the default; each profile owns its model
menu, whose first entry is its default model (`settings.defaultModel` can name
another). A legacy `config.json` migrates itself into a `default` profile on
first run:

```json5
{
  configVersion: 1,
  profiles: [
    {
      name: 'work',
      baseUrl: 'https://api.openai.com/v1',
      apiKey: 'PLACEHOLDER',
      models: [{ nickname: 'mini', model: 'gpt-4o-mini', context: 128000 }],
    },
  ],
}
```

`DASHFLOAT_BASE_URL`, `DASHFLOAT_MODEL`, `DASHFLOAT_API_KEY`, and
`DASHFLOAT_CONTEXT_TOKENS` override the file per field; `--profile <name>`
(startup flag, or `DASHFLOAT_PROFILE`) selects the active profile and
`--model <nickname>` a model within it. The status bar names the active model
`nickname (profile)`. Put your provider's own base URL in `baseUrl`; DashFloat
appends `/chat/completions`. Details:
[ADR 0008](docs/decisions/0008-config-layout-profiles-json5.md). Then:

```sh
mix run --no-halt
```

Type a prompt and press Enter: tokens stream into the log and the status bar
flips Streaming → Idle when the reply completes. Press Esc mid-stream to cancel
— the partial reply is kept and a gray `[cancelled]` line marks it. Shift+Enter
inserts a newline on terminals that report enhanced key events (kitty
protocol, modifyOtherKeys) — on others, use Alt+Enter. Up/Down walk input
history, PageUp/PageDown scroll the log, Ctrl+Q (or Ctrl+C) quits.

Without a provider configured the TUI still starts; submitting logs the setup
instructions instead of a reply. This live-key run is the manual smoke step —
the test suite is offline and deterministic (recorded SSE fixtures plus a
loopback server).

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
could catch it. Coverage counts shipped code only: the test harness
(`test/`) is excluded via `skip_files`, so the floor guards `lib/`.

CI runs it on every pull request and every push to `main`, uploads the HTML
coverage report as an artifact, and sends the JSON report to Codecov. The
required branch-protection check is **Wait for CI**. See
[AGENTS.md](AGENTS.md) for the repository conventions.

## License

MIT — see [LICENSE](LICENSE).
