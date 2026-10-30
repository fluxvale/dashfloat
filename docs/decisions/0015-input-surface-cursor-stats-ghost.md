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
deciding (`ex_ratatui` 0.17.1):

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

**Status:** Accepted. Supersedes exactly one clause of §1 above — the
"focused + idle" bullet's "costing **zero new timers** (ADR 0006's idle ⇒
no timers ⇒ no renders stands untouched)" — which the owner's smoke test
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
