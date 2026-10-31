# 0001 — Founding stack and architecture

- **Status:** Accepted
- **Date:** 2026-10-23

## Context

DashFloat replaces Octofriend as our CLI AI coding harness: a fast, robust,
responsive terminal application that streams LLM responses, executes structured
tool calls, and manages coding sessions. The founding spec settled the goal,
stack, and shape; this ADR is its durable record — the decisions that outlive
the bootstrap task that created this repository
([issue #1](https://github.com/fluxvale/dashfloat/issues/1)). All dependency
versions were verified on hex.pm on 2026-10-23 (`mix hex.info`).

## Decision

Build DashFloat in Elixir on Erlang/OTP. The concurrency model — processes,
GenServers, Tasks, Ports — maps directly onto the harness's concurrent
workloads (streaming, tool execution, session management).

### Stack

| Concern | Choice | Pin | Verified notes |
| --- | --- | --- | --- |
| Language / runtime | Elixir / Erlang OTP | `mix.exs` requires `~> 1.20.0`; dev runs 1.20.4 / OTP 29; CI floats `1.20.x` (currently 1.20.4) | ex_ratatui supports Elixir 1.17+, OTP 26–29 |
| TUI | `ex_ratatui` | `~> 0.19.0` | Rustler-backed ratatui bindings; precompiled NIFs for OTP 26–29 (its own NIF-2.18 build on OTP 29 since 0.18) |
| HTTP + SSE | `req` | `~> 0.7.5` | stable line (0.8 is release-candidate only) |
| JSON | `jason` | `~> 1.4` | 1.4.5 is the latest stable |
| Distribution | core `mix release` | built into Elixir | per-platform tarballs + installer + Homebrew; see [ADR 0010](0010-release-packaging.md) |

### Process architecture

Four cooperating processes; the UI process never performs I/O.

1. **UI process** (`ExRatatui` runtime) — owns global UI state (input buffer,
   scroll positions, session history, execution status) and renders purely.
   State changes are immutable transformations inside `handle_info/2` /
   `handle_event/2`.
2. **Agent Manager** (`GenServer`) — coordinates model state, context-window
   management, tool selection, and tool execution.
3. **Stream Handler** (`Task`) — consumes SSE from the LLM provider, buffers
   chunks, and sends parsed tokens to the UI process via `send/2`.
4. **Subprocess Executor** (`Port`/`Task`) — spawns shell commands and file
   operations in isolated processes and returns output to the UI without
   blocking state.

Guideline: all I/O — network, filesystem, shell commands — lives off the UI
process, inside dedicated Tasks or GenServers, so the render loop stays fast and
non-blocking. Failed subprocesses report back to the chat stream gracefully
rather than crashing the BEAM node.

### Key subsystems

The TUI is three regions: a header/status bar (model info, context-size
indicator, execution state — idle / streaming / executing tool), a scrollable
main log view (markdown-formatted model messages, tool calls, shell outputs),
and a multi-line input box with history navigation and an execution trigger
(`Enter` / `Ctrl+Enter`).

The core toolset is fixed and structured (JSON function calls):

- `read_file(path, offset, limit)`
- `write_file(path, content)`
- `edit_file(path, search_block, replace_block)`
- `execute_command(command, cwd)`
- `list_directory(path)`

File mutation uses explicit, structured search-and-replace blocks — no
line-number or best-guess edits. Changes are previewed in the TUI before they
are applied whenever user confirmation is required.

### Roadmap

- **Phase 1 — TUI skeleton:** `ex_ratatui` application shell; input handling,
  scrolling log window, simple state updates.
- **Phase 2 — LLM streaming engine:** SSE streaming via `req`; live-updating
  tokens in the UI.
- **Phase 3 — Tool call parsing & execution:** tool calls parsed from streaming
  JSON; file read/write and command execution via `Port` and `File` APIs.
- **Phase 4 — Context management & history persistence:** session state,
  truncation/sliding-window summaries; sessions saved as JSON under
  `~/.config/dashfloat/sessions/`.

## Alternatives considered

- **`finch` + `mint` directly** (the spec's other option) — `req` wraps them
  and already provides the streaming plumbing; less code we own. Chose `req`.
- **Rust toolchain in CI for the NIF** — unnecessary: `ex_ratatui` publishes
  precompiled, checksummed NIFs per release for OTP 26–29, so neither
  development nor CI needs Rust. A source build is the documented escape hatch
  (`EX_RATATUI_BUILD=true` plus a direct `{:rustler, ">= 0.0.0"}` dependency)
  for targets without precompiled artifacts; any recent stable Rust suffices
  then.

## Consequences

- First compile downloads the precompiled NIF artifact — network access is
  required, and the artifact is checksum-verified by `rustler_precompiled`.
- The transitive dependency tree is pinned in `mix.lock`; dependency bumps are
  deliberate, reviewed PRs.
- Elixir/OTP upgrades must stay inside `ex_ratatui`'s support window
  (currently OTP 26–29, Elixir 1.17+); the project's own floor is stricter and
  lives in `mix.exs` (`~> 1.20.0`).
- The four-process shape is the review lens for every later phase: I/O found in
  the UI process is a bug, and subprocess failures must degrade to chat
  messages, never crashes.
