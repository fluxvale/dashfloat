# 0023 — Session titles and UUID session ids

- **Status:** Accepted (owner go on the plan, Oct 30; the plan gate of
  2026-10-29/30).
- **Date:** 2026-10-30
- **Implements:** [issue #80](https://github.com/fluxvale/dashfloat/issues/80).
- **Amends:** [ADR 0014](0014-session-persistence.md) — the session id format
  (§2), the file schema (§3, additive `title`), and `--resume` (§6, id-or-title
  resolution plus the boot-time legacy sweep). The amendment notes live inline
  in 0014; this ADR owns the reasoning. Nothing else is superseded.
- **Borrows:** [ADR 0015](0015-input-surface-cursor-stats-ghost.md) §3 — the
  ghost-text side-request's async discipline is the auto-title nudge's
  template (supervised one-shot, fail-open, cheap-model default, cancellable).

## Context

ADR 0014 made sessions persistent and resumable by id — but ids are
`20261027-143052-a1b2c3`-shaped machine names, hard to tell apart when
loading. The owner wants TITLES: easier to load, `--resume` accepts one, and
because resume is a single-valued surface — one argument, resolved as an id
OR a title, never both — duplicate titles must be refused for resolution to
stay deterministic. Titling is not solely manual: the model is nudged to
propose a title once a session has started.

Two facts verified before deciding:

1. **Elixir 1.20 / OTP 29 ship no UUID module** (`UUID` and `:uuid` both
   absent — probed live). "Stdlib v7" was never an option; the real choice
   was implement-in-module vs a dependency.
2. The local store holds zero legacy session files (the store shipped Oct
   27); the only things pinning the timestamp id shape are 33 test literals
   and README examples.

## Decision

### 1. Session ids become UUIDv7, minted in `DashFloat.Session`

`new_id/0` builds an RFC 9562 UUIDv7 — 48-bit unix milliseconds, version 7,
variant `10`, 74 random bits — canonical lowercase, ~15 lines on
`:crypto.strong_rand_bytes/1`, no dependency. **v7 over v4** because ADR
0014 §2's "name-sortable ≈ time-sortable" property is load-bearing (the
future session picker wants recency order for free); v4 would discard it
permanently. **A dependency over in-module** was rejected — fifteen lines of
vendored arithmetic beats a dep for a value this central. Collision safety
is the 74 random bits (12 in `rand_a`, 62 in `rand_b`) per millisecond; ids
minted within one millisecond may
sort out of order (random tails) — accepted, they are still unique and
time-clustered.

Validation is the strict lowercase `8-4-4-4-12` shape (`Session`'s
`@id_shape`). We mint lowercase; a typed uppercase value fails validation
and is treated as a title by the boot (§5). The `.json`-suffix tolerance of
`--resume` (the `ls` remedy) is unchanged.

### 2. Legacy timestamp ids migrate at boot, once, shape-gated

A boot-time sweep (`Session.migrate_legacy_ids/1`, wired in the Application
after classification, before resume resolution):

- **Sentinel:** if every `*.json` filename is UUID-shaped, the boot writes
  nothing — steady-state boots keep ADR 0014 §6's "a boot without `--resume`
  never touches session files" byte-for-byte. The amendment carves that
  clause ONLY while legacy files remain.
- A legacy-named file is rewritten **only if it fully loads** (the §4
  validation, minus the id-shape gate, via the shared `load_by_path`):
  a fresh UUIDv7 file is written first (id field + filename, every other
  field verbatim, the standard 0600 atomic write), THEN the old file is
  removed — write-before-delete, never the reverse. Undecodable files are
  left untouched; the load path stays the loud reporter of hand damage.
- **Kill window:** a kill after the write and before the delete leaves both
  files; the next sweep mints a second UUID for the legacy name — an orphan
  duplicate, no data loss. Accepted (a lock file would buy less than it
  costs, the ADR 0014 §7 stance). A *persistent* remove failure is rolled
  back instead: the fresh copy is removed with it, so an un-removable legacy
  file cannot mint one orphan per boot — the acceptance is a one-time
  duplicate, not a multiplier.
- **A failed sweep degrades:** warn and continue; resume-by-UUID still
  works, the next boot retries.
- **Accepted consequence:** old timestamp ids stop being resumable the
  moment this binary runs (not a UUID → title path → §5's refusal). The
  sessions live on under UUID names, reachable by title or the future
  picker/`--continue` slices, not by typing the old id.

The alternative — a permanent legacy read path — is rejected: it would make
`--resume` resolution depend on more than UUID validation, exactly the
id-or-title ambiguity the owner's rule exists to kill.

### 3. Titles: one normalization, one comparison key

`DashFloat.Session.Title.normalize/1` — trim, scrub control/C1/bidi
characters (the Suggest scrub set, defined locally — the store never depends
on the TUI), collapse inner whitespace runs, drop invalid UTF-8 at the
trust boundary; refuse `:empty` (nothing visible left), `:too_long` (> 80
graphemes), `:reserved` (UUID-shaped — titles and ids share the `--resume`
surface; a UUID-shaped title would make resolution ambiguous). The stored
form is the normalized form, case-preserved. **The comparison key**
(`normalize_key/1`) is the normalized form downcased: uniqueness and
resolution are case- and whitespace-insensitive while display keeps what
the user typed. NFC normalization rejected as over-engineering.

### 4. The store: additive `title`, schema stays v1

An optional top-level `"title"` string rides the ADR 0022 additive seam:
written only once non-nil (an untitled session's file is byte-identical to
the pre-title shape), loaded tolerantly the `pin` way (absent or non-string
→ nil, never a refusal), dropped by older binaries on re-save (the recorded
0022 consequence). Uniqueness is **not** a file-schema constraint — it is
enforced at the three set paths (§6, §7, §8) by scanning:

- `title_holder(dir, title, except_id)` — every `*.json` decoded, the first
  id whose title key matches; undecodable files skipped silently (a
  fail-open scan; the load path stays loud).
- `find_by_title(dir, title)` — all matching ids: one, none, or
  `{:ambiguous, ids}`.

**Scanning is the accepted mechanism at realistic counts** — hundreds of
files, a boot-time one-shot, Jason decode is microseconds each; an index
file is the future fix if a measured need ever appears. **No locking** (the
ADR 0014 §7 stance): two concurrent instances can race a check and both
write the same title; the on-disk duplicate then surfaces as §5's ambiguity
refusal — the backstop, not corruption.

### 5. `--resume <value>`: UUID-valid ? id : title

- The value (one trailing `.json` stripped) matching the UUID shape is the
  **id path** — ADR 0014 §6's behavior verbatim, including the unknown-id
  refusal text (now with the UUID example).
- Anything else is the **title path**: `find_by_title` → exactly one holder
  → load it as today (pin compare, replay, hand-off unchanged); none →
  `no session titled "V" under <dir> — list sessions with: ls <dir>` (the
  unknown-id refusal's shape); two or more (hand damage or the §4 race) →
  refuse naming both ids, remedy: resume by id.
- No fuzzy/close-match listing — the refusal names the typed value and the
  remedy; the user re-types or `ls`es. No id-to-title fall-through — §3's
  `:reserved` refusal keeps the namespaces disjoint, so validation alone
  decides.

### 6. Manual titles: `--title` at start

`--title <v>` / `--title=<v>`, the `--resume` parse discipline. After
classification, before children: normalize (refuse empty/blank, >80,
UUID-shaped — stderr + exit 1, the resume-refusal shape: the user named a
title, silently starting untitled is the blank-session outcome a refusal
exists to prevent), then uniqueness (`title_holder`, naming the holder and
the remedy). With `--resume` it is a boot-time rename — the loaded session
is exempt from its own current title, any other holder refuses. The
normalized storage form threads to the agent (`boot_title/1`); the refusal
messages quote the typed value where a value is worth quoting (the
taken-refusal names it; the shape refusals state the rule).

### 7. The rename seam (the command registry's future home)

`{:set_title, ui, title}` on the agent — the `{:prompt, ui, text}` plain-send
shape. Normalize (refusals arrive as system entries naming the reason),
uniqueness except self (refusal names the holder id), then set, persist,
and confirm with one `[session titled: T]` entry. The #69 command registry
maps its `/title` command onto this message — the message name is the
coordination contract. No TUI surface ships in this slice; the TUI stays
title-unaware beyond the agent's system entries.

### 8. The auto-title nudge (the ADR 0015 §3 discipline, agent-side)

Titles are store metadata, so the trigger and the landing live with the
persistence owner — the agent — not the TUI.

- **Trigger:** the first `end_turn_final` with non-empty content in a
  process run (the first settled assistant turn), when persistence is on,
  the session is untitled, the provider resolved, and `autoTitle` is not
  `false`. One-shot latch per run; a resumed-untitled session is titled
  after its next settled exchange; cancelled or aborted turns do not
  trigger. No debounce timer — the agent holds no timers and the trigger is
  one-shot per run, not per turn.
- **Request** (`Session.Title.request/2`, the Suggest mirror): a supervised
  task under the agent's supervisor; `POST {base_url}/chat/completions`,
  Bearer only when a key exists, `redirect: false` (never relay the
  conversation to a third host), `retry: false`, 5 s timeout, fail-open on
  everything — a raise is just another failure. `max_tokens: 32`; the
  prompt is a fixed instruction plus the first user message and first
  assistant reply, each byte-capped at 1 KiB.
- **Model:** the `autoTitle` tri-state — settings `autoTitle` / env
  `DASHFLOAT_AUTO_TITLE`, threaded exactly like `suggest` (`false` is the
  hard stop — the request is never built; a model id targets exactly that
  id; absent means the provider's cheap model from the ADR 0015 preset
  table, custom providers fall back to the active model). The
  tri-state→model resolution is one shared helper (`Presets.side_model/3`)
  — the suggester and the titler are its two callers.
- **Landing:** the task auto-normalizes inside itself (first line, quote
  strip, scrub, truncate to 80 — then `normalize/1`; a refused result,
  e.g. a UUID-shaped proposal, is nil: silent give-up, no retry) and sends
  `{:title_proposal, ref, text}`. The agent applies it only when the
  session is STILL untitled — **that check is the entire precedence rule**:
  `--title` and the rename seam set the title, a proposal only ever fills
  an empty slot, so user intent wins by construction and no provenance
  state exists. Collisions resolve by suffix: `T`, `T (2)`, `T (3)` … each
  candidate re-sliced under the 80-grapheme cap, the first free one wins,
  silent give-up after eight (a free suffix always exists; a second model
  call would spend latency on what arithmetic settles). On success: set,
  persist (the normal full rewrite now carrying the title), and one
  `[session titled: T]` entry so the event is visible. Failures are silent
  — the ghost precedent.
- **Cancellable / never blocking:** the request runs in a supervised task;
  the settle path returns to idle without waiting, and the next prompt may
  start while it is in flight. Stragglers are no-ops: the ref guard drops
  stale proposals, and a user title set mid-flight wins the landing check.
  A task that cannot start leaves the latch unarmed — a later settled turn
  retries.

### 9. Titles never mint a session

A titled session that never starts a turn leaves no file (the boot opt
waits in agent state; `persist_if_started`), and a rename before the first
prompt normalizes, confirms, and waits — preserving ADR 0014 §5's
"a session file appears iff at least one turn was started".

## Interface changes

- `DashFloat.Session`: `new_id/0` → UUIDv7; `@id_shape`/example → UUID;
  `migrate_legacy_ids/1`; `t()` gains `optional(:title)`; `load/2` returns
  `title:` tolerantly; `save/2` drops nil titles.
- `DashFloat.Session.Title` (new): `normalize/1`, `normalize_key/1`,
  `title_holder/3`, `find_by_title/2`, `display_cap/0`; the nudge's
  `model/1`, `body/2`, `request/2`, `fetch_async/3`.
- `DashFloat.Agent` opts: `:title` (boot-normalized storage form),
  `:title_fetcher` (test seam); `:resume` may carry `title:`; the
  `{:set_title, ui, title}` handler; the `{:title_proposal, ref, text}`
  landing.
- `DashFloat.CLI`: `--title <v>` / `--title=<v>` → `[title: v]`.
- `DashFloat.Application`: the sweep + id-or-title resolution + the
  `--title` gate and threading.
- `DashFloat.Config`: the `autoTitle` tri-state (field, settings key, env
  var); `DashFloat.Config.Presets.side_model/3` (shared with
  `TUI.Suggest.model/1`, whose behavior is unchanged).

## Alternatives considered

- **UUIDv4 or a UUID dependency** — v4 permanently breaks lexical ≈
  recency; a dep for fifteen lines of arithmetic. Both rejected (§1).
- **Lazy migration inside the title scan** — never runs for users who
  avoid title surfaces while their old ids are already unresolvable;
  converges the store on the first boot instead (§2).
- **A legacy read path** — violates the either/or resolution rule (§2).
- **Case-sensitive uniqueness** — "fix parser" vs "Fix Parser" are the same
  name to a human typing `--resume`; the downcased key compares what the
  user means (§3).
- **NFC normalization** — no demonstrated need; over-engineering.
- **A second model call on collision** — latency and cost for what a
  deterministic suffix settles (§8).
- **Retry-on-failure for the nudge** — fail-open is the ghost precedent;
  the next settled turn is the natural retry (§8).
- **Provenance flags on titles (user vs auto)** — unnecessary state: a
  proposal only fills an untitled session, which IS the precedence rule
  (§8).
- **Fuzzy close-match listing on an unmatched title** — the refusal names
  the typed value and the `ls` remedy; matching heuristics are complexity
  without a demonstrated need (§5).
- **TUI title display / a `/title` parser this slice** — the system entries
  carry the news; the command registry (#69) and the picker are their own
  slices.

## Consequences

- Sessions are loadable by human names; `--resume` stays single-valued and
  deterministic; ids are validatable UUIDv7s that sort by recency.
- The store self-heals off timestamp ids once, then boots write nothing
  (steady state); old typed ids die with the sweep (§2).
- `--title` collisions refuse loudly naming the holder; auto-proposals
  self-suffix; concurrent instances can still race (no locking) and the
  ambiguity refusal is the backstop.
- Every untitled session's first settled exchange spends one cheap-model
  side request (≤ ~2 KiB prompt, ≤ 32 completion tokens) unless
  `autoTitle: false` — the suggester's budget posture, applied to titles.
- Old binaries re-saving a titled file drop the title (the 0022 additive
  consequence); new binaries tolerate its absence forever.

## Test plan (the issue's Done-when)

1. `mix ci` green — format, warnings-as-errors, credo strict, dialyzer,
   coverage floor; patch coverage 100% on the diff.
2. Manual round-trip: a `title:` agent run saves the title, a resume
   re-saves it intact, `--resume <title>` boots it, `--resume <uuid>`
   unchanged.
3. Auto-title e2e at the loopback seam: the side-request's body carries
   the cheap/overridden model, `max_tokens: 32`, the instruction and the
   first exchange; the scripted reply lands as the file's title plus the
   `[session titled: …]` entry; the turn reached idle BEFORE the
   side-request was answered (non-blocking).
4. Precedence: a user-set title survives a landing proposal.
5. Refusals: create (boot stderr + exit 1), rename (entry naming the
   holder), auto-collision (the ` (2)` suffix; eight-holder saturation
   gives up), empty/whitespace/UUID-shaped at every path.
6. Ids: UUIDv7 shape/version/ordering; the sweep migrates a legacy file
   (fields preserved, old name gone, 0600), skips undecodable files,
   writes nothing on an all-UUID store, degrades on failure; the
   steady-state no-write sentinel; `--resume <timestamp-id>` refuses as a
   title.

## Amendment (2026-10-31, issue #106): bare /title opens a dialog; the TUI becomes title-aware

The owner's smoke test hit the gap this ADR's §7 left open: bare `/title`
did nothing visible, and the TUI never learned the title it was carrying.
This amendment **supersedes §7's closing clause** — "No TUI surface ships
in this slice; the TUI stays title-unaware beyond the agent's system
entries" — and nothing else. The rename seam is untouched: every path
still rides the verbatim `{:set_title, ui, title}` send, with the agent
owning normalization, uniqueness, and persistence exactly as recorded in
§7.

1. **Bare `/title` opens an input dialog** ([ADR 0020](0020-command-surface.md)'s
   modal pattern: a centered Popup, palette keys swallowed, the global
   quits still working). It is pre-filled with the current title when one
   exists; Enter submits the draft through the unchanged
   `{:set_title, ui, title}` seam and the dialog stays open until the
   agent's reply closes or errors it; Esc cancels. `/title <name>` inline
   is unchanged. On the `--resume --title` combination (§6's boot-time
   rename) the mount value follows the agent's own precedence — the
   override wins, because the session's live title after that boot IS the
   override; the loaded file's old title never pre-fills.
2. **The TUI learns titles** two ways: a `:title` mount opt (the boot
   `--title`'s normalized form, or a resumed session's own file title),
   which pre-fills the dialog, plus two display-only pushes from the
   agent — `{:title, t}` at every successful set/adoption (rename seam
   and auto-title alike; it closes an open dialog) and
   `{:title_refused, reason}` at every refusal (normalize errors and the
   holder collision), carrying the entry's human text minus the
   `[title not set: …]` framing. An open dialog renders the refusal —
   naming the holder id, per §4's uniqueness rule — instead of making the
   user read it out of the log; the system entries remain the log record
   in both cases. Nothing new at the agent's rename mechanics: the pushes
   are `display/2` sends alongside the entries that were already there.
   The title's only TUI consumer this slice is the dialog's prefill — no
   footer or chrome display ships; a visible title surface is future
   work.
3. **Refused titles never lose the draft** — the dialog keeps its text
   across a refusal, so a collision is fixed with a retype, not a
   re-open.
