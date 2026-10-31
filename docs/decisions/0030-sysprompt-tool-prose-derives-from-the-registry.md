# 0030 — The system prompt's tool prose derives from the tool registry

- **Status:** Accepted (settled in
  [issue #101](https://github.com/fluxvale/dashfloat/issues/101), probed live
  Oct 30).
- **Date:** 2026-11-01
- **Implements:** [issue #101](https://github.com/fluxvale/dashfloat/issues/101)
  — the stale tool list in the assembled system prompt.
- **Amends:** [ADR 0019](0019-session-system-prompt.md) §1 (the
  tool-discipline prose is no longer a fixed sentence; the section header
  and bullets render from the registry).
- **Cross-refs:** [ADR 0007](0007-tool-calls-and-execution.md) (the tool
  catalogue's advertised/enforced no-drift principle — the same rule now
  covers prose), [ADR 0021](0021-synthetic-repair-and-web-search.md) §6
  (web_search is advertised only with a Synthetic context),
  [ADR 0028](0028-choice-widget-and-ask-user.md) (the question tool rides
  every mode).

## Context

The live verification probe (Oct 30, #101) caught `SystemPrompt`'s
tool-discipline section hardcoding "You have five tools: …" while the
`tools` array advertised six — web_search had arrived with ADR 0021 and the
prose never heard. A hand-fix bumped the sentence to six, and #141's
question tool then made the true count seven: every catalogue change
re-drifts a memorized sentence. The model was unaffected in practice (the
`tools` array is the operative channel), but the prose is a claim about the
catalogue, and a claim that can lie will.

The same class lived one bullet lower: "read_file and list_directory run
automatically. write_file, edit_file, and execute_command wait for the
user's approval" is also a memorized catalogue claim — it silently omitted
web_search (a safe, auto-running tool) whenever one was advertised.

## Decision

1. **One name derivation.** `DashFloat.Tools.names/1` returns the
   catalogue's advertised names in order (web_search gated on the Synthetic
   context, ADR 0021 §6). `schema/1` renders the wire array from it; the
   system prompt renders its prose from it. Names now have exactly one
   source, the way parameters already do (ADR 0007's one-table rule).

2. **The prompt enumerates what it is given.** `SystemPrompt.build/2` takes
   a `:tools` opt (the ordered names) defaulting to `Tools.names(nil)`; the
   agent's session-start seeding passes `Tools.names(synthetic)` — the same
   slice the wire schema advertises for that session. The count, the name
   list, and the auto/confirm grouping (derived per name from
   `Tools.class/1`: safe-but-not-question auto-runs; mutating and risky
   wait) all render from that list. Adding, removing, renaming, or gating a
   tool changes the prose with no prompt edit.

3. **Drift is pinned, not policed.** The tests extract the enumeration
   sentence from the rendered prompt and require count and names to equal
   the schema's advertised set — for both context slices, and for a
   fixture-injected catalogue with a hypothetical extra tool. A memorized
   sentence of any kind fails CI; a registry addition cannot.

## Accepted edges

- **Assembly-once stands (ADR 0019 §1).** The prose snapshots the catalogue
  at session start; a mid-session provider switch (`:set_provider`
  re-discovers the Synthetic context) changes the wire schema, not the
  persisted prompt. Accepted: the schema array is the operative channel and
  re-assembling would rewrite transcript history (ADR 0019 §5).
- **Behavior prose still names tools.** The question and edit_file bullets
  and the editing section's "with execute_command" describe behavior, not
  catalogue membership, and name tools that ride every mode — they are
  rename-owned, not derived. Membership claims derive; behavior references
  do not.

## Alternatives considered

- **Re-hardcode the corrected sentence** — rejected: it drifted twice
  already; the third drift was one merge away.
- **Re-derive the prompt per request** — rejected: re-litigates ADR 0019's
  assembly-once (and would rewrite the persisted transcript's history).
- **Derive every tool-name mention** — rejected: guarding behavior prose
  against tools that never leave the catalogue is defensive code for
  impossible cases.

## Consequences

The prompt's tool section can no longer disagree with the schema the model
actually receives. `Tools.names/1` becomes public API of the catalogue; the
system prompt grows a compile-time dependency on the tool registry it
describes — the coupling is the point.
