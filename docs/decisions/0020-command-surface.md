# 0020 — Command surface: slash commands, Ctrl+P palette, runtime model/profile/mode/title switching

- **Status:** Accepted (designed Oct 29 and parked; resumed Oct 30 with
  `/mode` and `/title` folded in — the modes and titles lanes merged while
  this lane parked, leaving the seams this registry maps onto);
  **amended 2026-10-31** ([issue #105](https://github.com/fluxvale/dashfloat/issues/105) —
  Tab completes the highlighted filter match; see
  [Amendment (2026-10-31, issue #105)](#amendment-2026-10-31-issue-105-tab-completes-the-highlighted-filter-match)
  below)
- **Date:** 2026-10-29
- **Implements:** [issue #69](https://github.com/fluxvale/dashfloat/issues/69).
- **Extends:** [ADR 0015](0015-input-surface-cursor-stats-ghost.md) (the
  composer the commands type into; ghost text arms only on an empty draft,
  so it never competes with a slash draft),
  [ADR 0016](0016-interaction-modes.md) §7 (the reserved `/mode` name),
  [ADR 0023](0023-session-titles-and-uuid-ids.md) §7 (the rename seam
  `/title` maps onto).

## Context

The owner's v0.1.1 test drive (Oct 29, issue #69) could not find how to switch
models: there was no command surface at all. Selection of profile and model is
startup-only ([ADR 0008](0008-config-layout-profiles-json5.md) and
[ADR 0009](0009-config-v3-persona-profiles.md) both named runtime switching as
a future slice; the catalog entries were kept in state for exactly this
picker). Issue #69 graduates that slice: slash-prefix commands in the composer
with an autocomplete popup, and Ctrl+P opening the same list as a palette.

The pinned `ex_ratatui ~> 0.19.0` already ships purpose-built widgets nothing
used yet: `Widgets.SlashCommands` (`parse/1`, `match_commands/2`,
`render_autocomplete/2`) and `Widgets.Popup` + `Widgets.List`.

## Decision

### Registry is data; execution stays in `TUI.State`

`DashFloat.TUI.Commands` holds one list of
`ExRatatui.Widgets.SlashCommands.Command` structs (`name`, `description`,
`aliases`) plus thin matching wrappers around the widget's `parse/1` and
`match_commands/2`. Adding a command is one registry entry plus one
`run_command/2` clause in `TUI.State`. The
registry never executes anything — `TUI.State` owns transitions (ADR 0002's
pure-state contract holds: no processes, terminal, or timers).

### One palette state, two modes

`State.palette` holds `%DashFloat.TUI.Palette{mode: :filter | :modal, kind:
:commands | :models | :profiles, items:, selected:}`:

- **`:filter`** is the composer slash autocomplete. It is derived state:
  recomputed after every draft-changing keystroke from the draft
  (`SlashCommands.parse` → prefix match), visible only while idle, the draft
  is command-shaped, and at least one command matches. Up/Down move the
  selection (the selection resets to 0 whenever the match set changes;
  typing that narrows within the same set keeps it); Enter executes the
  selected match; Esc dismisses until the next draft change (cursor-only
  keys neither reopen nor keep it alive past the dismissal).
- **`:modal`** is Ctrl+P (the command palette), the `/model` picker, and the
  `/profile` picker. It swallows every key except Up/Down/Enter/Esc/Ctrl+P
  (toggle) and the global quits (Ctrl+Q/Ctrl+C clauses sit above it, so quit
  always works).

Enter executes the highlighted entry in both modes — palette parity, one rule.

**Command-shaped:** trimmed text whose first whitespace-free token is a
registry name — `/clear`, but also `/mode plan` or `/title fix the login`
(arg-taking commands); the name matches case-insensitively (`/MODE plan`
runs `mode`), matching the widget's case-insensitive autocomplete. The
autocomplete popup shows only while the draft starts with `/` and has no
whitespace yet (the name is still being typed).
Anything else starting with `/` (e.g. `/etc/hosts is weird`) is an ordinary
message — the escape hatch for literal slash text. Argless commands ignore
trailing text after their name.

### Key routing order

Palette clauses slot into `route_key` after the global quits, startup, and
confirm clauses, and before the shift+tab mode cycle, Enter/Esc/scroll/
history/forward. A pending confirmation outranks the palette (ADR 0016 §3's
swallow rule: while a decision stands it owns every key), and an open
palette swallows the mode cycle — no surface switch fires mid-pick.
`forward/3` (the textarea path) recomputes the `:filter` palette.
PageUp/PageDown stay log-scroll; inside a modal palette they are swallowed.

### The commands

- `/clear` — resets the log (`entries`, `in_flight*`, `selection`, `scroll`,
  `follow?`). The input history list survives.
- `/help` — one `:system` entry listing the registry and the key hints.
- `/quit` — the existing `:quit` action (same path as Ctrl+Q).
- `/model` — modal picker over `state.catalog[active base_url]` (ADR 0009's
  fetched entries), the current model marked and preselected. Enter swaps
  `state.provider` to `%Config{model: id, nickname: nil, context_tokens: nil}`
  (a catalog id has no nickname; the label and context denominator fall back
  to the catalog automatically) and returns `{:switch_model, {:ok, config}}`,
  which the TUI delivers to the agent via the existing `{:set_provider, _}`
  send. The agent reads its provider per episode, so the switch provably takes
  effect on the **next** request — mid-episode swaps never race the running
  stream. An empty catalog warns in a `:system` entry (the catalog is
  fail-open; it may legitimately be empty).
- `/profile` — returns `:list_profiles`; the TUI reads
  `Config.profile_names/1` (new, read-only) and `State.profiles_arrived/2`
  opens the picker (or warns when there is nothing to list). Enter returns the
  existing `{:select_profile, name}` action and rides `resolve_setup` exactly
  as boot-time selection does: re-load through the resolver, hand the agent
  the new classification, restart the catalog sweep.
- `/mode` — the modes lane's reserved name (ADR 0016 §7): bare `/mode`
  appends a `:system` entry naming the current mode; `/mode <name>` parses
  through `Mode.from_string/1` and returns the existing `{:set_mode, mode}`
  action — shift+tab's seam verbatim; the agent validates, applies, and
  echoes (`[mode: Build → Plan]`). An unknown name warns locally with the
  four valid names, without the round-trip.
- `/title <text>` — maps onto the titles lane's rename seam (ADR 0023 §7):
  returns `{:set_title, title}`, which the TUI delivers as
  `{:set_title, ui, title}`. The agent owns normalization, uniqueness, and
  persistence; its system entries (`[session titled: T]`, the refusal
  reasons) are the whole UI — the TUI adds no title validation of its own.
  Bare `/title` opens the input dialog — see [ADR 0023](0023-session-titles-and-uuid-ids.md)'s
  2026-10-31 amendment.
- Unknown command — a `:system` warning entry naming the offender and
  `/help`.

Switches are **session-scope**: nothing writes `settings.json5` (the issue
says the switch applies to the next request; persisting runtime switches
remains a future slice). The transcript and the agent's message history
survive a switch — `/clear` exists for the user who wants a clean slate.

### Rendering

The palette renders last (on top) in `View.render/2`'s widget list. Command
lists (autocomplete and Ctrl+P alike — "the same list") go through
`SlashCommands.render_autocomplete/2`; the model and profile pickers build
`Popup` + `List` with custom labels (`· current` marker, context detail).
Styles come from `Theme.style/1` roles only (ADR 0006). The custom labels
cap at the popup's render-time inner width, `…` marking the cut
([ADR 0015](0015-input-surface-cursor-stats-ghost.md)'s #152 amendment —
the #146 width class).

## Alternatives considered

- **Hand-rolled popup widgets** — rejected; the pinned dep already ships
  them, unused.
- **A dedicated action per command from the registry (data-driven
  dispatch)** — rejected; five commands with real transitions in `State`
  (clear/help) need no TUI round-trip, and a generic dispatch table would be
  speculative configurability for two pickers.
- **Persisting `/model` and `/profile` choices to settings.json5** — rejected
  as scope creep; the issue demands next-request semantics only.
- **Extending `CLI.parse` for runtime args (e.g. `/profile work`)** —
  rejected; `CLI` is settled startup-time surface, and pickers cover the UX.
- **Filterable model/profile pickers (type-to-search inside the modal)** —
  deferred; the modal capture is simpler and the catalog list is short.

## Consequences

- `/mode` and `/title` ship in this lane as registry entries riding seams
  other lanes left (ADR 0016 §7, ADR 0023 §7) — no new agent surface, and
  the surface stays additive by design.
- Palette keys are captured while any palette is open, so composer
  multitouch habits (history arrows while a slash draft is pending) change
  meaning when the popup is visible; Esc or any non-slash edit dismisses it.
- `restart_catalog` runs on profile switches only; a model switch keeps the
  sweep (same provider set).
- `/model` mid-stream is allowed from the picker only while idle (palette
  opens are idle-gated like submit), so the "next request" boundary is the
  only seam to reason about.

## Amendment (2026-10-31, issue #105): Tab completes the highlighted filter match

**Status:** Accepted. The owner's v0.3.0 smoke test (Oct 31): pressing Tab
while a slash autocomplete popup is open should complete the command.
Extends the `:filter` mode's key set; nothing else moves.

- **The rule:** while the filter popup is open (matches exist), plain Tab
  completes the draft to **the highlighted match** — `"/" <> name <> " "` —
  not the common prefix. The highlighted row is the popup's one selection
  model: arrows move it, Enter runs it, Tab completes it; a common-prefix
  rule would invent a second, weaker affordance (and "/mode" for "/mod" —
  registry order puts `mode` ahead of `model` — is a complete command,
  never a truncation artifact). The trailing space closes the popup (args
  may follow) and leaves the cursor at the end, editable. Shift+Tab keeps
  its swallow while the popup is open; BackTab never completes.
- **No fight with the ghost (ADR 0015 §3):** the suggester arms only at a
  finalize with an EMPTY draft and lands only into an empty draft — a
  `/`-prefixed draft is non-empty by construction, so no ghost ever sits
  beside a filter popup. Verified, not suppressed: nothing needed to change
  in the suggest path. The filter Tab clause sits above the ghost-Tab
  clause in routing, so even a hypothetical stale ghost could not win a
  `/`-draft. Elsewhere Tab's ghost-materialization is untouched.
