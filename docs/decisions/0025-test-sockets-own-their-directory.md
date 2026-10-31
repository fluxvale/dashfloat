# 0025 — Test-rig sockets own their directory: per-test unique, self-created

- **Status:** Accepted
- **Date:** 2026-10-31
- **Implements:** [issue #121](https://github.com/fluxvale/dashfloat/issues/121).
- **Pattern precedent:** the df92 XDG_DATA_HOME hermeticity fix — no test
  depends on filesystem state another test happens to create.

## Context

The Herdr delivery-path tests stand in for Herdr's server with a real
unix-domain listener (`:gen_tcp.listen/1`, `ifaddr: {:local, path}`). Their
socket path was derived as `/tmp/opencode/herdr-test-<unique>.sock` — inside a
directory **no herdr code ever created**. Nothing else in the suite creates
`/tmp/opencode` deliberately either: several modules `mkdir_p` their own
*unique subdirs* under it, so the parent appears only as a cross-module side
effect. On a dev box the harness pre-creates `/tmp/opencode`; on a fresh CI
runner `/tmp` starts empty.

An Erlang listener on `{:local, path}` fails with `{:error, :enoent}` when the
parent directory is absent (verified: `File.stat("/tmp/opencode")` →
`{:error, :enoent}` at the failed listen). Both delivery-path tests therefore
passed or failed on whether *some other module's* `mkdir_p` had landed before
the standin's listen — an ordering race under ExUnit concurrency, ~1-in-5 on
GitHub runners (issue #121), invisible locally. The herdr standin is the only
unix-socket listener in the suite; every other test server binds TCP loopback,
which has no filesystem coupling.

## Decision

**A test that binds a unix socket owns its directory: a unique per-test
subdirectory, created by the test itself before any listen, removed by
`on_exit`.**

`short_socket/1` now builds `/tmp/opencode/herdr-<name>-<unique>/s.sock`,
`mkdir_p`s the directory, and `rm_rf`s it on exit. The `File.rm(path)` before
listen stays: a killed run can leak a socket at the same unique integer path
on the next run (`System.unique_integer/1` restarts per VM), and the
`rm_rf`-then-`mkdir_p`-from-clean-slate discipline is the one
`Tools.RunnerTest` already follows.

The directory is per-test *unique*, not the shared `/tmp/opencode` itself:
mkdir on a shared parent would fix the missing-dir race but keep the
cross-module coupling (and nothing may ever `rm_rf` a parent other tests are
concurrently using). Path length stays far under the ~107-byte `sun_path`
cap — the reason ExUnit's own `tmp_dir` (long module-qualified names) is not
used.

The runtime side of [ADR 0024](0024-herdr-integration.md) is untouched: in
production Herdr owns its socket path; DashFloat only connects.

## Alternatives considered

- **`mkdir_p` on the shared `/tmp/opencode` parent** — fixes the missing-dir
  symptom but leaves every test implicitly coupled to one shared directory;
  also makes any future "clean the dir" helper a cross-test hazard. Rejected.
- **ExUnit's per-test `tmp_dir`** — module-qualified paths exceed the
  unix-socket `sun_path` cap on the herdr filenames. Rejected (as before).
- **Retries or serializing the herdr tests** — treat the symptom, hide the
  coupling. Rejected per issue #121's constraints.

## Consequences

- The delivery-path tests are hermetic: green on a fresh `/tmp` with the
  module run alone, in any order, at any concurrency.
- The rule generalizes: any future test binding a unix socket creates its own
  directory and never relies on a shared one existing.
