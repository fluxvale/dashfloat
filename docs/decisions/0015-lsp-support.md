# 0015 — LSP support: client supervision, per-filetype servers, diagnostics feedback

- **Status:** Accepted
- **Date:** 2026-10-29
- **Implements:** [issue #77](https://github.com/fluxvale/dashfloat/issues/77)
- **Extends:** [ADR 0001](0001-founding-stack-and-architecture.md) (a fifth subsystem joins the
  process shape), [ADR 0007](0007-tool-calls-and-execution.md) (tool catalogue, result shapes,
  the single-voice rule), [ADR 0008](0008-config-layout-profiles-json5.md) /
  [ADR 0009](0009-config-v3-persona-profiles.md) (settings.json5), and reuses
  [ADR 0013](0013-exec-pgid-tracked-at-spawn.md) (process-group kill discipline).

## Context

The agent edits files blind to compiler knowledge. A `write_file` that breaks the
build only fails when the model thinks to run `mix compile`; unused variables,
type errors, and unresolved references never surface unless the model runs a
checker itself. Editors solved this with the Language Server Protocol: a
per-language server process that indexes the project and pushes *diagnostics*
(errors/warnings per file) whenever a document changes.

Prior art, surveyed before deciding:

- **OpenCode** (terminal agent, TypeScript): LSP **disabled by default**, enabled
  with `"lsp": true`; a built-in catalog maps file extensions to servers
  (activated only when the server's requirements hold); servers start when a
  matching file is touched; after an edit the harness touches the file and pulls
  diagnostics into the tool result. Their docs are honest about the trade-off:
  servers get out of sync, eat memory, vary by version, and can slow the loop —
  "in many projects it is better to have the agent run lint/typecheck CLIs
  directly." We adopt the shape and the honesty.
- **Crush** (terminal agent, Go): same shape — per-language `{command, args}`
  config, a manager process at boot, diagnostics and code intelligence fed to the
  agent. Manual configuration only; no auto-install.
- **Gemini CLI**: skipped an in-process LSP client entirely, integrating with the
  user's IDE (ACP) instead. Not available to us: DashFloat owns the terminal and
  assumes no IDE.

Elixir client landscape, evaluated (not picked blindly):

- **`gen_lsp`** (elixir-tools, v0.11.x): an OTP behaviour "for building processes
  that implement the LSP" whose entire vocabulary is server-side — its callbacks
  receive notifications/requests "from the client", its communication adapters
  read the process's *own* stdio, and everything built with it (Next LS,
  credo-language-server, refactorex) is a server. Using it as a *client* (spawn a
  server over a Port, speak the other direction) is off-label: the I/O model
  fights us, and it drags `schematic` + `typedstruct` plus a generated
  protocol-struct surface for the whole meta-model into a release whose size is a
  feature (ADR 0010). Rejected.
- **Nothing else exists**: Hex has LSP *servers* (elixir-ls, lexical, next-ls all
  embed their own client plumbing) and no maintained standalone client library.

DashFloat already owns every primitive a minimal client needs: Port-spawned
processes with group-kill reaping (`Tools.Exec`, ADR 0013), a pure incremental
byte-stream parser (`LLM.SSE`), JSON via `jason`, and bounded-everything
discipline. The v1 protocol surface — `initialize`/`initialized`/`shutdown`/
`exit`, `didOpen`/`didChange`/`didClose`, `publishDiagnostics`, and generic
server-request replies — is a small, well-specified slice of JSON-RPC 2.0.

## Decision

### 1. Scope: diagnostics only, v1

One capability drives the design: **the model sees compiler diagnostics for the
code it just wrote**. Everything else the protocol offers is deferred (see
Alternatives). Two delivery paths, both bounded:

1. **Post-edit enrichment** — a successful `write_file`/`edit_file` result gains
   a `diagnostics` array when a language server for that file exists and reports
   within the wait budget.
2. **On-demand `diagnostics(path)` tool** — pulls the cached diagnostics for one
   file (the cache is filled by `publishDiagnostics` pushes; `read_file` warms it
   via `didOpen`).

Definitions/references/hover/formatting are **future work**, recorded here so
nobody re-litigates scope: they add UTF-16 column mapping, tool surface, and (for
formatting) a conflict with ADR 0007's approved-diff invariant — none justified by
v1's goal. The model still has `execute_command` for greps and CLI checkers; LSP
is additive, not a replacement (OpenCode's best-practices note applies verbatim).

### 2. Hand-rolled minimal client, zero new dependencies

New modules, all under `DashFloat.LSP`:

| Module | Shape | Owns |
| --- | --- | --- |
| `DashFloat.LSP.Protocol` | pure | frame codec: `Content-Length`-prefixed UTF-8 JSON-RPC 2.0; incremental parser in the `LLM.SSE` style (`new/feed/2`), outbound `encode/1`; 16 MiB inbound frame cap |
| `DashFloat.LSP.Position` | pure | line counting and UTF-16 code-unit lengths (the protocol's position encoding) for the whole-document end position and future use |
| `DashFloat.LSP.Catalog` | pure | well-known server table + merge with the user's `lsp` config section; extension → entry resolution |
| `DashFloat.LSP.Server` | GenServer, `:temporary` | one language server OS process: Port spawn under its own process group (ADR 0013 kill discipline), request-id bookkeeping, `initialize` handshake, capabilities, open-document versions, diagnostics cache for its files, generic replies to server-initiated requests |
| `DashFloat.LSP` | GenServer (registry) | entry → server mapping, lazy start on demand, restart cooldown, and the single seam other subsystems call (`touch/3`, `diagnostics/2`, `enabled?/0`) |

The registry holds no timers (cooldown is a timestamp checked lazily on demand —
the same discipline the agent uses for timeouts). The Server GenServer owns all
port I/O; no LSP process ever talks to the UI.

### 3. Supervision and lifecycle

```
DashFloat.Supervisor (one_for_one)
  ├─ DashFloat.TaskSupervisor
  ├─ DashFloat.LSP.Supervisor  (DynamicSupervisor — LSP Server children)   NEW
  ├─ DashFloat.LSP             (registry; started only when LSP is enabled) NEW
  ├─ DashFloat.Agent           (gains `:lsp` opt, default DashFloat.LSP)
  └─ DashFloat.TUI
```

- **Lazy start.** No server process exists until the agent touches a file whose
  extension resolves to a catalog entry (`read_file`, or a landed
  `write_file`/`edit_file`). One server per *entry* (language), not per file,
  rooted at the agent's cwd (`rootUri`).
- **Persistent while session runs.** Servers survive turns and episodes; warm
  diagnostics beat cold-start latency. Idle shutdown is future work.
- **Death is a notice, never a crash.** Server children are `:temporary`. On
  abnormal exit (or init timeout, 30 s) the registry marks the entry
  `{down_at: monotonic_time}`, reports one system entry through the agent —
  `[lsp: <entry> exited — language features off]` — and refuses restarts for a
  60 s cooldown (checked lazily; no timer). Demand after the cooldown starts a
  fresh instance. A configured command missing from PATH is reported the same
  way at first start attempt.
- **Shutdown** is best-effort graceful: `shutdown` request (5 s), `exit`
  notification, port close, then SIGKILL the process group (ADR 0013) — when the
  registry stops and, opportunistically, at VM halt (ports die with the VM
  regardless; well-behaved servers exit on stdin EOF).

The registry reports to the agent (`{:lsp_notice, text}` plain send; `notify`
opt, default `DashFloat.Agent`), and the agent turns that into the usual system
entry — the single-voice rule holds: LSP never renders, the agent does.

### 4. Which servers, and how installed: documented, never bundled

A **well-known catalog** ships in code (names, command lines, extensions) and
activates only when the binary exists on PATH (`System.find_executable/1`). No
downloads, no auto-install, nothing bundled in the release (supply chain, release
size, per-platform builds — see Alternatives).

| Entry | Extensions | Command | Install (documented, user-run) |
| --- | --- | --- | --- |
| `elixir-ls` | `.ex`, `.exs` | `elixir-ls` (script from the release zip's `language_server.sh`) | GitHub release zip or `brew install elixir-ls` |
| `typescript` | `.ts`, `.tsx`, `.js`, `.jsx`, `.mjs`, `.cjs` | `typescript-language-server --stdio` | `npm i -g typescript typescript-language-server` |
| `go` | `.go` | `gopls` | `go install golang.org/x/tools/gopls@latest` |
| `python` | `.py`, `.pyi` | `pyright-langserver --stdio` | `npm i -g pyright` or `pipx install pyright` |
| `rust` | `.rs` | `rust-analyzer` | `rustup component add rust-analyzer` or `brew install rust-analyzer` |

Elixir is first-class by dogfood right: DashFloat is an Elixir repo. Install
one-liners and the trade-off note live in the README (slice S4), pointing here.

### 5. Configuration: `lsp` section in settings.json5

LSP is **opt-in**, mirroring OpenCode's (research-backed) default:

```json5
// settings.json5
{
  // ...profiles as today (ADR 0009); "lsp" is a new top-level section
  lsp: true,                       // enable the well-known catalog (PATH-gated)
  // or, explicitly:
  lsp: {
    elixir: {                      // entry name; extends/overrides the catalog
      command: ["elixir-ls"],      // argv array; required for custom entries
      extensions: [".ex", ".exs"],
      initialization: { mixEnv: "test" },   // initialize params.options
      disabled: true               // turn one entry off
    },
    mylang: { command: ["mylang-lsp", "--stdio"], extensions: [".my"] }
  }
}
```

`lsp` omitted or `false` → subsystem inert: no processes, no tools, no notices
(the silent absence below). Keys per entry: `command` (argv, required for
user-added entries), `extensions`, `initialization`, `disabled`. v1 deliberately
omits per-server `env` (settings.json5 is credential-free by construction —
ADR 0009 — and the common servers need no env). Client `initialize` params send
`clientInfo`, `rootUri` (the agent cwd), and minimal capabilities:
`textDocument.publishDiagnostics.versionSupport: true` — nothing we do not
implement.

### 6. Document synchronization

- **`read_file`** → `didOpen` (full text, `languageId` from the entry, version 1)
  when the file's extension has an entry. Warms the server and the diagnostics
  cache; the read result shape is unchanged.
- **Landed `write_file`/`edit_file`** → `didOpen` (new files) or `didChange`
  with the *full new content* and version+1 — full sync when the server declares
  `TextDocumentSyncKind.Full`/none, or a single whole-document range change when
  it declares `Incremental` (end position computed by `Position` in UTF-16).
- **External mutation** (`execute_command` rebuilds/refactors files): the
  server's view can go stale — v1 has no file watcher. On the agent's next
  `read_file`/`edit_file` of that file, DashFloat re-reads disk and pushes full
  content, so staleness is bounded by "until we touch that file again",
  documented honestly. `workspace/didChangeWatchedFiles` is future work.
- **Server-initiated messages** get generic replies (JSON-RPC requires a
  response to every request): `workspace/applyEdit` → `{applied: false}`;
  `workspace/configuration` → array of `null`; everything else → `null` result.
  `window/logMessage` and `$/…` notifications are dropped silently (v1).

### 7. The diagnostics pipeline

- `publishDiagnostics` arrivals are cached per URI. **Stale guard:** when the
  push carries a `version` and it does not equal our current version for that
  document, the push is dropped — no ghosts from in-flight analyses. Servers
  that omit `version` are trusted (limitation recorded).
- **Post-edit wait lives in the runner Task** (never the agent GenServer, never
  the UI): after the write lands and content is pushed, the runner polls the
  cache for a push matching the pushed version, deadline **2 s** (agent opt
  `:diagnostics_wait`, injectable for tests). Timeout → the result ships without
  `diagnostics` — silence is the designed degradation, not an error.
- **Result shape** (bounded like every ADR 0007 result): `diagnostics` is an
  array of `{severity: 1..4, line, message}` (errors first, at most 50 entries /
  8 KiB, then a truncation marker). Example:

```json
{"ok":true,"path":"lib/foo.ex","replaced":1,
 "diagnostics":[{"severity":1,"line":12,"message":"undefined function bar/1"}]}
```

- **`diagnostics(path)` tool** (new catalogue entry; validation lives in
  `DashFloat.Tools`'s single parameter table like every other tool): args
  `path` (required). Advertised only when LSP is enabled — the agent composes
  the catalogue at episode start. Server absent/down/cooling down → honest error
  result (`no language server for .foo files` / `language server down`), never a
  hang: the call is bounded by the same deadline.

### 8. Failure modes: silent absence vs visible notice

| Situation | Behavior |
| --- | --- |
| `lsp` unconfigured/disabled | silent absence — subsystem fully inert |
| Extension has no catalog entry | silent absence — file tools behave exactly as today |
| Entry's binary missing at start attempt | visible: one system entry naming entry + remedy; entry treated as absent |
| Server init timeout (30 s) / crash / frame > 16 MiB | visible notice, entry `down` with 60 s cooldown, next demand restarts |
| Diagnostics wait timeout | silent: result ships without `diagnostics` |
| Stale `publishDiagnostics` | silent: dropped by the version guard |

Rule: **absence at idle is silent; failure at the moment of use is visible.** The
user is never nagged for not having a server; the model is never lied to when it
asks.

### 9. Security and trust posture

An LSP server is an arbitrary local program, but it is either DashFloat's
well-known catalog (PATH-gated) or a command the user wrote into their own
settings — the config *is* the consent; no per-run confirmation (unlike
`execute_command`, whose input is model-authored). Servers run unsandboxed under
their own process group and may read the working tree, like any local tool the
user runs. Document content sent to a server is content the agent already
scoped through the path policy. All buffers bounded: frame cap 16 MiB, cache
capped per URI, send-side content capped at the edit caps already enforced.

### 10. Testing

- `Protocol`/`Position`: recorded frame fixtures fed whole and at every byte
  offset (the `LLM.SSE` pattern); UTF-16 lengths over emoji/CJK/surrogates.
- `Server`/registry integration: a **fake language server** script
  (`test/support/lsp/fake_server.exs`, run with `elixir`) speaks real framed
  JSON-RPC over stdio — scripted per test to ack `initialize`, declare a chosen
  sync kind, echo `didOpen`/`didChange` versions, publish diagnostics (fresh and
  stale), exit on `shutdown`, or die on demand. Deterministic, offline.
- Agent end-to-end: the existing loopback SSE server drives an `edit_file` call;
  the fake LSP publishes diagnostics; the test asserts the `role: "tool"`
  message content carries them — plus the regression: LSP disabled ⇒ byte-equal
  results to today's shapes.

## Implementation slices

Each slice is independently implementable and independently green; specs here
are the worker's complete context.

**S1 — Client core (no agent-visible change).** `Protocol`, `Position`,
`Catalog`, config plumbing (`lsp` section read via the existing JSON5 loader),
`Server` lifecycle (spawn/group-kill, initialize/initialized, shutdown/exit,
request-id bookkeeping, generic server-request replies), `DynamicSupervisor` +
registry with lazy start, missing-binary notice, crash notice + lazy cooldown.
Application wiring: registry started only when enabled (never in `:test` env).
*Done when:* `mix ci` green; framing tests pass on byte-split feeds; fake-server
tests cover initialize handshake, graceful shutdown (fake exits 0), crash →
notice → cooldown refuses restart → demand after cooldown (injected clock)
restarts; no change to any existing test's behavior.

**S2 — Document sync + diagnostics cache (still invisible to the agent).**
`didOpen`/`didChange` (both sync kinds, whole-doc range via `Position`),
version tracking, `publishDiagnostics` cache with stale guard, bounded caps,
`DashFloat.LSP.diagnostics/2` read API. *Done when:* `mix ci` green;
fake-server tests prove: didOpen → cache fill; post-edit push with matching
version replaces the cache; stale-version push is dropped; an
incremental-declaring server receives a whole-document range change; cache caps
truncate with a marker.

**S3 — Wire into the tool loop.** Agent `:lsp` opt; `read_file` didOpen;
`write_file`/`edit_file` post-write sync + bounded diagnostics wait + result
enrichment (runner-Task-side); `diagnostics` tool in `DashFloat.Tools`
(conditionally advertised; runner dispatch via opts); `{:lsp_notice, _}` →
system entry in the agent. *Done when:* `mix ci` green; the end-to-end loopback
test (edit → confirm → fake server publishes → tool message contains the
diagnostics array) passes; LSP-disabled run produces byte-equal tool results to
main (regression test); no-server-extension yields no `diagnostics` key and no
crash.

**S4 — Docs + dogfood.** README section: config shape, the well-known table
with install one-liners, and the honest trade-off note (when CLI checkers beat
LSP). Run DashFloat-on-DashFloat with `elixir-ls`; record findings in
issue #77. *Done when:* docs merged; a #77 comment reports a real session where
post-edit diagnostics surfaced (or the concrete blocker found).

## Alternatives considered

- **`gen_lsp` as the client** — off-label (server behaviour, stdio-bound,
  meta-model-sized dependency surface). Rejected; see Context.
- **IDE/ACP integration instead of a client (the Gemini route)** — presumes an
  IDE; DashFloat is the terminal. Rejected.
- **CLI checkers only, no LSP (status quo plus docs)** — cheapest, and the right
  default for many projects, but push-diagnostics need zero per-project config
  and catch what the model forgot to run. Both coexist by design.
- **Auto-install / bundling servers in the release** — supply-chain exposure,
  release bloat, per-platform builds for five ecosystems, licensing tangles.
  PATH detection + documented installs instead.
- **Servers at boot / per file / per project root** — boot wastes memory on
  languages never touched; per-file multiplies processes for no gain; v1 has one
  root (the agent cwd) by construction. Lazy-per-entry won.
- **Diagnostics injected into context as system messages** — unbounded context
  growth and a second voice into the transcript; results-riding diagnostics are
  bounded and ordered by the loop. Rejected.
- **Formatting-on-edit / LSP-aware edit application** — would break ADR 0007's
  "approved diff == landed diff" invariant (the user confirmed bytes that a
  formatter then mutates). Deferred; a future explicit `format_file` tool can
  keep the invariant by confirming the formatted result.
- **Definition/references tools in v1** — real value, but UTF-16 column mapping
  and tool surface beyond v1's goal; `execute_command` grep covers the gap.
  Future work, not rejected.
- **Per-server `env` config in v1** — no current need; tension with the
  credential-free settings rule. Deferred until a server demands it.

## Consequences

- A fifth subsystem joins the ADR 0001 shape; its review lens (I/O off the UI
  process, failures degrade to messages, everything bounded) extends to it
  unchanged.
- Two new process kinds (registry, per-server GenServers) and one config
  section; zero new dependencies; `mix release` size unchanged.
- The tool catalogue becomes dynamic (composed at episode start when LSP is
  enabled) — the first departure from the fixed five, gated on one boolean.
- Diagnostics quality is the servers' quality: stale-push guards and bounded
  waits bound the damage, and the OpenCode trade-off note is inherited into our
  docs verbatim in spirit.
- Server trust is config-declared, not confirmed per run — recorded here as the
  deliberate boundary, symmetric with running any local tool.
