# 0018 — Image attachments: capability flag, content parts, visible refusal

- **Status:** Accepted; **amended 2026-10-31** ([issue #112](https://github.com/fluxvale/dashfloat/issues/112) —
  dropped image paths become numbered `[Image #n]` chips, bracketed-paste
  detection; see
  [Amendment (2026-10-31, issue #112)](#amendment-2026-10-31-issue-112-dropped-image-paths-become-numbered-chips)
  below)
- **Date:** 2026-10-29
- **Implements:** [issue #75](https://github.com/fluxvale/dashfloat/issues/75). Amends
  [ADR 0005](0005-llm-streaming-engine.md) (the outbound message shape),
  [ADR 0008](0008-config-layout-profiles-json5.md) (the models-entry schema),
  and [ADR 0002](0002-tui-skeleton.md) (the composer's key surface); the log
  indicator rides [ADR 0006](0006-ui-truth-and-rendering.md)'s entry seam.

## Context

The owner asked (Oct 29) that DashFloat attach images when the currently
selected model accepts image input, in the OpenAI-compatible content-parts
format, with capability known per model. Octofriend's attachment flow was
read as the reference (READ-ONLY, `~/DevTools/octofriend`):

- capability is a per-model `modalities` config (image enabled, accepted
  MIME types, a size cap), resolved per batch;
- attached images ride an LLM-agnostic IR as `image` parts and lower, on the
  OpenAI chat-completions wire, to
  `{"type": "image_url", "image_url": {"url": "data:<mime>;base64,…"}}`
  content parts after a leading text part;
- a paste onto a non-vision model is refused with an error banner, while an
  image part that survives to a non-vision model at lowering time degrades
  to a placeholder text — a deliberate soft-drop;
- the UI shows attach badges at the composer and `📎` chips in the
  transcript (no thumbnails).

DashFloat differs deliberately in two places: the attach path is a typed
file path with completion (terminal image *paste* is not standardized —
bracketed paste is text-only), and an image that cannot be sent is **refused
visibly, never placeholder-dropped** (silent degradation of a user attachment
is a lie about what the model saw).

## Decision

### 1. Capability: a strict `images` flag on the models entry

A `settings.json5` models entry may carry `images: true`. The flag is a
strict boolean: `true` means image-capable; absent or `false` means not;
anything else (a string, a number) warns naming the field and means not
([ADR 0009](0009-config-v3-persona-profiles.md)'s tolerance principle — same
shape as `context`). The selected entry's flag rides `DashFloat.Config` as
`images` alongside `context_tokens`.

The standing catalog refresh never sets or refreshes the flag: the OpenAI
`/models` shape carries no capability field, so catalog entries are
image-incapable by definition, and on an id collision the menu's own entry —
flag included — already wins (ADR 0009's merge rule; only `context`
refreshes). The status bar shows `📎` beside the model label when the
selected model is image-capable, so the capability is visible before any
attach attempt.

### 2. Message shape (ADR 0005 amendment)

A user turn without attachments is unchanged: `%{role: "user", content:
text}`. A user turn **with** attachments carries content parts — text part
first (omitted when the prompt text is empty; an image-only turn is a legal
submit), then one image part per attachment:

```json5
{ "role": "user", "content": [
  { "type": "text", "text": "what is this?" },
  { "type": "image_url", "image_url": { "url": "data:image/png;base64,…" } }
] }
```

`ChatStream` is unchanged — it already Jason-encodes the agent's message
list verbatim, and atom- or string-keyed parts encode identically. Like
every message, image parts ride the transcript for the session's life and
are re-sent on every later episode of that conversation; token and billing
accounting for re-sent images is provider-side. The chars/4 heuristic
([ADR 0022](0022-context-accounting-and-compaction.md) §1) weights a
list-content message by its parts — the text and the data-URL bytes — so
the context estimate (and the footer's percent) stays truthful between
usage frames instead of scoring an image turn at zero. Assistant, tool,
and system messages never carry parts — which is also why the AUTO safety
check's prompt ([ADR 0016](0016-interaction-modes.md) §6, built from tool
args and preview lines only) can never see an image part: no leak vector,
verified at implementation time.

**Persistence coordination (ADR 0014): 0014 landed on main BEFORE this
ADR's implementation, persisting `state.messages` verbatim; per the
land-first rule this lane adapts — its load validation widens here to
accept a list of content parts (each `type`/`text` or
`type`/`image_url.url`), and its round-trip test gains an image-bearing
fixture.**
Resuming an image-bearing session under a non-image model then sends parts
to a text model; the provider's HTTP error surfaces through ADR 0005's
taxonomy (`[llm: HTTP …]`) — visible and honest, which is the rule.

### 3. One owner for image rules: `DashFloat.Images`

The extension allow-list (`.png .jpg .jpeg .gif .webp`), the MIME map, the
size cap (10 MiB per file), path validation, and the bytes→data-URL encode
live in one module used by both surfaces — the attach prompt validates a
path before it can sit in the composer; the agent re-validates at submit
(the file may have changed on disk, and the provider may have changed under
the TUI since attach).

### 4. Refusal semantics: visible, with the reason, never a drop

Every refusal is a `[images: …]` system entry in the chat log — the same
surface as `[llm: …]` and `[cancelled]` — naming the reason: the model (id
or nickname) when the selected model is not image-capable; the path when it
is unreadable, not a regular file, not an image extension, or over the cap;
the byte size when over cap. Nothing is ever silently dropped and nothing is
placeholder-substituted on the wire.

Two gates, one predicate each side of the seam:

- **Attach (the TUI):** Enter in the attach prompt validates the path and
  the selected model's capability. A refusal lands as the system entry and
  the prompt stays open with the draft intact (fix the path and retry).
- **Submit (the agent — the single voice):** a prompt carrying attachment
  paths is gated on the provider's `images` flag and on re-reading the
  files. Refusal answers the UI with the system entry and `{:phase,
  :idle}`; nothing is sent, nothing enters the transcript, the attachments
  stay pending in the composer for the user to resolve.

### 5. Attach UX (ADR 0002 amendment): a one-line prompt mode

`Ctrl+O` (only while idle) opens the attach prompt in the activity row; the
composer's textarea is untouched. While open, the prompt is a key mode like
confirmation mode: printable keys and Backspace edit the path draft,
bracketed pastes append to it, `Tab` completes against the filesystem
(longest common prefix; a completed directory gains a trailing `/`;
dotfile entries complete only after a `.` prefix), `Enter` attaches,
`Esc` closes the prompt keeping pending attachments, `Ctrl+D` clears all
pending attachments. The global `Ctrl+C`/`Ctrl+Q` clauses still apply.

Pending attachments render as a `📎 n` count in the input block's title;
the submitted user entry renders one dim `📎 name (n KB)` line per image
under the prompt text — the log indicator. Entry `text` stays verbatim
(ADR 0006): the indicator is display lines only.

Path completion and the attach-time existence check read the filesystem in
the UI process — the sanctioned exception, scoped exactly to the attach
prompt (one `readdir` and one `stat`, local and bounded), mirroring the
wizard's exception in ADR 0009. Image **bytes** are read only by the agent
at submit — never in the UI process.

### 6. The seam change

`{:prompt, ui, text}` becomes `{:prompt, ui, text, paths}` (a list of image
paths, `[]` for a plain turn). The agent reads and encodes the bytes, builds
the content parts, and starts the episode; the TUI never touches image
bytes and keeps only `{path, name, kb}` metadata for display. Pending
attachments clear when the agent's `{:phase, :streaming}` echo opens the
turn — a submit-time refusal never echoes it, so the pending set survives
the refusal exactly as §4 requires.

### 7. Testing

The request seam asserts over the loopback server: an image-capable fixture
driven through the agent must put the content parts in the decoded request
body; an incapable model must refuse visibly with **no** request reaching
the server. TUI tests drive the prompt end to end (open, type, complete,
attach, indicator, refusal), and config tests pin the flag's parse and its
tolerance arm.

## Alternatives considered

- **Octofriend's placeholder lowering** (wire-level soft-drop for image
  parts on non-vision models) — silently misrepresents the conversation;
  DashFloat refuses instead. Rejected.
- **Paste-to-attach** — terminal image paste is not standardized; bracketed
  paste delivers text only. A pasted *path* is supported instead. Rejected
  for this slice.
- **Reading/encoding image bytes in the UI process at attach** — big
  binaries and file I/O in the process whose contract is zero I/O; the
  agent owns the bytes at submit. Rejected.
- **A per-model MIME/size matrix (Octofriend's `modalities.image`)** — one
  global allow-list and cap until a provider demands otherwise. Rejected as
  premature.
- **`images` as a per-provider (not per-model) flag** — capability is
  per-model in every real fleet (a flash model takes images where its
  flagship sibling may not). Rejected.
- **Stripping image parts from earlier turns after their first send** —
  saves request bytes but rewrites conversation truth mid-session;
  accounting belongs to #43. Rejected.

## Consequences

- The fleet's image-capable models are opted in by hand in `settings.json5`
  until a provider's `/models` grows a capability field (none today). A
  runtime `/model` switch re-resolves the picked id against this menu by
  id (a marked entry keeps its capability; a catalog-only id is not
  capable) — the flag never carries over from the outgoing model.
- Image turns re-send their base64 on every later episode of the session —
  larger requests and provider-side image-token billing per turn, the price
  of a truthful transcript.
- An agent crash report may echo the message list — data URLs included —
  through OTP's `State:` report, the one echo surface besides the session
  file and request bodies where the base64 exists by design. Accepted for
  now (the transcripts are local); redact via `format_status/2` if it ever
  leaks somewhere it matters.
- The 10 MiB cap bounds each file; a turn with many attachments still
  multiplies (the request body carries all of them). The read-side
  re-check closes the stat/read race — a file grown between the two is
  refused, never silently sent over the cap. Acceptable until a real
  transcript hits the multiply.
- The attach prompt's Tab completion may read one directory listing plus
  probe completed candidates for directory-ness (`File.dir?/1`) — the
  sanctioned exception's "one readdir and one stat" in spirit: bounded,
  local, prompt-scoped.
- ADR 0014 landed first; this lane widened its user-content validation to
  parts, per §2 — and the TUI's transcript replay renders list-content
  user turns (concatenated text plus one `📎` row per image part) instead
  of crashing on them.
- The composer gains its first file-reading surface; it stays scoped to
  completion and one `stat`, and the ADR 0002 process contract is otherwise
  untouched.

## Amendment (2026-10-31, issue #112): dropped image paths become numbered chips

**Status:** Accepted. The owner's v0.3.0 smoke test (Oct 31): attaching
should be drag-and-drop — the image shows up on the field. Extends §5's
attach UX and reverses exactly one alternative below ("Paste-to-attach …
rejected for this slice" — that rejection was about IMAGE PAYLOADS in
pastes, which bracketed paste still cannot carry; a pasted PATH was always
text, and this amendment is exactly that). The capability flag (§1), the
wire shape (§2), the refusal semantics (§4), and the seam (§6) are
unchanged.

- **Detection is bracketed-paste-only, whole-paste, and existence-gated.**
  A drag onto most terminals PASTES the file's path. A paste converts to an
  attachment only when its ENTIRE content — one trailing newline and
  surrounding whitespace stripped, nothing else — is a single
  whitespace-free path with an image extension that names an **existing
  regular image file** (`Images.image_file?/1`, one `stat` — the same
  sanctioned read shape as §5's prompt). A multi-line paste, prose, a
  missing file, or a non-image extension is ordinary text: pasting a path
  AS TEXT keeps working, and false positives need a file that actually
  exists. **Typed paths never convert** — the deliberate asymmetry: typed
  text is ambiguous (paths as prose are common), a whole-paste drop is not;
  typed paths keep `Ctrl+O`. No `~` expansion, matching the prompt's
  literal-path rules.
- **The gates mirror the prompt's Enter.** An existing image file under a
  non-capable model refuses visibly (`[images: model … does not accept
  images — attach refused]`) and the paste types nothing; an over-cap or
  unreadable image refuses through `Images.check/1`'s named reasons; a
  capable model appends the pending attachment. Drops land in any phase
  where the composer owns pastes (the other input modes — confirm, setup,
  attach prompt, /title dialog — swallow pastes before it, unchanged); the
  queue only rides a submit, which stays idle-gated.
- **Chips replace the `📎 n` count.** Pending attachments render in the
  input block's title as `[Image #1] [Image #2] …` — accent, like the `❯`
  glyph they extend — numbered by pending-queue order (re-derived on every
  change, so a pop renumbers). Rendering chips inside the Rust textarea is
  not possible; the title is the composer's own chrome and the chips sit on
  the field's border, the honest v1 surface.
- **Backspace pops before it deletes.** With an EMPTY draft, Backspace
  removes the newest pending attachment (the chip row renders ahead of the
  draft; an empty cursor sits at its boundary) — the chip-row UX terminals
  teach. With draft text, Backspace keeps its ordinary edit. `Ctrl+D`
  inside the attach prompt still clears everything.
- **Ctrl+O's own attach does not snap the log** (issue #110's rule is
  composer EDITS — keystrokes and pastes; a prompt action is neither, and
  the prompt is open precisely because the user is mid-task on the
  composer's chrome). The drop path and the chip pop DO snap: they are
  composer events. *(Superseded 2026-10-31, #131 — [ADR
  0006](0006-ui-truth-and-rendering.md)'s Enter-only re-pin amendment
  reversed #110 wholesale: NOTHING but a dispatched Enter pins, the drop
  path and chip pop included; the Ctrl+O clause above survives as one
  case of that general rule.)*
- **The submitted entry keeps §5's indicator rows** (`📎 name (n KB)` per
  image under the prompt text): the chips are the composer's pending
  display, the entry's rows are the transcript's record — different
  surfaces, both dim-by-design.
