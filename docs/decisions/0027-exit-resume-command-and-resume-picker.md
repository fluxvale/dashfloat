# 0027 — Exit prints the resume command; /resume opens an in-session picker

- **Status:** Accepted (owner smoke-test feedback, issues #127/#128, Oct 31).
- **Date:** 2026-10-31
- **Implements:** [issues #127](https://github.com/fluxvale/dashfloat/issues/127)
  and [#128](https://github.com/fluxvale/dashfloat/issues/128).
- **Extends:** [ADR 0014](0014-session-persistence.md) §6 (the resume
  hand-off's one-load-two-consumers rule, now reachable mid-process),
  [ADR 0019](0019-session-system-prompt.md) §1 (adopted transcripts carry
  their system message verbatim), [ADR 0020](0020-command-surface.md) (the
  registry gains `/resume`; the picker is a fourth `:modal` palette kind),
  [ADR 0023](0023-session-titles-and-uuid-ids.md) (titles as the
  human-shaped resume handle). **Amends** [ADR 0024](0024-herdr-integration.md)
  §6's "There is no in-process session switch in DashFloat" clause — see §3.
- **Borrows:** the `/profile` picker's TUI-read pattern (ADR 0020: a fast
  local read feeding a pure `*_arrived/2`), and the title scan's fail-open
  store pass (ADR 0023 §4).

## Context

The owner's v0.4.0 smoke test hit two gaps in one theme: closing DashFloat
gives no way back to the conversation ("it should output what the resume
command would be"), and the only way to pick a past session is typing an id
or title after `--resume` at a fresh shell ("we don't have a /resume command
that I can use to choose a chat to resume").

## Decision

### 1. The exit print (#127)

Every sanctioned exit path already funnels through `TUI.terminate/2`'s
`:normal` arm — Ctrl+Q, the confirmed double Ctrl+C (the exit-guard flow),
`/quit`, and the Ctrl+P palette's quit all reduce to the same `:quit` action
— so the print is one clause there, not four. The server restores the
terminal before the callback runs, so the bytes land on the normal screen
after the alt screen exits; the Herdr release (ADR 0024 §6) stays first —
the synchronous socket call lands, then the print, then `System.stop`. A
crash or supervisor shutdown (exit code 1) prints nothing: the print is the
clean deliberate exit's alone.

**Presentation (recorded per the issue):** a lead-in line plus the command
on its own line —

```
resume this session with:
dashfloat --resume "fix the parser"
```

The value is the session's **title when one is live**, double-quoted and
shell-escaped (`"` `\` `` ` `` and `$` prefixed — the four POSIX
double-quote specials, so any title pastes verbatim into any POSIX shell),
else the **bare UUIDv7 id** (a UUID needs no quoting). The command carries
no `--profile`/`--model` tail: the owner's ask named exactly this form, the
boot's pin-compare warning covers provider drift, and Herdr's richer argv
(ADR 0024 §5) is its own surface with its own rules — divergent purposes,
not divergent presentations of one command.

**The gate is the store itself:** a session id whose file exists under the
sessions directory. A launch-and-quit (no id minted) or a first save that
persistently failed (id announced, no file — ADR 0023 §5's accepted
posture) prints nothing rather than a command that would refuse at the next
boot; a resumed boot mounts the id and the file was just loaded. A title
that collides on disk (the ADR 0023 §4 concurrent-race consequence) prints
the title form; the next boot's ambiguity refusal names both ids — loud,
never silent, the same backstop the title set paths rely on.

### 2. The /resume picker (#128)

`/resume` registers in the command registry (ADR 0020) and returns
`:list_sessions`; the TUI runner reads `Session.summaries/1` — a fail-open
scan in the title scan's discipline (ADR 0023 §4: every `*.json` decoded,
UUID-named and id-consistent files with a string `created_at` and a
`messages` list picked, everything else skipped silently; the load path
stays the loud reporter of hand damage) — and `sessions_arrived/3` opens a
fourth `:modal` palette kind, `:sessions`. This is the `/profile` shape
exactly: a fast local read for the list, a pure landing for the rows, and
the heavier work (the full `Session.load`) only on the picked row's Enter.

**Rows** (most recent first — `created_at` descending, the UUIDv7 id as the
tiebreak, ADR 0023 §1's name-sortable ≈ time-sortable): `title or
first-message preview · relative time · provider · model`. The preview is
the first **user** message (the stored system prompt is never row material;
a parts-list message joins its text parts, ADR 0018 §2), one flat line
capped at 40 graphemes with `…`; relative time buckets `now / Nm / Nh / Nd`
and falls to the plain date past a week; the provider half is the pin's
profile name, else the base_url's preset label, else its host (ADR 0015 §2's
ladder, rungs a–c); nil pin fields read `—`.

**Enter adopts in-process; Esc cancels untouched.** Esc (and any load
refusal) leaves the current session byte-for-byte as it was — the palette
closes, nothing else moves. Enter loads the picked session (one load, two
consumers — ADR 0014 §6's rule, now mid-process): the runner sends the
agent `{:adopt_session, ui, session}` and replays the same load through
`State.session_adopted/3` — the transcript replay path (leading system
message skipped, ADR 0019; the #116 crash shape is asserted in the picker's
tests), the session identity and title following the file, every live-turn
surface reset (stats, context snapshot, scroll/selection, pending
attachments), and the boot's pin compare (`Application.pin_note/2` — the
one implementation of the mismatch warning) appending last as the resume
note when the picked session was pinned elsewhere.

**The agent's adopt** mirrors `init`'s resume adoption: id/pin/created_at/
title/messages adopted verbatim (the stored system message included, never
re-seeded), the context anchor re-derived from the persisted diagnostics,
the auto-title latch re-armed (the target session's next settled exchange
is its own first chance), and no immediate write — the file is the load's
own bytes and converges on the next save (ADR 0014 §4).

### 3. Amendment to ADR 0024 §6

ADR 0024 §6 stated "There is **no** in-process session switch in DashFloat
(sessions change by restarting with `--resume`, which is a new process that
reports afresh), so release-on-exit can never race a switch." This slice
introduces the in-process switch; the release claim it supported survives
narrowed and still holds: **release fires only from `terminate/2`** — a
switch mid-process never releases (the pane still holds the running
agent), so exit-release and session-switch remain disjoint events. The
Herdr reporter re-reports the switched session automatically: the snapshot
signature carries the session id (ADR 0024 §5), and the adoption lands
through the schedule choke point. Herdr's own restore command keeps using
the id form (its argv rules are Herdr's, not the shell's) — unchanged.

### 4. The two recorded calls the issue demanded

- **Unsent draft on switch: preserved.** The draft is composer state, not
  session state — `/clear` keeps the input history across a log reset for
  the same reason — and `/resume`'s own submit bookkeeping has already
  cleared the draft before the picker opens on the typed path (ADR 0020:
  every command clears it); the Ctrl+P path keeps it and it survives the
  switch visibly in the composer. Discarding silently would destroy typed
  text; a discard-with-confirm would add a third key-mode for text the
  composer still holds. **Pending attachments are cleared** — they are
  payload of the outgoing session's next turn, not composer furniture, and
  riding them into the resumed session would attach them to the wrong
  conversation.
- **Text filtering in the picker: deferred.** The modal palette swallows
  every key but Up/Down/Enter/Esc (ADR 0020); a filter needs a typed-draft
  sub-mode inside the modal plus filtered-selection arithmetic — real
  machinery, deferred with ADR 0020's own alternative ("filterable
  model/profile pickers") unless the owner asks. The rows are scannable:
  title/preview first, most recent first.

## Interface changes

- `DashFloat.Session`: `summaries/1` (+ the `summary/0` type) — the
  fail-open picker listing, most recent first.
- `DashFloat.TUI.State`: `sessions_dir` field (mount opt; nil = no store);
  `sessions_arrived/3`, `session_adopted/3`, `session_refused/2`; the
  `:list_sessions` / `{:resume_session, id}` actions; the `:sessions`
  palette kind's row builder.
- `DashFloat.TUI`: `exit_message/1` (the pure command build) + the
  terminate print; the `:list_sessions` read and the
  `{:resume_session, _}` load-adopt-hand-off.
- `DashFloat.Agent`: the `{:adopt_session, ui, session}` handler (idle-only).
- `DashFloat.TUI.Commands`: `/resume — pick a saved session to open`.
- `DashFloat.Application`: `sessions_dir` threads to the TUI child.
- `.credo.exs`: `StructFieldAmount` to 51 (ADR 0004's rider, below).

## Alternatives considered

- **Print `--profile`/`--model` alongside `--resume` (Herdr's argv
  posture)** — rejected for the exit print: the issue names the exact form,
  the pin warning covers drift, and Herdr's rules (arg sanitation, its 64-arg
  cap) are transport concerns the shell does not share (§1).
- **Print only the id** — rejected: the title is the handle the titles lane
  exists to give the user; the id is the fallback, not the presentation (§1).
- **Gate the print on the announced session id alone** — rejected: a failed
  first save announces an id with no file (ADR 0023 §5); the print would
  then name a command that refuses at the next boot. The existence check
  makes "nothing persisted prints nothing" literally true (§1).
- **A quit-time confirmation dialog for the draft** — rejected: the draft
  survives by construction (§4); a third key-mode for a non-loss is
  machinery without a victim.
- **Filtering in the picker** — deferred (§4).
- **A dedicated picker process / agent-owned listing** — rejected: the
  `/profile` precedent (a fast local read in the runner, pure state after)
  is one scan of a local directory; a process would add supervision for a
  user-paced read (§2).
- **Agent-side load on Enter** — rejected: it would fork the replay path
  (entries derive in State) through a new display protocol; one load, two
  consumers is ADR 0014 §6's settled shape (§2).

## Consequences

- Quitting DashFloat leaves the reopen command on the shell — copy-paste
  resumes the conversation; nothing prints when there is nothing to reopen.
- `/resume` switches sessions without leaving the TUI; the Herdr sidebar
  follows the switch at the next event, and the pane is never released
  mid-process (§3).
- Two sessions with identical previews are distinguishable by time and
  provider; identical titled rows (the on-disk duplicate race) remain
  ambiguous in the picker — Enter opens the listed (most recent) one, and
  the load-by-id is unambiguous regardless of row look.
- The picker's listing decodes every session file once per open — the
  accepted scan posture at realistic counts (ADR 0023 §4); an index is the
  future fix if a measured need ever appears.

## Test plan (the issues' Done-whens)

1. `mix ci` green — format, warnings-as-errors, credo strict (StructField
   amount rider recorded in ADR 0004), dialyzer, the 99.2% floor.
2. Unit: `summaries/1` (order, fields, parts-list preview, fail-open skips,
   nil/missing dirs); row labels (title-vs-preview, buckets, provider
   ladder, cap/ellipsis, control scrub); Enter/Esc routing;
   `session_adopted` (system-skip replay — the #116 shape — resets, draft
   kept, note last); `session_refused`; `exit_message` (title/id forms,
   escaping, the nothing-persisted gates); `terminate` print ordering after
   the Herdr release and its silence on crashes; every quit path's
   teardown print; the agent's adopt (transcript carried verbatim including
   the stored system message exactly once, latch reset, busy-ignore).
3. E2E in the rig: the picker over real sessions (GIF — the picker is
   motion); the exit print after the alt screen, and the printed command
   pasted verbatim reopening that session (a second rig run boots it and
   asserts the replayed transcript).
