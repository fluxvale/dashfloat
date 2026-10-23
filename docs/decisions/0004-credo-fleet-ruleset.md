# 0004 — Credo ruleset pinned to the FluxVale fleet config

- **Status:** Accepted
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
