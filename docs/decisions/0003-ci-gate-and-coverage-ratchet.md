# 0003 — CI gate and coverage ratchet

- **Status:** Accepted
- **Date:** 2026-10-23

## Context

The bootstrap workflow ran four steps inline (`deps.get --check-locked`,
`format --check-formatted`, `compile --warnings-as-errors`, `test
--warnings-as-errors`). A list duplicated between CI and local devs drifts: a
check added in one place is silently absent in the other. DashFloat also wants
static analysis (Credo, Dialyzer) and coverage tracking from the start rather
than retrofitted over a grown codebase.

## Decision

**One gate alias.** `mix ci` in `mix.exs` is the single list of checks, and CI
invokes only that alias — never the steps individually. Locally, `mix ci` is the
same command (all CI-grade tasks are pinned to `:test` via
`cli/preferred_envs`, so a dev-env invocation works). Checks: `deps.get
--check-locked`, `format --check-formatted`, `compile --warnings-as-errors`,
`credo --strict`, `dialyzer`, `coveralls.multiple --type json --type html`.

**Cache keying on resolved versions.** Both caches key on setup-beam's
`elixir-version`/`otp-version` outputs — the versions actually installed — not
the requested `"1.20.x"`/`"29"` strings, plus `hashFiles('mix.lock')`. A runner
patch bump therefore busts the cache instead of restoring a binary-incompatible
build. Dialyzer's PLT gets a separate cache (`dialyzer-` prefix, `priv/plts`):
a PLT is a binary tied to the exact OTP patch, and a stale restore fails with
"Old PLT file".

**Coverage floor as a ratchet.** `coveralls.json` sets `minimum_coverage` to
today's measured value — 100 as of this ADR — enforced by ExCoveralls on every
gate run. It is a ratchet: raised as coverage improves, never lowered to make a
red run green.

**`Wait for CI` as the required check.** The `wait-for-ci` umbrella job runs
`if: always()` and passes only when every job in `needs` succeeded or was
skipped. Branch protection requires this check, so a job renamed or added later
cannot leave a required check pending forever — the umbrella is the only check
guaranteed present. The skipped arm is future-proofing for path-gated jobs.

**Codecov upload watchdog.** The upload sets `fail_ci_if_error: true`: an
upload failure or a codecov.io outage reds the step instead of silently
dropping coverage.

## Alternatives considered

- **Inline steps in the workflow** (the bootstrap shape) — two lists to keep in
  sync; rejected for that drift.
- **A separate coverage job re-running the suite** — a second full run for one
  artifact; the gate already produces both, so rejected.
- **`coveralls.json` then `coveralls.html`** — the obvious pair, but Mix does
  not re-run the `test` task twice in one invocation, so the second task
  generates no report and CI's HTML artifact is empty. `coveralls.multiple
  --type json --type html` runs the suite once and writes both; chosen.
- **Codecov `fail_ci_if_error: false`** — a silent coverage drop is worse than
  a red build on a third-party outage; revisit only if outages bite.
- **A `.credo.exs` with relaxed rules** — nothing in the current code fails the
  default ruleset, so no config file ships at all.

## Consequences

- Adding a check means editing one list, in `mix.exs`; CI needs no change.
- The floor must be raised deliberately in the same PR that adds coverage —
  otherwise it silently guards an old value.
- A Dialyzer PLT build is slow on a cache miss (minutes); the separate cache
  key keeps that rare.
- `priv/plts/` is gitignored and rebuilt as needed, never committed.
