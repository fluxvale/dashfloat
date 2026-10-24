# 0006 — UI truth & rendering: markdown log, live status, activity line, input hardening

- **Status:** Accepted
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

Four regions; the activity row exists only while work is in flight:

```
┌ status ─ 1 row ──────────── ❯ ~/FluxVale/dashfloat · model · 4.1k tok · 30 tok/s ● Streaming
│ log     :min 0             (windowed; markdown-rendered assistant rows)
├ activity 1 row (0 idle) ── ⠋ Streaming…  esc interrupt
└ input   2 + draft lines ── rounded border, ❯ title, placeholder, soft wrap
```

- **Status bar** — one left-flowing `Line` of styled spans, dim separators:
  `❯ <cwd>` (dim, last two path segments, `~/`-prefixed), `<model>` (default
  foreground — truth, not decoration), `ctx <n>` (+`/<window>` and a percent
  when configured), `<rate> tok/s` (only after/while a stream has produced
  tokens), phase dot + label (accent while busy, dim idle), log position
  (dim). The bar omits token fields entirely until something has streamed.
- **Activity line** — spinner glyph + action label + dim interrupt hint,
  accent-colored, on the 1-row region above the input. Labels: `Thinking…`
  (streaming, no token yet), `Streaming…` (tokens arrived), `Running tool…`
  (`:executing_tool`). Spinner is a braille frame set stepped by the tick.
- **Input box** — rounded border in dim gray, `❯` as the block title in
  accent, placeholder text (`ask anything — Enter send · Shift+Enter newline
  · Esc interrupt · Ctrl+Q quit`) in dim. `wrap_mode: :word_or_glyph` so long
  words/URLs wrap at word boundaries and split at glyph boundaries only when
  unbreakable.
- **Message rows** — user input echoed dim with a bold `❯ ` prefix on its
  first line, continuation lines indented; assistant output rendered as
  markdown in default foreground; tool and system rows dim (system italic).
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
| `:user` | `:dark_gray` |
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
  exactly two bounded places:
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
  changes the count just re-clamps.

### Entries carry rendered lines

Entries become maps `%{kind: :user | :assistant | :tool | :system, text:
String.t(), lines: [Line.t()]}` (was `{kind, text}`). `text` is kept verbatim
for persistence (Phase 4); `lines` is the render truth built once at append
by `DashFloat.TUI.Render.entry_lines/2`. The raw text never re-renders.

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
- **Context usage** — the turn's final usage total (the **last** frame wins;
  per-chunk usage reporters send running totals on every frame, and summing
  those would inflate the number) is banked once at finalize into a cumulative
  `total_tokens` across turns (today's engine sends single-turn requests, so
  the sum is the honest number; when Phase 3/4 send history, `prompt_tokens`
  already includes it and the display switches to that truth). A usage frame
  arriving after the turn finalized is ignored — it belongs to a turn that is
  over. Optional config field `context_tokens` (+ env
  `DASHFLOAT_CONTEXT_TOKENS`, validated as a positive integer, absent → nil —
  never an error) supplies the window denominator: `ctx 4.1k/128k`. Without
  it, the bar shows the absolute total only.
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
- **Word wrap** — input `wrap_mode: :word_or_glyph` (above). Log lines still
  truncate (ADR 0002's scroll-math decision stands; re-litigation refused).
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
  `State.rate_label/1`, `State.context_label/1`, `State.provider_model/1`,
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
- **Wrapped log lines** — ADR 0002 rejected; scroll math stays exact.

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
