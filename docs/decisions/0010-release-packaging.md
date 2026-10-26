# 0010 — Release packaging: core `mix release` tarballs, installer, Homebrew

- **Status:** Accepted
- **Date:** 2026-10-26
- **Supersedes:** the Distribution row of [ADR 0001](0001-founding-stack-and-architecture.md)

## Context

ADR 0001 chose `burrito` for single-binary distribution. That dependency was
pinned at bootstrap and never exercised: until this decision there was no
release workflow, no release config, and no artifact ever built. Burrito's
repository is archived on 2026-11-30 (final release 1.6.0, July 2026), and its
predecessor Bakeware is already dead. Both of the tools built on top of it
(relexe, tinfoil) inherit that end of life.

The packaging lane exists to ship a release users can install and run without
an Erlang/Elixir toolchain, and to prove the packaging works before v0.1.0 is
announced. The constraints that decide the shape:

- The BEAM is a native executable. A release bundles ERTS but not the system
  libraries `beam.smp` and the crypto NIF are linked against: on Linux those are
  `libtinfo.so.6`, `libstdc++.so.6`, and OpenSSL 3 (`libcrypto.so.3`). Any Linux
  artifact therefore has a glibc floor and real runtime library dependencies.
  Measured, not assumed: Debian 11 (glibc 2.31) fails with
  `GLIBC_2.34 not found`; Debian 12 (2.36) runs.
- `ex_ratatui` resolves its Rustler NIF from `rustler_precompiled` per
  `{target, nif_version}`. There are native artifacts for
  `x86_64-unknown-linux-gnu`, `aarch64-apple-darwin`, and
  `x86_64-apple-darwin` (nif 2.17 for OTP 29), so each platform can build
  natively — no cross-compilation, no Rust toolchain, no Zig.
- GitHub's `ubuntu-22.04` runner is deprecated (terminated 2027-04-17).
  Building on `ubuntu-24.04` natively would set a glibc 2.39 floor, cutting off
  Debian 12 and Ubuntu 22.04 users. `macos-15-intel` is the last x86_64 macOS
  runner and is retired in August 2027.
- macOS quarantines downloaded binaries that are not notarized. No packaging
  tool changes that; only an Apple Developer account does.

## Decision

**Drop `burrito` and package with core `mix release`.** The artifact is a
per-platform tarball of the assembled release directory; an installer script and
a Homebrew formula wrap it. This is the LiveBook/mise/asdf shape: no wrapper
project to outlive, and the release format is supported by Elixir itself.

### Release assembly

`mix.exs` declares one release, named `dashfloat` (the binary name users type,
distinct from the OTP app `:dash_float`), with `include_executables_for: [:unix]`.
Version `0.1.0` is the first release cut from this pipeline.

A `rel/env.sh.eex` overlay sets `RELEASE_DISTRIBUTION=none`. A single-user
CLI/TUI starts no distribution and needs no epmd, and the default `sname` makes
two concurrent instances collide on one machine.

Elixir's generated `bin/dashfloat` launcher is operator-shaped: every argument
is a release command, `start` discards its own arguments, and a bare
invocation prints a command list. That is the wrong shape for a binary users
run, and it silently breaks `--version` *and* the existing `--profile`/`--model`
selection flags. Release assembly therefore rewrites two fragments of Elixir's
own launcher (a step in `mix.exs`, not a forked launcher):

- a bare or `-`/`--`-leading invocation is treated as `start`, so `dashfloat`
  starts the TUI and `dashfloat --version` answers;
- `start` shifts the command word and forwards `"$@"` to the VM.

The step fails the build if either fragment is missing, so an Elixir upgrade
that changes the template breaks the release loudly instead of shipping a
binary that ignores what the user typed.

A release also boots applications *before* Elixir's CLI parses `-extra`
arguments into `System.argv/0`, so at boot `System.argv/0` is empty. The boot
falls back to `:init.get_plain_arguments/0` (minus the launcher's `--no-halt`),
which is what makes the flags work in a packaged binary.

The release boot answers `--version` before config loading or terminal
initialization, and forces the `ex_ratatui` NIF to load first: a version query
is also the cheapest packaging smoke, so a NIF/host mismatch must fail loudly
instead of printing a version.

That path ends in `System.halt/1`, which would take the test VM down with it, so
the boot takes the halt function and the argument sources through its existing
`args` seam (`halt:`, `plain_argv:`, `system_argv:`). Production passes none of
them and gets `System.halt/1` and the real sources; the tests pass a function
that reports the exit code, which is what lets the version arm, its stdout
write, and both branches of the argv fallback be covered rather than excluded
from the coverage floor.

### Platforms and the glibc floor

| Target | Runner | Produces |
| --- | --- | --- |
| `x86_64-unknown-linux-gnu` | `ubuntu-24.04` host, build inside `debian:bookworm` container | glibc 2.34 floor |
| `aarch64-apple-darwin` | `macos-15` (arm64) | native macOS arm64 |
| `x86_64-apple-darwin` | `macos-15-intel` | native macOS x86_64 |

The Linux build runs in a pinned `hexpm/elixir` bookworm image rather than on
the runner's own OS. Bookworm is the oldest still-supported Debian with an
OTP 29 build image, and the artifact it produces needs **glibc 2.34** — the
floor is a property of the image, not of the runner host, so it does not move
when GitHub replaces the 24.04 host. That covers Debian 12+ and Ubuntu 22.04+;
Debian 11 is out, which matches Debian's own support window.

x86_64 macOS keeps its slot in v0.1.0. The `macos-15-intel` retirement in
August 2027 is recorded here and in the release notes as a future migration;
shrinking the first release to avoid a migration roughly two years out is the
wrong trade.

Linux aarch64, musl/Alpine, and Windows are out of scope for v0.1.0. Alpine is
the honest gap against single-binary tools: a musl artifact needs a musl ERTS
and musl NIFs, and precompiled musl ERTS is exactly the trick that made Burrito
attractive. It is deferred until someone asks, not replaced.

### Artifact layout

Each tarball holds the release root directly (`bin/`, `erts-*/`, `lib/`,
`releases/`) with no wrapper directory, so extraction into an empty versioned
directory and Homebrew's `libexec.install Dir["*"]` both work unchanged. Assets
per tag:

```
dashfloat-0.1.0-x86_64-unknown-linux-gnu.tar.gz
dashfloat-0.1.0-aarch64-apple-darwin.tar.gz
dashfloat-0.1.0-x86_64-apple-darwin.tar.gz
dashfloat-0.1.0-sha256sums.txt
install.sh
```

One checksums file, one line per asset (`<sha256>  <filename>`), is the single
source both the installer and the formula read. `install.sh` is attached to the
release too, so the URL a user pipes from always serves the script that shipped
with that version.

### Installer

`install.sh` is a POSIX shell script published in the repo and attached to each
release, so the URL a user pipes from is always the script that shipped with
that release:

```
curl -fsSL https://github.com/fluxvale/dashfloat/releases/latest/download/install.sh | sh
```

It installs into versioned directories and never writes outside them:

- `$DASHFLOAT_HOME` (default `${XDG_DATA_HOME:-$HOME/.local/share}/dashfloat`)
  holds `versions/<version>/` and a `current` symlink.
- `$DASHFLOAT_BIN_DIR` (default `$HOME/.local/bin`) gets a `dashfloat` shim
  script that execs `current/bin/dashfloat`, so an upgrade only moves the
  symlink and PATH never goes stale.
- The tarball's sha256 is verified against the release checksums file before
  anything is extracted. A mismatch aborts with both hashes printed.
- Upgrading prunes every version directory except the new one. One version on
  disk, no rollback: a CLI this size re-installs in seconds, and keeping old
  copies of a self-contained runtime is the failure mode worth avoiding.
- `DASHFLOAT_VERSION` pins a version; the default resolves `releases/latest`.
  `DASHFLOAT_RELEASE_BASE_URL` overrides asset URLs (used by CI to smoke the
  exact artifacts it just built).

Unsupported platforms fail with an explicit message before downloading:
Linux non-x86_64, musl systems (detected via `ldd`), and macOS on anything but
arm64/x86_64.

### Homebrew

A formula in `fluxvale/homebrew-tap` wraps the two macOS tarballs, with
per-architecture `url`/`sha256` and `libexec.install Dir["*"]` plus a `bin`
symlink. Homebrew is the macOS-native path; the installer still works there and
covers Linux.

### Release notes

The workflow composes the Release body: install commands, the macOS
Gatekeeper/right-click-open instructions for the unsigned binaries, the glibc
floor and the runtime library requirement, and the security note that checksums
are attached. Notes are generated from the workflow so they cannot drift from
the assets.

## Alternatives considered

- **Keep Burrito** — archived 2026-11-30, and it was never exercised here. A
  wrapper we would inherit 334 commits of Zig plumbing from cannot be the
  long-term path for a tool we own.
- **batamanta** — the only living single-binary packager, but bus factor one,
  ~1.5k downloads, born March 2026. Its ideas (Zstandard, escript mode, daemon
  mode) are worth borrowing; depending on it repeats the Burrito bet. Its daemon
  mode is a pattern we build in-OTP anyway.
- **Build on `ubuntu-22.04`** — the requested baseline, but deprecated with
  termination inside this pipeline's life, and the runner label, not the
  toolchain, would decide the glibc floor.
- **Build on the `ubuntu-24.04` runner natively** — glibc 2.39 floor, excludes
  Debian 12 and Ubuntu 22.04.
- **Musl/static ERTS** — removes the glibc and system-library dependency
  entirely, at the cost of a musl ERTS build chain and musl NIFs. Deferred, see
  above.
- **Single-file self-extracting launcher** — reintroduces exactly the
  extract-and-exec wrapper we just removed, and the installer makes the
  directory-shaped artifact invisible to users.
- **Homebrew only** — no Linux story.
- **`mix escript`** — needs an Erlang runtime on the target; a release does not.
- **Notarization for v0.1.0** — $99/year to remove one right-click. Documented
  instead; revisit if downloads justify it.

## Consequences

- Users install with one command, and the artifact is a directory they never
  see. `scp`-one-file distribution and Alpine support are given up consciously.
- Linux artifacts require glibc ≥ 2.34, OpenSSL 3 (`libcrypto.so.3`),
  `libtinfo.so.6`, and `libstdc++.so.6`. Those are present on Debian 12+,
  Ubuntu 22.04+, and current Fedora/RHEL — but a *minimal* container image can
  lack them, so the installer checks for them up front and names the package
  to install instead of installing a binary that cannot start. `libsctp.so.1`
  is optional: with it absent the VM logs one `Failed open sctp dynamic
  library` line at boot and continues.
- macOS binaries are unsigned: Gatekeeper blocks the first launch of a
  downloaded copy until the user right-click-opens it. The release notes and
  the installer's output say so.
- No Windows support in v0.1.0.
- Upgrades are re-running the installer (or `brew upgrade`); there is no
  in-binary self-update. `dashfloat upgrade` can be a product feature later.
- `--version` is a public CLI surface now, and it exercises the NIF.
- The release workflow is the only place artifacts are produced, so packaging
  breakage surfaces on the tag rather than at user install time — and the
  workflow smokes the published artifacts on a clean Debian container and on
  both macOS runners in the same run.
