# 0013 — Exec's process group is tracked at spawn, not queried from the port at reap

- **Status:** Accepted
- **Date:** 2026-10-27
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
them — reproduced on pristine main by a leak loop that caught a surviving
`sleep` after a clean exit 0.

## Decision

The pgid is captured at spawn, independent of the port
(`DashFloat.Tools.Exec.Group`):

1. **Arm** — `Group.arm/0` pre-writes a tracker file into tmp holding the
   sentinel `"0\n"` ("wrapper has not reported yet"). An unwritable tmp
   refuses the spawn: without a tracker the kill would again depend on the
   port's lifetime, and a known-leaky fallback is worse than an honest
   refusal.
2. **Wrap** — `Group.wrap/2` spawns a wrapper shell that writes `$$` into
   the tracker and then execs the user command. A `{:spawn, …}` child is a
   session and group leader (pid == pgid == sid), so the wrapper's `$$` IS
   the pgid of everything the command spawns. The `&&` is load-bearing: if
   the write fails, the user command never runs — a tracker still holding
   the sentinel is a positive proof nothing was exec'd.
3. **Reap** — every completion path kills by the reported pgid
   (`kill -9 -<pgid>`), which works whether or not the port is alive. A
   sentinel plus a dead port is the proven nothing-to-kill case (see 2); a
   `Port.info` belt covers a `:cancel` that lands before the wrapper's
   report — a live port's os_pid is the pgid.

## Alternatives considered

- **Keep the birth-time/reap-time os_pid capture** — that is the leak: a
  fast-exiting program is unqueryable at both moments. Rejected.
- **Fall back to the racy path when tmp is unusable** — a silent return to
  the leak under conditions nobody watches. Rejected for the honest
  refusal.
- **Scan /proc for survivors** — pattern-matching unknown processes is the
  wrong tool: group membership is the fact needed, and a /proc scan races
  the very window this fixes. Rejected.

## Consequences

- One tiny tracker file per exec run in tmp, deleted on reap; a stale file
  can only exist if the BEAM crashes mid-run — inert.
- The tiny pid-reuse window between a group's death and the kill is
  accepted, unchanged from ADR 0007.
- Children that escape via `setsid` (own session, untracked pgid) remain out
  of scope — the ADR 0007 process-sandbox boundary.
