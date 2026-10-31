# 0015 — Input surface: blinking cursor, stats footer, model-driven ghost text

- **Status:** Accepted; **amended 2026-10-30**
  ([issue #91](https://github.com/fluxvale/dashfloat/issues/91) — the idle
  cursor carries an explicit bright fg+bg pair, and the placeholder rule is
  tightened; see
  [Amendment (2026-10-30, issue #91)](#amendment-2026-10-30-issue-91-cursor-prominence-placeholder-rule)
  below); **amended again 2026-10-30**
  ([issue #67](https://github.com/fluxvale/dashfloat/issues/67) stage 2 —
  the footer gains tokens-used + percent-of-context from the accounting API
  and the top bar's `ctx` field is deleted; see
  [Amendment (2026-10-30, issue #67 stage 2)](#amendment-2026-10-30-issue-67-stage-2-tokens-used--percent-of-context)
  below); **amended again 2026-10-31**
  ([issue #109](https://github.com/fluxvale/dashfloat/issues/109) — the
  footer's model span becomes `provider - model`; see
  [Amendment (2026-10-31, issue #109)](#amendment-2026-10-31-issue-109-the-footers-model-span-becomes-provider---model)
  below); **amended again 2026-10-31**
  ([issue #104](https://github.com/fluxvale/dashfloat/issues/104) — the
  idle cursor now blinks; see
  [Amendment (2026-10-31, issue #104): the idle cursor blinks](#amendment-2026-10-31-issue-104-the-idle-cursor-blinks)
  below); **amended again 2026-10-31**
  ([issue #129](https://github.com/fluxvale/dashfloat/issues/129) /
  [issue #130](https://github.com/fluxvale/dashfloat/issues/130) — a
  two-row breathing gap between the transcript and the composer cluster,
  and the footer gains `ttft` beside a whole-response `tok/s` average that
  is never live; see
  [Amendment (2026-10-31, issues #129 + #130): breathing gap, ttft, whole-response tok/s](#amendment-2026-10-31-issues-129--130-breathing-gap-ttft-whole-response-toks)
  below); **amended again 2026-10-31**
  ([ADR 0028](0028-choice-widget-and-ask-user.md), issues #133/#134 — the
  composer may be temporarily replaced by the choice widget; see
  [Amendment (2026-10-31, ADR 0028): the composer is replaceable](#amendment-2026-10-31-adr-0028-the-composer-is-replaceable)
  below); **amended again 2026-11-01**
  ([issues #146](https://github.com/fluxvale/dashfloat/issues/146) /
  [#147](https://github.com/fluxvale/dashfloat/issues/147) — the two
  width-class stragglers: the session picker's whole row caps at the
  popup's inner width (metadata tail drops first), and the wizard's input
  lines tail-fit so the block cursor stays on screen; see
  [Amendment (2026-11-01, issues #146 + #147): the width stragglers](#amendment-2026-11-01-issues-146--147-the-width-stragglers)
  below).
- **Date:** 2026-10-29
- **Implements:** [issue #66](https://github.com/fluxvale/dashfloat/issues/66),
  [issue #67](https://github.com/fluxvale/dashfloat/issues/67) **stage 1**,
  [issue #70](https://github.com/fluxvale/dashfloat/issues/70) (owner scope,
  Oct 29: model-driven from the start).
- **Amends:** [ADR 0006](0006-ui-truth-and-rendering.md) — visual language
  (status bar composition, a new footer region), input contract (cursor,
  Tab), and animation model (one new sanctioned one-shot timer). Nothing
  else in 0006 moves.

## Context

The owner's v0.1.1 test drive (Oct 29) found three gaps on the composer
surface: no cursor state (inside a multiplexer you cannot tell which pane
holds focus), no stats under the input (OpenCode shows cwd / model / tok/s
there), and no ghost-text suggestion (Claude Code shows a greyed next-input
that Tab materializes). Dependency facts verified from source before
deciding (`ex_ratatui` 0.17.1; re-verified unchanged at the 0.19.0 bump,
2026-10-31):

- `Widgets.Textarea` carries `cursor_style` / `cursor_line_style` (both
  default the empty style — which is why the composer shows no cursor
  today). The cursor cell is a style patch under the cursor grapheme,
  correct under wrapping because the Rust side computes the position.
- Focus events (`Event.FocusGained` / `Event.FocusLost`) exist but must be
  opted in at start (`focus_events:` — the same connect-path option shape
  as `mouse_capture:`, and the connect telemetry span carries both in its
  metadata).
- `ExRatatui.CellSession` is a styled-cell API for tests:
  `CellSession.new(w, h)` builds a test terminal, `CellSession.draw(session,
  widgets)` renders through the real Rust renderer, and
  `CellSession.take_cells(session)` returns `%{cells: [...]}` with per-cell
  `modifiers` — so a style artifact is proven by asserting the drawn cells
  themselves, not the widget struct and not a text dump.
- `Req` is already the one-shot HTTP client (`Config.Catalog.fetch`),
  `DashFloat.TaskSupervisor` the supervised-task home, and `SSEServer`
  forwards every loopback request to its owner as
  `{:sse_request, method, path, headers, body}` — a loopback seam that can
  capture a side-request's prompt and answer it.

## Decision

### 1. Cursor — styled cell, focus-gated, tick-blinking (issue #66)

`Theme` gains a `:cursor` role (`modifiers: [:reversed]`). `State` gains
`focused?: boolean()` (default `true`); the TUI routes
`FocusGained`/`FocusLost` to it and **enables focus reporting by default**
(`focus_events: true` in `start_link`, the mouse-capture policy pattern —
terminals that ignore it send nothing and the state stays `focused?`, the
status quo ante). The composer's `cursor_style`:

- **unfocused** — the empty style: the cursor artifact is absent, so a
  glance at a multiplexer shows which pane holds focus;
- **focused + idle** — static bright reversed (an explicit `fg: :white,
  bg: :black` pair — see the 2026-10-30 amendment): visible on every
  terminal, and costing **zero new timers** (ADR 0006's idle ⇒ no timers ⇒
  no renders stands untouched);
- **focused + active phase** — reversed on
  `rem(div(anim_step, 4), 2) == 0`: a 500 ms half-period blink riding the
  existing 125 ms activity tick, within the 8 fps budget by construction —
  the blink changes buffer content, never frame count.

### 2. Stats footer — cwd, model, live tok/s under the composer (issue #67 stage 1)

`View.regions/3` gains a permanent 1-row `footer` region directly under the
input (the split order becomes status / log / activity / input / footer;
every consumer — scroll heights, selection mapping, rendering — already
flows through the one split, so consistency is by construction). The footer
renders `❯ <cwd> · <model> · <rate> tok/s` in dim styling, reusing
`State.cwd_label/1`, `provider_label/1` (the ADR 0008 label — it already
reads "nickname (profile)"), and `rate_label/1` (nil until a rate exists;
live while streaming because the tick recomputes it; frozen after
finalize). The top status bar **sheds cwd, model, and rate** — moved, not
duplicated — and keeps `ctx`, the phase cluster, and the log position.

**Stage 2 is bound, not built:** when #43's usage-accounting API lands, the
footer gains tokens-used and percent-of-context **from that API** (and `ctx`
leaves the top bar). No token accounting is added here; the banked-total
`ctx` stays where it is until #43 can replace its source.

### 3. Ghost text — a model-driven side-request (issue #70)

A new pure module `DashFloat.TUI.Suggest` owns the prompt, the request, and
the normalization; `State` carries the plumbing as data; the TUI runner
interprets intents (the submit-action pattern — side effects never in
`State`).

- **Trigger** — one arm-intent flag set by the finalize of an assistant
  turn (`{:phase, :idle}` with a finalized `:assistant` entry), only when
  the draft is empty, suggestions are enabled (`suggest != false`), and a
  provider is resolved.
  The intent is one-shot: draft churn (type, backspace to empty) never
  re-arms — at most **one side-request per completed turn**.
- **Debounce** — the choke point converts arm-intent into a single
  `Process.send_after` (`:dashfloat_suggest`, 600 ms default, injectable
  for tests). This is sanctioned exception #4 (after the exit guard's #3):
  one bounded one-shot per completed turn, whose dispatch draws no frame.
- **Request** — `POST {base_url}/chat/completions` through `Req` (the
  `Catalog` precedent: fail-open, no retries, 5 s timeout, secrets never in
  errors), **on the cheap model by default, user-configurable, or off
  entirely** (`settings.suggest`, tri-state, env override
  `DASHFLOAT_SUGGEST`):
  - `false` — opt-out, the hard stop: no side-request is ever built;
  - a model id string — the suggester targets exactly that id;
  - absent — the **provider's default cheap model**
    (`Config.Presets.suggest_model/1`, keyed by base URL): the officially
    supported presets ship one each (`glm-5.3-flash` on Z.AI,
    `glm-4.7-flash` on Synthetic) — the owner's budget call (cheap tier =
    low spend by default). A custom OpenAI-compatible provider has no
    official cheap tier and falls back to the active model.
  The body carries `max_tokens: 48` and a fixed instruction plus the last
  assistant reply tail capped at 2 KiB.
- **Budget / opt-out** — the tri-state above IS the budget control:
  `false` spends nothing; the default spends only cheap-tier tokens. Bounds
  by construction: ≤ 1 request per completed turn, ≤ 48 completion tokens,
  ≤ ~3 KiB prompt.
- **Cancel** — every draft-changing transition (typed or pasted input,
  history navigation, submit) and every new phase sets a reap-intent; the
  choke point cancels a pending debounce and kills an in-flight task (the
  socket dies mid-request). Stragglers are dead on arrival: each request
  carries an epoch and a `{:suggestion, epoch, result}` whose epoch is not
  current is ignored, render-suppressed.
- **Display** — the landed suggestion is stored in state (normalized: first
  non-blank line, trimmed, surrounding quotes stripped, ≤ 80 chars; blank →
  none) and shown **only while the draft is empty**, replacing the
  composer's placeholder text in the existing placeholder styling; the
  placeholder otherwise follows the 2026-10-30 amendment (the short
  `"ask anything"` hint, only before the session's first exchange; nothing
  mid-session). **No deterministic fallback**: before any assistant turn
  there is no suggestion at all — zero side-channel spend until real
  context exists.
- **Tab** — accepts: the draft becomes the suggestion (editable, cursor at
  end) and Enter sends it through the unchanged submit path.
- **Test gating** — the side-request runs on live sessions or when a
  fetcher is injected (`suggest_fetcher:`, the `catalog_fetcher` pattern);
  the default suite stays hermetic and its idle-discipline windows keep
  holding. The e2e seam is the loopback server: the captured
  `{:sse_request, "POST", "/chat/completions", _, body}` proves the prompt
  and model; the scripted response renders as the ghost.

## Alternatives considered

- **Overlay-glyph cursor** (drawing a `█` at a computed cell) — the
  textarea wraps and scrolls its own overflow Rust-side per frame; any
  Elixir-side position math misplaces under wrapped overflow. Rejected.
- **Terminal-native cursor** (`frame.set_cursor`) — no such hook in the
  `ExRatatui.App` render contract (a widget list). Not available.
- **Blink while idle** — needs a recurring idle timer; violates ADR 0006's
  zero-idle-tick guarantee. Static-when-idle chosen instead.
- **Colorless reversed cursor (this ADR's first cut)** — a bare
  `modifiers: [:reversed]` inherits the terminal's default foreground, which
  reads dim-family next to the dark-gray placeholder (the v0.2.0 smoke
  test: "the same color as the placeholder"). An explicit bright fg+bg pair
  chosen (#91).
- **Keystroke-reset blink phase** — nicer feel, extra state, no budget
  benefit. Deferred.
- **Duplicating cwd/model/rate in both bars** — visual noise; the fields
  move to the footer instead.
- **Deterministic suggestion source** — the owner scoped #70 model-driven
  from the start (Oct 29); the deterministic hint survives only as the
  rejected empty-session fallback (spend with no context).
- **Suggestions through the agent seam** — grows ADR 0007's contract for a
  UI concern; the wizard/catalog precedent (supervised task + plain send)
  does it without touching the agent.
- **Active-model-first (this ADR's first cut)** — best conversation quality
  but spends flagship tokens by default; the owner's refinement (Oct 29)
  inverts the default to the cheap tier with the active model only as the
  custom-provider fallback, and puts the quality choice in the user's hands
  via the model-id override.
- **Recompute-on-empty-display** — a stored suggestion cleared once on
  input has no staleness bug class; recomputing invites request churn.

## Consequences

- `regions/3` returns a five-key map (breaking for direct callers — all
  in-tree); `Theme` grows `:cursor`; `Config` grows `suggest` (tri-state
  field, settings key, env var) and `Config.Presets` grows the
  provider→cheap-model table; `TUI.Suggest` is new.
- One new timer class exists (the suggest debounce): one-shot, turn-paced,
  render-suppressed at dispatch. The render-rate metric of record
  (`Runtime.snapshot/1`) still shows zero idle renders: the only idle
  frames are event-driven (focus change, a landed suggestion).
- Terminals without focus reporting never hide the cursor (degradation is
  the previous behavior plus a static cursor, never a blank composer).

## Amendment (2026-10-30, issue #91): cursor prominence, placeholder rule

The owner's v0.2.0 smoke test (Oct 30) found the composer reading as dead:
the idle cursor does not blink (by design — ADR 0006's idle budget) and its
colorless reversed block inherits the terminal's default foreground, the
same dim family as the placeholder. Two changes, both style/data only —
**no new timers, no new renders**:

1. **Idle cursor prominence.** `Theme`'s `:cursor` role carries an explicit
   `fg: :white, bg: :black` pair under `modifiers: [:reversed]`: the
   reversed block renders bright on every terminal palette instead of
   inheriting the default foreground. Still static at idle; the active-phase
   blink mechanism is untouched. An idle blink remains rejected — it would
   force periodic renders and break ADR 0006's 0-renders-while-idle budget.
2. **Placeholder rule (owner-set).** The instruction tail
   ("Enter send · Shift+Enter newline · …") is gone from the composer —
   the key map lives in `/help` ([ADR 0020](0020-command-surface.md)).
   The placeholder is now, in precedence order:
   - the ghost suggestion, whenever one has landed (unchanged — #70's
     contract; when a suggestion exists it IS the placeholder);
   - else `"ask anything"` — short and neutral — **only while the session
     has no entries yet**;
   - else nothing at all: the first prompt, a command's output, or a
     resume note all make the session underway, and a mid-session hint
     ("feels patronizing" — the owner's refinement, Oct 30) renders no
     placeholder.

## Amendment (2026-10-30, issue #67 stage 2): tokens-used + percent-of-context

**Status:** Accepted. The binding this ADR's §2 froze ("stage 2 is bound,
not built") is now built, against [ADR 0022](0022-context-accounting-and-compaction.md)
§7's API exactly as PR #81 specced. The footer grows a fourth span and the
top status bar's banked `ctx` field is **deleted** — the affordance moves,
its source is replaced: `Accounting.usage/3` (the usage-frame-anchored
estimate), not the last-frame-wins `context_total` banking, which is
deleted with the field. The footer reads, left to right:
`❯ <cwd> · <model> · <used>/<window> · <percent>% · <rate> tok/s`.

1. **Carry and cadence.** The agent owns the message list and the anchor,
   so it pushes a `{:context, %{messages:, anchor:}}` snapshot to the UI at
   every **transcript mutation** — the persist seam, which every mutation
   already passes through (prompt append + compaction, tool batch, tool
   flush, finalize, cancel fill), persistence on or off — and at each
   **usage frame** (the anchor's own refresh, mid-episode). The span itself
   recomputes at render time: `footer_widget/1` reads
   `Accounting.usage(messages, anchor, window)` per frame. The read walks
   the whole message list (the viewport only renders visible rows — this
   is O(messages), not O(viewport)) but each step is an O(1) `byte_size`
   or map read, so it is microseconds against a frame's milliseconds — and
   it happens exactly when frames happen: **never while idle** (no new
   timers; the idle 0-render discipline is untouched by construction), at
   most the 8 fps budget while active. In-flight deltas are deliberately
   not counted — the usage frame is the only ground truth ([ADR
   0022](0022-context-accounting-and-compaction.md)
   §1); the span moves at frames and mutation pushes, not per stream tick.
2. **Window.** The denominator is the TUI's **display window** —
   `provider_context_tokens/1`: the configured per-model `context` (env
   override), else the standing catalog's fresh value, display-only
   ([ADR 0022](0022-context-accounting-and-compaction.md) §2's exact
   framing of that fallback). This is what the old `ctx` field showed, so
   the moved field keeps its denominator-fill behavior (a catalog landing
   mid-idle fills the percent in with no push needed).
3. **Formatting, stated once.** Used and window go through
   `State.humanize/1` (999 → `999`, 1_500 → `1.5k`, 1_048_576 → `1m`); the
   percent is `Accounting.usage/3`'s one-decimal value with a trailing
   `.0` trimmed — `humanize`'s own number rule: `4.2k/128k · 3.3%`,
   `… · 5%`. With **no display window** the span shows the absolute total
   alone (`4.2k`) — no slash, no percent
   ([ADR 0022](0022-context-accounting-and-compaction.md) §2's
   "absolute total alone" carries over).
4. **No-frame / no-session state.** The span is **hidden** until the first
   snapshot lands (nil `state.context` → no span, the rate-span's
   omitted-until-it-exists pattern): a fresh session pre-first-turn shows
   cwd · model only. The first snapshot rides the first prompt's persist —
   before any usage frame exists it carries `anchor: nil`, and the span
   shows the heuristic estimate ([ADR 0022](0022-context-accounting-and-compaction.md)
   §1's nil-anchor rule), so frame-less providers still get a number.
5. **What dies.** `status_widget/2`'s ctx group, `State.context_label/1`'s
   banking form, and the `context_total`/`turn_total` stats machinery
   (last-frame-wins banking at finalize). `{:usage, _}` frames still
   reconcile the rate's token count; the percent and totals now come only
   from the accounting API.

## Amendment (2026-10-31, issue #109): the footer's model span becomes provider - model

The owner's smoke test found the footer naming the model but not **which
provider it sits under** — the profile identifies the config, not the
endpoint. This amendment supersedes the span-composition line of §2 and of
the [stage-2 amendment](#amendment-2026-10-30-issue-67-stage-2-tokens-used--percent-of-context)
in one respect: the model span `<model>` becomes
`<provider> - <model>`, so the footer reads
`❯ <cwd> · <provider> - <model> · <used>/<window> · <percent>% · <rate> tok/s`.
Still one compact span — never the full base_url, never a second span.

1. **The provider ladder**, resolved at render time from the resolved
   config, in precedence order (stated once, here):
   - **(a) Preset match** — the base_url's entry in
     `DashFloat.Config.Presets.label/1` ("zai" / "synthetic",
     trailing-slash-insensitive like `suggest_model/1`). A preset URL
     **always** reads its preset label, even when the settings entry
     carries a (host-defaulted) label: the presets are the first-class
     providers and the owner's examples use those names.
   - **(b) Settings label** — the active profile's `providers` entry whose
     `baseUrl` equals the config's (trailing slashes trimmed on both
     sides), by its `label` — already explicit-or-host at parse time
     ([ADR 0008](0008-config-layout-profiles-json5.md)). An explicitly
     labeled custom URL shows that label.
   - **(c) Host degrade** — no matching entry (env-only boots,
     `providers: []`): the base_url's `URI.parse` host, else the raw
     string. An unlabeled custom URL degrades here the same way.
2. **The model part** is `nickname || model` — the issue's own examples:
   `zai - glm-5.3` (id), `synthetic - fixer` (nickname).
3. **The profile suffix moves out.** ADR 0008's `"nickname (profile)"`
   footer form is retired — the issue asks for provider + model, not
   profile; the profile stays reachable via `/profile`
   ([ADR 0020](0020-command-surface.md)). nil still only when nothing
   resolves (no provider classification) — the footer's "—" arm.
4. **Cadence unchanged.** The span stays a render-time read of
   `State.provider_label/1`, so `/model` and `/profile` switches show on
   the next frame exactly as the model span always did — nothing new at
   any agent seam ([ADR 0007](0007-tool-calls-and-execution.md)).

## Amendment (2026-10-31, issue #104): the idle cursor blinks

**Status:** Accepted. Supersedes the "focused + idle" bullet of §1 above —
its "costing **zero new timers** (ADR 0006's idle ⇒ no timers ⇒ no renders
stands untouched)" parenthetical AND its "static bright reversed" wording —
which the owner's smoke test
([issue #104](https://github.com/fluxvale/dashfloat/issues/104)) reversed.
Everything else in §1 stands: the focus gate (unfocused shows no cursor,
still zero extra renders), the explicit bright pair, and the active-phase
blink riding the 125 ms tick. The idle blink is a dedicated 500 ms timer —
**measured 2.0 renders/s while idle** — owned, costed, and recorded by
[ADR 0006](0006-ui-truth-and-rendering.md)'s 2026-10-31 blink amendment
(exception #5); this note only keeps §1's record coherent. The Tab rule in
§3 is untouched: the ghost arms and lands only on an EMPTY draft, so a
`/`-prefixed draft never carries a ghost, and the filter popup's Tab
(issue #105, ADR 0020's amendment) cannot fight Tab-the-ghost.

## Amendment (2026-10-31, issues #129 + #130): breathing gap, ttft, whole-response tok/s

**Status:** Accepted. The owner's v0.4.0 smoke test (Oct 31), one lane:
"Can you add some margin at the bottom of the chat so there's a gap
between the chat and the input box" (#129) and "Can we show the
time-to-first-token alongside the tok/s?" (#130), the latter refined
mid-lane (below). #129 extends §2's split with one more fixed region; #130
supersedes §2's rate wording ("live while streaming because the tick
recomputes it; frozen after finalize" — the rate is no longer live at all)
and [ADR 0006](0006-ui-truth-and-rendering.md)'s status-bar-truth "tok/s"
bullet (cross-noted there). Everything else stands.

### #129 — the breathing gap

- **Two blank rows between the transcript and the composer CLUSTER.**
  `View.regions/3`'s split becomes status / log / **gap** / activity /
  input / footer, the gap a fixed `@gap = 2` rows carrying no widget —
  the margin language's own rhythm
  ([ADR 0006](0006-ui-truth-and-rendering.md)'s #108 amendment established
  two cells at every screen edge; the gap is the same two cells, applied
  inside the chrome). The activity row renders UNDER the air, hugging the
  input: it is the composer's own status chrome (`Streaming… esc
  interrupt` interrupts the turn the composer sent), so the cluster the
  air separates from the chat is activity + input + footer together.
- **Constant by construction.** The gap is a region, not a render effect:
  it holds snapped to the tail and scrolled mid-history alike, and the
  composer's own height never moves (the log absorbs the two rows — the
  idle 80×24 log goes 15 → 13; that is the recorded cost of the air the
  owner asked for). Popups and setup screens overlay the whole inset area
  and are untouched.
- **Degenerate frames give the air back first.** When the inset height
  cannot carry status + gap + a minimal (3-row) composer + footer, the
  gap collapses to zero and the layout degrades exactly as the margin
  amendment's degenerate rule does — never raise, never negative.

### #130 — ttft beside a whole-response tok/s

The exact format, stated once: **`ttft 1.4s · 32 tok/s`** — ttft first,
both one decimal with a trailing `.0` trimmed (the percent span's own
rule, #67 stage 2: `1.4`, `2`, `32`).

- **ttft = send → first token.** `submit/2` stamps `sent_at` (the Enter
  moment, injectable like every clock read) and the turn's first token
  captures `ttft_ms` **once per turn** — a mid-turn tool interlude wipes
  the episode counters but not the turn's ttft, so it always reads from
  the Enter that sent it. A token with no send behind it (resume replay,
  a straggler) shows no span; a clock wound backwards reads 0, never
  negative.
- **During streaming: ttft alone, once known — never a live tok/s.** The
  owner's refinement, verbatim: *"it tends to speed up by the end so it
  doesn't give a good representation of the TPS."* The tick no longer
  touches the rate at all (spinner + in-flight refresh only); `stats.rate`
  is nil from send to finalize.
- **The average definition (recorded next to the number):** the shown
  tok/s is the **whole-response average — total tokens ÷ the decode
  window, first → last token** — frozen at finalize (and cancel; a turn's
  last episode wins, the existing carry). Total ÷ (send → done) was
  rejected: it folds TTFT into a throughput number and drags it down —
  the decode window is the representative reading of steady decode speed.
  The usage frame still reconciles the count (its completion total
  replaces the per-delta estimate, so the frozen average divides real
  tokens), and a single token (zero-width window) honestly yields no
  rate.
- **Persistence: both spans outlive the turn; the next SEND retires
  them.** After `{:phase, :idle}` the footer keeps the finished turn's
  `ttft … · … tok/s` as its record; the next **send** — a plain-message
  submit, the one submit that opens a model turn — stamps a new `sent_at`
  and clears `ttft_ms`/`rate`, so a streaming footer shows the new turn's
  ttft once a token lands and never a stale tok/s. Command submits (typed,
  filter-Enter, or the modal palette — all dispatched submits under ADR
  0006's #131 re-pin rule) deliberately do NOT touch the stats: no model
  turn follows them, so the finished turn's record stays until a real
  send supersedes it.
- **Width discipline: the pair may never clip.** At 80 cols the full row
  (`❯ cwd · model · used/window · % · ttft · tok/s`) overflows; the
  optional groups drop from the left in reverse order of urgency — the
  cwd first (the least volatile thing on the row), then the context
  snapshot, then ttft — the ❯ glyph, the model label, and the rate are
  never dropped, and the last resort keeps the rate alone and clips as
  the Paragraph always did. (The attach row's hints-drop is the
  precedent: drop what fits worst, keep the payload whole.)

## Amendment (2026-10-31, ADR 0028): the composer is replaceable

**Status:** Accepted. This ADR owns the composer's surface; [ADR
0028](0028-choice-widget-and-ask-user.md) adds the one thing §1–§3 never
contemplated: the composer can be **temporarily replaced** — while a
pending choice (an approval question, #133, or the model's `question`
tool, #134) owns the input, the input region renders the choice widget (a
Paragraph in the composer's own bordered box) instead of the `Textarea`,
and the region's height flows from the widget's rows, not the draft's.

- **The draft is preserved by construction.** The textarea's state is
  never touched while replaced — no save/restore dance, no cursor
  restoration; the composer restores with whatever was in flight the
  moment the choice resolves.
- **The ghost is reaped on arm.** While replaced, the placeholder (ghost
  or hint) can neither render nor land into a draft the user could
  Tab-materialize, so arming a choice sets the dismiss/reap intent of §3:
  the debounce dies, an in-flight task is killed, stragglers orphan on the
  epoch. The next completed turn re-arms per §3's once-per-turn rule; Tab
  is swallowed by the choice.
- **The cursor does not blink while replaced** — there is no composer to
  blink over; the selection marker is the choice widget's cursor. The
  idle-blink timer's gate is unchanged (the choice arms a non-idle phase,
  so `blinkable?` is already false).
- **Attachment chips do not render while replaced** (they are the
  composer title's chrome); the pending set is untouched underneath and
  reappears with the restored composer.

## Amendment (2026-11-01, issue #139): the width discipline is measured by the renderer's classifier

**Status:** Accepted. The #130 amendment's width discipline — which groups
drop, in what order — is unchanged; what changes is the ruler. The footer
originally measured candidate rows with a private approximation
(`String.length` plus one cell per astral-plane grapheme), which
undercounts BMP-wide glyphs: every Han/Hangul/fullwidth grapheme counts
one cell to the approximation and two to the terminal, so a footer
carrying a CJK cwd or model name could believe a row fit that actually
overflowed, clipping a span the ladder had promised whole (#139, recorded
imprecision from #137's audit).

- **One classifier for both surfaces.** The footer now measures span
  widths with the transcript renderer's own classifier — `Wrap.width`
  (the module pinned cell-by-cell against `ex_ratatui`'s unicode-width in
  `wrap_test.exs`) — so the transcript and the footer can never disagree
  about how many cells a string occupies. No second width classifier
  exists in the TUI; the footer's approximation is deleted, not kept
  alongside. (The attach row's and the rename dialog's naive
  `String.length` accounting is the same bug class and survived this
  amendment — filed as #144, not settled here. Settled by #144: both
  surfaces, plus the resume picker's preview cap, now measure through
  `Wrap` — the "no second classifier" claim holds with no exceptions
  left.)
- **The drop ladder's arithmetic is cell-accurate for wide glyphs.** The
  #130 rung order is untouched; only its measurements improve. At 80 cols
  a CJK cwd drops exactly when its measured width (two cells per Han
  grapheme) overflows the rect — never one cell late, which is precisely
  the clip the approximation could ship — and the never-drop rate lands
  whole behind it.

## Amendment (2026-11-01, issues #146 + #147): the width stragglers

**Status:** Accepted (issues
[#146](https://github.com/fluxvale/dashfloat/issues/146) and
[#147](https://github.com/fluxvale/dashfloat/issues/147), found by #144's
hostile review). Both are completion work on the [#139
amendment](#amendment-2026-11-01-issue-139-the-width-discipline-is-measured-by-the-renderers-classifier)
(the amendment that settled #144)'s
class — the fit functions (`Wrap.fit_head/fit_tail`) already existed;
this records where they were still not applied. **Amends** [ADR
0027](0027-exit-resume-command-and-resume-picker.md) §2's row clause and
[ADR 0009](0009-config-v3-persona-profiles.md)'s wizard-mechanics clause
(one more rendering rule each; composition and masking unchanged).

- **#146 — the session picker's whole row caps at the popup's inner
  width.** The row label (`preview · time · provider · model`) is fit by
  `Wrap.fit_head` at render time against the popup the renderer actually
  draws (85% of the inset area, truncating division, minus borders —
  62 cells at 80 cols). Two alternatives were weighed in the issue:
  shrinking the preview budget was rejected because the metadata tail is
  **unbounded** (user-chosen profile and model names) — no fixed shrink
  can promise fit; only the render-time budget is honest. **Drop order
  when the budget is tight: the model drops first, then the provider,
  then the time; the preview is the row's identity payload and the last
  to lose cells** — the [#130 ladder's](#amendment-2026-10-31-issues-129--130-breathing-gap-ttft-whole-response-toks)
  rule (drop the scaffolding, keep the payload whole) by a deliberately
  simpler mechanism: the picker row is one plain string in a `List` that
  clips rather than wraps, so one `…` cut replaces the footer's span-
  group ladder — no groups exist to drop one by one.
- **#147 — the wizard's input lines ride the tail-showing rule.** Every
  `input_line` call site tail-fits the shown draft (`…` marking the
  dropped head) into the setup box's inner width minus the `❯ ` prefix
  and the cursor's own cell, so the block cursor — where editing
  happens — never leaves the screen. The masked-secrets form rides the
  same budget: its stars are one cell each by construction, but a long
  masked draft overflows the row exactly the same way. This is the
  attach row's and title dialog's rule applied to the last cursor
  surface that lacked it.
