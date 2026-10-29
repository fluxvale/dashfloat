# 0016 — Interaction modes: the confirmation boundary becomes a mode setting (Plan / Build / Auto / Unchained)

- **Status:** Accepted (revised at the plan gate, Oct 29: the owner's AUTO correction and
  PreToolUse addendum are folded in; renumbered from a draft "0014" by PA arbitration —
  0014 is session persistence, 0015 is LSP)
- **Date:** 2026-10-29
- **Implements:** [issue #68](https://github.com/fluxvale/dashfloat/issues/68) — the owner's
  v0.1.1 test-drive feedback.
- **Extends:** [ADR 0007](0007-tool-calls-and-execution.md) §4 (confirmation semantics —
  **amended** by §10 below), [ADR 0006](0006-ui-truth-and-rendering.md) (status-bar
  vocabulary — one new span; one new phase; no new roles).
- **Reserves a name for:** [issue #69](https://github.com/fluxvale/dashfloat/issues/69)
  (`/mode` in the command registry).

## Context

The owner's v0.1.1 test drive: DashFloat's single confirm-before-mutating boundary is
either always-on friction or impossible to relax short of approving everything by hand.
Claude Code's Plan/Build/Auto and Octofriend's Unchained (verified in its source, read
only: a `--unchained` boot flag plus a Shift+Tab in-session toggle, a
`SKIP_CONFIRMATION_TOOLS` auto-allow list, and red chrome while unchained) all express
one idea — the confirmation boundary should be a session mode the user moves as trust
changes. ADR 0007 §4 hardcoded that boundary (`automatic?/1`: read tools auto, every
mutation behind a keypress). This ADR replaces the hardcode with a mode-driven gate.

**The owner's correction (Oct 29, at the plan gate).** The draft's AUTO — writes
auto-approved, the shell always confirmed — was wrong: that is the accept-edits shape
(Claude Code's auto-accept), closer to BUILD than to AUTO. In his Claude Code experience
AUTO works closer to UNCHAINED: **all tools are eligible for auto-run, and what makes it
Auto is a model-based safety check deciding per call whether a tool call is safe to run
without asking.** The AUTO-vs-UNCHAINED distinction IS the safety check. His addendum
fixes the placement, modeled on Claude Code's hypothesis: the check lives at a
**synchronous pre-tool-call boundary** — a PreToolUse-shaped seam in the tool-execution
path — so a future user-hooks system (PreToolUse/PostToolUse) plugs into the same gate.

## Decision

### 1. Mode set

| Mode | Meaning |
| --- | --- |
| `:plan` | Read-only research: safe tools run; every other tool call is **proposed** (previewed in the log), never executed |
| `:build` | Today's behavior — ADR 0007 §4 verbatim. **The default** |
| `:auto` | All tools eligible for auto-run; the **safety check** (the v1 PreToolUse evaluator, §6) decides run-vs-confirm per mutating/risky call. A failed check errs to confirm |
| `:unchained` | Everything runs. No confirmation is ever asked, no check is ever made |

Default `:build`; per-session in-memory only (no config key, no boot flag — deferred,
Consequences). Cycle order `plan → build → auto → unchained`.

### 2. Tool risk taxonomy

Three classes, declared **on the catalogue entry** — the one table in `DashFloat.Tools`
that already drives `schema/0` and `validate/2`, so the advertised contract and the
enforced class cannot drift:

| Class | Definition | Tools |
| --- | --- | --- |
| `:safe` | No side effects; bounded reads | `read_file`, `list_directory` |
| `:mutating` | Writes confined to the working tree by ADR 0007 §3's path policy; previewable, and the preview is byte-exact what lands | `write_file`, `edit_file` |
| `:risky` | Effects no DashFloat policy bounds — the shell can leave the tree, the network, and the machine | `execute_command` |

`Tools.class(name) :: :safe | :mutating | :risky`; **unknown names classify `:risky`**
(fail closed — unreachable today because validation rejects unknown tools first, but any
future tool added to the catalogue without a class declaration inherits the strictest
gate). Future/custom tools declare their class in the same table row; a tool that cannot
be honestly classified is risky.

Honest note: the four modes gate `:mutating` and `:risky` **identically** (§3) — the
safe/non-safe split is what the modes consume today. The mutating/risky split stays
because the safety check consumes it as its severity prior (§6: a shell is scrutinized
harder than a scoped edit) and because it is the extension point a future mode or hook
can split on.

### 3. Per-mode gate matrix

`Mode.gate(mode, class) :: :run | :confirm | :propose | :vet` — pure, table-tested, all
twelve cells:

| class \ mode | plan | build | auto | unchained |
| --- | --- | --- | --- | --- |
| safe | run | run | run | run |
| mutating | propose | **confirm** | **vet** | run |
| risky | propose | **confirm** | **vet** | run |

The bold build column is ADR 0007 §4 (the amendment is behavior-preserving in the
default mode). `:vet` resolves dynamically (§6): **allow → run; ask, or any check
failure → confirm.** `:plan` still runs safe tools — a planning model that cannot read
cannot plan.

The gate is read **per call at dispatch time**. A switch mid-batch affects calls not yet
dispatched. A pending confirmation is never retroactively converted — and while one is
pending it owns every key (ADR 0007 §4's swallow rule), so the cycle surface simply does
not fire mid-decision: answer it or Esc it.

### 4. The three static outcomes (and previews staying load-bearing)

- **`:run`** — dispatch the runner immediately, exactly as safe tools dispatch today.
- **`:confirm`** — today's flow unchanged: preview entry, `:confirming` phase, Enter/Esc.
- **`:propose`** — `:plan`'s replacement for execution: the preview renders as a
  **proposal** entry (no confirm state, no keypress, no `:confirming` phase), and the
  model receives `{"ok":false,"blocked":"plan"}` — not `rejected`: no human said no, the
  mode did. The result is the feedback loop; the model learns to present the change as a
  suggestion (no system-prompt injection — alternative considered below).

**Previews stay load-bearing in every outcome.** Mutating-class and risky-class calls
always build their preview first; the mode decides only what follows it. A preview error
(path refusal, ambiguous edit block) remains the error result it is today — an error
proposal would be a lie, an unpreviewable auto-run shares the same failure, and the
safety check's evidence is that same preview (§6). One consequence, accepted: when a
mutating/risky call runs without a keypress (`:auto` allow, `:unchained`), the preview
entry becomes the **execution receipt** — the diff the user no longer keypresses still
lands in the log, which is what makes unchained watchable rather than terrifying.

### 5. The PreToolUse seam

One **synchronous interception point in the tool-execution path**: after validation and
preview build, before any dispatch — the stage the agent names `pre_tool_use`. Nothing
executes before the gate resolves; no tool contains its own gating (the boundary is the
path, not the tools).

The seam's verdict vocabulary is Claude-Code-compatible: **allow** (run), **ask**
(confirm with the human), **deny** (block outright). v1 uses allow and ask; **deny is
reserved** for the future user-hooks system. Composition rule, frozen now so hooks can
never weaken safety: **evaluators may only escalate strictness** — run → ask or deny —
never relax another evaluator's ask. A future user hook therefore cannot overrule the
mode's own confirm, and nothing user-side can touch `:plan`'s propose (plan runs
nothing, so no evaluator ever fires there).

v1's only evaluator is the AUTO safety check (§6), wired in when the mode matrix yields
`:vet`. Future work, one line and out of scope here: a general user-hooks system
(PreToolUse/PostToolUse) plugs into this same gate with the ordering above.

### 6. The safety check (the v1 PreToolUse evaluator)

**Shape.** A fresh-context, one-shot completion over the existing provider plumbing
(`ChatStream` with `tools: []`, reporting to the vetter task): the vet judges the
ACTION, not the story around it. The conversation is never in the vet's prompt — a
jailbreak or a chased-bad-plan living in the conversation is simply not present — so
independence comes from the fresh context, not from different weights.

**Model.** The **active session model**, fresh context. No new config surface, frontier
judgment, and the fresh context already delivers the independence that matters; a cheap
dedicated vetter model is a deferred cost/latency option (the seam takes the provider,
so the override is additive). Latency is bounded by the hard timeout and still beats
BUILD's human round-trip.

**The prompt.** Static, code-versioned in the vetter module; a single user message
(instruction + payload; no system role — DashFloat carries none, ADR 0005). The
instruction fixes the task and the reply contract — strict JSON
`{"decision":"run"|"confirm","reason":"…"}` — with the rubric: **run** = routine,
reversible, project-scoped development work (builds, tests, searches, file edits inside
the project, lockfile-driven installs); **confirm** = destructive, irreversible, outside
the project, touching credentials or secrets, network mutation (push, deploy),
installing from the network, privilege escalation, force operations.

**The payload.** Tool name, risk class, normalized arguments (JSON-encoded, capped at
8 KiB with a disclosed marker), and **the same preview lines a human would confirm in
BUILD** — bounded by construction (50 preview lines). The symmetry is the design: in
AUTO a model plays the human's role on exactly the evidence the human sees in BUILD.

**Latency.** The check sits on the tool-dispatch path (synchronous at the seam) and is
visible, not hidden: the phase becomes `:checking` (§8) so the user sees why the pause
exists. A hard timeout — default 10 s, agent opt `:vet_timeout`, injectable for tests —
is enforced **inside the vetter task** (timers live in tasks, never the agent; ADR
0001/0007 discipline). Batching optimizations (pre-vetting call N+1 while N runs) are
deferred: pure latency wins, and they would re-add concurrency to the tool slot that
ADRs 0012/0013 just de-raced.

**Fallback — the fail-safe direction.** Any failure — HTTP error, provider taxonomy
error, timeout, unparseable reply — resolves to **confirm**, with a dim system entry
`[safety check unavailable — confirming]`. AUTO with a broken check degrades to BUILD
for mutating/risky calls, never to UNCHAINED. A check that says ask gets
`[safety check: needs confirmation]` and the standard confirm flow.

**Lifecycle.** The vetter runs as a `restart: :temporary` task under the TaskSupervisor
and reports `{:vet_done, id, verdict}`; the agent monitors it under the runner
discipline of ADRs 0012/0013: the task self-reports every death its body can observe, a
DOWN the body could not report resolves as a **failed check → confirm**, and a stale
`vet_done` (ref mismatch) is ignored exactly like a stale confirm decision. Esc during a
check cancels by message: the vetter cancels its stream child, and the batch aborts per
ADR 0007 §4 (cancelled results keep the transcript round-trippable).

**Conversation contract unchanged.** The vet never enters the conversation messages;
its usage frames are dropped engine-side (they are not the UI's conversation truth); the
model sees only the ordinary result shapes.

### 7. Switching surface

The agent owns the mode (it owns the gate). The seam:

- UI → agent: `{:set_mode, ui_pid, mode}` (plain send, like `{:prompt, _}`, in every
  chat phase). An invalid mode gets a system entry naming the valid ones, no change.
- Agent → UI: `{:mode, mode}` — the single-voice echo. The UI never optimistically
  applies a mode: it sends, the agent validates, the echo updates the chrome (the same
  discipline as `confirm_decided`'s one-hop gap). The agent also appends the system
  entry `[mode: build → unchained]` — agent-authored, like every log entry.

The surfaces that drive the seam:

- **Shift+Tab cycles the four modes** (`plan → build → auto → unchained → plan`),
  Claude Code's muscle memory, available now with zero dependency on #69. Intercepted in
  `route_key` before the textarea forward; swallowed by a pending confirmation per §3.
- **`/mode` is reserved for #69's command registry** and must drive this same seam:
  bare `/mode` prints the current mode; `/mode <plan|build|auto|unchained>` sets it.
  `Mode.from_string/1` freezes the spelling now so #69 implements against a stable name.
  No composer-level slash parsing ships in this lane — #69 owns slash syntax.

### 8. Chrome

One new status-bar span, always present, between the model and ctx spans:
`❯ ~/dir | glm (flux) | Auto | ctx 4.1k/128k | …` — the mode is session-wide standing
truth like the model label; hiding the default would imply "sometimes there is a mode".

| Mode | Label | Role |
| --- | --- | --- |
| `:plan` | Plan | `:status_idle` (dim — quiet research) |
| `:build` | Build | `:assistant` (neutral — the default is not a warning) |
| `:auto` | Auto | `:status_tool` (light yellow — acting with autonomy) |
| `:unchained` | Unchained | `:error` (light red — Octofriend's red-chrome signal, distilled to the label) |

Unchained is the only mode with alarm-colored chrome and the only mode in which
`:confirming` can never be entered. A new phase joins the vocabulary: **`:checking`**
(status "Checking", `:status_tool`), entered while a safety check is in flight — the
spinner keeps stepping (an active phase; the tick discipline is untouched) and Esc
interrupts per §6. The `@phases` map gains one entry; regions and layout are untouched.

### 9. UI contract additions

| Message (agent → UI) | Effect |
| --- | --- |
| `{:mode, mode}` | set `state.mode` (the announcing system entry arrives separately as `{:entry, :system, text}`) |
| `{:tool_preview, %{id, name, args, lines}}` | append the preview entry (same styling as a confirm preview — share `Render.confirm_preview`) **without** arming `state.confirm` and **without** the `:confirming` phase |

`{:phase, :checking}` joins the phase vocabulary alongside `:streaming`,
`:executing_tool`, and `:idle`. `{:confirm, ref, preview}` is unchanged (render + arm).
The preview-rendering code is shared; only the arming differs.

### 10. ADR 0007 amendment

ADR 0007 §4's first two bullets ("Automatic: `read_file`, `list_directory`" / "Blocked on
a keypress: `write_file`, `edit_file`, `execute_command`") are **replaced** by §3's gate
matrix. In the default mode `:build` the behavior is identical, so nothing else in 0007
moves. Specifically:

- `Agent.automatic?/1` is deleted; the gate is the agent's `pre_tool_use` stage —
  `Mode.gate(state.mode, Tools.class(call.name))`, then the safety check when the
  outcome is `:vet` (§5–§6).
- The model-facing tool descriptions' "The user confirms before it runs" is reworded
  mode-neutrally ("The user may confirm before it runs, depending on the session mode") —
  a description that promises a confirmation that never comes (`:auto` allow,
  `:unchained`) or execution that never happens (`:plan`) teaches the model wrong.
- Everything else in 0007 (path policy, previews, Esc semantics, result shapes) stands;
  `{"ok":false,"blocked":"plan"}` joins the §1 result-shape table as the propose outcome,
  and the tool-result row reads it as status `proposed (plan)`.

## Interface freeze

- `DashFloat.Mode`: `modes/0 :: [mode()]` (cycle order), `cycle/1`, `valid?/1`,
  `from_string/1 :: {:ok, mode()} | :error`, `label/1`,
  `gate/2 :: :run | :confirm | :propose | :vet`.
- `Tools.class(String.t()) :: :safe | :mutating | :risky` (unknown → `:risky`).
- `DashFloat.Tools.Vetter`: `verdict(provider, call, preview_lines, opts) ::
  {:allow} | {:ask} | {:error, reason}` (the task body; owns its timeout),
  `build_prompt(call, preview_lines) :: String.t()`,
  `parse(String.t()) :: {:ok, :run | :confirm} | :error` (strict JSON).
- Agent: start opts `:mode` (default `:build`; invalid raises `ArgumentError`), `:vetter`
  (module implementing `verdict/4`, default `DashFloat.Tools.Vetter` — the injection
  seam for tests), `:vet_timeout` (default 10 000). Messages per §6/§7/§9; internal
  `{:vet_done, id, verdict}`. `tool_slot` gains `{:vetting, ref, pid, call, preview}`.
  Result shape `{"ok":false,"blocked":"plan"}`.
- State: field `mode` (default `:build`; no mount opt — the echo is the single writer),
  phase `:checking` in the phase type, action `{:set_mode, DashFloat.Mode.t()}`,
  keybinding `shift+tab`.

## Alternatives considered

- **AUTO as accept-edits** (writes auto-approved, the shell confirmed by rule — and its
  cousin, safe-only AUTO) — the draft's shape, and Claude Code's auto-accept. Both leave
  AUTO as BUILD-plus-conveniences with a static rule where the shell is concerned.
  **Rejected by the owner (Oct 29 correction):** what makes a mode Auto is a model
  judging each call; the safety check IS the AUTO-vs-UNCHAINED distinction.
- **A configured cheap vetter model** — deferred: independence comes from the fresh
  context, not different weights; the active model needs zero new config and gives
  frontier judgment. The seam takes the provider, so a cheap override is an additive
  rider when latency or cost demands it.
- **A "deny" verdict in v1** — rejected: the human is the final arbiter of a flagged
  call; blocking without asking hides it from the user. Deny stays in the seam's
  vocabulary, reserved for future user hooks (§5).
- **Pre-vetting call N+1 while N runs** — deferred: a pure latency optimization that
  re-adds concurrency to the tool slot ADRs 0012/0013 hardened; inline-with-visible-
  phase first, optimize only if AUTO feels slow in practice.
- **The check inside individual tools** — rejected: the boundary is the tool-execution
  path, not each tool. One gate covers every current and future tool by class, and it is
  the one seam a future hooks system plugs into (the owner's addendum).
- **Plan via system-prompt injection** — providers vary in system-role handling and
  DashFloat carries no system prompt today; the blocked-result loop costs one episode of
  latency and zero provider risk. Deferred; revisit if plan-mode models flail.
- **Octofriend-style per-call whitelisting** ("always allow this exact command") — a
  further dimension of state for a later lane; the mode matrix subsumes its common
  cases. Deferred.
- **Two-step arm for entering `:unchained`** — rejected for v1: the red label, the
  logged switch, and one keypress back out is Octofriend's proven guardrail level.
- **Per-mode config default / `--unchained` boot flag** — trivial riders once asked for;
  per-session memory keeps this lane at the issue's scope. Deferred.
- **`:plan` blocks mutations with a bare error** — rejected: the issue specifies
  "proposes commands instead of running them", and the preview machinery already builds
  exactly that proposal; a bare error teaches the model only "no", not "show the human".

## Consequences

- The confirmation boundary is data (mode × class) plus one evaluator at one seam:
  adding a tool means declaring a class, and the modes and the future hooks system pick
  it up for free.
- AUTO's safety is a probabilistic check and this ADR says so plainly: a wrong **allow**
  runs a call without asking. Nothing else separates AUTO from UNCHAINED. The fail
  direction is confirm — on doubt, on error, on timeout — and the check's evidence is
  exactly what a BUILD human would have seen.
- Per mutating/risky call in AUTO: one small fresh-context completion and up to 10 s of
  visible `:checking` latency. Safe tools never pay it.
- `:tool_preview` receipts in `:auto`-allowed and `:unchained` runs add log volume for
  mutations (bounded at 50 preview lines) — the price of an audit trail, paid only for
  mutations.
- #69 implements `/mode` against `Mode.from_string/1` and the `{:set_mode, _}` seam; no
  mode logic lands in the command layer.
- The PreToolUse seam anchors a future user-hooks system (PreToolUse/PostToolUse,
  Claude-Code-compatible, escalate-only ordering); building that system is out of scope
  here.
- ADR 0007's interface freeze loses the private `automatic?/1` and gains the seam above.
