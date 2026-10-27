# 0011 — Boot-time terminal detection, the clean refusal, and libsctp in the release

- **Status:** Accepted
- **Date:** 2026-10-27
- **Amends:** [ADR 0009](0009-config-v3-persona-profiles.md) (the
  non-interactive-refusal rule) and [ADR 0010](0010-release-packaging.md) (the
  artifact's runtime library set)
- **Implements:** [issue #56](https://github.com/fluxvale/dashfloat/issues/56).

## Context

The owner's real install test drive found the first-run path broken in the
packaged binary, in three separate ways.

**1. The wizard was unreachable on a real terminal.** A release is launched
`elixir -noshell --no-halt`, and the boot's interactivity probe was
`match?({:ok, _}, :io.columns(:standard_input))`. Under a `-noshell` boot the
standard_input device answers `{:error, :enotsup}` *always* — on a real pty,
not just on a pipe. Measured inside the built release in a 120×40 pty:

| probe | real pty | headless |
| --- | --- | --- |
| `:io.columns(:standard_input)` | `{:error, :enotsup}` | `{:error, :enotsup}` |
| `:io.columns(:user)` | `{:ok, 120}` with a sized pty, `{:error, :enotsup}` with an unsized one | `{:error, :enotsup}` |
| `:prim_tty.isatty(:stdin)` | `true` | `false` |
| `:prim_tty.isatty(:stdout)` | `true` | `false` |

So the check could never succeed in a release, and the refusal was structurally
guaranteed for every first run of the installed artifact — while the same fresh
state booted the wizard under `mix test` (which runs a normal shell-started
VM) and the TUI booted fine in the same binary once config existed (crossterm
reads the terminal directly, never consulting `:io`). `:io.columns(:user)` is
not a usable substitute either: it answers about the *group leader*, and only
reports a size when the terminal's winsize is actually set (a default
`script -qec` pty is 0×0 and answers `{:error, :enotsup}` just like headless),
so it would have been a second, differently-shaped bug.

**2. The refusal crashed the VM.** The refusal returned
`{:error, :interactive_setup_required}` from `Application.start/2`. A release
boots with `start_permanent` semantics, so that error return makes OTP
terminate the kernel: the `{exit,terminating, ...}` term on stdout, the
`Kernel pid terminated (application_controller)` line, and an `erl_crash.dump`
written into the user's current working directory. A first-time user got a
crash report for a first-run configuration.

**3. Every boot printed a C-level warning.** `[UNIX-ESSIO] Failed open sctp
dynamic library: libsctp.so.1` on stdout, before anything else. When OTP is
built with SCTP headers present (as in the official Debian-based images the
release workflow builds in), the esock backend unconditionally
`dlopen("libsctp.so.1")` at VM init
(`erts/emulator/nifs/unix/unix_socket_syncio.c`, `essio_sctp_init_dynamic/0`)
and writes an `=ESOCK WARNING MSG====` block to stdout via
`enif_vfprintf(stdout, …)` when it is missing. It is not an Erlang logger
message and not a configurable one.

## Decision

### Terminal detection asks the file descriptors

The boot's interactivity probe is `:prim_tty.isatty/1` on **stdin or stdout**,
never `:io.columns/1`. A terminal on either is enough to drive the wizard; the
probe is a named, injectable function (`DashFloat.Application.tty?/1`) so the
mixed cases are unit-testable. Measured mixed cases: stdin-only → `true/false`,
stdout-only → `false/true`, neither → `false/false`.

The two false arms are deliberate and tested. stdin-only is a real terminal
whose output is redirected (`dashfloat > log`); stdout-only is a real terminal
with input redirected. Both mean a human is at the terminal, which is what the
wizard needs to know before it draws. The stdin-only arm is the weaker of the
two: the wizard does start, but its escape sequences go into the redirect and
the terminal stays blank until the user redirects differently — the same
behaviour any full-screen TUI has under `> log` (measured: 131 bytes into the
file, nothing readable on the terminal). We take that over refusing an
interactive session, because the alternative — demanding both fds — would
refuse the common `| tee` / `> log` case outright.

### The refusal halts at the boot boundary

The non-interactive refusal writes the instructions to stderr and then calls
`System.halt(1)` — through the same injected `halt:` seam the `--version` path
already uses. The `{:error, :interactive_setup_required}` return stays as the
test-seam value; in production the halt ends the VM first, so OTP never sees an
error return, never terminates the kernel, and never writes a crash dump. Exit
status is 1 (non-zero, as the issue requires) and the friendly message is the
only thing the user sees.

### The release carries libsctp

The release pipeline bundles the genuine `libsctp.so.1` into `lib/sctp/` and
`rel/env.sh.eex` prepends that directory to `LD_LIBRARY_PATH` when it exists.
The `dlopen` then succeeds and the warning is never composed. The step
(`DashFloat.Release.bundle_sctp/1`) resolves the library from
`DASHFLOAT_LIBSCTP`, then the usual multiarch paths, and **does nothing when no
library exists** — which is correct on macOS, where OTP is built without SCTP
support and the warning is impossible. The Linux release job installs
`libsctp1` before `mix release` and asserts both that the library shipped and
that the boot prints no `sctp` line.

## Alternatives considered

- **Keep `:io.columns/1`, add a `:user` fallback.** `:io.columns(:user)`
  answers `{:ok, _}` on a pty *with a winsize set* and `{:error, :enotsup}` on
  a 0×0 pty or headless, so a fallback would have worked only sometimes — a
  second bug shaped exactly like the first. It also answers about the group
  leader rather than the terminal the user is typing into. Asking the fds is
  the same amount of code and is actually correct.
- **`System.get_env("TERM")`.** Set in non-tty contexts (CI, SSH commands) and
  unset in some real terminals. A worse proxy for the same question.
- **Keep the `{:error, _}` return and silence the crash dump via
  `ERL_CRASH_DUMP=/dev/null` or `+d`.** Hides the artifact of the crash without
  preventing the crash: the `Kernel pid terminated` spew still prints, and the
  exit status would be whatever OTP chooses. Halting at the boundary removes
  the cause.
- **A `sh` wrapper that redirects the first boot's stdout.** Would mangle the
  TUI's own output and every later boot; the warning is per-VM-boot, not
  first-run only.
- **Build OTP without SCTP (`--disable-sctp`).** We do not build OTP; the
  release uses the prebuilt ERTS from the official image. Rebuilding ERTS to
  drop a library we never use is far more expensive than shipping 18 KB.
- **Suppress the warning with a runtime flag.** There is none: the print is a
  `dlopen` failure in C at VM init, before any Erlang code runs. Tried and
  measured with no effect: `-kernel inet_backend inet`, `-kernel inet_backend
  socket`, `-proto_dist inet_tcp`, plain `-noinput`.
- **Vendor a stub `.so` that satisfies the `dlopen`.** Proven to work, but it
  would break the SCTP socket API for anything that ever used it, for a
  warning's sake. The real library is 18 KB, LGPL-2.1+ (lksctp-tools), glibc
  floor 2.4, and depends only on `libc.so.6` — the honest fix.

## Consequences

- The wizard is reachable on the first run of the installed artifact, in any
  terminal, which is the whole point of the onboarding flow in ADR 0009.
- A headless first boot is a clean, quiet, non-zero exit: no crash dump in the
  user's CWD, no kernel spew. Scripted/dotfile boots keep working — the
  instructions on stderr are unchanged.
- Release artifacts gain an 18 KB library and one `LD_LIBRARY_PATH` export.
  The export is inherited by every child process the VM spawns — and DashFloat
  is an agent harness that spawns shell tools — so `lib/sctp/` is deliberately
  a single-library directory: only an SCTP-using child could resolve a
  different library there than the host intends, and the SCTP ABI is stable.
  Nothing else in the release's search path is shadowed. The release
  directory stays self-contained, so installing and upgrading (ADR 0010) are
  unaffected.
- The bundled library is LGPL-2.1+ (`lksctp-tools`). Redistributing it means
  shipping its licence in the artifact, which `bundle_sctp/1` does by copying
  the upstream copyright text in beside it; the file stays user-replaceable on
  disk, which is what preserves the licence's relinking freedom.
- The SCTP warning returns if a future artifact is built without the library
  bundled; the release job's smoke assertion is what catches that.
- `:prim_tty` is an OTP-internal module (`-moduledoc false`). It is the only
  public-in-practice way to ask "is this fd a tty" from Erlang, and it is
  stable across OTP 26–29; the cost of the dependency is accepted, and the
  probe is isolated behind `tty?/1` so a future replacement touches one
  function.
