# ADR 0024: Herdr integration: state reporting, resume command, pane release

- **Status**: Accepted
- **Date**: 2026-10-31
- **Issue**: [#113](https://github.com/fluxvale/dashfloat/issues/113)
- **Supersedes**: none

## Context

DashFloat is dogfooded inside [Herdr](https://herdr.dev), a terminal
multiplexer whose sidebar tracks agents running in its panes. Herdr exposes a
first-class integration surface ([docs](https://herdr.dev/tui/docs/add-herdr-support/)):
every process in a Herdr pane inherits `HERDR_ENV=1`, `HERDR_PANE_ID`,
`HERDR_BIN_PATH`, and `HERDR_SOCKET_PATH`, and an agent may report its state
(`idle` / `working` / `blocked`), the command that reopens its session, and its
departure — through the `"$HERDR_BIN_PATH"` CLI. Outside Herdr the integration
must do nothing.

The DashFloat side already has the disciplines this needs: the TUI's phase
machine (`DashFloat.TUI.State`), the fire-and-forget side-request pattern
(`DashFloat.TUI.Suggest`, `DashFloat.Session.Title`), UUIDv7 session ids
(ADR 0023), and the resume flow (ADR 0014 §6).

## Decision

### 1. One reporter module, inert by default

`DashFloat.Herdr` owns the whole integration. Detection happens once at boot —
`Herdr.detect/1` on the env map the Application already reads — and returns a
context struct only when `HERDR_ENV=1` **and** `HERDR_PANE_ID` and
`HERDR_SOCKET_PATH` are non-empty. Anything else yields `nil`, and `nil` is
permanently inert: every hook (`report/2`, `release/1`) pattern-matches the nil
head first — no task, no connection, no log. The context rides into the TUI as
a mount opt (`herdr:`) next to the existing `provider:`/`resolve:` opts.

### 2. Phase-to-state map

The TUI's phase machine maps to Herdr's three states, with two non-phase
promotions:

| DashFloat | Herdr state | `--message` |
| --- | --- | --- |
| phase `:idle` (composer) | `idle` | — |
| phase `:streaming`, `:executing_tool`, `:checking` | `working` | — |
| phase `:confirming` (pending confirm) | `blocked` | `approve <tool>` |
| exit prompt armed (double-Ctrl+C guard) | `blocked` | `exit? press Ctrl+C again` |
| startup setup (forced selection or wizard) | `blocked` | `first-run setup: choose a provider` |

`:checking` is the AUTO safety check *running* (agent busy) → `working`; the
safety-check **outcome** prompt arms the same `:confirming` as Build-mode
confirmation → `blocked`. The wizard's questions are decided as **blocked**:
they are decisions awaiting the user, exactly Herdr's definition, and the
notification that fires on `blocked` is what brings the user back to a fresh
pane. The post-decision `:confirming` gap (decision sent, agent not yet
re-announced) maps to `blocked` for the sub-second it lasts — simpler than
special-casing, and invisible. Precedence: pending confirm > exit prompt >
setup > phase.

### 3. Seq policy: clock, forced strictly increasing

`--seq` is stamped from the wall clock (`System.system_time(:millisecond)`) —
it survives restarts, which Herdr requires — and forced strictly increasing
(`max(now, last + 1)`) by the one process that reports (the TUI), so
same-millisecond bursts still order. Herdr ignores reports whose seq is not
higher than the last accepted, which is the "drop queued older reports"
discipline delegated to the receiver: DashFloat fires one task per change and
does not queue; a late report cannot overwrite newer state. The dedup on
DashFloat's side is a signature compare (state, message, session id, provider
tag) — a report fires only when the signature changes, so token spam never
reaches Herdr.

### 4. Fail-open delivery over the socket API

State reports follow the suggester/auto-title discipline: one temporary task
under `DashFloat.TaskSupervisor` per report, fire-and-forget — the spawn's
`:exit` (dead supervisor) is caught, the body rescues everything, and each
request is bounded (connect/send/read-reply-line, each at a short timeout —
default 2 s) on its own connection. No result is read beyond the reply line.
A `runner` fun on the context is the test seam (the `suggest_fetcher`
pattern). `release/1` is the one synchronous-bounded call: it runs during
`terminate/2`, user-paced, and must land before the VM stops — Herdr's
idle-prompt self-clear is the safety net, not the mechanism.

The transport is Herdr's **socket API** (newline-delimited JSON over
`HERDR_SOCKET_PATH` — the documented direct-IPC alternative to the CLI), not
the CLI. Verified against Herdr 0.9.5 (2026-10-31): the CLI invoked from
inside a pane — the documented `"$HERDR_BIN_PATH" pane report-agent` flow —
exits 0 but **silently drops** `pane report-agent`; stripping `HERDR_ENV`
from its child env, identical argv/env from a plain shell, a python spawn,
and an Erlang port spawn from outside the session all deliver, yet the same
call from the agent's own process tree does not, while reads and
`release-agent` work. The raw socket path (`pane.report_agent`,
`pane.report_agent_session`, `pane.release_agent`) delivers reliably from
inside panes, including the resume command (persisted in the session file).
Recorded as a workaround with the evidence; worth an upstream report to
Herdr. Consequence: platforms without a unix-domain socket path (Windows
named pipes) would need the CLI fallback — DashFloat does not ship there
today.

### 5. Resume argv: what `--resume` alone does not restore

Verified: `--resume <uuid>` restores **only the transcript**. The session file's
pin (`profile`, `model`, `base_url`) is diagnostics (ADR 0014 §6) — the active
provider comes from the boot classification, and a mismatch warns without
switching. So the reported command carries the provider selection along:

```
--agent-session-id <uuid> -- dashfloat --resume <uuid> [--profile <p>] [--model <m>]
```

`--profile`/`--model` are included whenever the active config names them, so a
restored pane boots the same provider the session was pinned to — including
after a mid-session `/model` or `/profile` switch (the provider tag is part of
the report signature, so the argv re-reports on switch). The session id reaches
the TUI two ways: at mount for a resumed boot (Application opt), or as a
`{:session_id, id}` send from the agent when a fresh session's id is minted at
first save (ADR 0023). Args are sanitized per Herdr's rules: profile/model
values containing an apostrophe or control character are dropped (Herdr
rejects the whole report otherwise); the UUIDv7 id is always clean; the total
stays far under 64 args / 8 KiB. Env-derived `base_url` is not argv-restorable
— an env-configured provider restores only if the environment still provides
it; noted limitation, not worked around. `dashfloat` (not a path) is the first
word: the binary installs onto `PATH` (ADR 0010).

### 6. Release on the real quit path only

`Herdr.release/1` fires from `TUI.terminate/2` — every deliberate exit
funnels there (Ctrl+Q, confirmed double-Ctrl+C, `/quit`). There is **no**
in-process session switch in DashFloat (sessions change by restarting with
`--resume`, which is a new process that reports afresh), so release-on-exit
can never race a switch; releasing anywhere else would drop the pane's agent
slot while the agent still runs.

### 7. Identity

`--source dashfloat --agent dashfloat` — our own name, never `herdr:`-prefixed
(that prefix is reserved for Herdr's own integrations).

## Alternatives considered

- **A GenServer reporter process** — rejected: nothing needs a mailbox or
  state beyond the last seq/signature, which the TUI already owns; tasks under
  the existing supervisor match the codebase's side-request shape.
- **The `"$HERDR_BIN_PATH"` CLI as the transport** — rejected after live
  verification (§4): on Herdr 0.9.5 the CLI silently drops `pane
  report-agent` when spawned from inside a pane, while the socket API
  delivers. Revisit if Herdr fixes the CLI.
- **A client-side queue that drops older reports while one is in flight** —
  rejected: Herdr's seq guard already discards stale reports server-side;
  duplicating it client-side adds state without changing outcomes.
- **Attaching the resume argv to the state report** — rejected in favor of the
  dedicated `pane.report_agent_session` follow-up: the docs require the source
  to hold the pane first, and the pair (state, then session with the next
  seq) is exactly what Herdr's seq guard orders.
- **Wizard mapped to `working`** — rejected: the wizard waits on the user,
  not the machine; `blocked` is Herdr's "needs a decision" and drives the
  notification that brings the user back.

## Consequences

- Inside Herdr, DashFloat appears in the sidebar and `herdr agent list`/
  `wait`, participates in notifications, and reopens its session after a
  Herdr restart. Outside Herdr, nothing changes — one nil-check per event.
- The TUI gains two inert-by-default fields (`herdr`, `session_id`) and one
  hook point threaded through `mount`, `schedule`, the exit-guard expiry, and
  the `{:session_id, _}` landing; the agent gains one display send at id
  minting.
- A slow Herdr server costs at most one 2 s-bounded task per report and
  never touches the UI loop; a failed report is silent (fail-open
  absolutely).
- Delivery depends on the unix-socket API; if Herdr changes the protocol or
  DashFloat ever ships on Windows (named pipes), the transport needs a
  fallback — the request-building layer is transport-agnostic.
- Provider restore fidelity is bounded by what argv flags can express
  (profile + model); env-pinned base URLs are the documented gap.
