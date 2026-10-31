# 0029 — Capture-rig reply-end needles are exchange-unique

- **Status:** Accepted
- **Date:** 2026-11-01
- **Implements:** [issue #125](https://github.com/fluxvale/dashfloat/issues/125).
- **Pattern precedent:** the F7 caveat's own remedy (`wait_for` a content
  needle, not quiet) — this ADR makes that remedy structurally safe.

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
  (marked at the counter in `_sse`).
- If the app ever retries a stock request on a new connection, the retry
  takes the next number and the scenario's wait times out — a loud capture
  failure, which is the rig's contract (fail, never ship).
- `test/dash_float/rig_needle_test.exs` pins the source invariants (no bare
  reply-body needle; the sentinel is defined, stamped, and waited on; waits
  match wrap-collapsed text). It is red on the pre-fix rig by construction.
