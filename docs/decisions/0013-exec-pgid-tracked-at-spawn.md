# 0013 — Exec's process group is tracked at spawn, not queried from the port at reap

- **Status:** Accepted
- **Date:** 2026-10-27 (revised 2026-10-28 after hostile review)
- **Implements:** [issue #59](https://github.com/fluxvale/dashfloat/issues/59).
- **Extends:** [ADR 0007](0007-tool-calls-and-execution.md) §2 (execution
  architecture: every exec completion path SIGKILLs the command's process
  group).

## Context

`Exec` SIGKILLs the command's whole process group on every completion path
(exit, timeout, cancel), but it learned the group id from
`Port.info(port, :os_pid)` — once immediately after `Port.open`, once as a
belt at reap time. A program that has already exited answers nil, and a dead
port makes the pid permanently unqueryable: the belt read port-gone as "the
children died with the program" and skipped the kill. A command that exits
before its background children (`sleep 300 & echo done`) therefore leaked
them — reproduced on pristine main by a leak loop under scheduler load (a
surviving `sleep` after a clean exit 0), though the window is
load-shaped: the same loop leaks on the first spawn after a cold BEAM here
and never in a hostile reviewer's otherwise-identical runs, because the
window is a preemption race, not a guarantee.

## Decision

The pgid is captured at spawn, independent of the port
(`DashFloat.Tools.Exec.Group`):

1. **Arm** — `Group.arm/0` pre-writes a tracker file holding the sentinel
   `"0\n"` ("wrapper has not reported yet"). The path is absolute (a relative
   `TMPDIR` resolves against the command's cwd inside the wrapper and against
   the BEAM's cwd at reap — the two diverge, so the sentinel would be read
   where the report never landed), the name is 64 bits of crypto-random, the
   create is `O_EXCL`, and the mode is 0600: a pre-planted symlink is never
   followed and no other local user can write the file — the same hardening
   `Runner.write_file/3` applies to its temp files. An unusable tmp refuses
   the spawn: without a tracker the kill would again depend on the port's
   lifetime, and a known-leaky fallback is worse than an honest refusal.
2. **Wrap** — `Group.wrap/2` spawns a wrapper shell that writes `$$` into
   the tracker and then execs the user command. A `{:spawn, …}` child is a
   session and group leader (pid == pgid == sid), so the wrapper's `$$` IS
   the pgid of everything the command spawns. The `&&` is load-bearing: if
   the write fails, the user command never runs.
3. **Reap** — every completion path kills by the reported pgid
   (`kill -9 -<pgid>`), which works whether or not the port is alive. A
   report is trusted only in the exact shape the wrapper writes it: digits,
   newline-terminated, naming a real group (≥ 2 — group 1 would make the
   kill target `-1`, every process the uid can signal), in a regular file.
   Anything else — file missing, sentinel still present, garbage, a torn
   prefix — cannot prove the group is dead:
   - sentinel + dead port is the *one* positive nothing-to-kill proof: the
     wrapper's `&&` never passed, so the user command was never exec'd and
     the group only ever held the wrapper itself;
   - a live port answers the belt (`Port.info` os_pid == the pgid), which
     also covers a `:cancel` landing before the wrapper's report;
   - anything else with a dead port is *unknown*, and is said so: a warning
     is logged instead of a silent `:ok`, because the pgid may have been
     reported and then lost (a tmp cleaner, or the command deleting its own
     tracker — `rm -f /tmp/dashfloat-exec-*.pgid` in the executed line
     reproduces it with no external actor).

## Alternatives considered

- **Keep the birth-time/reap-time os_pid capture** — that is the leak: a
  fast-exiting program is unqueryable at both moments. Rejected.
- **Fall back to the racy path when tmp is unusable** — a silent return to
  the leak under conditions nobody watches. Rejected for the honest refusal.
- **Scan /proc for survivors** — pattern-matching unknown processes is the
  wrong tool: group membership is the fact needed, and a /proc scan races
  the very window this fixes. Rejected.

## Consequences

- One tiny tracker file per exec run in tmp, deleted on reap.
- Trackers are orphaned whenever the runner task dies outside the three
  completion paths — a supervisor shutdown, a BEAM crash, or an external
  kill of the runner task (none occur in the agent's production paths; the
  suite's kill-tests produce them deliberately). Orphans are inert as a kill
  vector — the names are unique and never re-read — but they are uncollected
  litter, not nothing.
- A same-user process (above all: the executed command itself, which the
  confirmation gate already trusts with the user's full shell) can still
  overwrite its own tracker with a foreign well-formed pgid; the reap will
  kill that group. Accepted residual: the command could signal any of those
  processes directly, so the tracker grants no new privilege — the same
  boundary ADR 0007 draws at `setsid` escapes.
- The tiny pid-reuse window between a group's death and the kill is
  accepted, unchanged from ADR 0007.
- Children that escape via `setsid` (own session, untracked pgid) remain out
  of scope — the ADR 0007 process-sandbox boundary.
