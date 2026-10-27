# 0012 — A runner dead before its monitor goes up is cancelled, not crashed

- **Status:** Accepted
- **Date:** 2026-10-27
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
:noproc}`. Until this ADR that DOWN fell into the generic crash clause and the
status line told the user their tool *crashed* — when in truth it never ran.
The refusal-surface work built the promise that statuses say what happened;
this window broke it 1-in-N runs (reproduced deterministically by injecting
the exact DOWN a dead-at-monitor child produces).

## Decision

**`:noproc` on a `{:running, …}` tool slot means cancelled** — the same
abort path as an externally killed runner (`:killed`): cancelled result for
the announced call, cancelled results for the rest of the queue, no model
re-prompt. The clause matches the slot's monitor ref, so a stale DOWN from an
unrelated monitor cannot abort a live batch.

The equivalence rests on a happens-before chain, not on inspecting the corpse:

1. The runner's only act is `send(agent, {:tool_done, …})` — the send
   happens before the child's exit.
2. The exit generates the DOWN into the agent's mailbox, after the send.
3. Mailbox order preserves that: if a `:noproc` DOWN is processed while the
   slot is still `{:running, …}`, no `:tool_done` preceded it.

So `:noproc` (dead *before the monitor existed*) proves no result was ever
sent — there is nothing to report but the cancellation, and nothing crashed
after the fact. A mid-run crash keeps its real exit reason and still reports
`tool crashed`.

## Alternatives considered

- **Monitor-before-attach discipline** — impossible as literally stated: the
  pid exists only once `start_child` returns, and that is exactly the window.
  Wrapping the runner in a middleman process that monitors before spawning
  would move the same window, add a process per tool call, and still need
  `:noproc` semantics at the agent. Rejected.
- **`Task.Supervisor.async_nolink`** — its monitor lives in the caller too;
  the window survives, only the message shape changes.

## Consequences

- The stream task (`start_episode/1`) has the same spawn window; a `:noproc`
  there degrades through the existing stream-DOWN clause to
  `[stream failed: :noproc]` — a stream that never started *is* a failed
  stream, so that wording stays honest and untouched.
- The `{:running_cancelled, …}` slot already treats every DOWN reason —
  including `:noproc` — as the cancel it is; no change needed there.
