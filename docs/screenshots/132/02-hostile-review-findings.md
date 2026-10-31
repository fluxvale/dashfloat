# Hostile review findings — DashFloat lane 0132 (issue #132), done-notification

Reviewer: fresh-context hostile review per `/tmp/opencode/df132-review-brief.md`,
2026-10-31. Deliverable under review: commit `1e89adb`
(`docs(herdr): done-notification verified live on 0.9.5; ADR 0024 §8 (#132)`),
checked out read-only at `~/Work/FluxVale/dashfloat-132-review`.

VERDICT: FINDINGS

No blockers, no majors. The central claim — DashFloat's existing reports
already drive Herdr's derived `done` status, watched completions never
notify, and no product change is warranted — **survived hostile
re-verification end to end on a real isolated herdr 0.9.5**: I reproduced
all three flows independently (below) and cross-checked every source-level
assertion against the v0.9.5 tag. The findings are precision gaps in the
ADR/evidence, not defects in the decision. Nothing here demands a product
change; findings 1–3 suggest small doc amendments before merge.

## Findings

1. **minor — ADR §8's mechanism description is incomplete: `done` also
   derives from `blocked → idle`, and DashFloat has a timer-driven one.**
   Herdr's completion predicate is `is_background_completion_transition` =
   new `Idle` && prev `Working|Blocked` (`src/app/actions.rs:22-24`, tag
   v0.9.5), not `working → idle` as §8 states. DashFloat's exit-guard
   expiry is a blocked→idle that fires with **no further user input**
   (`lib/dash_float/tui.ex:341-347` — the hook rides the `@exit_guard`
   expiry; `@exit_window_ms 2_000`, `state.ex:104`). Live-verified spurious
   done: armed the exit prompt with a single Ctrl+C on t1, switched to t2
   inside the 2 s window, let it expire:

       armed:    {"focused_tab": "w1:t1", "df": [["dashfloat", "blocked", null]]}
       switched: {"focused_tab": "w1:t2", "df": [["dashfloat", "blocked", null]]}
       expired:  {"focused_tab": "w1:t2", "df": [["dashfloat", "done", 5]]}   # ● badge

   A "dashfloat finished" badge (+ chime per config) for a cancelled exit
   prompt during which the agent did zero work. This is Herdr-side
   semantics (any integration's backgrounded blocked→idle gets it), and
   DashFloat's reports are honest, so "no product change" still holds —
   but §8 (and the CHANGELOG's "existing working→idle reports already
   drive") should say the derivation is working|blocked → idle and note
   the exit-guard-expiry consequence. One amended sentence fixes it.

2. **minor — the ADR's task-interleaving analysis names the wrong "worst
   case"; a missed `working` report silently kills that turn's done
   notification and does not self-heal.** The alternatives section says
   interleaved report tasks are "at worst briefly dropping an older task's
   session request to the newer one's seq — self-healing at the next
   signature change". But the dropped older request can be the `working`
   **state** report (its connect/recv may stall up to the 2 s bounds while
   a short turn completes): the turn-end `idle` then lands first with a
   higher seq, the stale `working` is discarded by Herdr's
   `hook_report_is_newer` (`src/terminal/state.rs:1946-1952`), Herdr
   observes idle→idle — no completion transition, **no done, no badge, no
   chime**, and nothing re-fires (the idle signature is committed;
   `Herdr.report/2` only re-fires on change). The missed notification is
   permanent for that turn. Probability is tiny (local unix socket,
   seconds-scale stall required), the class is the fail-open risk §4
   already accepts, and no product change is warranted — but §8's
   "DashFloat's reports already produce that transition" has this corner
   exception, and the alternatives bullet's "at worst" enumeration is
   wrong as written. Worth one honest clause.

3. **minor — the chime half of "badge + chime" (ADR §8 + CHANGELOG) was
   never observed live.** The evidence file demonstrates the badge for the
   owner's config (§2) but no rig can carry audio. Source-verified only:
   `SoundConfig` defaults `enabled: true` (`src/config/sound.rs:154-163`),
   `dashfloat` is not in the `agents` off-list so `sound.allows/1` passes,
   and the delayed-queue path (the owner's stock `delay_seconds = 1`,
   `ToastConfig::default` in `src/config/model.rs:1249-1257`) forwards the
   Sound notify to the foreground client (`src/server/headless.rs:3306-3320`
   → `headless/notifications.rs:176-192`). The claim is very likely true;
   it is asserted without live evidence. A word ("chime verified from
   source") or one BEL-capable capture would close it.

4. **nit — evidence §2's round labels don't reproduce from the on-disk
   artifacts.** The idle sidebar row is annotated "(round 7's watched
   completion)" while `/tmp/opencode/herdr132_e2e7.py` (round 7)
   self-documents as the owner-config switch-away (background) flow;
   §4 separately cites "rounds 6/7" as watched. No behavior hinges on it
   — I re-derived both directions independently — but the provenance
   labels in the shipped evidence file are internally inconsistent.

5. **nit — "Watched completions never notify" holds only while the
   terminal is focused (or focus unknown).**
   `active_tab_suppresses_notifications = is_active_tab &&
   outer_terminal_focus != Some(false)` (`src/app/actions.rs:38-41`): with
   the OS window unfocused, Herdr notifies even for the active tab. Real
   behavior is slightly *more* notifying than §8 implies; the
   smoke-feedback explanation is unaffected.

6. **nit — the architect's rig left a live process behind.** `beam.smp`
   pid 1703957 (`mix run --no-halt`, scratch XDG `/tmp/opencode/herdr132-df`,
   socket pointed at the long-dead `df132test` session) was still running
   ~40 min after the last capture; I killed it during my cleanup
   (cmdline recorded in my session log). No repo impact; a "leave no
   debris" miss in the e2e lane.

## What I ran (independent e2e, real herdr 0.9.5)

Rig: own session `herdr --session df132-review` (nested client in a tmux
pane via `env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_BIN_PATH -u
HERDR_SOCKET_PATH -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID -u TERM_PROGRAM
HERDR_CONFIG_PATH=…`), the REAL TUI (`mix run --no-halt`) in the session's
own `w1:p1` via `pane send-text` + `send-keys enter`, mock provider =
`scripts/capture.py` MockHandler on 127.0.0.1:33457, reports through my
own logging unix-socket proxy, tab focus driven through the herdr client
itself (prefix+digit via tmux). Scripts/logs preserved:
`/tmp/opencode/df132rev-*.{py,log,txt}`. (Rig note: the nested pane's
shell re-resolves mise and starts *compiling Erlang* — the launch script
must pin absolute `mise/installs/elixir|erlang` paths.)

- **Flow A — backgrounded completion, toast config** (`delivery="herdr"`):

      mount:            df [["dashfloat","idle",null]]
      working (watched):df [["dashfloat","working",null]]     focused w1:t1
      switched away:    df [["dashfloat","working",null]]     focused w1:t2
      settled:          df [["dashfloat","done",3]]
      client render:    '│● dashfloat finished  │'           (tmux capture)
      sidebar:          ' ● ~ · 1'

  Matches evidence §1 exactly.

- **Flow B — watched completion, same session**: stayed on t1 through the
  turn: `working` → `idle` with `completion_seq` 3→5 ("the completion
  registered"), open dot `○`, **no toast**; switched to t2, waited 5 s,
  switched back: still `idle`, nothing re-fires. Matches evidence §4.

- **Flow C — owner's stock config**: stopped the inner session, relaunched
  with `herdr132-config-owner.toml` (verified byte-identical to the real
  `~/.config/herdr/config.toml` except the appended
  `[experimental] allow_nested = true` required for nesting; no
  `[ui.toast]` ⇒ default `delivery="off", delay_seconds=1`). Same
  backgrounded flow: `done` + `completion_seq 3` + `●` badge, **no toast**.
  `herdr agent list` → `dashfloat … "agent_status":"done","completion_seq":5`.
  Matches evidence §2 (badge; chime per finding 3).

- **Wire capture (proxy log, Flow A's mount + turn)** — identical shape to
  evidence §3, seqs strictly increasing, state report first / session
  behind, the session-id-mint `working` re-fire present:

      16:34:35.241 c1 > pane.report_agent         state=idle    seq=…675231
      16:35:15.119 c2 > pane.report_agent         state=working seq=…715119
      16:35:15.136 c3 > pane.report_agent         state=working seq=…715135
      16:35:15.236 c4 > pane.report_agent_session seq=…715136 (resume_argv)
      16:35:17.604 c5 > pane.report_agent         state=idle    seq=…717603
      16:35:17.705 c6 > pane.report_agent_session seq=…717604

- **Incidental live verification of §5's resume argv**: after my inner
  session stop/start, herdr respawned the pane running exactly the
  reported command — `dashfloat --resume 01a19119-… --profile demo
  --model glm-5.3`; the installed binary refused loudly (session not under
  the real data dir) and exited. Reported argv round-trips; no owner data
  touched.

- **Source cross-checks (tag v0.9.5 at /tmp/opencode/herdr-src)**:
  reportable states `idle|working|blocked|unknown` in both the CLI usage
  string (`src/cli/pane.rs:1159`) and the socket schema
  (`src/api/schema/common.rs:151-156`); `done` derived as `(Idle, seen=false)`
  (`src/app/api_helpers.rs:96-107`); `pane.seen =
  suppress_active_tab_notifications` on completion transitions
  (`src/app/actions.rs:1846-1847`); toast gated on `ToastDelivery::Herdr`
  (`src/app/actions.rs:2001-2010`); default toast config
  `Off`/`delay_seconds 1` (`src/config/model.rs:1249-1257`).

- **Deliverable hygiene**: diff is docs-only (3 files, +126 — CHANGELOG,
  ADR 0024 §8 + one rejected alternative, evidence file); CHANGELOG entry
  under `[Unreleased] → Added`; conventional-commit title; ADR-first; no
  speculative code; evidence links point at real files. Worktree left
  clean (only gitignored `_build`/`deps` added, explicitly allowed).

## Not verified, and why

- **Audible chime** — no audio path exists in a tmux/pyte rig;
  source-verified instead (finding 3).
- **The owner's literal config file** — cannot be run in a nested session
  without adding `allow_nested` (modifying it is out of bounds); a
  diff-verified copy (+`[experimental]` only) was used instead.
- **`mix ci`** — not re-run per the brief; the commit touches no code, and
  I modified nothing tracked by git in the worktree.
- **Live rejection of `--state done` by the CLI** — thought of it after
  teardown; the schema enum and CLI usage string are definitive.

## Cleanup

Inner session stopped (`herdr session stop df132-review`) and
`~/.config/herdr/sessions/df132-review` removed; tmux session `df132rev`
killed; mock + proxy killed, proxy socket removed; scratch XDG removed
(`/tmp/opencode/df132rev-df`); my scripts/logs kept as review evidence.
Also killed the architect's leftover beam (finding 6). The owner's
default session and workspaces were never touched; `herdr session list`
shows the pre-existing state only.
