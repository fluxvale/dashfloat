# 0033 — Idle-time auto-compaction: a cache-TTL-derived idle timer over the shared eviction pass

- **Status:** **Proposed** — the plan gate ([issue #99](https://github.com/fluxvale/dashfloat/issues/99)'s
  design-only lane): this ADR parks at the owner's morning read. Nothing below is
  implemented, and nothing binds, until the status moves to Accepted (or the ADR
  is amended at the gate). The open questions in
  [§9](#9-open-questions-at-the-gate) are the decisions the owner owns.
- **Date:** 2026-11-02
- **Implements:** [issue #99](https://github.com/fluxvale/dashfloat/issues/99)
  (design-only; the implementation lane is gated on this ADR's acceptance).
- **Extends:** [ADR 0022](0022-context-accounting-and-compaction.md) — the
  80% trigger, the shared eviction pass, the window resolution chain, and the
  §8 stage-2 seam (whose "documented inert" clause gains an amendment note
  at acceptance, when `idleTtlSeconds` goes live); [ADR 0014](0014-session-persistence.md)
  §5 — the persistence semantics every compaction reuses; [ADR 0020](0020-command-surface.md)
  — `/compact`, the manual caller of the same pass; [ADR 0007](0007-tool-calls-and-execution.md)
  — whose "the agent holds no timers" contract (restated in the agent's
  moduledoc) this design amends with exactly one deliberate exception (§1).
  [ADR 0006](0006-ui-truth-and-rendering.md) is deliberately untouched: the
  timer is agent-side, never render-side. Nothing is superseded; two ADRs
  gain amendment notes **at acceptance**, not in this design PR.
- **Governs (at acceptance):** the agent's idle timer and its epoch guard, the
  usage frame's cached-token passthrough, the TUI's activity signal, and the
  `compaction` settings key's first live sub-key.

## Context

The owner watched Claude Code and asked ([issue #99](https://github.com/fluxvale/dashfloat/issues/99)):
when the agent has been idle a while, auto-compact **before** the provider's
prompt cache expires, so the compaction cost never lands on the user's
critical path — "harvest the cache before it's wasted." The prefix has already
been paid for; letting the TTL lapse unused throws that away, and a
post-expiry compaction then pays full input price on the whole history.

Three facts about the codebase shape everything below (all verified in-tree):

1. **The compaction machinery exists and is shared.** ADR 0022 + its #92/#111
   amendments: strictly-past-80% whole-turn eviction (`Accounting.compact/3`),
   one shared `eviction_pass/3` behind both the prompt-time hook and the idle
   manual `/compact`, whole-turn floors (the one-remaining-turn rule, the
   pinned system message), the window chain (configured → seeded → visible
   default), and drop-time persistence per ADR 0014 §5. There is no third
   implementation to fork and no new floor to invent.
2. **The cache signal does not exist yet.** The usage frame is
   `%{prompt_tokens, completion_tokens, total_tokens}` — integer-shape-guarded
   in `ChatStream.emit_usage/3`, every other field dropped. No code reads
   `cached_tokens`; no code anywhere knows a cache TTL. Both the signal and
   the timing basis are new work this ADR designs.
3. **Stage-2 summarization does not exist yet.** Compaction today is local
   drop-oldest eviction — no API call. The `settings.compaction` key is
   documented inert (ADR 0022 §8). The economics are honestly different
   (the issue insists the ADR say so):
   - **Today:** the request bytes are identical whether eviction runs now or
     at the next prompt — the win is *latency placement*. The recorded m1
     follow-up from the #43 lane (reviewer-ruled non-blocking) is the reason
     it matters: the eviction loop recomputes weights per drop, ~O(n²),
     measured 10.1 s at 20 k messages — a huge idle session currently stalls
     its **first send** on prompt-time compaction. The idle path pays that
     stall while nobody is watching.
   - **At stage 2:** compaction becomes an LLM summarization call; then the
     TTL timing is the whole point — the summarize request rides the
     still-warm prefix cache (cheap input), and running it during idle also
     removes its latency from the user's critical path.

The architecture fit is the issue's own framing: the agent is an event-driven
GenServer, so a `Process.send_after` timer — cancelled and re-armed on
activity, epoch-guarded against stale fires (the suggester's
[`Suggest.fetch_async/3`](../../lib/dash_float/tui/suggest.ex) pattern) — is
agent-side and touches no render discipline. In-tree precedents: the vetter's
deadline timer, the TUI's blink/suggest debounce timers, onboarding's fetch
epochs. One contract bends to admit it, and only it: the agent's moduledoc
and [ADR 0007](0007-tool-calls-and-execution.md) say the agent **holds no
timers** (the invariant behind "idle ⇒ no timers ⇒ no renders"). This design
adds exactly **one** agent-held timer whose fire is a plain message — no
render, no display call — so the invariant's *purpose* (an idle agent costs
no renders) survives while its letter is amended. ADR 0007 and the moduledoc
gain that amendment note at acceptance, in the implementation lane.

## Decision

### 1. What "idle" means — two clocks, one timer

Two distinct idlenesses, and the design keeps them separate:

- **Agent-idle** = `status: :idle` — no turn in flight; the message list is
  stable. This is the same structural gate `/compact` uses (its #92
  amendment). The timer arms only from agent-idle transitions and a fire is
  honored only in agent-idle.
- **User-idle** = no TUI-originated **activity** for at least `@min_quiet`
  (60 s). Activity is any user-originated event: composer keystrokes, command
  and palette submissions, dialog and picker interactions, image attach.
  Explicitly **not** activity: ticks, renders, footer refreshes, suggestion
  arrivals (agent-originated), Herdr pings. The TUI forwards each activity as
  one plain `{:activity, ui}` send — the same dispatch discipline as
  `{:prompt, ui, …}`.

The **TTL clock is not reset by activity** — it starts at the last
**request**, because the cache's clock is the provider's, not ours. A user
typing for ten minutes after a turn keeps a deadline set when the turn's last
episode was *issued*; activity only postpones the *fire*, never the expiry.
The anchor is **episode start** — the same site that already mints
`request_len` — not the usage frame's arrival: a frame lands one full
generation after the request that refreshed the cache, and on a 300 s TTL a
60 s reply would silently eat the whole margin and fire post-expiry. The
usage frame's job here is only the telemetry of §4.

One timer, one formula (all times monotonic; `now` is arming time):

```
effective_ttl = configured | seeded-per-provider | @default_ttl (300 s)   §3
margin        = max(60 s, 10 % of effective_ttl)
deadline      = last_request_at + effective_ttl − margin
arm_delay     = max(@min_quiet, deadline − now)    # deadline passed ⇒ @min_quiet
```

- **Arm** at every arrival at agent-idle — there are exactly two code paths
  that reach `status: :idle` today: `reset_turn/1` (every completed,
  errored, or aborted turn) and `fill_cancelled/1` (a cancelled tool run,
  which sets idle inline). The implementation lane puts the arming predicate
  in one helper both call (or routes `fill_cancelled` through
  `reset_turn`); the invariant is *predicate-on-idle-arrival*, not a hook in
  any one function. Activity events while idle also re-arm. **Cancel and
  clear** at turn start, at `{:adopt_session, _}` (a whole different
  transcript — §6), and at `{:set_provider, _}` (a different provider — §6).
- The fire is one `{:idle_compact, epoch}` message to the agent. Each (re)arm
  increments the epoch and stamps it into the timer message; a fire whose
  epoch ≠ the current one is dropped. `Process.cancel_timer/1` can lose the
  race against a message already in the mailbox — the epoch guard closes that
  race by construction, the suggester's pattern exactly. The `status: :idle`
  guard on the fire handler is the second belt: within one GenServer mailbox
  messages serialize, so the epoch guard and the status guard together cover
  both orderings of a fire racing a prompt.
- Monotonic time only (`System.monotonic_time`): wall-clock jumps cannot move
  a deadline. Suspend pauses the monotonic clock, so a laptop waking fires
  *late* (post-expiry) — the safe direction (§7).

### 2. The trigger interaction — same 80% trigger, same pass, nothing else

- The idle path **arms only when the estimate is strictly past the 80%
  trigger at arm time** (`threshold = div(window * 4, 5)`, ADR 0022 §3). The
  estimate cannot grow while idle *on its own* — new messages only arrive
  with a turn — and the two idle-state events that can change it or its
  inputs (`{:adopt_session, _}` swaps the whole list;
  `{:set_provider, _}` re-resolves window and seed) both **cancel and
  clear** the timer state (§6), so by construction nothing can grow or jump
  the estimate between arm and fire: **below-threshold idle sessions never
  compact, and an armed fire's estimate is the one the arming predicate
  approved.**
- At fire, the trigger check is re-authoritative, and the fire runs **the
  same `eviction_pass`** `/compact` runs — the third caller of one pass, not
  a third implementation. The floors are inherited unchanged: whole-turn
  eviction, the one-remaining-turn rule (the user's most recent question is
  never dropped), and the pinned leading system message
  ([ADR 0019](0019-session-system-prompt.md)'s rule, threaded through the
  pass). "Never below a floor that keeps recent context whole" is §4's
  existing guarantee; the idle path adds no new floor because it needs none.
- Confirmed against the harvest counter-argument (issue design question 2):
  harvesting expiring cache only pays when compaction is otherwise *needed*.
  Below 80% the window is not at risk; an idle compaction there would (today)
  destroy detail reclaiming nothing — the #92 amendment's below-trigger
  reasoning, extended from the manual caller to the timer caller — and (at
  stage 2) burn input tokens to shrink a prefix that fits. The 80% trigger
  stays the single risk boundary; the idle path changes *when*, never
  *whether*.

### 3. The TTL resolution chain — observable over assumed, honestly

The threshold derivation mirrors the #111 window chain's shape and its
discipline (verified data only; nothing guessed silently):

1. **Configured** — `settings.compaction.idleTtlSeconds` (milliseconds or
   seconds per the implementation lane; the `compaction` settings key already
   exists, ADR 0022 §8 — this is its first **live** sub-key). Always wins.
2. **Seeded** — a per-provider table in `DashFloat.Config.Presets`,
   **verified numbers only** (the #111 rule: an unverified TTL is a guess;
   the seed table is data, asserted in tests, updatable without an ADR).
   This ADR deliberately hardcodes no vendor TTLs — they differ per tier and
   change; the implementation lane populates the table from provider
   documentation at implementation time.
3. **Default** — **300 s**, the shortest widely-documented prompt-cache TTL
   tier. Conservative by design: assuming *short* never misses a harvest —
   the drops are identical under drop-oldest, and a stage-2 summarize issued
   early still rides a cache whose real TTL is longer. Assuming *long* fires
   post-expiry on every shorter-TTL provider — the one unrecoverable
   mistake. The honest cost of the short default, recorded rather than
   hidden: on a provider whose real TTL is much longer (the owner's observed
   hour-tier), stage 2 would pay a summarize per 300 s idle window where a
   seeded 1 h TTL would pay one — early-and-often trades money for
   guaranteed warmth, which is exactly why layer 2 exists and why open
   question 4 puts the default to the owner. When in doubt, harvest early.

**Observability's honest role.** The issue's initial preference was to derive
the TTL from observed `cached_tokens` decay. This ADR argues the observation
**cannot be the primary derivation**: a cache miss is only ever *retroactive*
evidence (you learn a TTL lapsed at the next request, after the harvest is
already lost), and capacity eviction on a multi-tenant provider impersonates
expiry, so gap-vs-read inference converges slowly on confounded data.
Observation instead gets the two jobs it can do reliably:

- the **telemetry gate** (§4) — proof the provider does prefix caching at
  all, from the first frame that shows a positive cached count; and
- a **calibration** signal (deferred, §8) — a per-provider ledger of
  (gap, cached_tokens) observations that tightens seeded TTLs across
  sessions, once there are sessions to learn from.

The chain plus the gate give correct behavior from the *first* idle window;
calibration improves it later. Building the passthrough once, for both jobs,
is the seam §8 sketches.

### 4. The telemetry gate — no signal, no timer

- **The enabling prerequisite:** `ChatStream.emit_usage/3` forwards
  `cached_tokens` when the frame carries a valid
  `usage.prompt_tokens_details.cached_tokens` (integer ≥ 0; absent or
  malformed ⇒ nil — the existing shape-guard discipline, no new failure
  mode). The agent records `last_request_at` (monotonic, stamped at episode
  start — §1) and a session-scoped `cache_seen?` flag — ever observed
  `cached_tokens > 0` on this provider. Both are **provider-scoped facts**:
  a mid-session `{:set_provider, _}` (the `/model` and `/profile` pickers,
  ADR 0020) clears them — a switch onto a no-telemetry provider must not
  inherit the old provider's evidence, and a switch off a caching provider
  must not keep arming against a stale seed (§6).
- **Idle compaction arms only where `cache_seen?`.** Without telemetry the
  provider's cache behavior is pure assumption, and an *agent-initiated*
  transcript mutation on a timer, with no provider signal behind it, is the
  guessing ADR 0022 §2 refuses in spirit (its window twin refused to guess a
  denominator; this refuses to guess a cadence). The prompt-time hook and
  manual `/compact` are unchanged on every provider.
- **Degradation is silent here, deliberately** — and the distinction from
  #111's visible-default rule is the point: a wrong *window* sizes a
  destructive trigger (data-loss risk — must be visible); a wrong *TTL* only
  mistimes a mutation the 80% trigger already authorized (no data risk — a
  note would buy nothing). Providers **with** telemetry but no seed degrade
  to the 300 s default (chain layer 3), same silence rule.

### 5. What the user sees — heard when it acts, silent when it doesn't

- A dropping idle fire emits the automatic path's entry **verbatim**
  (`[context: dropped N oldest turn(s) — est B→A of W]`, plus the #111
  assumed-window suffix when the window is the default), and persists +
  records exactly as `/compact` does (ADR 0014 §5 semantics): compute-then-
  one-write, so a crash mid-pass leaves the pre-pass file loadable and
  simply un-compacted — the same seam as prompt-time, no new exposure.
- The TUI hears a dropping fire through the **two messages it already
  renders for any transcript mutation**: the drop entry and the
  `{:context, …}` snapshot `persist/1` pushes (the footer's data source).
  No new agent→TUI message type exists — the timer itself is invisible
  until it acts, and when it acts it speaks with the prompt-time path's
  exact voice.
- An idle fire that drops nothing — below-threshold at fire, or the oversize
  single-turn case — is **fully silent and latched off**: it does not
  re-arm on activity, only when the message list actually changes (a turn
  end or an adopt). Without the latch, an oversize session — over-threshold
  forever by construction — would re-run the full pass on every
  keystroke-then-quiet cycle, putting the m1 O(n²) stall into the typing
  loop; the latch bounds an oversize session to one silent fire per turn.
  The manual `/compact` keeps its oversize warning because the user asked;
  the rule in one line: agent-initiated passes are heard when they act;
  user-initiated ones always report. Making that true needs one seam change
  named here: the oversize warning is emitted inside the shared pass today,
  so the pass gains an **announce policy** (one parameter, two policies —
  idle passes announce drops only; manual and prompt passes announce
  everything). One pass, two announcement policies; still no forked loop.
- The `compactions` record gains an additive optional `"source"` key
  (`"idle" | "prompt" | "manual"`): diagnostics only, tolerated on load,
  dropped by older binaries on re-save — exactly §6's existing tradeoff.
  The drop entry **is** the user-visible marker; DashFloat has no `/undo`
  surface and none is added (the dropped turns are not recoverable from the
  compacted file; undo would be its own lane, not a rider on this one).
- **No status-line changes, no new render events.** The timer lives in the
  agent; while it waits, nothing renders because of it. The issue's probe
  ("idle renders stay 0") is scoped honestly: with the fixture's cursor
  blink suppressed (the sanctioned idle blink is the one idle-period render
  ADR 0006's amendment allows), an armed-but-waiting session produces zero
  renders, and the fire produces exactly the two messages a prompt-time
  compaction of the same session would produce — nothing more.

### 6. Coexistence — /compact, prompts, adoption, provider switches, and resume

- `/compact` stays "check NOW": the manual, on-demand caller of the same
  pass. After a manual compact finishes (idle, mutated list), the arming
  predicate runs again — re-arm only if still over threshold (the oversize
  case can be). Uniform rule: **every arrival at agent-idle runs the arming
  predicate** (over-threshold AND `cache_seen?` AND not latched ⇒ arm with
  `arm_delay`; else ensure cancelled).
- A prompt cancels the timer (turn start), and the prompt-time hook is
  unchanged — it remains the safety net for every fire that never happened,
  and it covers the very first prompt of a resumed session exactly as ADR
  0022 §5 always has.
- **`{:adopt_session, _}` (the in-session `/resume` picker) cancels and
  clears everything the timer knows.** An adopted transcript is a different
  conversation: its estimate may be anywhere, and the previous session's
  `last_request_at`/`cache_seen?` are evidence about a *different*
  transcript — the old session's deadline must never arm compaction against
  the adopted one. The adopted session gets the boot rule below (no timer
  until its first turn end here).
- **`{:set_provider, _}` (the `/model`/`/profile` pickers, mid-session)
  cancels, clears `last_request_at`/`cache_seen?`, re-resolves the window
  and TTL seed for the picked provider, and re-runs the arming predicate.**
  Both flags are provider-scoped facts (§4); carrying them across a switch
  is exactly the silent assumption the telemetry gate exists to forbid. The
  next turn's frames re-establish them.
- **No timer at boot or resume.** The arming predicate needs
  `last_request_at`, which is not persisted; persisting one more timestamp
  would buy a harvest window only when the user resumes *inside* a TTL — and
  a resuming user is present by definition (their first prompt's hook
  covers safety; `cache_seen?` re-establishes at that turn's frame). The
  timer's lifecycle starts at the session's first turn end. A cold cache at
  boot is not a cache worth timing against.
- Activity while idle re-arms with `arm_delay` recomputed from *now* —
  unless the no-progress latch (§5) is set, in which case only a list
  change re-arms. A typist is never compacted under mid-composition more
  than once per deadline, and the `@min_quiet` floor keeps even a
  passed-deadline re-arm (fire in `@min_quiet`) from landing inside an
  active typing burst.

### 7. Failure modes and their answers

- **Fire-while-busy race** (timer expires as a prompt arrives): the
  `status: :idle` guard plus the epoch — ignored; the prompt's own hook
  compacts at prompt time.
- **Stale timer after cancel/re-arm**: epoch mismatch — dropped, even when a
  racing fire message is injected directly into the mailbox.
- **No telemetry**: never arms (§4). **Telemetry, no seed**: 300 s default
  (§3).
- **Clock**: monotonic only; suspend pauses the clock so a wake fires late
  (post-expiry) — degrading toward the safe direction. Wall-clock arming
  rejected: NTP jumps move deadlines both ways.
- **Crash mid-pass**: compute-then-one-write; the old file is the floor, and
  it is loadable (ADR 0014 §4/§5 unchanged — the loader never sees a
  half-compacted list).
- **The O(n²) eviction (m1)**: a *dropping* idle fire happens **once per
  idle window** — it *relocates* the stall off the user's first send; it
  does not multiply it (fires are bounded by the trigger: once under 80%,
  nothing re-arms until growth). The no-progress latch (§5) closes the one
  loop that threatened this bound: without it, an oversize session —
  over-threshold forever — would re-run the full pass on every
  activity-then-quiet cycle, putting the m1 stall into the typing loop;
  with it, every session shape is bounded at one silent pass per turn. The
  pass runs in the agent process, so the TUI renders independently either
  way. A user returning mid-fire queues behind it in mailbox order — the
  same one-shot cost the prompt path charges today, no worse. m1 therefore
  stays its own slice, with one trigger: the implementation lane measures
  fire time on a 20 k-message over-threshold fixture, and **> 1 s pulls the
  running-total refactor into the lane** (issue #99's "in scope if the
  idle path makes it hot," answered with a measurement rather than a
  guess).

### 8. The stage-2 contract — designed INTO, not bolted after

Issue #99's scheduling note asked that this trigger be designed into the
stage-2 summarization lane; this ADR is that design's idle half. The timer,
the epoch guard, the arming predicate, the telemetry gate, and the TTL chain
are **stage-invariant** — what the fire *triggers* changes, never when or
whether it may:

- At stage 2, the fire becomes an async **summarization episode**
  (supervised, monitor'd — the ChatStream shape). Its input is the
  to-be-summarized *prefix* — the warm-cache rider, the entire economic
  point of TTL timing. While it runs, the agent is busy; a prompt arriving
  mid-summarize queues behind it exactly as it queues behind a stream — the
  mailbox is the queue, no new mechanism.
- **Fail-closed, and fail-bounded:** a failed summarize mutates nothing (the
  transcript stays whole) and retries — but at most **twice**, then the
  timer disarms until the next user turn. An unbounded retry would bill one
  summarize per idle window on a persistently-failing provider with nobody
  watching (an overnight terminal at the 300 s default ≈ hundreds of paid
  attempts); the user's next turn re-arms and the failure is visible in the
  log by then. Never a partial replacement; persistence is one write on
  success (the summary replaces the summarized turns atomically). The
  `instructions` sub-key stays inert until stage 2 proper.
- The remaining stage-2 shape choice (summary as a synthetic message vs a
  pinned block) belongs to the stage-2 lane; this ADR pins only the timer
  contract and the failure posture.
- **Calibration** (the deferred observability payoff): the (gap,
  cached_tokens) ledger from §4's passthrough, persisted per provider,
  tightening the seed over time. Explicitly phase 2 — sketched here so the
  passthrough is built once, never twice.

## Alternatives considered

- **A fixed comfort interval (e.g. 5 min)** — rejected: the issue's own
  refinement. A fixed number mistimes every provider but one, and post-expiry
  firing wastes the harvest on exactly the providers where it matters most.
- **Deriving the TTL from cached_tokens decay as the primary source** —
  rejected over the issue's initial lean (argued in §3): misses are
  retroactive and confounded by capacity eviction; the chain + gate are
  correct from the first idle window, calibration improves later.
- **A TUI-owned idle timer** — rejected: the timer must fire the *agent's*
  eviction; a render-side timer driving agent mutations inverts the process
  boundary (ADR 0006's separation) and would need window/estimate state the
  TUI only mirrors.
- **Activity = submit-only, no per-key signal** — deferred to the gate
  (open question 3): per-key sends are cheap, but the coarser signal is
  simpler; the stage-2 typing-during-summarize race is the reason the issue
  suggested any-key.
- **A dedicated timer process (keeping the agent's no-timers letter intact)**
  — rejected: a whole supervised process, name, and failure story for one
  `send_after`; the contract's *purpose* (idle ⇒ no renders) is preserved by
  an epoch-guarded fire that is only a message, at far less machinery. The
  letter bends, recorded in §1; ADR 0007 gains the amendment note at
  acceptance.
- **Arming at boot/resume** — rejected (§6): buys at most one harvest
  window, costs a persisted timestamp and a timer for a user who is present.
- **Below-threshold idle compaction (harvest everything)** — rejected (§2):
  the 80% trigger is the settled risk boundary; idle changes when, not
  whether.
- **A periodic oversize/idle warning** — rejected (§5): noise from an
  unattended timer.

## Consequences

- Over-threshold idle sessions compact themselves inside the TTL window:
  today that relocates the eviction stall (the m1 cliff) off the first
  send; at stage 2 it additionally buys the summarize a warm-cache ride and
  takes its latency off the critical path.
- One new TUI→agent message class (`{:activity, ui}`) per user-originated
  event — a plain send, the `{:prompt, ui, …}` discipline; ignored while
  busy, never a render. And one bent contract, recorded: the agent's
  "holds no timers" moduledoc/ADR 0007 invariant gains exactly one
  exception whose fire is a plain message (amendment note at acceptance).
- The `compaction` settings key starts living earlier than ADR 0022 §8's
  "inert until stage 2" promised — `idleTtlSeconds` is live with this ADR
  (0022 §8 gains its amendment note at acceptance), `instructions` stays
  inert until stage 2 proper. Recorded here as the seam's first bend,
  deliberate.
- Providers without cached_tokens telemetry get no idle compaction
  (§4); the latency-placement residual is accepted — open question 2 puts
  the counter-argument to the owner rather than deciding it unilaterally.
- **This ADR is Proposed.** Every section is the recommendation the owner
  accepts, amends, or rejects at the gate; the implementation lane opens
  only on that read, and the open questions below are his to answer.

## Test plan (probes for the implementation lane)

Adapted from the issue's done-when; the design lane ships none of them.

1. **Idle renders stay 0 while the timer waits** (blink suppressed in the
   fixture — the sanctioned idle blink is ADR 0006's one idle render), and
   a fire produces exactly the two messages a prompt-time compaction
   produces (drop entry + context push) — nothing the timer itself renders.
2. **The fire path:** an over-threshold, `cache_seen?` session left idle
   auto-compacts within `arm_delay` (test clock accelerated); the entry, the
   `compactions` record (`source: "idle"`), and the persisted file match
   `/compact`'s shapes.
3. **The epoch guard:** activity during the window cancels/reschedules; a
   stale-epoch fire injected directly into the mailbox is a no-op.
4. **The busy race:** a fire racing a prompt (busy at fire) is ignored, and
   the prompt-time hook still runs.
5. **The negatives:** below-threshold sessions never arm; no-telemetry
   sessions never arm; oversize-only fires are silent and **latched** —
   subsequent activity does not re-run the pass; only a list change does.
6. **The resets:** `{:adopt_session, _}` and `{:set_provider, _}` each
   cancel, clear `last_request_at`/`cache_seen?`, and leave no armed timer
   until the next idle arrival; the old session's deadline never fires
   against an adopted transcript (assert directly).
7. **The crash seam:** a crash between compute and persist leaves the
   pre-pass file loadable and un-compacted.
8. **The stall measurement:** on a large over-threshold fixture, the
   post-idle prompt's pre-episode time excludes the eviction cost — the
   number that feeds §7's m1 gate.
9. `mix ci` green (the design PR itself is docs-only; these probes belong
   to the implementation lane).

## 9. Open questions at the gate

1. **The derivation itself** — the issue's refinement says the threshold
   should be derived from observed cache behavior "rather than hardcoding
   one"; §3 argues observation cannot be the *primary* derivation (misses
   are retroactive, capacity eviction impersonates expiry) and proposes
   chain + telemetry gate + deferred calibration instead. That is a
   deliberate contravention of the written lean, argued but not the owner's
   to lose by default: **confirm the chain-over-derivation reversal, or
   direct the lane to attempt observation-first.** Recommend: the chain.
2. **No-telemetry providers** — hard-off (no idle compaction without
   `cached_tokens` evidence, §4), or a degraded fixed-interval variant that
   keeps only the latency-placement win? Recommend: hard-off in v1; revisit
   if a no-telemetry provider becomes the owner's daily driver.
3. **Activity granularity** — any-key forwarding (`{:activity, ui}` per
   composer keystroke and command/dialog event, §1) or submit-only
   (coarser, no per-key traffic, but re-opens the stage-2
   typing-during-summarize race)? Note the `/resume` picker's *selection*
   is itself an activity event — and it adopts a transcript whose timer
   state is cleared (§6); the two rules interlock deliberately. Recommend:
   any-key — the sends are cheap and the race is the reason activity
   exists.
4. **The 300 s default and its silence** — conservative default when
   telemetry exists but no seed does (§3, including the recorded cost: on a
   long-TTL provider, stage 2 pays a summarize per 300 s idle window a
   seeded TTL would have spread to an hour), and *silent* timing
   assumptions (§4's no-data-risk argument). Confirm both, or ask for a
   visible note anyway.
5. **The m1 gate and the stage-2 contract** — keep the O(n²)
   running-total refactor its own slice with the >1 s fire-time
   measurement as the pull-in trigger (§7)? And does §8's stage-2 contract
   (fail-closed, bounded retry, prompts queue behind the summarize) match
   how the owner wants the stage-2 lane framed — or should stage 2 re-open
   this ADR rather than amend under it? Recommend: the measure gate, and
   amend-under.
