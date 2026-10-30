# 0019 — Session system prompt: Octofriend-pattern assembly and AGENTS.md injection

- **Status:** Accepted (design settled in
  [issue #71](https://github.com/fluxvale/dashfloat/issues/71) and
  [issue #72](https://github.com/fluxvale/dashfloat/issues/72), filed Oct 29).
- **Date:** 2026-10-30
- **Implements:** issues #71 and #72 — the system-prompt half of the owner's
  Octofriend study (Oct 29).
- **Extends:** [ADR 0007](0007-tool-calls-and-execution.md) (§6's "message
  list starts `[user]`" — amended below),
  [ADR 0014](0014-session-persistence.md) (the transcript's role vocabulary
  gains `system`),
  [ADR 0022](0022-context-accounting-and-compaction.md) (eviction pins the
  system message). Nothing is superseded.
- **Governs:** `DashFloat.SystemPrompt` (new), `DashFloat.ProjectInstructions`
  (new), and the agent's session-start seeding.

## Context

DashFloat shipped without any system message: `Agent.init` opened with an
empty list and the first prompt made the list `[user]` (ADR 0007 §6). The
model therefore learned its role, its tools, and its environment only from
what drifted in with user prompts — the Octofriend study (owner, Oct 29)
supplied the assembly pattern: an identity block, tool discipline, editing
rules, cheap environment facts, and the project's own instruction files with
per-file provenance. Issues #71/#72 froze the scope: assemble once at session
start (#71), then discover and inject the `AGENTS.md` chain (#72).

Three constraints from the settled codebase shaped the design:

1. **The request path is verbatim.** `ChatStream.run(agent, provider,
   messages, tools)` forwards `messages` to the wire as-is (ADR 0005); the
   assembly must therefore live at the message-list level, not inside the
   streaming engine.
2. **The transcript is the persistence truth** (ADR 0014): whatever the
   system message does to `messages` propagates into session files, resume,
   the loader's validation gate, and ADR 0022's eviction.
3. **Assembly is not per-message work.** The Phase-4 coordination rule keeps
   request assembly out of the per-episode path; the system prompt is
   session-scoped state, built once.

## Decision

### 1. Assembly, once, at session start

`DashFloat.SystemPrompt.build/2` is a pure function of the cwd (plus an opts
seam for tests and callers): identity ("You are DashFloat, an AI coding
assistant running in the user's terminal"), tool discipline (the five tools,
announce-then-call, read/list auto-run vs. mutate/confirm, `{"ok": false}` is
information), editing rules (match style, minimal diffs, run the project's own
checks), environment facts, and the slots below. A **fresh** session seeds
`messages` with `%{role: "system", content: build(cwd, ...)}` as its first
element — `Agent.init`'s `initial_messages/3`. A **resumed** session adopts
the persisted transcript verbatim: it already carries the system message the
original session start built, and re-seeding would duplicate it. A session
persisted before this ADR simply never gains one — no migration.

**Amends ADR 0007 §6:** the message list starts `[system, user]`, not
`[user]`. Everything else in §6 is unchanged.

### 2. Environment facts: cwd, platform, git — nothing else

The environment section carries the working directory, `:os.type()` platform,
and — via one cheap `git --no-optional-locks status --porcelain=v1 --branch`
probe — the branch and dirty flag when the probe succeeds from the cwd. Any
failure omits the git line; `git_info:` is the test seam. No date (stale the
moment it is written), no directory listing (the tools cover it; Octofriend
lists, we deliberately do not).

### 3. Seams: documented no-ops with named owners

Two slots render today as nothing and are tested as no-ops:

- `mode_sections/1` (after "Editing code") — **deliberately unfilled.**
  [ADR 0016](0016-interaction-modes.md) decided the mode reaches the model
  through the blocked-result loop, not prompt injection ("Plan via
  system-prompt injection — deferred"), and its premise ("DashFloat carries
  no system prompt today") changing does not re-open a settled deferral. A
  system prompt assembled at session start could not track `/mode` switches
  anyway — a stale mode section would be worse than none. Revisit only if
  plan-mode models flail, per ADR 0016's own trigger.
- `skills_section/1` (after Environment) — the skills lane is HELD; the seam
  exists so that lane lands without touching this module's callers.

### 4. AGENTS.md discovery, precedence, budget (#72)

`DashFloat.ProjectInstructions.load(cwd)` walks cwd upward, collecting each
directory's readable, non-empty `AGENTS.md`, and stops after examining the
nearest ancestor whose `.git` exists — inclusive of that root, `.git` tested with
`File.lstat/1` because linked worktrees make it a file and a dangling `.git`
symlink is still a placed marker. No git root means walk to the filesystem
root. The return is most-general-first (root first, cwd last); unreadable
files are skipped, never raised. **Only regular files are collected** (an
lstat, not a stat): a cloned repo must not be able to aim the discovery at
files outside itself — the tool layer's sandbox rejects the same class
(ADR 0007) — and a FIFO or device must not be able to hang or slurp the
boot; the cost is that a dotfile-style symlinked AGENTS.md is silently
rejected. The read is bounded to one byte past the budget, so a multi-GiB
AGENTS.md costs 32 KiB + 1, not memory. `build/2`'s `project_instructions:`
slot renders the chain with an absolute-path provenance line per file and
the precedence rule stated in the section header: when files conflict, the
later (closer) file wins. The budget is a per-file 32 KiB head-truncation
with a trailing marker naming the original byte size — no total cap, no
file-count cap. Only `AGENTS.md` (no CLAUDE.md / OCTO.md chain — out of
scope, lazy). The env-facts git probe carries no timeout — accepted: a hung
`git status` means a hung repository, where every exec tool call would hang
equally; discovery hangs are the bounded-read/lstat case handled above.

### 5. The transcript carries it: persistence and compaction

Because the system message lives in `messages`, three adjacent contracts
extend rather than fork:

- **Persistence (ADR 0014):** the system message persists with the
  transcript. The loader's role gate accepts `"system"` with binary
  `content`; it neither opens nor closes a tool-call batch, so the batch
  state passes through — and `repair/1` agrees: a system message interleaved
  in a tool batch rides the block (splitting the block at one would
  synthesize a duplicate answer and brick the file on its next load).
- **Accounting (ADR 0022):** the anchor's `index` counts the full list, so
  provider-measured `prompt_tokens` and the heuristic stay aligned with what
  the wire actually carries.
- **Compaction (ADR 0022 §4):** a leading `system` message is session
  context, not a turn — it is pinned, never evicted, and its weight rides
  the estimate as a **heuristic floor** whenever the anchor is nil or spent:
  the eviction trigger always sees the full list the wire carries, system
  message included (a real anchor already measured that weight — the two
  never add). The anchor shifts with the pin and shifts back unless it
  covers nothing — nil stays nil, index 0 stays index 0, and everything with
  coverage returns full-list coordinates whether or not a drop re-indexed
  it. The carve-out is exactly one message, exactly
  leading: the prelude rule ("leading non-user messages form their own first
  group, dropped first") stands for everything else, and a `system` message
  that lands mid-transcript (hand-built resume maps can carry anything)
  groups into its turn like any other message.

## Alternatives considered

- **Assemble per request** — rejected: re-probes git and re-reads AGENTS.md
  every episode for a session-scoped constant, and puts assembly inside the
  per-message path the Phase-4 rule keeps clear.
- **Keep the system message out of `messages`** (own struct field, prepended
  at send time) — rejected: it forks the transcript's truth (the file would
  not match the wire), and it de-synchronizes ADR 0022's accounting — the
  provider's `prompt_tokens` vouch for a list that includes the system
  message; estimating against a list that excludes it under-counts forever.
- **Directory listing + date in env facts** (Octofriend parity) — rejected:
  stale-by-construction facts are lies; the tools answer both questions.
- **Total-cap or count-cap budgets** — rejected: per-file truncation is the
  whole policy; a chain budget is a tuning axis nobody asked to tune.
- **CLAUDE.md / OCTO.md chain support** — deferred as scope creep for #72;
  one filename, one walk.

## Consequences

The model now has a stable, honest self-description and the project's own
instructions with provenance — at the cost of ~1–4 KiB per request (inside
the anchor's measured coverage, so the estimate tracks it) and per session
file. Session files written before this ADR resume without a system message
(accepted; no migration). Tests that assert exact transcript shapes match the
leading system message through a shared helper that builds it from the same
cwd — its content is cwd/git dependent by design, so assertions match shape
and identity markers, never full bytes. The mode seam staying empty means
`/mode` keeps working exactly as ADR 0016 shipped it.
