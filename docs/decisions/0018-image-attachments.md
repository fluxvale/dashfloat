# 0018 — Image attachments: capability flag, content parts, visible refusal

- **Status:** Accepted
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
accounting for re-sent images is provider-side. Assistant, tool, and system
messages never carry parts.

**Persistence coordination (ADR 0014, in flight on `feat/session-persistence`):
the session file persists `state.messages` verbatim, so image-bearing user
messages round-trip as list-content messages. ADR 0014's load validation
currently types user `content` as binary — when it lands, it must also
accept a list of content parts (each `type`/`text` or
`type`/`image_url.url`), extending its round-trip test with an
image-bearing fixture. This ADR lands first; the 0014 branch adapts.**
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
bytes and keeps only `{path, name, kb}` metadata for display.

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
  until a provider's `/models` grows a capability field (none today).
- Image turns re-send their base64 on every later episode of the session —
  larger requests and provider-side image-token billing per turn, the price
  of a truthful transcript.
- The 10 MiB cap bounds each file; a turn with many attachments still
  multiplies (the request body carries all of them). Acceptable until a
  real transcript hits it.
- ADR 0014 (in flight) must widen its user-content validation to parts, per
  §2.
- The composer gains its first file-reading surface; it stays scoped to
  completion and one `stat`, and the ADR 0002 process contract is otherwise
  untouched.
