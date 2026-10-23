# 0003 — CI gate and coverage ratchet

- **Status:** Accepted
- **Date:** 2026-10-23
- **Implements:** [issue #5](https://github.com/fluxvale/dashfloat/issues/5).

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
same command: the alias is pinned to `:test` via `cli/preferred_envs`, so a
dev-env invocation works without a `MIX_ENV` prefix. Checks: `deps.get
--check-locked`, `format --check-formatted`, `compile --warnings-as-errors`,
`credo --strict`, `dialyzer`, `coveralls.multiple --type json --type html`.

`deps.get --check-locked` fetches a missing `deps/` itself, so CI has no
`mix deps.get` bootstrap step: a plain `deps.get` first would silently rewrite
a stale lock, leaving the check-locked gate passing on a lockfile it just
repaired. NB: the alias runs under `MIX_ENV=test`, so the lock check sees the
dev+test dep set — a future `only: :dev` dep would need its own care.

**Cache keying on resolved versions.** Both caches key on setup-beam's
`elixir-version`/`otp-version` outputs — the versions actually installed — not
the requested `"1.20.x"`/`"29"` strings, plus `hashFiles('mix.lock')`. A runner
patch bump therefore busts the cache instead of restoring a binary-incompatible
build. Dialyzer's PLTs get a separate cache (`dialyzer-` prefix): the project
PLT in `priv/plts` and the Erlang/Elixir core PLTs in `~/.mix` — a PLT is a
binary tied to the exact OTP patch, and a stale restore fails with "Old PLT
file", while leaving the core PLTs out would rebuild them on every fresh
runner.

**Coverage floor as a ratchet.** `coveralls.json` sets `minimum_coverage` to
the codebase's measured coverage — enforced by ExCoveralls on every gate run.
Introduced at 100 (the bootstrap baseline), re-baselined to **94.3** when the
TUI skeleton ([ADR 0002](0002-tui-skeleton.md), #6) merged mid-flight, and to
**98.0** with the streaming engine ([ADR 0004](0004-llm-streaming-engine.md),
#8): the floor tracks the measured baseline of the code that lands, never a
wish about it. From here it is a ratchet — raised as coverage improves, never
lowered to make a red run green. `skip_files` excludes `test/`: test-support
code (the loopback SSE server, [ADR 0004](0004-llm-streaming-engine.md)) is
harness, not shipped, and the floor guards `lib/`.

**`Wait for CI` as the required check.** The `wait-for-ci` umbrella job runs
`if: always()` and passes only when every job in `needs` succeeded or was
skipped. Branch protection requires this check, so a job renamed or added later
cannot leave a required check pending forever — the umbrella is the only check
guaranteed present. The skipped arm is future-proofing for path-gated jobs.

**Codecov upload watchdog.** The upload sets `fail_ci_if_error: true`: an
upload failure or a codecov.io outage reds the step instead of silently
dropping coverage. It is skipped for fork PRs — they receive no secrets, and a
missing token with `fail_ci_if_error` would red every external contribution.
Same-repo Dependabot PRs are skipped for the same reason
([#13](https://github.com/fluxvale/dashfloat/issues/13)): GitHub withholds
repo secrets from `pull_request` runs attributed to `dependabot[bot]` —
re-runs included (on [PR #9](https://github.com/fluxvale/dashfloat/pull/9),
run 39931638996, the attempt-2 human re-run still sent an empty token), so
the skip keys on `github.actor`, which stays `dependabot[bot]` on re-runs.

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
- **Keying the Dependabot skip on the PR author**
  (`github.event.pull_request.user.login`) — a human push to a Dependabot
  branch flips the run's actor and does get secrets, so the run actor is the
  semantically correct key; rejected.
- **A `.credo.exs` with relaxed rules** — nothing in the current code fails the
  default ruleset, so no config file ships at all. (Reversed by
  [ADR 0004](0004-credo-fleet-ruleset.md), which ships the fleet's config.)

## Consequences

- Adding a check means editing one list, in `mix.exs`; CI needs no change.
- The floor must be raised deliberately in the same PR that adds coverage —
  otherwise it silently guards an old value.
- A Dialyzer PLT build is slow on a cache miss (minutes); the separate cache
  key keeps that rare.
- `priv/plts/` is gitignored and rebuilt as needed, never committed.
- Dependabot PRs (and their re-runs) land with no Codecov upload at all —
  `mix ci` still gates them; only the upload is skipped.
