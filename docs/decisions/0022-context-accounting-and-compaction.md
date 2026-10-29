# 0022 — Context accounting and compaction: usage-frame anchor, chars/4 growth, 80% whole-turn eviction

- **Status:** Accepted (design; start go given by the owner Oct 27 on the PA's
  lane framing, Oct 26 owner shaping recorded in
  [issue #43](https://github.com/fluxvale/dashfloat/issues/43)).
- **Date:** 2026-10-29
- **Implements:** [issue #43](https://github.com/fluxvale/dashfloat/issues/43) —
  the context half of Phase 4 of the
  [ADR 0001](0001-founding-stack-and-architecture.md) roadmap.
- **Extends:** [ADR 0014](0014-session-persistence.md) (the transcript is the
  persistence truth; this ADR exercises its additive-v1 seam and amends the
  "nothing else" clause of §3 for two new top-level fields),
  [ADR 0007](0007-tool-calls-and-execution.md) (the transcript shape and the
  no-dangling-`tool_calls` rule),
  [ADR 0008](0008-config-layout-profiles-json5.md)/
  [ADR 0009](0009-config-v3-persona-profiles.md) (per-model `context` windows
  in settings.json5; the tolerate-and-warn settings vocabulary),
  [ADR 0015](0015-input-surface-cursor-stats-ghost.md) (the stats footer's
  stage-2 binding, PR #81). Nothing is superseded.
- **Governs:** `DashFloat.Accounting` (new), the agent's prompt-time
  compaction hook, the session file's additive fields, and the #67 stage-2
  read API.

## Context

ADR 0014 shipped the transcript and its unbounded-growth contract: "The
transcript grows without bound in memory and on disk this slice — honest, and
#43's contract (same file, additive fields within v1)." Three facts verified
in code shape everything below:

1. **The only real token measurement is the usage frame.** `ChatStream`
   forwards one `{:usage, %{prompt_tokens, completion_tokens, total_tokens}}`
   per episode (`emit_usage/2`, integer-shape-guarded); `prompt_tokens`
   counts exactly the messages of THAT request — the whole conversation as
   sent. No tokenizer dependency exists or is wanted (issue #43: "the
   heuristic should be described as an estimate, never as a count").
2. **The window already exists**: per-model `context` in `settings.json5`
   (models menu, env override) lands as `Config.context_tokens`. The TUI's
   catalog fallback (`State.provider_context_tokens/1`) fills a *display*
   denominator; the agent has no catalog, and a window that is not configured
   must not be guessed.
3. **Turns are structural** (issue #43, verified in `DashFloat.Agent`): a turn
   is a `user` message plus everything up to the next `user` message — the
   assistant `tool_calls` message (`begin_tool_batch/3`) and one `role:
   "tool"` message per call (`flush_tool_messages/1`). Cutting anywhere else
   produces the dangling-`tool_calls` transcript ADR 0007 §1 rejects and
   ADR 0014 §4's loader refuses.

## Decision

### 1. The estimate: a provider measurement grown by a chars/4 heuristic

**Anchor on the last provider-reported `prompt_tokens`** and grow per message
after it: the anchor records `%{tokens: t, index: i}` — the measurement and
how many messages of the current list it covered. The estimate of the
conversation as it stands:

```
estimate(messages, nil)                = Σ weight(m) for all m
estimate(messages, %{tokens:, index:}) = tokens + Σ weight(m) for m after index
```

- **`weight/1` is bytes/4 per counted field** — `div(byte_size(x), 4)` for the
  message `content`; an assistant message's `tool_calls` add each call's
  `function.name` and `function.arguments` (the argument JSON is already a
  string in the transcript). Message maps arrive atom-keyed (live) or
  string-keyed (loaded, ADR 0014 §3) — weights read both.
- **No anchor (nil)** — a fresh session before any frame, or a resumed file
  written without one — means a pure heuristic estimate over the whole list.
  Chars/4 over-counts some text and under-counts other (CJK badly); the
  headroom under the window is the margin.
- The anchor is **minted per episode**: the agent records the request's
  message count when it starts an episode, and the episode's usage frame
  completes the anchor (`tokens` from the frame, `index` from that count).
  Intermediate (tool-loop) episodes anchor too — their frames are the freshest
  measurement covering the flushed tool messages. An episode that dies without
  a frame leaves the previous anchor standing; appends since then grow it.

This is deliberately NOT `prompt + completion`: the episode's own output is
counted once, as growth (its weight), when its message is appended.

### 2. The window: configured or never

Compaction reads `Config.context_tokens` and nothing else. **`nil` (or
non-positive) ⇒ nothing compacts, nothing is guessed** — the status bar shows
the absolute total alone in that case, unchanged. The TUI catalog fallback
stays display-only: evicting against an unconfigured window on the strength
of an async model-list refresh would be exactly the guessing the issue
forbids.

### 3. The trigger: strictly past 80%

`threshold = div(window * 4, 5)`. Eviction runs while `estimate > threshold`
— a transcript at 79% is untouched; one just past 80% loses turns until the
estimate is back at or under the threshold. `div` keeps the trigger in
integers (a 2000-token fixture window triggers above 1600).

### 4. Eviction: oldest COMPLETE turns, prefix-only

Messages group into turns (`chunk` before each `user` message; any leading
non-user prelude belongs to the first group). Eviction drops **whole groups
from the front only**, recomputing the estimate after each drop, and stops
when the estimate is ≤ threshold or **one group remains** — the user's most
recent question is never dropped:

- The retained list is always a suffix of the input, so it can never begin
  with a `role: "tool"` message, orphan a tool answer, or split a batch from
  its results — the ADR 0014 §4 invariant holds by construction, and the
  saved file must remain loadable by that same validator.
- **A single turn larger than the budget stays whole**, with a visible
  warning. Splitting it is impossible by the whole-turn rule; dropping it
  would discard the most recent question.
- **The anchor adjusts with the drop**: if `k` messages leave and the anchor
  covered `min(k, index)` of them, `tokens` loses their combined weights
  (floored at 0) and `index` shrinks by that count. If `index` reaches 0 the
  anchor is spent (`nil`) — a residual measurement must not be smeared over
  messages it never covered. The next usage frame re-anchors exactly.

### 5. Where it runs: prompt time, never mid-turn

One hook: the agent's `{:prompt, _ui, _text}` handler, **after** the user
message is appended and persisted (a kill still loses at most the reply,
never the question — ADR 0014 §5) and **before** the episode starts. The list
is stable there, the turn is not open, and every request is preceded by
exactly one check. Consequences:

- Compaction covers resumed sessions at their first prompt — ADR 0014 §6's
  "no truncation, no accounting" clause ends here, at the seam it reserved.
- Mid-turn mutation is structurally impossible: there is no second hook.
- Eviction rewrites the session file immediately (the compacted list plus its
  record, §6), so the persisted session and the next request agree — and the
  dropped turns are absent from both (issue #43's visibility clause).
- Compaction runs even when persistence is off (`session_dir: nil`): the
  window is about the request, not the file.

### 6. Recording: visible in the log, additive in the file

**Visible live:** dropping turns emits one `:system` display entry naming the
count (e.g. `[context: dropped 2 oldest turns — est 1650→1180 of 2000]`);
the oversize survivor emits its own warning entry. No mid-conversation
`role: "system"` message is injected — the request shape stays
provider-native.

**Recorded in the transcript** (schema stays **v1**; ADR 0014 §3's
additive-evolution seam, which anticipated exactly this):

```json5
{
  "version": 1, "id": …, "created_at": …, "pin": {…}, "messages": […],
  "context":     { "prompt_tokens": 412, "messages": 6 },
  "compactions": [ { "at": "…", "turns": 2, "window": 2000,
                     "estimate_before": 1650, "estimate_after": 1180 } ]
}
```

- `"context"` persists the anchor so a resumed session estimates from the
  last real measurement instead of re-deriving (ADR 0014's "banking history
  usage is #43's" consequence line, closed). `"compactions"` is the eviction
  history — a long session never silently loses its beginning, on disk too.
- Both are written only once they exist (no anchor / no evictions ⇒ no keys:
  pre-compaction files stay byte-compatible with ADR 0014's writer).
- **Load is tolerant** (the `pin` precedent, not the `messages` rules): absent
  keys degrade to `nil`/`[]`; a `"context"` that is not a map of two
  non-negative integers degrades to `nil`; a `"compactions"` that is not a
  list degrades to `[]`. Never a refusal — these are diagnostics, not
  conversation truth; `messages` validation is untouched.
- **Older binaries ignore AND drop them** on their next save (ADR 0014 §3:
  tolerance means no crash, not preservation). Accepted: this binary rewrites
  both fields on every save once they exist, so the record survives every
  save it can; an old binary's re-save loses the history but never the
  conversation. State the tradeoff, keep the version at 1.

### 7. The #67 stage-2 read API (frozen binding)

`DashFloat.Accounting.usage/3` is the one call the stats footer binds to
(PR #81: "tokens-used and percent-of-context from that API"):

```elixir
Accounting.usage(messages, anchor, window)
#=> %{window: 128_000 | nil, used: 4_180, percent: 3.3 | nil}
```

Pure; `percent` is `100 * used / window` rounded to one decimal, `nil` when
there is no window. No TUI work happens in this slice — the binding point is
this function plus whatever carry #67 chooses for `messages`/`anchor`.

### 8. Stage-2 seam: `compaction` in profile settings, documented inert

Issue #43 stages the work: stage 1 (this ADR) is deterministic drop-oldest;
stage 2 (a follow-up slice) summarizes instead of discarding, and only then
do custom compaction instructions mean anything — under drop-oldest there is
no prompt for an instruction to steer. The seam this slice leaves:

- The profile-level `settings` object in `settings.json5` knows the
  `compaction` key (joining `defaultModel` and `suggest` in the loader's
  known-settings list) — a user can write
  `settings: { compaction: { instructions: 'keep the design decisions' } }`
  without an unknown-key warning.
- **It changes nothing**: no `Config` struct field, no runtime read, no
  validation, no behavior — documented as reserved for stage-2 summarization
  in the README and here. This is the minimal "field exists, is inert" seam
  the lane spec requires, kept plumbing-free per the issue's warning that a
  parsed-but-dead field must not pretend to work.

### Interface freeze

- `DashFloat.Accounting` (new, pure — no I/O, no clock, no process state):
  - `estimate(messages, anchor) :: non_neg_integer()`
  - `usage(messages, anchor, window) :: %{window: pos_integer() | nil, used: non_neg_integer(), percent: float() | nil}`
  - `compact(messages, anchor, window) :: %{kept: [map()], anchor: anchor() | nil, dropped: non_neg_integer(), oversize: boolean()}`
  - `anchor :: nil | %{tokens: non_neg_integer(), index: non_neg_integer()}`
- `DashFloat.Session`: `load/2` additionally returns `context:` and
  `compactions:` (tolerant, §6); `save/2` unchanged (it encodes whatever the
  map carries); `t()` gains the two optional fields.
- `DashFloat.Agent`: state gains `anchor`, `compactions`, and the episode
  request length; opts `:resume` map gains optional `context:`/`compactions:`;
  the prompt handler gains the §5 hook.
- `DashFloat.Application`: threads the two loaded fields into the agent's
  resume map.
- `DashFloat.Config`: `@known_settings` gains `"compaction"` (§8) — the only
  config change in this slice.

## Alternatives considered

- **Message-granular eviction** (drop exactly enough messages) — rejected:
  it is the bug, not a shortcut; any cut inside a turn dangles `tool_calls`
  (ADR 0007 §1).
- **A tokenizer dependency for exact counts** — rejected: the usage frame is
  the only ground truth the system ever receives; chars/4 between frames,
  with the window headroom as margin, is the honest estimate.
- **Anchoring on `prompt + completion`** — rejected: double-counts the
  episode's own output (it is counted once, as growth, when appended).
- **Evicting at turn end (idle transition) instead of prompt time** —
   rejected: two hook sites for one behavior; prompt time is the single
   point every request passes through, and it covers resume with no init-time
   write-before-bootstrapping problem.
- **Compacting on the TUI's catalog window when config has none** — rejected:
  guessing a window from an async refresh is the failure mode the nil-window
  rule exists to prevent.
- **A `role: "system"` marker message in `messages`** — rejected: it rides
  the request to the provider (non-native shape, provider-dependent
  tolerance) and the loader refuses unknown roles; visibility belongs to the
  display entry and the file's additive fields.
- **Nesting the record inside `messages` entries** (survives old-binary
  re-saves verbatim, ADR 0014 §3) — rejected: it would ride every request
  body to the provider; top-level additive fields keep the wire shape clean
  and accept the old-binary drop.
- **Bumping the session schema to v2** — rejected: no existing field's
  *reading* changes; ADR 0014 built the v1 additive seam for exactly this.
- **Summarization, `/compact` command, instruction plumbing** — out of scope:
  stage 2 (issue #43's staging; §8).

## Consequences

- A long session now survives its own window: at just past 80% the oldest
  complete turns leave, in order, with the estimate back under the trigger
  and the transcript still provider-valid.
- The estimate is an estimate: within a turn of the last frame its error is
  the chars/4 drift of the messages since; after an eviction without a fresh
  frame it carries the subtraction error until the next frame re-anchors.
  The 80% trigger's headroom is the designed margin, and the oversize rule
  bounds the worst case (one huge turn) visibly instead of silently.
- Session files written by this binary may carry `context` and `compactions`;
  older binaries resume them fine and drop those keys on their next save.
- The status bar's display accounting (`context_total`, last-frame-wins per
  ADR 0006/0007) is unchanged — #67 stage 2 replaces it with
  `Accounting.usage/3` when it binds.
- Stage 2, when it ships, has its seams: the settings key (§8), the record
  shape (§6), and the pure functions to steer.

## Test plan (the issue's Done-when, refined)

1. `mix ci` green; patch coverage 100% on the diff (ADR 0003's ratchet).
2. **Accounting cells:** the anchor is a frame's `prompt_tokens` at the
   request's message count; growth asserted at `div(byte_size, 4)` for
   content, tool names, and argument JSON; a `nil` anchor estimates the whole
   list heuristically; `usage/3` returns window + used + percent (nil
   percent with no window).
3. **Trigger cells:** a fixture at 79% of its window is untouched; just past
   80% loses exactly the oldest turns required; post-drop estimate ≤
   threshold; a fixture window of 2000 compacts in one drop.
4. **Boundary cells:** post-eviction the retained list never begins with a
   `role: "tool"` message, every retained `tool_calls` id has its tool
   message, the retained list is a suffix, and a seeded randomized run over
   generated transcripts (with tool batches) never yields an unpaired call —
   asserted on the message list, and the compacted list passes the
   `Session.load` validation.
5. **Oversize cell:** a single turn above the budget is retained whole and
   the warning is emitted.
6. **Integration (loopback SSE, per issue):** a driven long-session fixture
   with tool batches crosses 80% at a small window; the next captured request
   body carries exactly the retained turns; the persisted session file
   carries the same list plus a `compactions` record naming the count; the
   `:system` entry names the count.
7. **Error band:** against a fixture provider whose tokenizer is chars/4
   plus fixed per-message scaffolding, the pre-request estimate tracks the
   next reported `prompt_tokens` within a stated band (asserted per turn).
8. **Anchor persistence:** a two-turn session saves `context`; a resumed
   agent adopts it (first prompt estimates from the measurement); a file
   without the key resumes on the pure heuristic; malformed values degrade
   to nil/[] without refusing.
9. **Stage-2 seam:** a profile `settings.compaction` loads without the
   unknown-key warning and changes nothing — the loaded `Config` is
   field-identical with and without it.
