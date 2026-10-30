# 0006 — UI truth & rendering: markdown log, live status, activity line, input hardening

- **Status:** Accepted; **amended 2026-10-24** ([issue #20](https://github.com/fluxvale/dashfloat/issues/20) —
  the log word-wraps to the current width; see
  [Amendment: log word-wrap](#amendment-log-word-wrap-issue-20) below);
  **amended 2026-10-25** ([issue #28](https://github.com/fluxvale/dashfloat/issues/28) —
  layout margin, double Ctrl+C exit guard, mouse selection/copy; see
  [Amendment (2026-10-25, issue #28)](#amendment-2026-10-25-issue-28-margin-exit-guard-mouse-selection)
  below); **amended 2026-10-26** ([issue #32](https://github.com/fluxvale/dashfloat/issues/32) —
  the overlay vocabulary gains two startup screens, the forced-selection
  modal and the onboarding wizard, rendered in place of the chat chrome
  until setup clears; specification and screens:
  [ADR 0009](0009-config-v3-persona-profiles.md) § "Startup classification"
  and § "First-run onboarding wizard"); **amended 2026-10-27**
  ([issue #27](https://github.com/fluxvale/dashfloat/issues/27) — the
  agent transcript, not entry text, is the persistence truth; entries are
  derived; see
  [Amendment (2026-10-27, issue #27): persistence truth moves to the transcript](#amendment-2026-10-27-issue-27-persistence-truth-moves-to-the-transcript)
  below); **amended 2026-10-29**
  ([issue #66](https://github.com/fluxvale/dashfloat/issues/66) /
  [issue #67](https://github.com/fluxvale/dashfloat/issues/67) /
  [issue #70](https://github.com/fluxvale/dashfloat/issues/70) —
  composer cursor, stats footer under the input, ghost-text suggestion;
  see [ADR 0015](0015-input-surface-cursor-stats-ghost.md)); **amended
  2026-10-31** ([issue #107](https://github.com/fluxvale/dashfloat/issues/107) /
  [issue #108](https://github.com/fluxvale/dashfloat/issues/108) — user
  entries bold with an accent `❯` prefix, the chrome margin widened to two
  cells; see
  [Amendment (2026-10-31, issues #107 + #108)](#amendment-2026-10-31-issues-107--108-user-entry-style-margin-2)
  below); **amended again 2026-10-31**
  ([issue #104](https://github.com/fluxvale/dashfloat/issues/104) — the
  idle cursor blinks: the zero-render idle discipline gains one bounded,
  measured exception; see
  [Amendment (2026-10-31, issue #104): the idle cursor blinks](#amendment-2026-10-31-issue-104-the-idle-cursor-blinks)
  below)
- **Date:** 2026-10-24
- **Implements:** [issue #16](https://github.com/fluxvale/dashfloat/issues/16) — Phase 2.5 of the
  [ADR 0001](0001-founding-stack-and-architecture.md) roadmap.
- **Extends:** [ADR 0002](0002-tui-skeleton.md) (layout, message contract, non-blocking rule)
  and [ADR 0005](0005-llm-streaming-engine.md) (usage frames); neither is superseded.

## Context

After Phase 2 the TUI works but lies: placeholder status fields, raw markdown,
no activity feedback, no paste hardening. The visual north star is Claude
Code's console — minimal top bar, warm terracotta accent, dim secondary text,
rounded bordered input with a `>` glyph, animated activity line while working —
implemented fresh with our own branding (no Anthropic wordmarks, no verbatim
UI strings). Out of scope (binding, from the issue): syntax highlighting
inside code blocks, resizable panes, mouse support, modal/confirmation UI.

Dependency facts verified from source before deciding (`ex_ratatui` 0.17.1,
`earmark_parser` 1.4.46):

- `ExRatatui.Widgets.Markdown` exists but is a NIF (`tui-markdown` crate,
  pulldown-cmark + syntect) with a hardcoded `base16-ocean.dark` syntect
  theme: it performs syntax highlighting the issue excludes, cannot be themed
  to our palette, and renders as an area-owning widget — it cannot flow
  through the log `Paragraph` as styled `Line`s.
- `ExRatatui.Widgets.Textarea` has `wrap_mode: :word | :glyph |
  :word_or_glyph` soft-wrap of the draft, width-aware (wide chars, emoji).
- `Style` supports `{:rgb, r, g, b}` and `{:indexed, n}` colors.
- `ExRatatui.Runtime.snapshot/1` exposes `render_count` and
  `last_rendered_at` — the server is already a frame counter of record.
- `ExRatatui.Layout.split/3` handles a four-way vertical split with a
  zero-height constraint (probed: a `{:length, 0}` region collapses cleanly).
- `EarmarkParser.as_ast/1` is pure Elixir (no NIF) and returns Floki-style
  tag tuples (`{"h1", [], ["Title"], %{}}`); malformed input degrades to
  paragraphs instead of raising, empty input yields `[]`, CRLF inside
  paragraphs is normalized to LF, and verbatim HTML keeps its inner text as
  plain strings.

## Decision

### Visual language

Five regions *(amended 2026-10-29,
[ADR 0015](0015-input-surface-cursor-stats-ghost.md))*; the activity row
exists only while work is in flight:

```
┌ status ─ 1 row ──────────── ● Streaming · follow L412
│ log     :min 0             (windowed; markdown-rendered assistant rows)
├ activity 1 row (0 idle) ── ⠋ Streaming…  esc interrupt
│ input   2 + draft lines ── rounded border, ❯ title, placeholder, soft wrap
└ footer  1 row ──────────── ❯ ~/FluxVale/dashfloat · model · 4.1k/128k · 3.3% · 30 tok/s
```

- **Status bar** — one left-flowing `Line` of styled spans, dim separators:
  phase dot + label (accent while busy, dim idle), log position (dim)
  *(ctx left the bar in #67 stage 2 — see the 2026-10-30 amendment to
  [ADR 0015](0015-input-surface-cursor-stats-ghost.md) §2)*. `❯ <cwd>` (dim,
  last two path segments, `~/`-prefixed), `<model>` (default foreground —
  truth, not decoration), tokens-used + percent-of-context, and
  `<rate> tok/s` (only after/while a stream has produced tokens) live in
  the input **footer** — a permanent 1-row region under the composer — per
  [ADR 0015](0015-input-surface-cursor-stats-ghost.md) §2 (moved, not
  duplicated; cursor per §1; ghost text per §3).
- **Activity line** — spinner glyph + action label + dim interrupt hint,
  accent-colored, on the 1-row region above the input. Labels: `Thinking…`
  (streaming, no token yet), `Streaming…` (tokens arrived), `Running tool…`
  (`:executing_tool`). Spinner is a braille frame set stepped by the tick.
- **Input box** — rounded border in dim gray, `❯` as the block title in
  accent, the composer's placeholder in dim (the placeholder text and its
  visibility rule live in [ADR 0015](0015-input-surface-cursor-stats-ghost.md)
  §3 and its 2026-10-30 amendment). `wrap_mode: :word_or_glyph` so long
  words/URLs wrap at word boundaries and split at glyph boundaries only when
  unbreakable.
- **Message rows** — user input echoed dim with a bold `❯ ` prefix on its
  first line, continuation lines indented; assistant output rendered as
  markdown in default foreground; tool and system rows dim (system italic).
  *(The user row's style is superseded — 2026-10-31, #107: bold default fg,
  accent `❯` prefix; see the amendment below.)*
  Every entry's rendered lines begin with one blank separator line — no
  special-casing of the first entry; the top padding reads as warmth.

### Theme as data

`DashFloat.TUI.Theme` is a map of role → `%Style{}` (`Theme.style/1`), so
Phase 3 extends the vocabulary by adding roles, not code:

| Role | Style |
| --- | --- |
| `:accent` | `{:rgb, 217, 119, 87}` — terracotta (`#d97757`) |
| `:dim` | `:dark_gray` |
| `:dim_italic` | `:dark_gray` + italic (system rows) |
| `:user` | bold, default foreground *(amended 2026-10-31, #107 — was `:dark_gray`)* |
| `:assistant` | default foreground |
| `:tool` | `:dark_gray` (accent prefix glyph is Phase 3's to add) |
| `:heading1` | accent + bold |
| `:heading2` | bold |
| `:heading3` | bold + dim (h4–h6 map here) |
| `:emphasis_bold` / `:emphasis_italic` / `:strikethrough` | modifiers |
| `:inline_code` | `{:indexed, 215}` (warm) |
| `:code` | fg `{:indexed, 252}`, bg `{:indexed, 234}` (fenced regions) |
| `:code_lang` | dim (fenced-block language tag) |
| `:link` | underlined |
| `:quote` | dim |
| `:rule` | dim |
| `:hint` | dim (activity-line interrupt hint, separators) |
| `:status_busy` / `:status_tool` / `:status_idle` | accent / `:light_yellow` / dim |

The palette is warm-dim by intent: one accent, grays, two warm support
colors — no rainbow.

### Markdown pipeline

- **Parser: `earmark_parser` (`as_ast/1`)** — pure Elixir, tag-tuple AST
  mapped by us to styled spans. This honors the issue constraint
  (pure-Elixir AST → styled spans; no HTML-rendering or other NIF) and the
  out-of-scope rule (no syntax highlighting — we never invoke a highlighter).
- **Mapper: `DashFloat.TUI.Markdown.render(text) → [Line.t()]`** — pure,
  total (never raises). Tag mapping: `h1`–`h6` → heading styles; `p` →
  default lines (embedded `\n` splits); `ul`/`ol` → `•`/`◦`/`▪` per nesting
  depth and `N.` numbering, two-space indent per level; `pre`+`code` → the
  fenced region below; `blockquote` → dim `│ ` prefix; `hr` → dim rule line
  (emitted long; viewport truncation gives a full-width rule for free);
  `strong`/`em`/`del` → modifiers; inline `code` → `:inline_code`; `a` →
  underlined text, plus a dim ` (<href>)` suffix only when text ≠ href;
  `br` → line break. Unknown tags and verbatim HTML: recurse and render the
  inner text plainly — unknown markup degrades to text, never to a crash.
  Empty/whitespace input → `[]`.
- **Fenced code blocks** — a backgrounded region inside the windowed
  renderer's line budget: a dim `┈ <lang>` tag line, then one display line
  per code line carrying `:code` bg/fg with a one-space side pad, then the
  block ends (the following blank separator restores rhythm). No borders to
  draw, no width math — one line in, one line out.
- **Where parsing runs** — in the UI process, never in `render/2`, in
  exactly two bounded places *(amended: a third bounded moment — resize —
  re-wraps without parsing; see the
  [wrap amendment](#amendment-log-word-wrap-issue-20))*:
  1. **Finalize** — an assistant entry is rendered once at append time and
     the lines are stored on the entry. The entry *is* the parse cache.
  2. **The animation tick** — while streaming, the tick (≤ 8 Hz) re-renders
     the in-flight text if tokens arrived since the last tick, capped at
     64 KiB of input; above the cap the live view keeps the last render
     until finalize (still one parse at the end).
  Per-frame cost stays `O(viewport)`: the windowed log slices stored lines;
  zero parsing and zero line-building happen in `render/2`.
- **Line accounting follows rendered lines** — `log_line_count/1` sums the
  stored line lists (plus the in-flight rendered lines). Scroll semantics
  (intent, clamp, follow-pin) are unchanged from ADR 0002; a re-render that
  changes the count just re-clamps. *(Amended by the wrap amendment below:
  the stored lists are wrapped display lines.)*

### Entries carry rendered lines

Entries become maps `%{kind: :user | :assistant | :tool | :system, text:
String.t(), lines: [Line.t()]}` (was `{kind, text}`). `text` is kept verbatim
for persistence (Phase 4); `lines` is the render truth built once at append
by `DashFloat.TUI.Render.entry_lines/2`. The raw text never re-renders.
*(Amended: entries also carry `logical` — the width-free render truth — and
`lines` is its wrap at the current width, re-wrapped on resize; see the
[wrap amendment](#amendment-log-word-wrap-issue-20).)*

### Status-bar truth

- **Model name** — from provider config (already landed; ADR 0005).
- **Live token count** — every `{:token, _}` message is one OpenAI-compatible
  delta ≈ one token; the counter increments per token and is reconciled by
  the usage frame when it arrives.
- **Usage** — `ChatStream` now sends
  `stream_options: {include_usage: true}` and, when a frame carries a
  `usage` object, sends it to the UI as a new contract message (below).
  This amends one ADR-0005 table row: usage frames are no longer silent
  shape misses, they are consumed. Provider-compat note: OpenAI-compatible
  routers broadly support `stream_options`; a provider that rejects it fails
  through the existing HTTP error taxonomy (degrades to a chat entry).
- **tok/s** — cumulative average: `tokens / elapsed`, elapsed measured from
  the first token's arrival (injected monotonic clock, below). Recomputed on
  each tick while streaming; frozen at finalize/cancel — the last rate stays
  visible after completion.
- **Context usage** — *(the banking this bullet described is deleted — #67
  stage 2 replaced it; see the 2026-10-30 amendment to
  [ADR 0015](0015-input-surface-cursor-stats-ghost.md) §2 and
  [ADR 0022](0022-context-accounting-and-compaction.md) §7)* the footer's
  tokens-used span reads `Accounting.usage/3` over the agent's
  {messages, anchor} snapshot — the usage-frame-anchored estimate, not a
  banked sum of frame totals. A usage frame arriving after the turn
  finalized is ignored — it belongs to a turn that is over. Optional config
  field `context_tokens` (+ env `DASHFLOAT_CONTEXT_TOKENS`, validated as a
  positive integer, absent → nil — never an error) supplies the window
  denominator — else the TUI's catalog fallback, display-only; without
  either, the span shows the absolute total only.
- **Cancellation math** — Esc keeps the partial tokens counted, freezes the
  rate at `tokens / elapsed(now)`, and never divides by zero (no tokens → no
  rate). The usage frame that never arrives simply never reconciles.

### Clock discipline

`State.stream_message/3` and `State.tick/2` take `now` (monotonic
milliseconds) with a `System.monotonic_time/1` default — pure functions with
an injectable clock. `render/2` never reads the clock: the displayed rate
lives in state, updated by tick/finalize.

### Animation model — active-only tick

A `:dashfloat_tick` message every **125 ms** via `Process.send_after/3`,
scheduled **iff `phase != :idle` and no tick is pending** (a `tick_ref` in
state), checked at a single choke point after every `handle_event`/`handle_info`
callback. The tick handler steps the spinner, re-renders dirty in-flight
markdown (bounded as above), recomputes the rate, and reschedules **only if
still active**; any transition to `:idle` cancels the pending timer. A tick
message that arrives stale (its timer was cancelled after the message queued)
— or that halts — returns render-suppressed, so it can never draw a frame.
**Idle ⇒ no timers ⇒ no renders.** This is the second sanctioned exception to
ADR 0002's non-blocking rule (the first is submit-time `start_child`):
`send_after` schedules a message and blocks nothing.

The activity animation exists *only* while a stream/tool is live — this is
both the Claude-Code feel and the fleet's parked-fan insurance: an idle
DashFloat renders nothing on a timer, ever.

### Message contract extension (ADR 0002 table)

| Message | Effect |
| --- | --- |
| `{:usage, %{prompt_tokens: n, completion_tokens: n, total_tokens: n}}` | reconcile token counts, hold the frame's total as the turn's banked total (last frame wins; non-negative integers only — anything else is ignored by the producer); no phase change |

Sent before the terminal `{:phase, :idle}` when the provider includes usage
(the stream's final chunk). Engines stay TUI-agnostic — it is data.

### Paste, wrap, cursor

- **Bracketed paste** — `ExRatatui.Event.Paste` (already wired) → normalize
  `\r\n` and lone `\r` to `\n`, then insert at the cursor. No size cap:
  a huge paste costs one bounded NIF insert; documented acceptance.
- **Word wrap** — input `wrap_mode: :word_or_glyph` (above). ~~Log lines
  still truncate~~ Log lines word-wrap to the current width —
  [Amendment: log word-wrap](#amendment-log-word-wrap-issue-20) below
  reverses this clause (and ADR 0002's corresponding rejection); scroll math
  follows wrapped display lines.
- **Cursor movement** — the textarea's existing key set (arrows, Home/End,
  Ctrl+A/E/K/W) with history-aware Up/Down at draft boundaries (ADR 0002,
  unchanged).

### Render-rate counter

Decision: **no new render-loop code.** The metric of record is
`ExRatatui.Runtime.snapshot/1` (`render_count`, `last_rendered_at`), already
maintained by the server. Tests and dev probes measure rates by sampling
snapshots — which doubles as the animation-discipline proof: renders increase
while a stream is live (ticks) and stay flat over an idle window with no
input. Keeping `render/2` free of counters preserves its purity.

## Interface freeze

The exact seams implementers build against:

- `State` new fields: `cwd` (label, computed at `new/1`), `anim_step`,
  `tick_ref`, `in_flight_lines`, `in_flight_dirty`, `stats`
  (`%{tokens, first_token_at, rate, prompt_tokens, completion_tokens,
  context_total, turn_total}`).
- `State.stream_message/2,3`, `State.tick/2` (`→ {state, :cont | :halt}`),
  `State.needs_tick?/1`, `State.paste/2`, `State.cwd_label/1`,
  `State.rate_label/1`, `State.context_label/1`, `State.provider_label/1`
  (née `provider_model/1`; renamed and profile-aware by
  [ADR 0008](0008-config-layout-profiles-json5.md)),
  `State.provider_context_tokens/1`.
- `Render.entry_lines(kind, text) → [Line.t()]` (includes the leading blank
  separator); `Markdown.render(text) → [Line.t()]`; `Theme.style(role)`,
  `Theme.spinner_frames()`.
- `View.regions(size, input_lines, active?)`; activity row height 1 when
  `active?`, else 0.
- `Config` field `context_tokens: pos_integer() | nil`.
- `ChatStream` request gains `stream_options: %{include_usage: true}`; usage
  frames become `{:usage, map}` messages.

## Alternatives considered

- **`ExRatatui.Widgets.Markdown`** — hardcoded syntect theme (excluded
  highlighting, wrong palette), area-based rendering that cannot flow into
  the windowed log Paragraph. Rejected despite zero new deps.
- **`mdex`/`cmark` NIFs** — violate the pure-Elixir constraint.
- **Hand-rolled parser** — a markdown bug farm; malformed input handling for
  free is worth one pure-Elixir dep.
- **Full `earmark`** — we need only the parser; the HTML transformer would be
  dead weight.
- **Parse in a Task, message back** — sanctioned by the task brief but
  unnecessary: tick-bounded parsing is bounded by construction, and a Task
  adds out-of-order render complexity for no measured need.
- **`Throbber` widget** — one label string; cannot style spinner, action, and
  hint differently. Custom spans.
- **Right-aligned status cluster** — alignment is per-`Line`, not per-span;
  a two-line bar wastes a row. Single left-flow chosen.
- **Wrapped log lines** — ADR 0002 rejected; ~~scroll math stays exact~~
  reversed by the wrap amendment below (wrapped scroll math is exact because
  accounting counts the stored wrapped lines).

## Amendment: log word-wrap (issue #20)

Live testing (#20) showed the shipped contract truncating long log lines at
the pane edge — cut off, not soft-wrapped — exactly as ADR 0002 had decided
and this ADR had retained. The product answer changed: **the log wraps.**
What was decided, amending this ADR (and ADR 0002's truncation clause):

- **`DashFloat.TUI.Wrap`** owns the transform: `wrap(lines, width)` folds
  each logical styled line into display lines no wider than the log region —
  word boundaries first, glyph boundaries for runs too long for a row
  (`:word_or_glyph`, same semantics as the input textarea). Styles travel
  with the text; a line that fits is rebuilt span-for-span (its own
  style/alignment ride along); a blank line wraps to a blank line
  (separators keep the rhythm). A line's leading whitespace plus an optional
  short symbolic marker (`• `, `│ `, `❯ `, `⚙ `) is its hanging indent: the
  first row keeps the prefix verbatim, continuation rows hang by its width —
  prose never matches (a leading word must be purely symbolic to count as a
  marker), and an indent wider than half the row is dropped rather than
  guttering the text. A whitespace run that would overflow a row is dropped
  *and closes the row*, so a wrap point can never fuse the words it
  separated.
- **Width accounting matches the Rust renderer** (`unicode-width`), measured
  against it during review: East Asian Wide/Fullwidth and emoji count two
  columns, combining marks and format characters zero, everything else one.
  Grapheme clusters carrying a variation selector (emoji presentation:
  ⚠️, ❤️, keycaps), a skin tone, or an emoji-led ZWJ sequence count two —
  the renderer's cluster width, where a per-codepoint sum would undercount
  and let the Paragraph clip the row tail (the exact #20 symptom, reproduced
  in review and pinned by buffer-level regression tests). The width tables
  are compile-time-checked sorted *and disjoint* (zero is consulted before
  wide, so an overlap would silently re-classify wide codepoints as
  zero-width — that exact bug shipped in an intermediate cut and was caught
  in review), and a renderer-agreement property test walks every table
  entry and the emoji families through the real cell renderer asserting
  `Wrap.width >= rendered advance`: measured zero under-counts across the
  review's 16,927-codepoint differential, the residual drift over-count
  only (wraps a column early, never truncates).
- **Entries carry both truths**: `logical` (the width-free render, the parse
  cache — still built once at append by `Render.entry_lines/2`) and `lines`
  (its wrap at the current width — what the view renders and the scroll math
  counts). `text` stays the persistence truth.
- **Where wrapping runs** — the same bounded places parsing always ran:
  append (inside `put_entry`), the tick's in-flight refresh, and now resize
  (width change only, re-wrapping every entry from `logical` — no re-parse;
  the in-flight reply re-renders from its text under the same 64 KiB cap).
  Above the cap no fresh render is possible, and a stale-width render would
  truncate at the new edge, so a width-changing resize clears the live view
  until finalize. Never per frame: `render/2` stays `O(viewport)`, slicing
  stored wrapped lines. The wrap itself is single-pass over graphemes with
  binary-searched width tables — measured at 35 ms for a 48 KB
  space-free CJK reply (was 1.6 s in the first cut, quadratic; a
  wall-clock regression test guards the tick budget).
- **Resize re-wrap cost is O(session) and known** — ~21 ms per 1000 entries
  for short lines, up to ~0.7 s for a 5000-entry log of 200-char prose
  (measured in review): resize is the one eager full-log pass, and unlike
  scroll-time accounting (which walks entry lists, not their lines) it
  touches every row, so a drag-resize on a huge log stalls the UI process
  per event. Accepted for now — resize is user-paced and rare; deferring
  the re-wrap (lazy per-entry re-wrap in the windowed slice, memoised per
  `{entry, width}`) is tracked follow-up work for when logs grow with
  Phase 4 persistence.
- **Scroll math counts display lines** — the invariant moved from
  "display == logical (no wrapping)" to "accounting and rendering read the
  same stored wrapped lines". `log_line_count/1`, `effective_scroll/2`, the
  windowed slice, and the status position all agree by construction (held
  through a 300-state randomized differential in review). Scroll *intents*
  survive resize numerically and re-clamp against the new counts — they are
  not content-anchored, so a re-wrapped view may sit at different content
  after a resize; content anchoring is deferred with Phase 4.
- **Markdown rules wrap like any other unbreakable run** (a 120-column rule
  at an 80-column terminal renders as two rows) — the visible price of the
  no-truncation guarantee; the alternative (truncating decorative runs)
  cannot be distinguished from data at the wrap layer.
- **Input box unchanged** — the textarea wraps its own draft Rust-side, per
  frame, at the area width, so resize re-wraps it for free; the box height
  stays bound to logical lines (ADR 0002's clamp), wrapped overflow scrolling
  inside the box.
- **Why the shipped tests missed the bug**: they asserted on stored logical
  lines and widget configuration (`wrap_mode: :word_or_glyph`) — never on
  what a narrow terminal buffer actually received. The regression tests now
  draw long entries into narrow test terminals and require every word (and
  the tail after an emoji sequence run) to reach the buffer.

ADR 0002's scroll-math rationale ("wrapped log lines" rejected; truncation
keeps the math exact) is reversed by this amendment: wrapping keeps the math
exact *by storing the wrapped lines as the counted truth*, and the
truncation it defended was the bug.


## Amendment (2026-10-25, issue #28): margin, exit guard, mouse selection

**Status:** Accepted. Extends this ADR's layout, input-contract, and
render-rate sections; supersedes nothing in ADR 0002 beyond what the mouse
amendment below already reversed. Live smoke testing (Oct 25) drove all three.

### Margin geometry — the padded width is the only width

*(The numbers here are superseded — 2026-10-31, #108: two cells per side;
see the amendment below. The single-source-of-truth rule stands.)*

One cell of padding on every side of the chrome: `View.regions/3` splits an
inner area inset by one from the frame, so no text hugs a screen edge.

- **Single source of truth:** the log rect *is* the wrap width.
  `State.log_width/1` reads the log rect from the same `View.regions/3` split
  that renders it — wrap at append, the tick's in-flight refresh, resize
  re-wrap, scroll viewport heights, windowed slicing, and (below) selection
  columns all derive from the one split. Consistency is by construction; the
  alternative (subtracting a margin constant at each consumer) re-creates the
  exact class of edge bug this guards against.
- **Odd and narrow widths** wrap at the padded width with no truncation —
  the #20 buffer-level regression tests now draw at odd frame widths with the
  margin, and every word must still reach the buffer.
- Degenerate frames collapse as before: the inset area can go to zero and the
  layout degrades without raising; `Wrap.wrap/2` still clamps below 1.

### Double Ctrl+C exit guard — and the sibling-key survey

Raw mode makes Ctrl+C a key event, and one accidental press must not kill a
live session.

- **State machine:** the first Ctrl+C arms a **2 s window** (monotonic,
  injectable like every other clock read in `State`) and shows a transient
  prompt on the activity row. A second press **inside the window** quits
  through the normal `{:stop, state}` teardown. A second press **after
  expiry re-arms** — the window never extends. Any other key press disarms.
- **Prompt:** the activity row now also exists while idle while a transient
  message is showing (`overlay?` in `View.regions/3`: active phase or armed
  guard). The exit prompt outranks the streaming/confirm activity text while
  it lives.
- **Sanctioned exception #3 (one-shot, bounded):** the prompt's visual expiry
  is a single `Process.send_after` ~2 s after the press — armed only by an
  explicit Ctrl+C, firing at most one frame, never looping. The idle
  discipline stands for everything else: no user action, no timer, no render.
  (The tick is exception #2; submit-time `start_child` #1.)
- **Sibling keys, each decided:**
  - **Ctrl+Q stays an immediate quit** — the deliberate exit path, named in
    the input placeholder; users keep a one-press way out.
  - **Ctrl+D was never an exit key** in DashFloat (it forwards to the
    textarea like any editing key) — nothing to guard, deliberately left.
  - **Ctrl+Z deliberately does not suspend.** Raw mode means no SIGTSTP
    reaches us; the event is inert textarea input. Real suspend support
    (restore terminal, signal self, re-init on resume) is unjustified
    complexity for a full-screen alternate-screen app — leave it out.
  - **Esc is untouched:** cancels a stream / rejects a confirm, never exits.
- The guard applies in every phase, including mid-confirmation (a pending
  confirm does not swallow Ctrl+C, matching the pre-guard quit ordering).

### Mouse selection and OSC 52 copy

Mouse capture (#21) took the terminal's native selection away; the app now
owns selection over the log.

- **Geometry is display-row based.** A left-press anchors a range at
  `{display_row, column}` in the same wrapped-display-line space the scroll
  math counts — and snapshots the entries' display-row count as the
  gesture's **base**; a drag moves the head; both clamp into the log rect
  **in screen space before the scroll mapping** — a click on the status bar
  or a drag into the input pane selects the viewport's edge row, content
  under the visible clamp, never rows beyond the viewport (a first cut
  clamped in content space instead and anchored off-screen; caught in
  review).
- **Content-anchored, not viewport-anchored:** indices are absolute display
  rows, so a selection **survives scrolling** (wheel or page keys — the
  highlight translates with the content) and **survives appends** (indices
  are stable under append-at-end). It is **cleared** by a width-changing
  resize (re-wrap invalidates the geometry) and by an in-flight finalize
  that the selection **reaches into** — judged against the gesture's own
  base, never a finalize-time recount: rows appended between the anchor
  and the finalize (the Esc-cancel contract's system entry, late tokens)
  shift the live block, and a recount drifts with them (a first cut
  recounted and silently kept selections whose content had changed;
  caught in review). A selection entirely below the base survives the
  finalize; appending cannot move the rows below it.
- **Click-to-clear, extent-based:** a press+release is a click unless the
  release sits on a different row or at least **three cells** (inclusive
  extent) from the anchor — a deliberate 3-cell same-row selection copies;
  the 1–2 cell wobble of a shaky click does not (a first cut measured the
  column distance strictly-greater and made 3-cell selections impossible;
  caught in review). Known, deliberate edge: a drag that returns to its
  anchor cell releases with a 1-cell extent and reads as a click — the
  extent at release decides, not the path.
- **Wide/emoji clusters are atomic:** a cluster is selected iff its *first*
  column is in range; slicing and highlighting never split a cluster
  (the wrap width tables do the measuring — one width vocabulary). Both
  endpoints select **through the cell they point at** — the range is
  half-open over cell edges, so the last column of a row is reachable (a
  first cut treated the pointed cell as exclusive and lost every row's
  final character; caught in review). A collapsed selection (press, not
  yet a drag) highlights nothing — one reversed cell would read as a
  cursor artifact.
- **Copy is display-faithful and bounded at the BUILD:** interior rows copy
  their rendered text verbatim (hanging indents included — exactly what a
  native terminal gives you when selecting a wrapped region), first/last
  rows by column range, rows joined with `\n`, per-row trailing blanks
  trimmed. The payload is capped at 64 KiB of text and the *build* stops
  at the cap — a monster span costs one cap-sized pass, never a full
  materialisation (a first cut built the whole span and froze the UI
  process on multi-megabyte logs; caught in review). Past the cap the
  write is dropped with a log line, the highlight stays, and the reported
  bytes are the accumulated size at the stop.
- **OSC 52 delivery:** on release the UI process writes one bounded
  BEL-terminated `\e]52;c;<base64>\a` sequence to standard output — the
  **third one-shot exception** pattern (a bounded write on a user-paced
  action, never in `render/2`, never blocking; `IO.binwrite` completes
  before the post-event frame draws, so bytes cannot interleave mid-frame).
  Live runs only; test mode never writes. Terminals that ignore OSC 52
  simply do nothing — degradation is silence, never a crash or block.
- **Shift is latched at gesture start:** a left-down with Shift is a
  native-selection gesture — it dismisses any existing app selection, and
  nothing in that gesture can select or copy (a later plain up after
  releasing Shift has no anchor to copy from — a first cut was inert only
  while Shift was held and leaked a clipboard write from a stale anchor;
  caught in review). Shift mid-gesture merely pauses extension; a
  plain-start gesture still copies at its release.
- **Render discipline:** down/drag/up are user-paced events that may draw,
  like keys; pointer motion without a button stays render-suppressed, and
  the wheel routing amendment below is unchanged.

## Consequences

- One new dependency (`earmark_parser`, pure Elixir, Apache-2.0).
- Entries hold rendered lines alongside text — memory grows by thin structs
  sharing the same strings; caps are Phase 4's problem with the log itself.
- Existing tests migrate from `{kind, text}` tuples to map entries.
- The tick is the only new timer in the UI process, and it cannot outlive
  activity; review lens for later phases: any timer firing while idle, any
  parse in `render/2`, any live parse above the 64 KiB cap.
- Phase 3 tool rows reuse the entry kinds, `Theme` roles, and the dim-row
  vocabulary exactly; confirmation UI remains out of scope until then.

---

## Amendment (2026-10-27, issue #27): persistence truth moves to the transcript

**Status:** Accepted. Supersedes exactly one clause of this ADR — the
"Entries carry rendered lines" section's claim that `text` is "kept verbatim
for persistence (Phase 4)" (retained by the word-wrap amendment as "`text`
stays the persistence truth"). Everything else about entries stands:
`text` remains the verbatim plain-text render cache, `logical` the width-free
render truth, `lines` its wrap at the current width.

- **The persistence truth is the agent transcript** — `DashFloat.Agent`'s
  `state.messages`, provider-shaped (assistant messages carry `tool_calls`
  with ids and full argument JSON; tool messages carry `tool_call_id` and the
  complete bounded result). Only the transcript round-trips: a log persisted
  from `text` has no tool ids, no argument JSON, and 30-line excerpts where
  the model needs the full result — reloading it would replay prettily and
  then die on ADR 0007 §1's dangling-`tool_calls` API error.
- **Entries are derived state.** Live, they derive from the display contract
  as today. After resume, they are rebuilt by replaying the transcript
  through the same render path — user/assistant content through
  `Render.entry_lines/2`, tool calls through `Render.tool_call/2`, tool
  results through `Render.tool_result/3` — so `logical`/`lines` are freshly
  built, never loaded.
- **Nothing display-only is persisted or survives resume**: `[cancelled]`,
  `[stream failed: …]`, `[model returned nothing]`, `[tool run cancelled]`,
  and confirmation previews exist for the screen; the 30-line excerpt cap
  stays a display cap (recomputed from the full result at replay).

Specification, file format, and resume semantics:
[ADR 0014](0014-session-persistence.md).

## Amendment (2026-10-24, issue #21): mouse wheel routing

**Status:** Accepted. Supersedes exactly one Phase-1 stance — the "mouse
capture for scrolling — rejected" alternative in
[ADR 0002](0002-tui-skeleton.md). Everything else in ADR 0002's input and
scroll contract stands.

### Root cause (the record)

DashFloat always runs in the alternate screen. With mouse tracking off —
the Phase-1 default — xterm-class terminals (xterm `alternateScroll`, VTE,
Windows Terminal, iTerm2, Alacritty, WezTerm, foot) translate each wheel
notch into Up/Down **arrow-key escape sequences**, byte-identical to real
arrow presses. They decoded as ordinary key events and landed in
`State.handle_key/3` for `"up"`/`"down"` → input-history navigation. The
live bug: the wheel walked the input draft instead of scrolling the log.
Interception at the event boundary is therefore impossible — emulated and
genuine arrows are the same bytes at every layer the app can observe.

### Decision

- **Real mouse tracking, not interception.** `DashFloat.TUI.start_link/1`
  defaults `mouse_capture: true` — the policy lives with the TUI module, so
  every starter (Application, tests) gets it, and the default is pinned by
  a test on the `[:ex_ratatui, :transport, :connect]` span metadata
  (ex_ratatui → crossterm `EnableMouseCapture`, `?1000h` + `?1006h` SGR
  among others; disabled again on every teardown path the runtime owns).
  Once capture is on, terminals stop emulating and report genuine wheel
  events; the arrow ambiguity disappears at the source.
- **Focus-free routing.** `scroll_up`/`scroll_down` mouse events always
  address the log view — regardless of which pane is under the cursor,
  whether a draft is being typed, and including mid-confirmation. There is
  no focus model; the input never sees the wheel. One notch scrolls three
  lines (the alternate-screen convention). Semantics mirror the page keys
  at line granularity: up unfollows (with page_up's nothing-to-scroll
  guard), down re-pins at the bottom, submit re-pins.
- **All other mouse events are inert and render-suppressed** — clicks,
  drags, and pointer motion draw nothing. A pointer wandering over an idle
  UI must not draw frames (the idle discipline above, applied to input).
- **Keyboard truth unchanged.** Genuine Up/Down keep their
  history-at-draft-boundary semantics; PgUp/PgDn keep viewport paging
  (ADR 0002).

### Costs and compatibility

- Native drag-selection is captured while the app runs; selecting log text
  requires the terminal's bypass modifier (Shift, honored by the mainstream
  terminals above). That is the price of a wheel that scrolls — Phase 1
  chose the other side of this trade; the live bug moves the balance.
- Terminals that ignore mouse-reporting modes entirely keep their legacy
  wheel behavior (indistinguishable from arrows, so unchanged history
  navigation); none of the mainstream family above does. tmux with its own
  `mouse on` intercepts the wheel for its copy mode — DashFloat never sees
  the event. Not verifiable headless in CI; the manual smoke on real
  terminals is the issue's acceptance step.
- Scroll math composes with display-line accounting: wheel scroll consumes
  `log_line_count/1` and `effective_scroll/2` — the same wrapped-display-line
  seam as the page keys (see the word-wrap amendment above) — and introduces
  no new line accounting of its own.
- **Known pre-existing upstream limitation (verified during this fix, not
  caused by it):** a single-burst write of more than ~1 KiB of *discrete*
  input events (e.g. >~100 raw arrow or mouse-motion byte sequences in one
  write) wedges the ex_ratatui/crossterm reader until the process dies —
  reproduced identically on main with plain letters. Human-reachable input
  is unaffected: typing is burst-far-below the threshold, a real mouse
  delivers at most a couple of events per 16 ms poll, and bracketed paste
  of any size arrives as one event (probed at 4 KiB). Worth an upstream
  report; explicitly out of scope here.

## Amendment (2026-10-31, issues #107 + #108): user-entry style, margin 2

**Status:** Accepted. One owner smoke test (Oct 31) drove both changes: the
owner could not tell their own messages from the assistant's (#107), and the
transcript hugged the screen edges (#108). Supersedes exactly the numbers in
the [2026-10-25 margin section](#margin-geometry--the-padded-width-is-the-only-width)
and the user-row styling in the [theme table](#theme-as-data) and
[message rows](#visual-language); everything else stands.

- **User entries read distinct (#107):** `:user` was `:dark_gray` — the same
  gray as half the chrome, vanishing into default-fg assistant text on light
  palettes. It is now **bold on the default foreground**: a pure weight
  change, legible on every palette, no wash, no new color (the palette stays
  warm-dim). The first line's `❯ ` prefix rides `:accent` + bold, tying the
  log's user entries to the composer's accent `❯` title — same glyph, same
  role, so "your input" reads as one system. Tool and system rows are
  unchanged, and resume replay already routes through the one styler
  (`Render.entry_lines/2`), so the distinction survives `--resume` by
  construction.
- **Margin two (#108):** one cell per side was not enough air at realistic
  widths. The chrome now insets **two cells on every side** — top, bottom,
  left, right; wrap width = frame − 4. The 2026-10-25 rule is untouched: one
  `@margin` drives `View.regions/3`'s inset area (status, log, activity,
  input, footer, and the palette/setup screens alike) and `content_width/1`,
  so the whole chrome moves together and the log rect is still the wrap
  width, by construction. At 80×24 the idle log keeps 15 rows — the
  top/bottom air is what makes the window read as framed.

## Amendment (2026-10-31, issue #104): the idle cursor blinks

**Status:** Accepted. The owner's v0.3.0 smoke test (Oct 31) decided the
question [issue #91](https://github.com/fluxvale/dashfloat/issues/91)
deferred to him: the idle cursor BLINKS. Supersedes exactly one clause of
this ADR's animation model — "**Idle ⇒ no timers ⇒ no renders.**" — and the
matching idle-cursor clause of
[ADR 0015](0015-input-surface-cursor-stats-ghost.md) §1 ("costing zero new
timers"); every other idle discipline stands (no parse in `render/2`, no
timers beyond the ones enumerated here, render-suppressed stale messages).

- **Sanctioned exception #5 — the first REPEATING idle timer.** A dedicated
  `:dashfloat_blink` timer at **500 ms** (the active-phase blink's own
  half-period) toggles `blink_on` and draws exactly one frame per toggle:
  **measured 2.0 renders/s while idle, ~50 bytes per frame at the terminal**
  (pty probe over 3 s: 6 frame-bursts, 297 bytes — the one-cell cursor diff;
  `scripts/capture.py probe`). That is the honest cost the owner accepted:
  idle is no longer zero renders, and this ADR no longer claims it is.
- **Dedicated timer, not the tick.** Riding the existing 125 ms activity
  tick would re-render at 8 Hz idle — 4× the accepted cost — and couple the
  blink to spinner bookkeeping. The blink owns its own timer, the same
  single-choke-point discipline as the tick: exactly one pending while the
  chat UI is idle (arm at mount and after every event; a fired-but-undrained
  timer is left to drain), cancelled on every exit from idle — the active
  cursor keeps riding the tick — with `blink_on` reset visible so the first
  idle frame always draws the cursor. Stale blink messages (cancelled or
  superseded arms) are render-suppressed, exactly like stale ticks.
- **Blink unconditionally; focus does not gate it.** The probe showed the
  cost is a one-cell diff twice a second — negligible — so the simpler rule
  wins: the timer runs whenever the chat UI is idle, focused or not. An
  unfocused pane's cursor artifact stays hidden (ADR 0015 §1 unchanged), so
  its toggle frames carry no visible change; that inert symmetry is the
  price of not threading focus state through the timer. Setup screens (no
  composer) never arm it.
- **The suite stays hermetic.** Arming is live-only by default (the
  suggest-arm pattern, ADR 0015 §3): an injected `blink_ms:` opts a test in
  at its own cadence; the default suite arms nothing, so every
  renders-stay-flat-at-idle assertion in it keeps holding — now as the
  no-injection contract, not as the idle discipline.
- **Capture rig.** `wait_boot`/`wait_quiet` treat writes under 96 bytes as
  blink noise (quiet means "nothing substantive changed", not "zero
  bytes"); the probe reports bursts/s as the blink's metric.
