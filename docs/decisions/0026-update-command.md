# 0026 — The update command: release check, method detection, verified self-replace

- **Status:** Accepted
- **Date:** 2026-10-31
- **Implements:** [issue #122](https://github.com/fluxvale/dashfloat/issues/122)
  (the owner's ask: "i'd also like an update command.")
- **Amends:** [ADR 0010](0010-release-packaging.md) — its launcher patch also
  forwards the `update` subcommand, and its "no in-binary self-update"
  consequence is superseded by this ADR (this *is* that future feature); and
  [ADR 0011](0011-boot-tty-and-clean-refusal.md)'s refusal discipline, applied
  to the update command's failure surface.

## Context

ADR 0010 shipped distribution but left upgrades manual: re-run install.sh, or
`brew upgrade`. The v0.4.0 test drive made the gap explicit — a user must
learn there is a new release, then re-pipe an installer. The owner asked for
an update command.

The forces:

- The check needs the network; DashFloat elsewhere phones nobody
  ([ADR 0009](0009-config-v3-persona-profiles.md)'s catalog is the standing
  exception, and it is fail-open). Any *automatic* check would break that.
- GitHub's unauthenticated API allows 60 requests/hour per IP; a CLI check
  must treat 403/429 as a first-class outcome, not an error.
- The install.sh layout ([ADR 0010](0010-release-packaging.md)) is a
  directory tree behind a `current` symlink — there is no single "binary" to
  overwrite — and its prune-on-upgrade deliberately kept no rollback.
  Replacing a running BEAM release has its own hazards (open files, lazily
  loaded code) that a single-file updater never meets.
- Homebrew-managed files belong to brew; writing into a Cellar path is how
  installations break.

## Decision

One subcommand, `dashfloat update`, with a scriptable check-only form
`dashfloat update --check`. It runs at the same early boot boundary as
`--version` ([ADR 0010](0010-release-packaging.md)): before config loading
and terminal setup, needing neither, exiting through the one halt seam.
`update` must **lead** argv (`dashfloat update [--check]`); elsewhere it is
what it always was — an unrecognized-argument warning. A `--version`
anywhere in argv still wins over a leading `update` (the version check runs
first and `--version` matches by membership) — `dashfloat update --check
--version` answers the version and exits 0.

### 1. The check

`GET https://api.github.com/repos/fluxvale/dashfloat/releases/latest`,
unauthenticated, no retries, 10 s timeout, via Req (the standing HTTP
client). `DASHFLOAT_UPDATE_API_BASE` overrides the API base — the same
escape hatch install.sh's `DASHFLOAT_RELEASE_BASE_URL` gives the installer,
so a smoke can steer a real binary at a controlled release source (the
release workflow's artifact checks use it the same way). The response's
`tag_name` is compared to the running version through Elixir's `Version`
(so pre-release tags order correctly and odd tags refuse instead of
guessing). Running **newer** than the latest release is reported and
treated as current — a main-branch build must not "update" itself
backwards.

Every failure is a **visible refusal on stderr, never a crash** (the
[ADR 0011](0011-boot-tty-and-clean-refusal.md) rule): offline/transport
errors, rate limits (403/429 with `x-ratelimit-remaining: 0`, naming the
`x-ratelimit-reset` time when present), no published release (404), other
HTTP statuses, undecodable bodies, and unreadable tags each print one
`dashfloat: …` line naming the cause and the remedy. No background or
startup checks exist and none may be added: the network is touched only when
the user runs the command (the issue's non-goal, kept as a standing rule).

Terminal output is **ASCII only** (written through `IO.binwrite`, the
[ADR 0011](0011-boot-tty-and-clean-refusal.md) seam). Found on the
real-artifact e2e: on OTP 29, a `binwrite` of non-ASCII bytes under a UTF-8
locale is transcoded to mojibake (each byte individually UTF-8-encoded),
while the chardata `puts` path escapes to `\x{2014}` under a C locale —
ASCII is the only spelling correct in every locale, so the em-dashes and
arrows the first draft used became `-` and `->`.

Exit codes — the scriptable contract:

| mode | outcome | code |
| --- | --- | --- |
| `--check` | current or ahead | 0 |
| `--check` | outdated | 1 |
| `--check` | refused (offline, rate-limited, …) | 2 |
| `update` | updated / current / brew handoff | 0 |
| `update` | any refusal | 1 |

Code 2 exists so a script can distinguish "outdated — act" from "couldn't
tell — don't act" without parsing text.

### 2. Install-method detection: the layout is the marker

`dashfloat update` never installs when it cannot prove which installation it
owns. Detection reads the running release's root (`:code.root_dir()`):

- a `…/Cellar/…` path → **Homebrew** (both `/opt/homebrew` and
  `/usr/local`, Linuxbrew included);
- a `versions/<v>` root whose parent directory holds a `current` entry →
  **install.sh** ([ADR 0010](0010-release-packaging.md)'s layout);
- anything else (a dev checkout, a manual unpack) → **unknown**.

install.sh records no marker file today, and none is added: its directory
shape is deterministic and self-describing, and a marker file could disagree
with the tree it sits in (a version-skew bug incubator). The layout *is* the
marker. The collision risk is accepted: a path that merely *looks* like the
layout (a manual unpack beside another tool's `current`) would be treated as
script-managed — the same trust install.sh itself extends to a user-run
shell script.

- **Homebrew**: print the handoff — `brew upgrade dashfloat` — and do
  nothing else. brew owns that binary; the command never shells out to brew
  and never writes inside a Cellar path.
- **install.sh**: the verified self-replace below.
- **Unknown**: a visible refusal listing both options (the brew command and
  the install.sh pipe).

### 3. The install.sh update: verify, swap atomically, smoke, roll back, prune

The release unit is the directory tree, so "replace the binary atomically"
is a two-rename swap. Step order is the safety claim —
`DashFloat.Update.install_release/3`:

1. Resolve the platform tarball (`x86_64-unknown-linux-gnu`,
   `aarch64-apple-darwin`, `x86_64-apple-darwin`; anything else is the
   platform refusal) and both asset URLs from the release record. A missing
   asset refuses before any bytes move.
2. Download the tarball and the release's `sha256sums.txt` (the single
   checksum source the installer and the Homebrew formula also read —
   ADR 0010) into a staging directory under `versions/`.
3. **Verify**: sha256 the downloaded tarball (streamed) and compare against
   the asset's checksums line. A mismatch — corruption, truncation, a swapped
   asset — prints both hashes and refuses: **the installation is
   byte-identical; nothing was swapped.** A checksums file without the
   asset's line refuses the same way. The residual risk is stated plainly:
   the checksums file comes from the same release as the tarball, so this
   detects corruption and truncation — it is not a signature against a
   compromised release, exactly the trust install.sh and the Homebrew
   formula already extend.
4. Extract with `:erl_tar` into the staging directory and assert
   `bin/dashfloat` exists. Both failures refuse; nothing was swapped.
5. **Swap atomically**: `rename(staging → versions/<new>)`, then create
   `current.new-<unique>` → the new tree and `rename` it over `current`.
   Both renames are single POSIX operations; no observer sees a half state,
   and the running installation is untouched until the second one lands. A
   failed swap removes the new tree and refuses — `current` never moved.
6. **Smoke**: run the new release's `bin/dashfloat --version` through a
   bounded port (15 s; a hung child is killed, a non-executable one is a
   failed smoke, not a crash) and require it to answer the new version —
   the same smoke the release pipeline runs on every artifact (ADR 0010).
   The child runs with the parent's `RELEASE_*` context cleared: a running
   release exports the whole suite and the generated launcher honors
   `RELEASE_SYS_CONFIG`/`RELEASE_VSN` over its own tree, so an inherited
   context boots the OLD release's code and answers the old version (found
   on the real-artifact e2e — a test VM carries no `RELEASE_*` environment,
   so the standin suite alone could not catch it).
   On failure: **roll back** — `current` is repointed to its previous
   target (the old link's stored value, verbatim, so relative and absolute
   links both round-trip), and only then is the new tree removed. A
   rollback that cannot repoint (an unwritable home, say) keeps the new
   tree — `current` still resolves into it — and refuses naming the repair
   (`re-run install.sh`), never a message claiming a rollback that did not
   land.
7. **Prune**: only after the smoke passes, everything else under `versions/`
   goes — ADR 0010's one-version rule, now held *behind* the rollback window
   it lacked.

The staging directory is removed on every exit, success or refusal, and
stale `current.new-*` links from a hard kill inside the two-rename window
are swept on the next swap, so no leftovers accumulate. One `dashfloat
update` at a time is the supported shape — concurrent updates race the
staging and symlink steps against each other and are not supported (the
same single-writer rule install.sh assumes when a user runs it once).

**Replacing a running release is safe here because the command's own VM
halts immediately after** (`handle_update` exits through the boot's halt
seam): the pruned old tree's files are already open in a VM that is about to
die, and a release boots all its code eagerly. The one real hazard — a
*second*, long-lived dashfloat instance running from the old tree while it
is pruned — can crash that instance on a lazy code load; it restarts on the
new version. That trade is accepted and recorded rather than solved with
reference-counted version retention, which is exactly the
keeping-old-copies failure mode ADR 0010 rejected.

### 4. The in-session `/update` call: not this lane

The issue asked for a judgment on an in-session `/update` (the
[ADR 0020](0020-command-surface.md) registry). **Call: no.** An in-session
command could only be check-only (installs are a CLI concern — the running
session's VM cannot be replaced under itself), so it would add TUI async
plumbing (a task, a message, a state seam, registry + `run_command`
clauses) to surface information the shell command already gives, and it
would put a second network-touching path inside the session — against the
keep-the-network-explicit rule above. The registry's extension point stands
(ADR 0020: one entry plus one clause); if the owner wants the nicety it can
ride a later lane on this ADR's check core unchanged.

### 5. The launcher amendment (ADR 0010)

`mix.exs`'s `patch_launcher/1` guard widens from `"" | -*` to
`"" | -* | update)`: the generated launcher would otherwise treat `update`
as an unknown release command and print usage. `dashfloat update` reaches
the app exactly as `dashfloat --version` does. The build still fails loudly
if Elixir's launcher template moves.

## Alternatives considered

- **A marker file from install.sh** — a second source of truth that can
  disagree with the tree; the layout is already unambiguous. Rejected.
- **Shelling out to `brew upgrade`** — modifying brew-owned state from
  outside brew is the classic way to break an installation. The printed
  handoff is one line for the user.
- **Re-running install.sh for the update** — hands a freshly-downloaded
  shell script to `sh`, needs `curl` in-process, and install.sh prunes the
  old version *before* proving the new one runs (no rollback window). The
  in-process path verifies, swaps, smokes, and rolls back.
- **Overwriting the release tree in place** — never atomic for a directory,
  and it destroys the running installation before the replacement is proven.
  The staging dir + rename pair is the same shape install.sh itself uses.
- **Keeping the previous version for real rollback** — ADR 0010 rejected
  old-copy retention deliberately; this ADR narrows that to a *window*
  (previous survives until the smoke passes) rather than reversing it.
- **Exit codes 0/1 only** — a script could not tell "outdated" from
  "offline"; 2 keeps the text-free contract honest.
- **`--check` as a top-level flag (`dashfloat --check`)** — a subcommand
  namespace keeps `--` for flags and leaves room for future subcommands;
  `update` leading argv is the convention the launcher already forwards.
- **Authenticated API calls (a `GITHUB_TOKEN` passthrough)** — more surface
  (a token in env or config), no user need yet; the rate limit is handled
  visibly instead.

## Consequences

- `dashfloat update` and `dashfloat update --check` are public CLI surface;
  their exit codes are a contract.
- An install.sh install updates itself with a sha256-verified, atomic,
  smoke-checked, rollback-protected replace; a Homebrew install prints the
  `brew upgrade dashfloat` handoff; everything else refuses visibly.
- The suite is hermetic: a loopback standin serves the GitHub API and the
  release assets ([ADR 0005](0005-llm-streaming-engine.md)'s raw-gen_tcp
  pattern), and the corruption, swapped-asset, smoke-failure, and
  rollback paths are demonstrated by test — no live network in the suite.
- The check is unauthenticated: 60/hour per IP. A CI-hosted or NAT'd user
  can hit the limit; the refusal names the reset time, and `--check`
  reports exit 2 so automation can back off.
- A second concurrently running instance may crash when its release tree is
  pruned mid-update; it restarts on the new version (recorded above).
- The launcher patch now forwards three invocation shapes; an Elixir
  upgrade that changes the template still fails the release build loudly.
- No `/update` in-session command ships (§4); the ADR 0020 registry is
  unchanged.
- Coverage floor raised 99.0 → 99.2 with this lane's suite (the ratchet,
  [ADR 0003](0003-ci-gate-and-coverage-ratchet.md)).
