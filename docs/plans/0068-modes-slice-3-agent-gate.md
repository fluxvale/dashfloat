# Slice 3 — Agent: mode state, the pre_tool_use gate, the vetting state machine

> **Superseded in part by [ADR 0016](../decisions/0016-interaction-modes.md) as amended
> (post-hostile-review):** the vet report is `{:vet_done, check_ref, id, verdict}`
> matched by per-check ref, the vetting slot is the 6-tuple, and every deferred
> resolution re-reads the gate. Where this spec and the ADR disagree, the ADR wins.

Issue [#68](https://github.com/fluxvale/dashfloat/issues/68). Design:
[ADR 0016](../decisions/0016-interaction-modes.md) — read §3–§6 and §10 before
starting. Depends on **slice 1** (`DashFloat.Mode`, `Tools.class/1`) and
**slice 2** (`DashFloat.Tools.Vetter`). Do not touch the TUI
(`lib/dash_float/tui*`) — slice 4 renders what this slice sends.

Files you will touch: `lib/dash_float/agent.ex`,
`lib/dash_float/tools.ex` (descriptions only), `test/dash_float/agent_test.exs`.
Study `lib/dash_float/agent.ex` first — especially `dispatch_validated/2`,
`automatic?/1`, the confirmation clauses, and the monitor clauses (the races
ADRs 0012/0013 hardened; the vetting state machine below follows the same
discipline).

## Goal

The agent owns the mode, gates every validated tool call through the
`pre_tool_use` stage (`Mode.gate` +, when the outcome is `:vet`, the safety
check), and speaks the new contract messages. BUILD behavior is byte-identical
to today.

## Spec

### 1. Mode state and the switching seam (ADR 0016 §7)

- `defstruct`/`start_link`: new fields `mode`, `vetter`, `vet_timeout`; new
  start opts `:mode` (default `:build`; invalid raises `ArgumentError` — loud,
  like `Keyword.fetch!`), `:vetter` (module implementing `verdict/4`, default
  `DashFloat.Tools.Vetter` — the injection seam for tests), `:vet_timeout`
  (default `10_000`).
- New UI message clause: `{:set_mode, ui, mode}` for a `Mode.valid?` mode:
  update `state.mode`, store `ui` (like `{:prompt, _}` does), then
  `display(ui, {:mode, state.mode})` and
  `display(ui, {:entry, :system, "[mode: #{Mode.label(old)} → #{Mode.label(new)}]"})`
  (exact arrow `→`).
- `{:set_mode, _ui, bad}` invalid: no change, system entry
  `"unknown mode: <inspect(bad)> (plan, build, auto, unchained)"`.
- Accepted in any phase (the gate is read per call at dispatch; a pending
  confirmation is left standing untouched).

### 2. The dispatch path (ADR 0016 §4–§6) — replaces `automatic?/1`

Delete `automatic?/1`. Restructure `dispatch_validated/2` into a named
`pre_tool_use` stage:

```elixir
# after Tools.validate (already done in next_call):
case {Tools.class(call.name), Mode.gate(state.mode, Tools.class(call.name))} do
  {:safe, :run} -> dispatch_runner(state, call)          # no preview, ever
  {_mutating_or_risky, outcome} -> with_preview(state, call, outcome)
end
```

`with_preview/3` builds the preview FIRST (every mutating/risky call, every
mode — previews stay load-bearing, ADR 0016 §4):

- `Preview.build` error → the error result is the call's result
  (record_and_continue; nothing dispatches, nothing vets) — identical to
  today's confirm-path handling.
- `{:ok, preview}` then branches on the outcome:
  - **`:confirm`** → exactly today's path: `{:confirm, ref, preview}`.
  - **`:run`** (UNCHAINED) → `display(ui, {:tool_preview, %{id, name, args, lines}})`
    (the receipt) then `dispatch_runner` — no confirm, no vet.
  - **`:propose`** (PLAN) → `display(ui, {:tool_preview, …})` then record
    `%{ok: false, blocked: "plan"}` — no confirm, no dispatch, no
    `:confirming` phase; `record_and_continue` keeps the batch alive. The
    status word lives in `Tools.display_status/1` since session persistence
    (ADR 0014) extracted it: add the clause there —
    `display_status(%{blocked: "plan"}), do: "proposed (plan)"`.
    The tool message content encodes as exactly `{"ok":false,"blocked":"plan"}`.
  - **`:vet`** (AUTO) → the vetting state machine below.

### 3. The vetting state machine (ADR 0016 §6)

- `tool_slot` gains the shape `{:vetting, ref, pid, call, preview}`.
- Start the vet: `display(ui, {:phase, :checking})`, then a
  `restart: :temporary` task under `state.supervisor` running
  `state.vetter.verdict(state.provider, call, preview.lines,
  [vet_timeout: state.vet_timeout, ...])`, reporting
  `send(agent, {:vet_done, call.id, verdict})`. Monitor AFTER spawn — and
  follow the ADR-0012 discipline: the task body self-reports every death it
  can observe (wrap it in the same try/rescue shape `dispatch_runner` uses,
  reporting `{:vet_done, id, {:error, "safety check crashed: …"}}`).
- `{:vet_done, id, {:allow}}` (slot matches, call id matches):
  clear the slot, `display(ui, {:tool_preview, …})` (receipt),
  `display(ui, {:phase, :executing_tool})`, `dispatch_runner`.
- `{:vet_done, id, {:ask}}`: clear the slot,
  `display(ui, {:entry, :system, "[safety check: needs confirmation]"})`,
  then arm the confirm with the ALREADY-BUILT preview (`{:confirm, ref, …}`) —
  phase `:confirming`.
- `{:vet_done, id, {:error, _}}`: same as ask but the entry reads
  `[safety check unavailable — confirming]` (exact text; the fail-safe
  direction — AUTO with a broken check degrades to BUILD, never UNCHAINED).
- A `{:DOWN, ref, :process, _, _}` on the vetting slot that the body could not
  report (`:killed`/`:noproc` per ADR 0012's clauses): treat as a failed
  check — same as the error path.
- Stale `{:vet_done, _id, _}` (slot is `:none` or refs differ): ignore —
  mirror the stale `confirm_decision` clause.
- `{:cancel}` while vetting: send the task `:cancel` (the vetter cancels its
  stream child and returns; a vetter that never checks its mailbox still
  dies at its own deadline), mark the slot cancelled, and abort the batch
  exactly like a cancelled running tool (existing `abort_tool_run` path: the
  current call and the queue get cancelled results, `[tool run cancelled]`
  entry, idle).
- The vetter reports only `{:vet_done, id, verdict}` to the agent — its
  stream's usage frames die with the task (they are never the UI's
  conversation truth, ADR 0016 §6).

### 4. Tool descriptions (ADR 0016 §10)

In `lib/dash_float/tools.ex` `@descriptions`: replace each occurrence of
`"The user confirms before it runs."` with
`"The user may confirm before it runs, depending on the session mode."` —
three tools carry it today (`write_file`, `edit_file`, `execute_command`).
Touch nothing else in the module.

### 5. What must NOT change

The confirm flow itself (BUILD), Esc semantics, abort logic, monitors,
`Preview.build`'s contract, the result JSON for ok/error/rejected/cancelled,
and BUILD-mode behavior — the existing agent tests must pass unmodified. If a
change to an existing test seems necessary, stop and report; the design says
none is.

Session persistence (ADR 0014, merged as PR #79) is untouched: the mode is
session-memory only, `:session_dir`/`:resume` opts and the `persist/1`
milestones need no changes, and the vetting state machine persists nothing —
every vet outcome resolves into messages (results/confirm flows) exactly as
today, so the transcript store is unaffected. `automatic?/1` (lines ~523-525
after the rebase) and `dispatch_validated/2` sit where the slice says; the
agent's `tool_result_msg` now derives its status via
`Tools.display_status/1`.

## Tests (in `test/dash_float/agent_test.exs`, following its existing
loopback/fake-UI patterns)

1. **BUILD is unchanged**: existing confirm/approve/reject tests stay green
   unedited.
2. **UNCHAINED runs a mutating tool with no confirmation**: `mode: :unchained`;
   a `write_file` call executes after the test (as UI) receives
   `{:tool_preview, _, _}` and NEVER `{:confirm, _, _}` and never
   `{:phase, :checking}`; the file exists; the second server connection
   carries the ok tool message.
3. **AUTO — vetter says allow** (inject a fake `:vetter` module returning
   `{:allow}`): `mode: :auto`, an `execute_command` call → phase `:checking`
   arrives, then `{:tool_preview, _, _}`, no confirm message, the command
   runs.
4. **AUTO — vetter says ask** (fake returns `{:ask}`): the check's system
   entry `[safety check: needs confirmation]` arrives, then
   `{:confirm, _, _}`; nothing ran before approval; approving runs it.
5. **AUTO — vetter fails** (fake returns `{:error, "boom"}`): entry
   `[safety check unavailable — confirming]` then `{:confirm, _, _}`; nothing
   ran.
6. **AUTO — stale vet_done**: send a fabricated `{:vet_done, "nope", {:allow}}`
   while idle: ignored, nothing dispatches.
7. **AUTO — Esc during the check** (fake vetter that parks until messaged):
   `{:cancel}` → batch aborts with cancelled results and the
   `[tool run cancelled]` entry; transcript stays round-trippable (tool
   messages present for every announced call).
8. **AUTO — one e2e with the real vetter**: inject a fake `:vetter` in most
   tests, but run one loopback test with the default
   `DashFloat.Tools.Vetter` against the recorded-SSE server serving
   `{"decision":"run",...}` on the vet request, proving the wiring (provider
   passed through, verdict parsed, dispatch happens).
9. **PLAN proposes and never mutates**: `mode: :plan`, an `edit_file` call
   yields `{:tool_preview, _, _}` and NO confirm; the file is byte-identical;
   the tool message content is exactly `{"ok":false,"blocked":"plan"}`; turn
   ends idle.
10. **PLAN safe tools still run**: a `read_file` under `:plan` returns
    content.
11. **set_mode seam**: `{:set_mode, self(), :unchained}` → echo
    `{:mode, :unchained}` + system entry naming both labels; a subsequent
    mutating call runs without confirm. Invalid mode: entry only.
12. **Invalid start opt**: `start_link(mode: :yolo)` raises `ArgumentError`.

## Done when

```
mix deps.get && mix test test/dash_float/agent_test.exs
```

exits 0 (existing tests unedited + the new ones above visible), and

```
mix ci
```

exits 0. Paste both transcripts. `git diff --stat main -- lib test` shows
exactly `lib/dash_float/agent.ex`, `lib/dash_float/tools.ex` (descriptions
only), `test/dash_float/agent_test.exs` (plus slices 1–2's files if not yet
merged).
