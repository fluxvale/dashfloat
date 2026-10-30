# 0002 — TUI skeleton: process shape, event flow, and terminal lifecycle

- **Status:** Accepted
- **Date:** 2026-10-23
- **Implements:** [issue #4](https://github.com/fluxvale/dashfloat/issues/4) — Phase 1 of the
  [ADR 0001](0001-founding-stack-and-architecture.md) roadmap.

## Context

Phase 1 builds the `ex_ratatui` application shell: status bar, scrollable log,
multi-line input — no LLM, streaming, or tool execution. Before designing, the
`ex_ratatui` 0.17.1 surface was read from source and probed empirically (a
throwaway script under `mix run`, not committed). Facts that shaped this ADR:

- `ExRatatui.App` is a LiveView-style behaviour — `mount/1`, `render/2`,
  `handle_event/2`, `handle_info/2`, `terminate/2` — run by `ExRatatui.Server`,
  a GenServer placed in our supervision tree (`use ExRatatui.App` injects
  `start_link/1`/`child_spec/1`). We do **not** hand-roll the `ExRatatui.run/2`
  loop; the Server already owns polling, rendering, and teardown.
- The Server polls input every 16 ms on a DirtyIo scheduler, traps exits, and
  **coalesces renders when messages are queued**: a burst that arrives while
  the mailbox is backed up produces one frame with the final state. Spaced
  messages (one token every N ms, mailbox empty in between) each render a
  frame — so per-frame cost must be bounded by the viewport, not the log
  (see the log-rendering rule below).
- `Task.Supervisor` restarts its children by default; producer tasks must be
  `restart: :temporary` or a killed/crashed producer would re-run and
  duplicate its reply.
- Teardown (verified with `[:ex_ratatui, :transport, :disconnect]` telemetry):
  terminal restore + BEAM reader reattach run both on a normal `{:stop, _}`
  transition **and** when a callback raises (the GenServer calls `terminate/2`
  before exiting). Only `Process.exit(pid, :kill)` bypasses it — no process
  survives that; documented here as out of scope.
- `test_mode: {w, h}` gives a headless TestBackend terminal, disables input
  polling, and pairs with `ExRatatui.Runtime.inject_event/2` (deterministic
  input) and `Runtime.snapshot/1` (render count, trace). This is how CI tests
  the app without a TTY.
- `Textarea` keeps its text in Rust-side state behind a reference; its
  synchronous in-memory API (`textarea_handle_key/3`, `textarea_get_value/1`,
  `textarea_set_value/2`, `textarea_cursor/1`, `textarea_line_count/1`) is
  deterministic and works headlessly. `textarea_set_value/2` leaves the cursor
  at `{0, 0}` — history restore must also send `"end"`.
- A `Block` title needs a border row to render on: a 1-row status bar is a
  plain `Paragraph` with styled `Span`s.
- `Layout.split/4` degrades gracefully on tiny frames (regions collapse to
  zero height) — no crash on 1-row terminals.

## Decision

### Process shape

```
DashFloat.Application (Supervisor, one_for_one)
├── DashFloat.StreamSupervisor   (Task.Supervisor — demo producer now, stream handlers in Phase 2)
└── DashFloat.TUI                (use ExRatatui.App → ExRatatui.Server, the UI state process)
```

- The **UI state process** is `ExRatatui.Server` running the `DashFloat.TUI`
  callbacks — the single process from issue #4. All state lives in its
  `user_state`; `render/2` is a pure function of that state.
- The TUI child is **`restart: :temporary`** (overriding the injected
  `:transient` spec): a crashed UI must exit the application, not bounce back
  as a blank screen. `terminate/2` below still restores the terminal first.
- The Application starts the TUI child **only outside `Mix.env() == :test`**
  (`Code.ensure_loaded?(Mix)` guard keeps releases working) so `mix test`
  never touches a real terminal. Tests start their own instances under
  `test_mode`.
- `iex -S mix` also launches the TUI; quitting the TUI stops the VM (see
  teardown). Interactive development uses `mix run --no-halt`, which is the
  Phase 1 "product".

### Event flow and module decomposition

```
keyboard ──poll──▶ handle_event/2 ─┐
                                  ├─▶ DashFloat.TUI.State  (pure transitions)
messages ──send──▶ handle_info/2 ─┘         │
                                            ▼
                              DashFloat.TUI.View.render/2 (pure)
                                            │
                                            ▼
                             [{widget, rect}] → Server draws (NIF)
```

- `DashFloat.TUI.State` — owns the state struct and every transition
  (key routing, history, submit, scroll, stream messages, resize). Returns
  `{state, action}` where `action` is `:quit`, `{:submit, prompt}`, or `nil`;
  the TUI module interprets actions (starting tasks, stopping). No processes,
  no terminal, no timers.
- `DashFloat.TUI.View` — pure `render(state, frame) → [{widget, rect}]`,
  plus the shared layout split used by both render and scroll arithmetic.
- `DashFloat.TUI` — thin `use ExRatatui.App` callbacks: delegate to
  `State`, interpret actions, own `terminate/2`.
- Key events are handled only for `kind` `"press"`/`"repeat"` (kitty-protocol
  terminals also report `"release"`; ignoring them prevents double-firing).
- The input text lives inside the textarea NIF reference held in state;
  `State` reads/writes it through the synchronous in-memory textarea API —
  deterministic, headless-testable, and the render path treats it as data.

### Layout — three regions

Vertical split of the full frame: status `{:length, 1}` (top), log
`{:min, 0}` (middle), input `{:length, input_height}` (bottom), where
`input_height = 2 + textarea_line_count` clamped to `[3, max(3, height ÷ 3)]`.
The input box grows as the draft gains lines and never exceeds a third of the
frame. The same pure split feeds both `View.render/2` and `State`'s
page-scroll arithmetic — one source of truth.

- **Status bar**: styled spans — `DashFloat` (bold) · `model: —` · `ctx: —`
  (placeholders until Phase 2 supplies real values) · phase label
  (`Idle`/`Streaming`/`Executing Tool`, color-coded) · log position
  (`L<first>–<last>/<total>` or `follow`).
- **Log**: borderless `Paragraph`, `wrap: false`, `scroll: {offset, 0}`.
  Entries are styled per kind (`user`/`assistant`/`tool`/`system`).
- **Input**: `Textarea` with borders, title `Input`, placeholder carrying the
  keymap hint.

### Scrollback model

- The log is a list of entries; each entry renders as one or more display
  lines. *(Amended by [ADR 0006](0006-ui-truth-and-rendering.md): long lines
  word-wrap; the display-line count is the stored wrapped count, so scroll
  math is exact. Originally: no wrapping — long lines truncated at the right
  edge, so display-line count == logical-line count.)*
- State holds `scroll` (lines from top — the *intent*) and `follow?`
  (auto-scroll pin). `View` computes the *effective* offset by clamping
  `scroll` to `max(0, total_lines − view_height)` — stale intents after a
  resize or new content can never render past the end.
- New content while `follow?` stays pinned to the bottom. `PageUp` clears
  `follow?` and scrolls up one log viewport — but is a **no-op when there is
  nothing to scroll** (empty or viewport-sized log), so the pin is never lost
  for content that cannot move. `PageDown` scrolls down and re-pins when the
  bottom is reached. **Submit re-pins**: a new question implies the user
  wants to watch its answer arrive, even if they had paged up first.
  Keyboard-only: no mouse capture, so the terminal's native text selection
  (copy out of the log) keeps working.
- **Rendering is windowed**: each frame builds and encodes only the visible
  slice of the log, so the expensive part of a frame — constructing widgets
  and shipping them through the NIF bridge — is `O(viewport)`. Line
  *accounting* (totals, offsets, finding the entry that contains the scroll
  offset) remains a cheap scan of the entry list (no `String.split` list
  building — `:binary.matches` allocates only its small result list):
  negligible at session scale (hundreds of entries), ~10 ms at an
  implausible 100k-line in-memory log. A prefix-sum index is deferred until
  Phase 4 persistence makes logs actually huge. The full log stays in memory
  (plain list, `O(n)` append per entry); size caps are Phase 4 concerns.
- An empty log renders a gray placeholder line.

### Input mechanics and Enter vs Ctrl+Enter

- **Enter and Ctrl+Enter submit** ([ADR 0001](0001-founding-stack-and-architecture.md)
  names both as the execution trigger; on terminals where Ctrl+Enter is
  indistinguishable from Enter the outcome is identical, so the ambiguity is
  harmless). **Shift+Enter and Alt+Enter insert a newline** — with the
  caveat that only terminals that report enhanced key events (kitty keyboard
  protocol, modifyOtherKeys) distinguish Shift+Enter from plain Enter; on
  legacy terminals it arrives as Enter and submits. Alt+Enter is the
  portable fallback. All other printable keys and unbound Emacs shortcuts go
  to the textarea. (Amended by [ADR 0018](0018-image-attachments.md):
  `Ctrl+O` while idle opens a one-line image-attach prompt — a key mode that
  owns keys until it closes — with `Tab` path completion; the composer's
  textarea itself is untouched.)
- **Up/Down are history-aware**: `Up` navigates history only when the cursor
  is on the textarea's first row, `Down` only on its last row; otherwise they
  move the cursor (multi-line editing). History navigation overwrites the
  draft via `textarea_set_value/2` + `"end"`; the pre-navigation draft is
  restored when navigating back past the newest entry.
- History stores submitted non-empty inputs, deduplicating consecutive
  repeats, capped at 500. `PageUp`/`PageDown` always scroll the log.
- Submit is **ignored unless the phase is `:idle`** — one in-flight request;
  queueing is a Phase 2 decision.

### Stream message contract (the Phase 2 seam)

Everything that isn't keyboard input reaches the UI as plain messages into
`handle_info/2`:

| Message | Effect |
| --- | --- |
| `{:token, text}` | append to the in-flight streaming entry (opened lazily) |
| `{:phase, :streaming}` | set the phase only — re-announcing streaming **never finalizes**; a producer resuming after a tool interlude must not fragment its reply |
| `{:phase, :executing_tool \| :idle}` | set the status phase and finalize the in-flight entry into the log |
| `{:entry, :tool \| :system, text}` | append a complete entry |

Phase 2's stream handler replaces the demo producer but sends these same
messages — that is the entire integration surface between the streaming engine
and the UI.

The producer runs as a **monitored, `restart: :temporary` task** under
`DashFloat.StreamSupervisor`. A dead producer must never brick the UI (the
[ADR 0001](0001-founding-stack-and-architecture.md) rule: failures degrade to
chat messages): its `{:DOWN, …}` monitor message finalizes any partial reply,
appends a `:system` entry explaining the failure, and returns the phase to
`:idle` so input keeps working. Abnormal exits are never restarted — the
handler owns retry semantics, and an auto-restart would duplicate the reply.
One race is accepted by policy: a producer that exits between
`start_child/2` returning and the monitor attaching yields `:noproc`, which
is indistinguishable from success after the fact — it is treated as a normal
exit (the fast demo cadence hits this window routinely). Note the flip side:
a producer that *crashes* that early is swallowed the same way — no error
entry, just a missing reply. Phase 2 producers must therefore always send
their own terminal `{:phase, _}` message before exiting; the monitor is a
safety net, not the reporter of record.

### Synthetic-update demo path

Superseded by [ADR 0005](0005-llm-streaming-engine.md): the demo module is
deleted and the real SSE producer takes its place. The description below is
kept as the record of what Phase 1 shipped.

`DashFloat.SyntheticStream.emit(ui_pid, prompt, opts)` runs under
`DashFloat.StreamSupervisor` as a Task (started by the TUI on submit) and
drives the full contract on a canned reply: ~60 word-tokens at ~25 ms
intervals, an `executing_tool` interlude with a simulated `list_directory`
entry, then `:idle`. It performs no I/O beyond `send/2` and `:timer.sleep`,
proving token-rate messages never block input handling — the UI stays typeable
while tokens land (verified by the responsiveness test, not by assertion).

### Teardown and crash paths

The terminal must never be left broken:

- **Normal quit** (`Ctrl+Q`, `Ctrl+C` → `{:stop, state}`): Server `terminate/2`
  restores the terminal and reattaches the BEAM reader; exit reason `:normal`.
- **Callback crash**: same `terminate/2` path runs (verified empirically) —
  terminal restored, then the `:temporary` child is gone and the application
  stops with a non-zero status.
- **`DashFloat.TUI.terminate/2`** calls `System.stop/1` — `0` **only** for an
  explicit user quit (`:normal`); `1` for everything else, including
  supervisor-driven `:shutdown` (a sibling crash-loop arrives as `:shutdown`
  and must not masquerade as success). SIGTERM-to-exit-code mapping is
  deferred to the release work ([ADR 0010](0010-release-packaging.md)). This
  runs only when mounted against
  a real terminal — under `test_mode` it does nothing. It makes
  `mix run --no-halt` (and the future binary) exit when the TUI quits,
  without breaking tests.
- **Ctrl+C in raw mode** arrives as a key event (not SIGINT), so it is bound
  to quit. The only unprotected window is before `init_terminal` enters raw
  mode; a Ctrl+C there never left the terminal modified.
- **No TTY** (piped stdin): `init_terminal` fails before raw mode is entered;
  the Server stops with `{:terminal_init_failed, reason}`, the application
  fails to start, and the VM exits non-zero with the terminal untouched.
- **`Process.exit(pid, :kill)`**: nothing runs — accepted as the one
  unrecoverable case (standard OTP reality).

### Non-blocking rule

`handle_event/2`, `handle_info/2`, and `render/2` perform zero network,
filesystem, shell, or timer work. The only side effect they may trigger is
`Task.Supervisor.start_child/2` on submit (cheap, non-blocking). Anything slow
lives in a Task under `DashFloat.StreamSupervisor` and reports back via
messages. Render errors are already contained by the runtime (frame dropped,
logged, loop continues).

## Alternatives considered

- **Hand-rolled `ExRatatui.run/2` loop** — re-implements supervision, teardown,
  and render coalescing the Server already provides. Rejected.
- **Reducer runtime** (`use ExRatatui.App, runtime: :reducer`, single
  `update/2`) — the callback runtime's split between `handle_event/2` (terminal
  input) and `handle_info/2` (messages) matches the event flow better and
  matches hexdocs' primary examples.
- **Mouse capture for scrolling** — breaks the terminal's native text
  selection; keyboard scrolling suffices for Phase 1.
- **Wrapped log lines** — scroll offsets would count rendered lines and jump
  on resize/reflow; truncation keeps the math exact and the view stable.
  *(Reversed by [ADR 0006's wrap amendment](0006-ui-truth-and-rendering.md):
  the log word-wraps and the math counts stored wrapped display lines.)*
- **`List` widget for the log** — `Paragraph.scroll` gives the same with less
  state; no selection behavior needed.
- **Spinner animation via subscriptions** — not required to demonstrate the
  message flow (the demo producer already does); cut for laziness.

## Consequences

- Phase 2 implements the stream handler against the three-message contract
  above; the UI process needs no changes beyond state it already models.
- Review lens inherited from [ADR 0001](0001-founding-stack-and-architecture.md):
  I/O found in the UI process is a bug. Phase 1 adds one sanctioned exception —
  the submit-time `Task.Supervisor.start_child/2`.
- Log widget building/encoding is `O(viewport)` per frame; line accounting
  is a cheap `O(total)` scan (~10 ms at an implausible 100k in-memory lines).
  Log *storage* is a plain list with
  `O(n)` appends, bounded only by memory until Phase 4 persistence.
- The demo producer's cadence is configurable through mount opts
  (`:demo_stream_opts`) purely so tests can run it in milliseconds; defaults
  are the human-visible demo.
