# 0012 — A runner dead before its monitor goes up is cancelled, not crashed

- **Status:** Accepted
- **Date:** 2026-10-27 (revised 2026-10-28 after hostile review)
- **Implements:** [issue #60](https://github.com/fluxvale/dashfloat/issues/60).
- **Extends:** [ADR 0007](0007-tool-calls-and-execution.md) §2 (execution
  architecture, monitor-based crash degradation).

## Context

`Agent.dispatch_runner/2` starts the runner Task and places its monitor only
after `Task.Supervisor.start_child/3` returns — the pid does not exist before
that call, so no code can monitor-first. A child that dies inside that window
(a scheduler preemption between spawn and monitor) is already gone when
`Process.monitor/1` runs, and the Erlang semantics are helpful: monitoring a
dead pid succeeds and immediately delivers `{:DOWN, ref, :process, pid,
:noproc}`. Until this ADR that DOWN fell into the generic crash clause and
the status line told the user their tool *crashed* — when in truth it never
ran. The refusal-surface work built the promise that statuses say what
happened; this window broke it.

## Decision

**The runner reports its own death; `:noproc` on a `{:running, …}` tool slot
means the body never reported, which is cancelled.**

1. **Self-reported crashes.** The task body wraps `Runner.run/4` in a
   `try/rescue` and always sends `{:tool_done, id, result}` — the real result,
   or a `tool crashed: <reason>` map built from the rescued exception. A crash
   therefore reaches the agent as a *result* through the existing
   `:tool_done` clauses (running or running-cancelled), with its true reason,
   whatever the monitor window does. `Runner.run` already carries its own
   function-level rescue (anticipated raises degrade to result maps there);
   the dispatch-level wrapper is the belt over that belt, and the
   load-bearing change is that the agent no longer trusts the DOWN reason to
   say what ran.
2. **`:noproc` semantics.** A `:noproc` DOWN reaching a still-`{:running}`
   slot means the body produced no report. The ordering half of that inference
   is happens-before: the body's `send` precedes its exit, which precedes the
   DOWN's delivery, so a `:noproc` processed at a running slot proves no
   `:tool_done` preceded it (hostile-review-verified over 100 000 iterations:
   `noproc_first=0`). With the self-report in place, no-report has exactly two
   causes: the body never started, or the process died to something the body
   could not catch (an external kill — `:kill` skips rescue blocks). Both are
   the deaths the existing `:killed` clause already reports as cancelled:
   aborted, same abort path, no model re-prompt.

The first cut of this ADR justified the clause with "the runner's only act is
the send, so `:noproc` proves nothing ran" — false about the code (`Runner.run`
mutates files and spawns processes *before* the send), and hostile review
measured that ~14 % of mid-body crashes present as `:noproc`, which the clause
would have reported as "cancelled" after real side effects. The self-report is
what makes the "nothing reported ⇒ nothing to report but the cancellation"
chain true; the reason alone carries no such information.

## Alternatives considered

- **Monitor-before-attach discipline** — impossible as literally stated: the
  pid exists only once `start_child` returns, and that is exactly the window.
  A middleman process that monitors before spawning moves the same window and
  adds a process per tool call. Rejected.
- **A reason-based `:noproc → cancelled` clause alone** — the first
  implementation of this ADR; misreports mid-body crashes (and their side
  effects) as cancelled. Rejected for the self-report + clause combination.
- **`Task.Supervisor.async_nolink`** — its monitor lives in the caller too;
  the window survives, only the message shape changes.

## Consequences

- Crash reasons become *more* honest than main: the model sees the rescued
  reason as a normal result even when the monitor raced.
- The stream task (`start_episode/1`) has the same spawn window; a `:noproc`
  there degrades through the existing stream-DOWN clause to
  `[stream failed: :noproc]` — a stream that never started *is* a failed
  stream, so that wording stays honest and untouched.
- The `{:running_cancelled, …}` slot already treats every DOWN reason —
  including `:noproc` — as the cancel it is; the self-report lands there as a
  normal `:tool_done` and records the crash result before the abort.
