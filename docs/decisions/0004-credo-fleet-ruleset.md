# 0004 — Credo ruleset pinned to the FluxVale fleet config

- **Status:** Accepted; **amended 2026-10-29** (`StructFieldAmount`
  parameterized to `max_fields: 40` for the TUI's whole-state struct; see
  [Amendment (2026-10-29): StructFieldAmount at 40](#amendment-2026-10-29-structfieldamount-at-40-tuistate)
  below)
- **Date:** 2026-10-23
- **Implements:** [issue #10](https://github.com/fluxvale/dashfloat/issues/10).
- **Supersedes:** the "no `.credo.exs` at all" alternative recorded in
  [ADR 0003](0003-ci-gate-and-coverage-ratchet.md) (the rest of 0003 stands).

## Context

`mix ci` ran `credo --strict` with no `.credo.exs` — credo's implicit default
ruleset (ADR 0003: nothing in the code failed it, so no file shipped). That
means the rule set silently changes with every credo upgrade, and it diverges
from the rest of the FluxVale fleet, where the reference config at
`~/Work/FluxVale/fluxvale/apps/platform/.credo.exs` (generated against credo
1.7.19, exact-pinned in both repos) settles the posture: fully enumerated
checks (immune to credo drift), `UnusedVariableNames [force: :meaningful]`,
`TagTODO [exit_status: 2]` (TODOs fail the gate), `MaxLineLength` at 120 with
low priority, `Readability.Specs` on, and a fixed disabled list.

## Decision

**Ship a `.credo.exs` derived from the fleet reference.** Same enabled set,
same disabled list, same per-check parameters, `strict: true` — identical
modulo single-app adaptations:

- `files.included` is `lib/` + `test/` only (no `src/`, `web/`, or umbrella
  `apps/*` paths exist here).
- The reference's Phoenix-web-only exemptions are dropped as dead entries:
  `flux_vale_web` module excludes, generated components, telemetry,
  `test/support`, and `Readability.Specs`' web-layer file exclusion. Specs are
  required everywhere here.

Adopting the ruleset surfaced ~150 findings in the TUI code (missing `@spec`s,
bare `_` names, single/multi-pipe style, variable rebinding, `@impl true`,
grouped aliases, `String.to_atom` in tests). All were fixed in the same change
with behavior-preserving edits; no check was relaxed to make that easier.

The config carries a header crediting its derivation and source path: future
readers diff the two files to sync fleet-wide changes, and a check added by a
future credo stays off until it is enumerated in both.

## Alternatives considered

- **Keep the implicit default ruleset** (ADR 0003's stance) — drifts with credo
  upgrades and diverges from the fleet; rejected for consistency.
- **`mix credo.gen.config` from scratch** — a second opinion to maintain;
  adopting the fleet's settled one is less total work.
- **Relax or parameter-scope checks the codebase fails** — the failures were
  real style debt, not noise; fixing the code keeps the ruleset identical to
  the reference.

## Consequences

- Credo upgrades cannot change the rule set: every check is enumerated, so a
  new credo version only changes check *implementations*.
- TODO/FIXME comments now gate the build (`TagTODO [exit_status: 2]`) — a
  `# TODO` fails `mix ci` until resolved or removed.
- Public functions need `@spec`s, and the test suite is held to the same
  readability rules as `lib/`.
- Sync with the fleet is a manual diff against the reference config (the
  header points at it); local deviations should be none.

## Amendment (2026-10-29): StructFieldAmount at 40 (TUI.State)

**Status:** Accepted. One deviation from the "identical modulo
single-app adaptations" rule above, recorded so the ruleset and the ADR
cannot drift.

`StructFieldAmount` is parameterized to `max_fields: 40` globally (credo's
default is 31 — the fleet config passes no parameter, i.e. 31): after the
ghost-text plumbing ([ADR
0015](0015-input-surface-cursor-stats-ghost.md) §3), `TUI.State` carries 38
fields. That size is deliberate — the TUI state is one flat pure struct
whose transitions read it whole (ADRs 0002, 0006, 0015; the ADR 0002
whole-state contract, the ADR 0006 render contract, and ADR 0015's
arm/reap/epoch intents all ride the same `%State{}`), and slicing it into
nested sub-structs would fight every whole-state transition for no behavior
gain.

**Scope:** the parameter is global, not a per-file exclude, because credo
check parameters cannot be scoped per file — 40 was chosen as the smallest
whole number above the struct's actual size, so any future field creep past
40 still fails the gate.

**Rider (2026-10-30, [issue #67](https://github.com/fluxvale/dashfloat/issues/67)
stage 2):** the gate fired exactly as designed — the footer's context
snapshot carry ([ADR
0015](0015-input-surface-cursor-stats-ghost.md) §2's stage-2 amendment)
is field 41, same flat-struct rationale (pure data the render contract
reads whole; nesting it into the numeric `stats` map would muddy that
type). `max_fields` moves to 41 — again the smallest whole number above
the actual size, so the creep gate stands.

**Rider (2026-10-31, [issue #106](https://github.com/fluxvale/dashfloat/issues/106)):**
the title and its dialog ([ADR
0023](0023-session-titles-and-uuid-ids.md)'s 2026-10-31 amendment) are
fields 44 and 45 — the dialog is the attach prompt's shape (a pure
draft+error map the key router and the view read whole). `max_fields`
moves to 45, again the smallest whole number above the actual size, so
the creep gate stands.

**Rider (2026-10-31, [issue #104](https://github.com/fluxvale/dashfloat/issues/104)):**
the idle blink's phase/timer/cadence ([ADR
0006](0006-ui-truth-and-rendering.md)'s 2026-10-31 blink amendment) are
three more flat fields — the blink timer lives in the TUI process but its
display phase and injected cadence are pure state the router, view, and
schedule choke point read whole (the tick's `anim_step`/`tick_ref` pair is
the direct precedent). Numbered against the #113 Herdr rider's landing
between design and rebase, they are fields 48–50. `max_fields` moves to
50, again the smallest whole number above the actual size, so the creep
gate stands.

**Rider (2026-10-31, [issues #127/#128](https://github.com/fluxvale/dashfloat/issues/127)):**
the sessions store directory ([ADR 0027](0027-exit-resume-command-and-resume-picker.md))
is field 51 — pure state the /resume picker's listing and the exit print's
existence check both read. `max_fields` moves to 51, again the smallest
whole number above the actual size, so the creep gate stands.
