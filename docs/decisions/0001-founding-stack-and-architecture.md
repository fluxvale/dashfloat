# 0001 — Founding stack and architecture

- **Status:** Accepted
- **Date:** 2026-10-23

## Context

DashFloat replaces Octofriend as our CLI AI coding harness: a fast, robust,
responsive terminal application that streams LLM responses, executes structured
tool calls, and manages coding sessions. The founding spec — goal, feature
subsystems, and phases — is recorded in
[issue #1](https://github.com/fluxvale/dashfloat/issues/1); this ADR pins the
decisions that outlive it. All dependency versions were verified on hex.pm on
2026-10-23 (`mix hex.info`).

## Decision

Build DashFloat in Elixir on Erlang/OTP. The concurrency model — processes,
GenServers, Tasks, Ports — maps directly onto the harness's concurrent
workloads (streaming, tool execution, session management).

### Stack

| Concern | Choice | Pin | Verified notes |
| --- | --- | --- | --- |
| Language / runtime | Elixir / Erlang OTP | 1.20.4 / 29 | ex_ratatui supports Elixir 1.17+, OTP 26–29 |
| TUI | `ex_ratatui` | `~> 0.17.1` | Rustler-backed ratatui bindings; precompiled NIFs for OTP 26–29 (ABI 2.17 loads on OTP 29) |
| HTTP + SSE | `req` | `~> 0.7.5` | stable line (0.8 is release-candidate only) |
| JSON | `jason` | `~> 1.4` | 1.4.5 is the latest stable |
| Distribution | `burrito` | `~> 1.6` | single-binary releases; musl precompiled NIFs are a supported payload |

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
  (currently OTP 26–29, Elixir 1.17+).
- The four-process shape is the review lens for every later phase: I/O found in
  the UI process is a bug, and subprocess failures must degrade to chat
  messages, never crashes.
