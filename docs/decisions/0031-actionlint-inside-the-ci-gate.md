# 0031 — actionlint inside the mix ci gate

- **Status:** Accepted
- **Date:** 2026-11-01
- **Implements:** [issue #53](https://github.com/fluxvale/dashfloat/issues/53).
- **Amends:** [ADR 0003](0003-ci-gate-and-coverage-ratchet.md) (the gate's check
  list).

## Context

Lanes have run actionlint **manually** at release-prep time (1.7.12, clean) —
it earned its keep there ([#49](https://github.com/fluxvale/dashfloat/issues/49)
review: release.yml problems caught at authoring time) — but nothing enforces
it. A malformed workflow file lands green and only fires as mystery behavior on
the next tag or run. The zero-runs episode is the motivating story: a linter
would not have caught that specific event, but the class it represents —
silently broken workflow files — is actionlint's exact diet.

The gate's shape is already settled ([ADR 0003](0003-ci-gate-and-coverage-ratchet.md)):
the whole gate is `mix ci`, the one list CI and local devs run, precisely so
the two cannot drift. So actionlint must ride **inside** the alias — a step in
`ci.yml` would be a second list, the exact drift ADR 0003 rejected.

Availability is the real decision. Observed on this machine the day this
shipped: bare actionlint **fatals** (exit 3) because a mise-managed
`shellcheck` shim sits on PATH with no version set — PATH lookup is not a
theoretical hazard but a live one, and "present on PATH" does not mean
"works". And a skip-with-warning is a green gate that did not check — the
silent-gap class this lane exists to close, reopened.

## Decision

**One new alias step.** `mix ci` gains `lint.workflows` (second position,
after `deps.get --check-locked`), running `Mix.Tasks.Lint.Workflows`:

- actionlint over every workflow file under `.github/workflows` (`.yml` and
  `.yaml`), invoked with
  `-shellcheck <pinned path>` so every `run:` block is shellchecked through
  actionlint's own integration — no PATH roulette;
- shellcheck over `install.sh` and `scripts/*.sh`;
- exit 1 = findings, any other exit = the tool refusing to run (actionlint
  exits 3 on unreadable input) — both red the gate; a clean run prints one
  line per tool (`actionlint: clean`) so CI logs prove the step ran.

**The gate fetches its own pinned binaries.** `DashFloat.PinnedTool` pins
actionlint **1.7.12** and shellcheck **0.11.0** — the version plus the sha256
of each release's `.tar.gz` for all four unix platforms (linux/darwin ×
amd64/arm64; actionlint's rows come from the release's own checksums file,
shellcheck ships none, so its rows were computed from the HTTPS-fetched
assets). On first use it downloads the archive, verifies the sha256, extracts
just the binary (stdlib `:erl_tar` — both tools ship `.tar.gz`, which is also
why shellcheck's `.tar.xz` assets are not used) into
`_build/tools/<tool>-<version>/bin/`, chmods it, and writes the archive sha
as a marker **last**: marker + binary is the whole cache-validity story, so a
version bump invalidates by content, with no cache-key dance. A successful
install also prunes the previous version's cache dir. Transient download
failures retry (`:safe_transient`) — a one-off network blip must not red a
cold-cache CI run. Later runs are
served warm (~1.3 s for the whole step).

**No PATH lookup, no skip.** CI and local run the same code path and the same
pinned version — availability cannot drift, and CI's workflow file gains
zero steps. A cold cache without network fails the gate loudly — the same
class as `deps.get --check-locked` offline. The shellcheck finding the step
immediately made (SC2015's `A && B || C` in ci.yml's wait-for-ci script) is
rewritten to if/else in this same change; no lint suppressions ship.

## Alternatives considered

- **An actionlint step in `ci.yml`** (the issue's original shape: a pinned
  download in CI) — beside the gate, not inside it: two lists that drift, and
  a workflow edit for every tool bump.
- **PATH lookup locally, skip-with-warning when absent** — the weakest form:
  the gate is green exactly when the check did not run.
- **PATH lookup locally, hard-fail when absent** — stronger, but the version
  is whatever happens to be installed (local and CI drift in behavior), and
  the broken-shim observation above shows presence ≠ working.
- **A mise/asdf plugin pin in the repo** — adopts a tool-manager convention
  repo-wide while CI (setup-beam) still needs a second install path; the
  drift survives, with a new dependency.
- **Vendoring the binaries in git** — four platform builds × two tools of
  mutable binaries in history; upgrades ship blobs. Rejected.
- **A pinned lint container job in CI** — out-of-gate again, plus workflow
  churn.

## Consequences

- The first `mix ci` on a machine downloads each tool once (~2.3 MB
  actionlint, ~3.8 MB shellcheck on linux/amd64); after that the step is
  local and fast. `_build/tools/` rides the existing `/_build/` gitignore.
- Bumping a tool = editing its version and four shas in `PinnedTool`;
  nothing else moves.
- `DASHFLOAT_TOOL_ROOT` overrides the cache root (tests point the task at a
  seeded cache; an operator can move it). Tests exercise the downloader
  against the loopback SSE server seam with stub archives via `fetch/2`
  opts (`:root`, `:base`, `:sha`) — the suite never downloads anything.
- The downloader is app code in `lib/`, so the coverage ratchet
  ([ADR 0003](0003-ci-gate-and-coverage-ratchet.md)) applies to it.
- `mix lint.workflows` is runnable on its own in any env; a bare task
  context starts no applications, so the cold path starts `:req` itself.
