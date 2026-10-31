# 0028 — The choice widget — approvals as questions, the ask-user tool, AUTO's binary resolve

- **Status:** Accepted
- **Date:** 2026-10-31
- **Issue:** [#133](https://github.com/fluxvale/dashfloat/issues/133),
  [#134](https://github.com/fluxvale/dashfloat/issues/134),
  [#135](https://github.com/fluxvale/dashfloat/issues/135) — the owner's
  v0.4.0 smoke test (Oct 31), one lane.
- **Amends:** [ADR 0007](0007-tool-calls-and-execution.md) (the tool
  catalogue gains `question`), [ADR 0015](0015-input-surface-cursor-stats-ghost.md)
  (the composer may be temporarily replaced), [ADR 0016](0016-interaction-modes.md)
  (the approval choice set; AUTO's vet resolve becomes binary),
  [ADR 0024](0024-herdr-integration.md) (the blocked message carries the
  question text). Each amendment is written into its ADR; this one is the
  widget's home.

## Context

The owner's v0.4.0 smoke test found the interaction surface split three
ways. Approvals answered from the activity row (Enter/Esc — not the
multiple-choice question he expected in the input field). There was no way
for the model to ask him a direct structured question at all. And worst: on
AUTO mode the agent "still asked for permission despite being on Auto" — a
permission prompt surfaced in the one mode whose promise is that it never
asks.

The #135 leak was not an accident of wiring; it was ADR 0016 §6's recorded
v1 design: `:vet` resolved "allow → run; **ask, or any check failure →
confirm**" — the ask verdict, the unavailable-check fallback, the timeout,
the vetter's death, every non-allow resolution armed BUILD's confirmation
prompt (`resolve_verdict/4` → `vet_confirm/4` → the `{:confirm, _}` seam →
the `:confirming` phase). One class leaked: **every AUTO vet resolution
except allow**. The owner's spec reverses the design: AUTO is binary —
safe → execute silently, dangerous → auto-reject with a visible reason —
and no gray zone may prompt.

## Decision

### 1. One choice widget, two askers

A new pure module, `DashFloat.TUI.Choice`, owns a pending multiple-choice
question as data: question text, options (label + optional description),
single- or multi-select, a selected index, and (multi only) a checked set.
While a choice is pending it **temporarily replaces the composer**: the
input region renders the question box (the composer's own rounded border
and `❯` title, the wizard's option-list vocabulary — `❯` selected, dim
otherwise, `[x]`/`[ ]` checkboxes in multi) instead of the `Textarea`, and
the input region's height flows from the widget (`Choice.height/1`: question,
blank, one row per option — two when it carries a description — blank,
hint). The textarea's Rust-side state is **never touched**: the draft is
preserved by construction and restores the moment the choice resolves —
that is the whole draft-preservation story, not a save/restore dance.

The two askers:

- **The approval (#133).** The agent's `{:confirm, ref, preview}` seam is
  unchanged — the preview entry still lands in the log as the evidence —
  but the UI now also arms `Choice.approve(ref, name)`: the question
  `Approve <name>?` with the **exact, fixed two-choice set [Approve,
  Reject], single-select, identical for the mutating and risky prompt
  classes** (those are the only classes that can prompt; `:safe` runs).
  Arrows + Enter answer; Enter on Approve (index 0) sends the unchanged
  `{:confirm_decision, ref, :approved}`; Reject, or Esc, sends `:rejected`.
  A third "Always-allow" choice is **deferred** — ADR 0016's recorded
  alternative stands (it needs agent-side per-session allowlist state, a
  later lane), and the issue left the set to decide.
- **The model's question (#134).** A new model-facing tool **`question`**
  rides the catalogue (`question`, `options` of `{label, description?}`,
  `multiple`) and renders into the same widget through a new
  `{:question, ref, payload}` display seam. The agent intercepts the call
  at the PreToolUse seam **before the class gate** — asking is not an
  action to gate — parks its tool slot on `{:asking, ref, call}`, and
  announces `{:phase, :asking}`. Enter answers; the result
  (`{"ok":true,"answers":[…]}` — the labels in option order, possibly none,
  a meaningful "none of these") returns to the model as the tool result so
  it acts on the answer. **Esc is an explicit answer, never a silent
  drop:** `{"ok":false,"cancelled":true}` — the model is told the user
  dismissed the question and can re-ask differently or proceed.

Key routing (the confirm swallow rule, extended): while a choice is
pending it owns every key — arrows move, Space toggles (multi only; a
no-op single), Enter answers, Esc is the explicit negative, everything
else is swallowed (the mode cycle included); the global Ctrl+Q/Ctrl+C
clauses still quit, the wheel still scrolls the log (focus-free), pastes
are swallowed. Any phase message supersedes a pending choice (the agent is
the single voice); the post-decision gap is one mailbox hop, exactly the
confirm flow's.

### 2. Decided semantics (recorded per the issues' asks)

- **Free-text escape: none in v1.** The schema is choices-only. The model
  already owns the free-text channel — its own prose, which the user
  answers by typing in the composer; a "type instead" mode would blur
  widget ownership mid-question and re-open every draft question #133 just
  settled. A model that needs an open answer should ask in prose; the tool
  exists for constrained choice. Esc → cancelled → the model re-asks or
  proceeds is the escape hatch that already exists.
- **ESC semantics:** dismiss = an explicit cancelled answer to the model,
  never silent, never a drop (above). On an approval Esc is Reject —
  ADR 0007 §4 unchanged.
- **Ghost text (#91 interplay):** while the composer is replaced the ghost
  can neither render (the textarea is not drawn) nor land into a draft the
  user could accidentally Tab-materialize — so arming a choice **dismisses
  and reaps** the suggestion (the debounce/task die, the epoch orphans
  stragglers). The next completed turn re-arms it per ADR 0015 §3's
  once-per-turn rule. Attachment chips do not render while replaced (they
  are the composer's own title); the pending set is untouched underneath.
- **AUTO's criteria and gray default (#135, ADR 0016 amendment).** The
  dangerous-classification criteria ARE the vetter's rubric (ADR 0016 §6):
  routine, reversible, project-scoped work → execute silently; anything
  destructive, irreversible, outside the project, touching credentials or
  secrets, network mutation, network installs, privilege escalation, or
  force operations → dangerous → **auto-reject**. **The gray default is
  reject**: any check failure — HTTP error, timeout, unparseable reply,
  vetter death, an out-of-contract verdict — auto-rejects with an
  "unavailable" reason. Fail-closed survives (AUTO never degrades to
  UNCHAINED); prompting does not.

### 3. AUTO resolves binary (#135)

Under a live `:vet` gate: **allow → run with the receipt; everything else
→ `auto_reject`** — the preview lands as the receipt of what was refused,
a system entry `[auto: rejected <tool> — <reason>]` carries the reason,
and the model receives `{"ok":false,"blocked":"auto","reason":…}` —
persisted in the transcript (the tool message), visible in the log,
returned to the model so it adapts. The vetter's `parse/1` now surfaces
the `"reason"` it always received and ignored (one line, capped at 160;
missing → the generic wording), and `verdict/4` returns
`{:ask, reason}`.

The mid-check mode re-read (ADR 0016 §3) is unchanged in mechanics and
still correct in spirit: a switch to UNCHAINED runs, to PLAN proposes, and
to BUILD arms the confirm — the mode is BUILD then, so a prompt is what
BUILD promises. What changed is only that a **live** `:vet` resolution can
never arm a prompt. The `question` tool is AUTO's sanctioned human reach:
it asks (a question, not a permission) in every mode, and the auto test
of record drives a question and a dangerous call through one batch — the
question asks, the call auto-rejects, nothing prompts.

### 4. Herdr carries the question text (ADR 0024 amendment)

The snapshot's pending-decision field becomes the QUESTION TEXT itself —
`Approve write_file?` for an approval, the model's question verbatim
(flattened, capped at 120 chars) for an ask — and `:asking` joins the
phases that map to `blocked`. Precedence: pending question > exit prompt >
setup > phase.

## Alternatives considered

- **A popup overlay for the choice widget** — the popup machinery is the
  palette's, and the owner asked for the question IN THE INPUT FIELD; the
  composer replacement also inherits the region height arithmetic for
  free. Rejected.
- **A save/restore dance for the draft** — copying the draft out and back
  would need its own cursor restoration and could race pastes; not
  touching the textarea at all preserves everything by construction.
- **"Always-allow" as a third approval choice** — deferred with ADR 0016's
  standing alternative (agent-side per-session allowlist state is its own
  lane); the fixed two-choice set keeps this lane's diff at the widget.
- **Free-text "type instead" entry in the question widget** — rejected for
  v1 (recorded in §2); the prose channel already exists.
- **AUTO gray → confirm (the v1 rule)** — the leak itself; reversed by the
  owner's binary spec. Kept only for the mode-switch-mid-check re-read,
  where the mode genuinely is BUILD.
- **AUTO gray → allow (fail-open)** — would degrade AUTO to UNCHAINED
  exactly when scrutiny is least available. Rejected; the gray default is
  reject.
- **The `question` tool gated like any other (safe class through the
  matrix)** — mechanically identical today (safe → run), but interception
  before the gate states the truth: a question is not an action, and no
  future mode should be able to "reject" the model's ability to ask. The
  class table still declares `:safe` so the fail-closed default cannot
  bite a renamed future.

## Consequences

- The approval flow's activity-row prompt (`Approve this change?`) stays
  for the phase's status chrome; the question the user ANSWERS lives in
  the composer. The status bar gains one phase label (`Asking`,
  tool-yellow) and the spinner keeps stepping (an active phase).
- Long option labels and descriptions clip at the box's width — the height
  arithmetic stays count-based (one logical row per line), recorded
  imprecision; option COUNT is capped at 10 at validation. (The clip was
  superseded 2026-11-01 by [ADR 0015](0015-input-surface-cursor-stats-ghost.md)'s
  #152 amendment: every row head-fits at the box's inner width, `…`
  marking the cut; the count-based arithmetic stands, and the box's
  clip-now-fitted behavior is unchanged in kind — honesty was the gain.)
- The model can now block on the user mid-batch (the tool slot parks on
  `{:asking, _}`); a mode switch mid-ask does not touch the standing
  answer (the human's pending answer outranks the mode, ADR 0016 §3's
  rule), and Esc-cancel of the surrounding turn aborts the batch with
  cancelled results exactly like a confirm that was never answered.
- ADR 0007's five-tool catalogue is six (seven with a Synthetic context);
  the system prompt (ADR 0019) says so and teaches the ask-don't-guess
  rule.
- Sessions resumed from transcripts with `blocked:"auto"` or `answers`
  results replay them (`auto-rejected: …`, `answered: …`) — the replay
  picker learns both fields.
