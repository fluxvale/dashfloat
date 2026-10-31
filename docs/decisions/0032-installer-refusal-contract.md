# 0032 — The installer's glibc-floor refusal contract

- **Status:** Accepted
- **Date:** 2026-11-01
- **Amends:** [ADR 0010](0010-release-packaging.md) (§ Installer, § Consequences)
- **Issue:** [#52](https://github.com/fluxvale/dashfloat/issues/52)

## Context

The release pipeline proves the glibc floor with a negative smoke: a
`debian:bullseye` container (glibc 2.31) must be refused. Until this ADR
the job accepted **any** failure as proof, and `install.sh` had no glibc
check at all — the floor made itself felt only when the installed binary
failed to start, after a full download and a complete install on disk, with
the loader's real error captured into a variable and never printed.

On the v0.4.0 tag the false green was live: stock bullseye lacks
`libcrypto.so.3` (it ships OpenSSL 1.1), so the library preflight refused
first, and the job passed without the floor ever being exercised. A
negative test that any failure satisfies is a test that proves nothing —
this ADR is the refusal contract both sides now hold.

## Decision

`install.sh` refuses a below-floor host itself, and the negative smokes
assert the specific refusal. The contract has three clauses:

1. **The message.** A Linux host whose glibc is below the floor is refused
   with `glibc <version> is below the GLIBC_2.34 floor (DashFloat needs
   glibc 2.34+, Debian 12+, Ubuntu 22.04+); nothing was downloaded or
   installed` — naming the running version, the floor, and the outcome. It
   fires in a new preflight that runs **before** the by-name library check:
   on an old-glibc host a missing-library hint is wrong advice (installing
   `libssl3` cannot help a binary the loader will still refuse), and the
   floor refusal must be the one that fires deterministically, whatever
   libraries happen to be present.
2. **The exit code.** Every installer refusal exits 1 through `die`.
3. **Nothing left behind.** A refused install writes nothing: no data
   directory, no shim. The preflight placement guarantees it; the smokes
   assert it.

The clauses are asserted in one shared, shellchecked script,
`scripts/refusal-contract.sh`, used by both negative smokes: the tag-run
`smoke-linux` bullseye arm (against the published `install.sh`, still
`curl | sh`) and a new bullseye arm in the dispatch `smoke-rehearsal`
(against the branch's installer and freshly built artifacts) — so the
strengthened assertion runs before a tag exists instead of first reding on
release day. A hermetic mix test pins the die message and the contract
script's grep to the same fragment and requires both smokes to invoke the
contract script, so the pair cannot drift through `mix ci`.

The floor itself stays where [ADR 0010](0010-release-packaging.md) put it:
a property of the pinned Debian 12 build image, moved only by deliberate
commit — in three places that move together: the workflow's measured
`objdump` check, the installer's preflight, and this contract's message.

Fixed here in the same class: the installer's post-install smoke died
claiming "the error above names what is missing" while swallowing the
captured error; it now prints the binary's actual failure before refusing.

## Alternatives considered

- **Keep any-failure acceptance, install the preflight libraries in the
  job** (issue #52's minimal reading) — the refusal then depends on the
  host loader's wording after a 30 MB download and a full install on disk,
  and the job proves the floor only on hosts configured to reach it.
- **Assert the loader's `GLIBC_2.34 not found` error** — that string
  belongs to the host's `ld.so`, not to DashFloat; it can change between
  glibc releases and never appears in the installer's own refusal.
- **No glibc preflight; clean up after a failed post-install smoke** —
  still downloads 30 MB to refuse, and every below-floor user pays for it.

## Consequences

- A below-floor host is refused in milliseconds with advice that names the
  real limit, before anything is downloaded.
- The negative smokes can fail: a missing refusal, a wrong message, a wrong
  exit code, an unrelated crash, or a leftover partial install each red the
  job. That is the point.
- Wording changes to the floor refusal must update `install.sh` and
  `scripts/refusal-contract.sh` together — or `mix ci` reds.
