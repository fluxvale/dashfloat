# 0029 — Capture-rig reply-end needles are exchange-unique

- **Status:** Accepted
- **Date:** 2026-11-01
- **Implements:** [issue #125](https://github.com/fluxvale/dashfloat/issues/125).
- **Pattern precedent:** the F7 caveat's own remedy (`wait_for` a content
  needle, not quiet) — this ADR makes that remedy structurally safe.
- **Amendment:** [2026-11-02, issue #143](#amendment-2026-11-02-issue-143-the-episodes-queue-is-dropped-not-wired)
  (the never-landed episode dispatch is void — the queue was deleted).

## Context

The rig's scripted stock reply is byte-identical every exchange, and every
scenario waited out a reply with `wait_for("rest")` — the reply's last body
word. In a two-exchange scenario (`scenario_reading_session`,
`scenario_growing_session`) the second exchange's needle was satisfied by the
first reply's stale text: measured on main, the first wait blocked 2.63 s for
the real reply while the second returned in 0.00 s — a no-op. The settle gate
(`wait_quiet`) cannot close the gap: its documented F7 caveat says token
frames can land under `QUIET_CHUNK_BYTES`, so quiet can pass mid-stream. A
still taken then ships a mid-race state (second reply absent or partial) as
settled evidence — the ex_ratatui lane's review caught one such still, and
the rig is the fleet's evidence machine, so every lane's verification was
quietly weaker.

The same audit found the mock sick since the #141 squash merge:
`_usage_and_done` was extracted into a method but kept `_sse`'s closure
variables, so **every streamed reply since #141 died with `NameError` after
its last token** — no usage frame, no `[DONE]`, the app finalizing on
connection close. `scenario_growing_session` still "passed" on persist-driven
footer snapshots, meaning its documented guard ("a mock that stopped
reporting usage fails the capture") was not actually enforced. The #133/#134/
#135 rig scenarios are unreachable besides (their argparse entries and the
episode/vet dispatch never landed) — separate follow-up, not this ADR.

## Decision

**Reply-end needles are exchange-unique by construction, not by diligence.**

1. The mock numbers its stock replies per app run (`STOCK_REPLIES` counter,
   reset by `App.__init__`): the n-th streamed stock reply closes with
   `— turn-N.` (`stock_closing(n)` is the one definition both the mock and
   the scenarios read). Every reply-end wait is `wait_for(stock_closing(n))`
   for its own n — a needle that no earlier exchange can render. The number
   in the log is also honest capture evidence: a still of a two-exchange
   scenario visibly carries both exchanges.
2. `wait_for`/`wait_gone` match whitespace-collapsed screen text
   (`flat_text`) — a needle may wrap across rows at any pty width, and a
   reader still reads the words as contiguous. Without this, a long closing
   would pass at one `--cols` and straddle a wrap at another.
3. Mid-stream needles (`"processes"`, `"independently"` — intentionally
   firing during the stream) and UI needles (popups, dialogs, footers) stay
   literal: the class defect is only the reply-END wait, whose job is to
   prove an exchange finished.
4. `_usage_and_done(req, reasoning_deltas)` takes its inputs as parameters;
   usage frames and `[DONE]` land again, and growing-session's usage-driven
   growth guard is real again.

Rejected: counting on-screen occurrences of a shared needle (breaks the
moment a reply scrolls off); a byte-offset watermark with partial replay
(the app re-emits existing rows on redraw, so raw bytes false-positive, and
replay into a snapshot screen is heavy machinery for a rig).

## Consequences

- A future episode dispatch in the mock must pop `EPISODES` before taking a
  stock number — episode replies carry their own unique text and take none
  (marked at the counter in `_sse`). *(Voided — 2026-11-02, #143: the
  queue was dropped, never wired — see the amendment below.)*
- If the app ever retries a stock request on a new connection, the retry
  takes the next number and the scenario's wait times out — a loud capture
  failure, which is the rig's contract (fail, never ship).
- **Load-bearing invariant (hostile-review finding): the reopened apps never
  submit.** The per-run counter reset means a resumed app's screen already
  replays the first app's persisted `— turn-1.` reply — the first
  reopened-app scenario that SUBMITS would see `wait_for(stock_closing(1))`
  satisfied instantly by replayed text. A future reopened-submit scenario
  must account for replayed closings (skip replays, or key its needle past
  the replay boundary).
- `flat_text` joins the whole screen with single spaces: a multi-word needle
  can match across what were separate regions. No current needle can (the
  sentinel is one token; UI needles are row-local), but needles added near
  region boundaries should stay row-local.
- A reply-end gate must use content visible in the CURRENT scroll state:
  `scenario_scrolled_stream` parks the view off the tail, so its reply's
  closing is below the viewport by design — the turn's end gates on the
  activity row retiring (`wait_gone("Streaming")`, visible in every scroll
  state), never on reply text.
- `test/dash_float/rig_needle_test.exs` pins the source invariants: every
  literal wait needle is frozen in an allowlist (a new one is a visible
  diff), no wait draws from the stock body or `REPLY_TOKENS`, the reply-end
  family rides `stock_closing` (site count never shrinks), and both waits
  match wrap-collapsed text. It is red on the pre-fix rig by construction.

## Amendment (2026-11-02, issue #143): the EPISODES queue is dropped, not wired

**Status:** Accepted (the owner's standing default — dead code misleads —
declared by the operating PA and not countermanded; the fork and its
reversibility are recorded in issue #143 and its closing PR, and the
morning-revert path below).
The Context's "separate follow-up" is resolved: of the wire-or-drop fork,
the rig **drops** the interaction-surface episode machinery.

- **Deleted:** `MockHandler.EPISODES`, `App.script/1`, the never-landed
  vet dispatch (`VET_REPLY`, `is_vet_request` — zero callers since the
  #141 era), the four unreachable scenarios (`approve-choice`,
  `question-single`, `question-multi`, `auto-reject` — never in the
  argparse menu), their dispatch branches, and their entries in the
  needle allowlist. The sentinel-site floor (≥9) is untouched: those
  scenarios waited on literals, not `stock_closing`.
- **Kept:** the shipped captures in `docs/screenshots/133–135/` as frozen
  evidence — the widget behavior they prove is app behavior (ADR 0028)
  with its own unit/integration tests; only the rig's ability to
  regenerate them died (with the queue, not with this ADR).
- **If the owner rules wire-in-the-morning:** revert the squash — the
  scenarios' text is in git history, and the wiring rule this ADR
  recorded (pop before taking a number) is the design to implement.
