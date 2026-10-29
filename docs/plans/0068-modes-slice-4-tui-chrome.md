# Slice 4 — TUI: mode cycling, mode chrome, preview-without-confirm, and the checking phase

Issue [#68](https://github.com/fluxvale/dashfloat/issues/68). Design:
[ADR 0016](../decisions/0016-interaction-modes.md) — read §7–§9 before
starting. Depends on **slice 1** (`DashFloat.Mode` exists and passes its
tests). Does not depend on slices 2–3: drive the TUI state directly with
contract messages (the module's existing test pattern) — a real agent is not
needed.

Files you will touch: `lib/dash_float/tui/state.ex`,
`lib/dash_float/tui/view.ex`, `lib/dash_float/tui.ex`, and TUI tests under
`test/dash_float/` (`tui_test.exs` and/or `test/dash_float/tui/`, following
what exists). Study `route_key/4`'s ordering, the `stream_message/3` confirm
clause, `status_widget`'s span list, and the `@phases` map first.

## Goal

The user can cycle modes with Shift+Tab, always sees the current mode in the
status bar, previews can render as proposals/receipts without arming a
confirmation, and the safety check has a visible phase.

## Spec

### 1. State (ADR 0016 §7–§9, freeze)

- `defstruct`: new field `mode: :build` (default in the struct — **no mount
  opt**; the agent's `{:mode, _}` echo is the single writer after boot).
- `@type phase`: add `:checking` to the union.
- `@type action`: add `{:set_mode, DashFloat.Mode.t()}`.
- `@type stream_msg`: add `{:mode, DashFloat.Mode.t()}`,
  `{:tool_preview, confirm_msg()}` (same payload shape as the confirm
  preview: `%{id, name, args, lines}`), and `:checking` to the phase
  messages.
- **Keybinding — shift+tab cycles.** In `route_key/4`, before the generic
  textarea forward (and after the pending-confirmation clauses, which swallow
  it — ADR 0016 §3: a pending confirm owns every key): a `"tab"` key with
  modifiers `["shift"]` returns
  `{state, {:set_mode, DashFloat.Mode.cycle(state.mode)}}`. It must work in
  every other chat phase (`:idle`, `:streaming`, `:executing_tool`,
  `:checking`) and must NOT fall through to the textarea.
- **`stream_message/3` clauses**:
  - `{:mode, mode}` → `state.mode = mode` (no entry, no phase change — the
    announcing system entry arrives separately as `{:entry, :system, text}`,
    which already renders).
  - `{:tool_preview, %{id: _, name: _, args: _, lines: lines}}` → append the
    preview entry via the same `Render.confirm_preview/1` builder the confirm
    clause uses, but do NOT set `state.confirm` and do NOT set phase
    `:confirming`. Nothing else changes.
  - `{:phase, :checking}` → set the phase like the other active phases: the
    in-flight entry finalizes (same handling as `:executing_tool`) and
    `state.confirm` clears (a phase message supersedes a pending confirm —
    same rule as the existing clauses).
- `TUI` runner (`lib/dash_float/tui.ex`): a `{:set_mode, mode}` action sends
  `send(state.agent, {:set_mode, self(), mode})` — mirror `prompt_agent/2`'s
  shape, in the same section. No local state change (single voice: the
  agent's echo updates the chrome).

### 2. View — the mode span and the checking phase (ADR 0016 §8)

In `status_widget`, insert one span between the model span and the ctx span:

```
separator(), Span.new(Mode label, style: Theme.style(role))
```

with (via a small map, matching how `@phases` is done):

| `state.mode` | Label | Role |
| --- | --- | --- |
| `:plan` | `"Plan"` | `:status_idle` |
| `:build` | `"Build"` | `:assistant` |
| `:auto` | `"Auto"` | `:status_tool` |
| `:unchained` | `"Unchained"` | `:error` |

Use `DashFloat.Mode.label/1` for the text; keep the role lookup local to the
view (display truth). The span is always present (all modes, all phases).

Add the phase to `@phases`: `checking: {"Checking", :status_tool}`. No new
Theme roles; no changes to regions, spinner, or the tick discipline
(`:checking` is an active phase — `needs_tick?`/`tick` treat it like
`:executing_tool`, which the phase-union change gives you; verify the idle
halt test still passes).

### 3. Esc while checking

`route_key`'s Esc-interrupt clause covers `:streaming` and `:executing_tool`;
add `:checking` to that list (Esc → `:cancel` action — the agent cancels the
vet and aborts the batch per ADR 0016 §6).

## Tests

1. **Cycle**: pressing `"tab"` + `["shift"]` from `:build` yields action
   `{:set_mode, :auto}`; from `:unchained` yields `{:set_mode, :plan}`; in
   phases `:idle`, `:streaming`, and `:checking`. The state itself is
   unchanged (the echo applies it).
2. **Swallowed mid-confirm**: with `state.confirm` set (pending
   confirmation), shift+tab returns `nil` and leaves `state.mode` untouched.
3. **Echo applies**: `stream_message(state, {:mode, :auto})` sets
   `state.mode`, adds no entry, does not change `phase`.
4. **tool_preview renders without arming**: `stream_message` with
   `{:tool_preview, %{id: 1, name: "edit_file", args: %{}, lines: ["@@ hunk"]}}`
   appends a tool entry whose text includes the preview lines, leaves
   `state.confirm == nil` and `phase` unchanged. Contrast case:
   `{:confirm, make_ref(), same}` sets `confirm` and phase `:confirming`
   (existing behavior, still green).
5. **Checking phase**: `stream_message(state, {:phase, :checking})` sets the
   phase, finalizes any in-flight entry; the phase renders "Checking" (see
   the `@phases` label test pattern in `view_test.exs`); Esc in `:checking`
   yields `:cancel`.
6. **Chrome**: render in each mode and assert the status bar carries
   `Plan` / `Build` / `Auto` / `Unchained` respectively — follow
   `view_test.exs`'s "status bar carries the cwd, model, and phase truth"
   test's extraction pattern. Also assert one styled case: in `:unchained`
   the label span's style equals `Theme.style(:error)`.
7. **Runner seam**: a `{:set_mode, :auto}` action makes the TUI send
   `{:set_mode, parent_pid, :auto}` to the agent (fake-agent pattern: the
   default `agent: self()` mount opt means the send lands in the test
   process's mailbox).

## Done when

```
mix deps.get && mix test test/dash_float/tui_test.exs test/dash_float/tui/
```

exits 0 with the new tests visible, and

```
mix ci
```

exits 0. Paste both transcripts. `git diff --stat main -- lib test` shows
exactly `lib/dash_float/tui/state.ex`, `lib/dash_float/tui/view.ex`,
`lib/dash_float/tui.ex`, and the TUI test files (plus earlier slices' files
if not yet merged).
