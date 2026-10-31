# 0009 — Config layout v3: persona profiles, endpoint-keyed keys, deliberate selection, onboarding

- **Status:** Accepted — PA design review approved the Phase A record with all
  six shaped corners endorsed (2026-10-26); the owner's later requirement
  (issue #32 body) added the standing model catalog refresh below, and this ADR
  now records it. The merged keys-split (#31) matched everything this record
  anticipated — no Phase A decision needed adjusting against the merged
  reality. The onboarding write-refusal surface amendment below landed with
  [issue #39](https://github.com/fluxvale/dashfloat/issues/39) (before the
  tracker crossing was untangled — it shipped as PR #41's wizard work); the
  v1+interleave pre-split refusal amendment below lands with the reopened
  issue #39, the migration defect that issue actually carries.
- **Date:** 2026-10-26
- **Implements:** [issue #32](https://github.com/fluxvale/dashfloat/issues/32).
- **Supersedes:** the *schema*, *model addressing and selection*, *effective
  provider fields*, and *migration* sections of
  [ADR 0008](0008-config-layout-profiles-json5.md) — including as amended by
  the keys split (#31). **Kept from ADR 0008/#31, unchanged:** the JSON5
  dialect and its wrapper, the never-echo error hygiene, atomic tmp-0600+rename
  writes, lstat symlink guards, backups-inherit-sensitivity, the no-loss
  migration invariant, env-only support, and the "UI process performs no file
  I/O" contract. ADR 0008 itself gains a supersession pointer when this lands
  (it is deliberately untouched in this lane's first commit — the keys-split PR
  owns that file in flight).
- **Extends:** [ADR 0006](0006-ui-truth-and-rendering.md) — a
  forced-selection modal and a startup onboarding wizard join the TUI's overlay
  vocabulary; the pointer amendment lands with the implementation.

## Context

v2's profile is one subscription: one endpoint, one credential, one model
menu. Real usage is personas — a personal profile with several AI
subscriptions and its own MCP setup, a work profile with a different set.
Fitting that into v2 means one profile per subscription and no home for MCP at
all. v3 makes the profile the persona and nests providers inside it.

Second gap: a first run with no config anywhere hits a README wall. Octofriend
whose layout v2 borrowed, solves this with a step-by-step first-time wizard
(welcome → provider + key, paste or env-var → done, config on disk); OpenCode's
onboarding is the reference for the two presets DashFloat wants first-class —
a friendly label plus a paste-a-key field, no OAuth for either.

The owner's settled direction is recorded in issue #32 (profiles as personas;
keys.json5 endpoint-keyed per Octofriend; deliberate selection; the four
accepted recommendations: MCP secrets as `$ENV_REF`, optional provider labels
defaulting to the URL host with `defaultProvider` referencing the label,
onboarding key paste written straight into keys.json5 at 0600, and
`--profile <unknown>` a hard error listing valid names). This ADR shapes the
corners the issue leaves open and refines its Done-when list.

## Decision

### Schema

`settings.json5` (placeholder values; secret-free — it **cannot** hold a
credential: no field in it is one, and a stray `apiKey` anywhere is
tolerated-with-warning and ignored, never a fallback, the #31 rule):

```json5
{
  configVersion: 3,
  defaultProfile: 'personal',        // optional — omit and selection turns deliberate
  profiles: [
    {
      name: 'personal',
      defaultProvider: 'zai',        // optional label; absent = first provider
      providers: [
        // label optional, defaults to the URL host ('api.z.ai' here)
        { label: 'zai', baseUrl: 'https://api.z.ai/api/coding/paas/v4',
          models: [{ nickname: 'glm-5.3', model: 'glm-5.3', context: 128000 }] },
        { baseUrl: 'https://api.synthetic.new/openai/v1',
          models: [{ model: 'hf:deepseek-ai/DeepSeek-V3-0324' }] },
      ],
      mcp: [                          // optional; storage shape only (no MCP client yet)
        { name: 'fetch', command: 'uvx', args: ['mcp-server-fetch'],
          token: '$FETCH_TOKEN' },    // ALWAYS an env reference, never a literal
      ],
      settings: { defaultModel: 'glm-5.3' },   // open map, v2 semantics unchanged
    },
  ],
}
```

- **Profile:** `name` (required, unique — duplicates warn, first wins, v2
  rule), `providers[]`, `mcp[]`, and the open `settings` map carried over from
  v2 verbatim (`defaultModel` remains its one known key; unknown keys warn by
  name). `yourName` stays tolerated-with-no-consumer.
- **Provider:** `baseUrl` (required — the endpoint identity), `models[]` (v2
  entry shape unchanged: `nickname` defaults to the id, `context` optional,
  extras tolerated), and `label` — **optional, defaulting to the URL host**.
  Labels address providers *within* their profile: duplicate labels (after
  defaulting) warn and the first wins; an absent `defaultProvider` means the
  first provider; a `defaultProvider` matching no label warns and falls back to
  the first. Non-list `providers`/`mcp`, non-object entries, and entries
  without `baseUrl` warn and are skipped — the v2 tolerance pattern.
- **MCP entry:** `name`, `command`, optional `args[]`, optional `token`.
  `token` must match `$[A-Z_][A-Z0-9_]*` — a reference resolved at launch when
  an MCP client exists, never stored plaintext in a secret-free file. A
  non-`$`-shaped `token` warns and the entry is ignored. Extra fields are
  tolerated silently (forward compatibility).
- `configVersion` **3** is the v3 marker: a file missing it is read as
  v2-shaped by the migration (with the ambiguity tripwires below); a newer
  version warns and loads best-effort (v2 rule). **A hand-made v3 file must
  lead with `configVersion: 3`** — the migration refuses on the shapes it
  cannot tell apart rather than guessing.

`keys.json5` — still the only home for credentials, nested per profile and
keyed by endpoint:

```json5
{
  personal: {
    'https://api.z.ai/api/coding/paas/v4': 'PLACEHOLDER',
    'https://api.synthetic.new/openai/v1': '$SYNTHETIC_API_KEY',
  },
}
```

- The **baseUrl is the join key**: a provider finds its key at
  `keys[profile.name][provider.baseUrl]`. Labels are cosmetics; endpoints are
  identity — so two providers on the same endpoint inside one profile share
  one key by design, and *same endpoint, different key* (work Codex vs
  personal Codex) is expressed as two profiles, which is exactly the persona
  model. v1/v2's "same provider twice" differentiator moves up one level.
- **Values** are a literal API key, or a `$ENV_VAR` reference (same strict
  shape as MCP tokens) resolved at load from the environment — the onboarding
  "name an env var" option and Octofriend's key-by-reference trait, one
  mechanism shared with `mcp.token`. The strict shape is the disambiguator: a
  literal key that merely starts with `$` (bcrypt-style `$2a$…`) does not match
  and is treated as a literal. An unresolvable reference warns naming the
  variable (env var names are not values) and the key counts as missing.
- **Renderer quoting rules apply at both levels:** profile-name keys that are
  JSON5 reserved words render quoted (a bare `default:` is unreadable in this
  dialect — verified against the dep in #31); baseUrl keys always contain
  scheme punctuation and always render quoted. Hand-writers quoting rules are
  theirs to follow; a bare reserved word fails as plain `invalid JSON5`.

### Selection (startup, flag > env > file — v2 spirit)

1. **Profile:** `--profile` flag, else `DASHFLOAT_PROFILE` (blank = absent),
   else `defaultProfile` from settings, else the classification below. An
   unknown `defaultProfile` warns and counts as unset.
   **An explicit `--profile`/`DASHFLOAT_PROFILE` that matches no profile is a
   hard `{:error, _}` listing the valid profile names** — names are user-facing
   vocabulary (the status bar shows them), and deliberate selection means a
   typo must not silently boot the wrong persona. This supersedes v2's
   warn-and-continue, which survives in exactly one corner: **zero profiles
   defined** (the env-only regime — v1/v2 parity where env vars complete
   everything and there is nothing to mistype into).
2. **Provider:** the profile's `defaultProvider`, else its first. No
   `--provider` flag in this lane — `defaultProvider` plus hand-editing
   covers it, and runtime switching is the named future slice that solves it
   properly.
3. **Model:** `--model`, else `settings.defaultModel`, else the first entry —
   of the **active provider's** menu, with v2's two-pass nickname-then-id
   lookup scoped to that menu. A `defaultModel` naming another provider's
   model warns and falls back to the first entry (the wrinkle of keeping
   `settings` at profile level; accepted — see alternatives).

**Effective fields and precedence** — the `DashFloat.Config.t()` struct keeps
its consumer shape; nothing about it changes but where the file value comes
from:

| Field | File source | Env override |
| --- | --- | --- |
| `base_url` | active provider's `baseUrl` | `DASHFLOAT_BASE_URL` |
| `model` | selected entry of the active provider's menu | `DASHFLOAT_MODEL` |
| `api_key` | `keys[profile][baseUrl of active provider]` (after `$REF` resolution) | `DASHFLOAT_API_KEY` |
| `context_tokens` | selected entry's `context` | `DASHFLOAT_CONTEXT_TOKENS` |

Blank env = absent; unusable context = nil; missing fields after the merge
error naming field names only — all v2 rules. An active provider with no key
under its baseUrl in an *existing* keys.json5 warns (names only; silent when
keys.json5 is absent — the env-keyed regime), the #31 unkeyed-profile warning
narrowed to the provider.

### Startup classification — the deliberate-selection state machine

Load-time, after migrations run, the Application classifies (testable as a
pure function over dir + env + cli):

1. **Explicit profile given** (flag/env): match it or **hard error listing
   valid names** (or, with zero profiles, warn and continue env-only).
2. **`defaultProfile` set and valid** → chosen.
3. **No default, exactly one profile** → auto-select it. *(Recorded refinement
   of the owner's "no default → modal forces a selection": with one profile
   there is nothing to force — a one-option modal is noise, not deliberateness.)*
4. **No default, two or more profiles** → **forced-selection modal**: the TUI
   lists names, arrows + Enter choose, and there is no skip — Esc/Ctrl-C quits
   the app. Deliberate means no silent fallback; the choice is per-session
   (nothing is written back to the file).
5. **Zero profiles:** env completing the required fields → env-only start (v2
   parity — **onboarding is state-based, not file-absence-based**, so env-only
   users never see a wizard); otherwise → **onboarding wizard**.
6. When the wizard or modal would run on a non-interactive stdin, error with
   setup instructions instead — the harness must never hang in CI or scripts.
   *Amended by [ADR 0011](0011-boot-tty-and-clean-refusal.md):* "interactive"
   means a tty on stdin **or** stdout as reported by `:prim_tty.isatty/1`
   (`:io.columns/1` is always `{:error, :enotsup}` on a release's `-noshell`
   stdin, so it refused every first run of the installed binary), and the
   refusal exits 1 at the boot boundary instead of returning an error into
   OTP's permanent-application crash path.

### First-run onboarding wizard (UX spec)

Modeled on Octofriend's first-time setup: a step-by-step modal wizard,
conversational plain copy, provider presets, key by paste **or** env-var
reference, sensible skips everywhere, ending with working files on disk. It
runs as a **startup phase of the one TUI**: the Application classifies at
boot, starts the UI in a setup mode (wizard or forced-selection modal), and
the completed choice re-loads the config and hands the result to both the UI
and the already-started agent — the wizard holds state; its writes and the
selection's reload go through the config layer's atomic machinery, and the
main chat UI mounts only when setup clears. This is the sanctioned exception
to "UI performs no file I/O", scoped to the startup phase exactly like the
migration the wizard extends; when it finishes the app loads normally and
starts under the new profile. Key inputs render masked; no step ever echoes a
value.

- **W0 Welcome** — one line of copy, Enter to begin. Ctrl-C aborts: nothing
  written, exit.
- **W1 Name your first profile** — prefilled `personal`; Enter accepts, typing
  edits. The name becomes `defaultProfile`.
- **W2 Add a provider** — preset list: **Z.AI Coding Plan**
  (`https://api.z.ai/api/coding/paas/v4`) and **Synthetic**
  (`https://api.synthetic.new/openai/v1`), plus **Custom OpenAI-compatible
  URL** (paste it). Each preset suggests a friendly label (`zai`,
  `synthetic`), editable; custom defaults the label to the URL host.
  Skippable — a provider-less profile is valid and the app still starts.
- **W3 The key** — paste the key, type a `$ENV_VAR` name instead (the `$`
  shape stores the reference, not a value), or skip. A paste/reference is
  written **immediately** to `keys[profile][baseUrl]` in keys.json5 — atomic
  tmp-0600+rename, merging into any existing file (an existing unparseable
  keys.json5 refuses the step: fix or remove it first, never clobber what might
  hold keys). Immediate writes are also abort-resume: a later re-run that
  reaches the same profile+endpoint and skips W3 finds its key already there.
- **W4 Pick a model** — with a usable key (literal, or a `$REF` that resolves
  right now), offer to **live-fetch the provider's `/models`**: `GET
  {baseUrl}/models`, `Authorization: Bearer <key>`, 5 s timeout; a 2xx parses
  the OpenAI shape (`data: [{id: …}]`) into a picker — entries land with
  `context` unset (the endpoint does not report it; hand-edit later). Any
  failure — auth, network, timeout — falls back to manual model-id entry with
  a gentle note, never an error screen. **Nickname defaults to the model id.**
  Skippable (empty menu is legal). One entry; menu breadth is a hand-edit.
  *(Superseded 2026-10-30 by
  [ADR 0022](0022-context-accounting-and-compaction.md)'s issue-#111
  amendment: `/models` entries that carry `context_length` keep it, and a
  picked model's observed window is written as its entry's `context`;
  providers without the metadata still land context-less and ride the
  runtime seed/default.)*
  The fetch is the same standing fetch defined below — onboarding reuses the
  catalog machinery, not a second HTTP path.
- **W5 Optional loops** — "add another provider?" (W2 again under the same
  profile), "add an MCP server?" (`name`, `command`, space-separated `args`,
  optional token env-var name stored as `$REF`), or "done". All skippable.
- **Done** — write `settings.json5` (configVersion 3, `defaultProfile` = W1's
  name, the profile with its providers and MCP entries) atomically at 0600;
  one summary line; the app starts under the new profile. Skipping everything
  still yields a valid minimal config — settings.json5 with one named,
  provider-less profile — so onboarding never loops.

### Wizard write refusals surface on the wizard (issue #39 amendment)

Through #37 the wizard's writers refused correctly — `write_keys_entry` and
`write_settings` never clobber — but a refusal rode a `Logger.warning` the
alt-screen TUI swallows: the wizard advanced to a done screen claiming
"All set — config written" over a write that never happened, and the next
launch re-entered onboarding forever. The tolerance principle above promises
loud, on-surface recovery; this amendment makes the wizard keep it. The state
machine is otherwise untouched.

- **Mechanism — advance-and-bounce, not a boot pre-check:** the step change
  and its write action stay one atomic `handle_key` pair; the TUI runner
  executes the write synchronously in the same key event and, on refusal,
  feeds the config layer's message back into the pure machine
  (`Onboarding.write_failed/2` — the same feedback family as
  `models_arrived/2`). A refused key write bounces to `:key` with the typed
  value restored in the (masked) draft and `pending.key` unset — the fetch
  offer must not appear for a key that is not on disk. A refused settings
  write bounces to `:loop`, the step where Done was picked. `:done`, its
  "All set" copy, and its finish handoff are therefore reachable only by a
  write that actually succeeded.
- **Why bounce-back over a pre-check at wizard boot:** `write_settings`'s
  refusal set is wider than "settings.json5 non-empty" (directory creation,
  unquotable strings, tmp-path obstruction, posture failures), and the key
  write needs an on-surface refusal mechanism anyway — one feedback path
  covers every refusal class for both writers, where a boot pre-check would
  predict one class of one writer and race a file appearing mid-wizard.
  Bouncing also preserves the in-memory wizard: apply the remedy (mv the
  file aside), pick Done again, the retry writes — no re-walk.
- **Rendering:** the bounced-to screen shows the config layer's message —
  error and remedy, word-wrapped to the box, in the error style; any step
  transition clears it (the error belongs to the step that produced it).
  While a refusal is showing at `:key`, the hint swaps from the write
  promise ("written to keys.json5 (0600) immediately") to a retry wording —
  the hint never claims a write the file state contradicts.
- **Refusal messages carry remedies** (the migration tradition, extended to
  the wizard's writers): an unquotable value names the character class (a
  backslash, or both quote kinds) and the `$ENV_VAR` alternative — never the
  value; the non-empty-file refusal keeps its `mv` remedy verbatim. A
  refusal whose culprit is PRE-EXISTING text in the file (backslash strings
  decode — only escaped quotes fail decode — so keys.json5 can hold a name
  or value the dialect cannot re-emit) blames the file with the by-hand
  remedy, never the fields the user just entered; while a refusal shows at
  `:key` the hint is that generic retry wording, since the draft is not
  always the culprit (issue #42).

### Presets (first-class, verified)

- **Z.AI Coding Plan** — `https://api.z.ai/api/coding/paas/v4`, key paste.
- **Synthetic** — `https://api.synthetic.new/openai/v1`, key paste. Verified
  2026-10-26 from dev.synthetic.new's API Overview ("OpenAI-compatible
  endpoints — Base Url: `https://api.synthetic.new/openai/v1`", with
  `/models` and `/chat/completions`); Octofriend's provider table ships the
  same URL. The docs' getting-started curl snippets also show a bare
  `https://api.synthetic.new/v1/` in places — an internal inconsistency; the
  dedicated OpenAI-compatible section is canonical and is what DashFloat uses.
- **Custom OpenAI-compatible URL.**

Presets are code constants shared by the wizard (a tiny module — nothing
configurable, nothing secret in them).

### Standing model catalog refresh (owner requirement, added at review)

Fetching `/models` is **not onboarding-only**. At every startup DashFloat
refreshes the model catalog from each configured provider — Octofriend's
pattern (`synthetic-models.ts`: fetch at startup, short timeout, fail-open)
adapted to DashFloat's async TUI:

- **Scope:** each provider of the **active profile** — the only profile whose
  menus this session can address (selection is startup-only until runtime
  switching exists). Fetching other personas' providers would be cost with no
  consumer; the scope widens when the runtime picker does.
- **Fetch:** `GET {baseUrl}/models` per provider, `Authorization: Bearer` with
  the provider's **effective key** (`DASHFLOAT_API_KEY` for the active
  provider, else `keys[profile][baseUrl]` after `$REF` resolution); the header
  is **omitted when no key resolves** — a catalog that needs no auth still
  refreshes. 5 s timeout, no retries.
- **Fail-open, absolutely:** any failure — auth, network, timeout, non-2xx, a
  body that is not the OpenAI `{data: […]}` shape — leaves the configured
  menus untouched. The refresh can never block, crash, or error the app; a
  failure is at most a debug-level log line.
- **Merge rules (in-memory, per session):** the user's explicit settings
  entries always win — a catalog entry whose id matches an existing entry
  never overrides it, but **may refresh metadata: the context window**
  (catalog wins when it reports one) and capability extras; catalog entries
  the menu lacks are **added** (nickname defaults to the id) — the
  `Catalog.merge/2` contract, defined and tested for the runtime picker that
  is its consumer. It is not wired into any menu today (issue #39's README
  correction): the refresh's one wired effect is the context denominator
  below. Nothing is written back to settings.json5 automatically — no config
  churn on every start; persisting a discovered model stays hand-editing.
- **Async wiring:** the fetch runs as a supervised, unlinked task started
  after the TUI mounts — startup latency stays flat. The catalog lands as a
  message; the UI stores it (per provider), and its one observable effect
  today is the status bar's context denominator filling in for a selected
  model whose config entry carried no `context`. The fetched entries are
  kept in state for the future runtime picker.
- Onboarding W4 reuses this same fetch and merge — one HTTP path, one parser,
  one merge contract.

### Malformed-config tolerance (owner requirement, added at review)

A hand-damaged file degrades to the least-surprising working state with a
warning naming the field or profile — never a crash, never silent
misbehavior (the v2 tolerance pattern, made universal). Terence's scenario —
an accidentally deleted `defaultProfile` — is the canonical case: the warning
names it, and the classification state machine IS the recovery path (one
profile auto-selects, two or more force the modal, zero hand off to the
wizard or env-only). The edges, each defined as delete-it / wrong-type-it /
empty-it:

- `defaultProfile` missing (silent — it is optional), not-a-string, blank,
  or unknown (warn + unset) → the classification arms above.
- `profiles` not-a-list / entries that are not objects / a profile-level
  `providers`/`mcp` that is not a list → **the migration refuses** (the
  refusal catalog above); at LOAD the shape degrades instead: not-a-list
  warns, nameless entries skip with a warning (a nameless profile is
  unaddressable); zero surviving profiles → the state machine. A
  `profiles: []`-over-the-file rewrite is the one outcome tolerance never
  buys — malformed input to a WRITER is refusal, never deletion (hostile
  review P1-1).
- `providers`/`mcp` entries that are not objects or lack `baseUrl`/`name`/
  `command` → skip-with-warning per entry.
- keys.json5 values that are not strings, or a profile's map that is not an
  object → warn + treat as a missing key. **keys.json5 only refuses when
  UNPARSEABLE** — never clobber what might hold keys.
- An empty (0-byte) settings.json5 is not a marker (#31's crash-debris
  rule): it reads as no config, and the state machine takes over.
- A file unreadable at the JSON5 level is a **loud error naming the path**
  (the #31 message tradition) and is **never auto-overwritten** — the wizard
  runs on absent/empty/zero-profile shapes, not over unparseable data.
- Loading a damaged-but-parseable v3 directory never rewrites any file's
  content: warnings and classification only. (The crash-debris completion
  move is the migration's own warned behavior, not load churn.)

### Migration v2 → v3 (and the v1 chain)

Rides #31's machinery — its renderer, its posture module, its outcome-driven
no-loss decision — as one more step in `Migration.maybe_migrate/1`. The chain
composes: v1 (today's single file) → #31's split → v2 → this step → v3, in one
load; a v1-era refusal surfaces with #31's message before this step runs.

- **Trigger:** a non-empty `settings.json5` whose `configVersion` is < 3 or
  absent. `configVersion: 3` (or newer) is the no-op marker.
- **settings.json5:** each v2 profile (`name`, `baseUrl`, `settings`,
  `models`) becomes a one-provider v3 profile — its `baseUrl` and `models`
  move into `providers[0]` (no label written: the host default is the point),
  `settings` rides verbatim, `mcp` starts empty. Top level gains
  `defaultProfile` = the first v2 profile's name, preserving v2's effective
  first-profile default so nobody meets the forced-selection modal as a
  migration side effect. No `defaultProvider` is written — absent = first = the
  only one.
- **keys.json5:** `keys[profile] = K` becomes `keys[profile][baseUrl] = K`,
  the baseUrl being that profile's v2 value. Keyless profiles simply get no
  entry.
- **No-loss invariant (credentials, #31's principle verbatim):** every
  credential value present before — keys.json5 values, the v2 `.bak` files,
  anything the chain touched — is present in ≥1 file on disk after, **or the
  migration refuses loudly with settings/keys/backups byte-unchanged**, the
  decision made from the backups' *actual outcomes* before the first
  destructive write. Backups: v2 settings.json5 → `settings.json5.bak`,
  v2 keys.json5 → `keys.json5.bak` — byte-exact copies at 0600
  (backups inherit sensitivity); existing `.bak`s are never clobbered and feed
  the loss decision.
- **Refusals (loud, names/paths only, each with a remedy in the message):**
  - duplicate v2 profile names when keys exist — one value cannot nest under
    two endpoints (remedy: rename one profile by hand, re-run);
  - a profile with a key but no `baseUrl` — no join key to nest under (remedy:
    add the `baseUrl`, or move the key by hand);
  - a profile with `models` but no `baseUrl` — legal v2 (env-completed
    endpoint), but v3 menus hang off providers and the migration never reads
    env (remedy: add the `baseUrl`). Names-only shells (no baseUrl, no key, no
    models) pass through as provider-less profiles;
  - **unshapeable input (hostile review P1-1):** a `profiles` field that is
    not a list, a list entry that is not an object, or a profile-level
    `providers`/`mcp` that is not a list — writing `profiles: []` over such a
    file would delete its provider tree (and any keys still inside it) from
    every file on disk, so BOTH the split and the reshape refuse it
    byte-unchanged with the field named (remedy: fix the file by hand, or set
    `configVersion: 3` if it is already v3);
  - **v3-shaped ambiguity tripwires:** a profile carrying `providers` or
    `mcp`, or a top-level `defaultProfile`, without `configVersion: 3` — the
    file looks v3 already and reshaping it as v2 would silently orphan its
    provider tree (remedy: set `configVersion: 3`);
  - an unparseable existing keys.json5, or renderer-unrepresentable strings —
    refused by path, never clobbered.
- **Idempotent:** the marker makes re-runs no-ops; a crash mid-migration
  leaves v2 intact (tmp+rename atomicity) and the re-run converges.
- **Dangling `.bak` symlinks are kept, never replaced** (issue #33's class,
  fixed here): a dangling link answers `File.exists? == false`, which the
  regular-file guard never reached — both backup paths lstat first now, so a
  `.bak` symlink (live or dangling) survives every migration with a warning
  and counts as no backup for the loss decision.

### The v1+interleave split refuses before it writes (issue #39, migration amendment)

The chain composes split → reshape in one load, and each step refused only on
its own catalog. That left a seam: a v1 file carrying BOTH an inline
credential AND a v3-only field — a hand-merged file, the shape a user gets
halfway through following two generations of docs — split cleanly (the
v3-only field rides verbatim by design), and the reshape's ambiguity
tripwire then refused on that same preserved field AFTER the split had
written `configVersion: 2` to disk. The tripwire's remedy ("set
`configVersion: 3`") is computed for a genuinely v3-shaped file missing its
marker; applied to the post-split file whose profiles are still v1/v2-shaped
(`baseUrl` at profile level, no `providers`) it yields a provider-less
config that fails to load, with the flat key stranded in `keys.json5` and
the real recovery named nowhere on screen. No value was ever lost — backups
and `keys.json5` hold everything — but the printed remedy was a dead end:
the remedy for state N was computed against state N-1.

- **Decision (the issue's first sanctioned arm, narrowed by hostile
  review):** the split refuses the interleave at the head of the chain,
  before any write — but only the interleave whose remedy would actually
  dead-end: inline credentials beside v3-only fields (`defaultProfile`,
  `mcp`) while NO profile carries a `providers` tree. The refusal names
  both facts and an explicit nothing-was-written guarantee; the directory
  stays byte-identical. Remedy in the message: remove the v3-only fields
  and re-run — the chain then carries the file to v3 in one load and
  re-derives `defaultProfile` itself (the first profile); re-add anything
  removed (`mcp` is authored content the migration cannot compute) — or
  reshape the file to v3 by hand. A **root-level `apiKey`** gets its own
  remedy clause (review round 2, P1-1): the split has no profile name for
  it, so removing the fields alone would strand that credential in a
  backup — the message says to move it into `keys.json5` under the FIRST
  named profile (the same `first_profile_name` rule the reshape uses to
  re-derive `defaultProfile`, so the named home is exactly the profile
  that will load), then remove it with the v3-only fields. A file with no
  named profile gets the by-hand arm only — there is nothing to move the
  key under and no `defaultProfile` to re-derive. Convergence is pinned by
  tests for the single- and multi-profile shapes.
- **Why providers-carrying interleaves are excluded (review round 1,
  P1-1):** when a profile already carries a `providers` tree, the split
  preserves it and the flat key nests under its single provider endpoint —
  the tripwire's "set `configVersion: 3`" remedy converges there, ending
  loadable with the tree intact (pinned by test). Refusing those at the
  head would trade a working automatic path for manual work, and a
  removal-remedy there would invite deleting the authored provider/mcp
  trees — exactly the half-migrated damage this amendment exists to
  prevent. They keep the chain's write-then-refuse with its fitting
  remedy (the issue's second arm). The providers test is deliberately
  coarse (`Map.has_key?`): a file whose `providers` is empty/null, or one
  sitting on a nameless profile, keeps the marker path — listed with the
  neighbors below.
- **The refusal is gated on the split's own precondition (review round 1
  P1-2; round 2 made it structural):** regularity is decided once, before
  both the refusal and the split, so the arm can only fire where the split
  itself would run. A symlinked or otherwise non-regular layout keeps the
  stand-down: the split was already left by hand there, and some such
  directories (a v3-shaped file completed by a symlinked keys file) load
  fine without any migration.
- **Why the prediction is sound:** `de_secret/1` only strips `apiKey` and
  stamps `configVersion`/`profiles`; every tripwire key survives the split
  verbatim, so the pre-split map trips if and only if the post-split map
  trips — and the arm only fires where the split would actually run.
  Refusing at the head keeps the chain transactional — the directory never
  enters a half-migrated state the chain itself could predict — and zero
  writes is the stronger, cheaper-to-verify guarantee.
- **Rejected alternative (the issue's other sanctioned arm):** a
  shape-aware remedy on the post-split tripwire ("delete the field") for
  the not-v3-shaped class. It would keep the write-then-refuse state and
  leave the user editing a v2 file the chain just wrote instead of the one
  they hand-damaged.
- **Pre-existing neighbors, unchanged and consciously out of scope (no
  credential value is lost in any of them; reviews round 1 P2/P3, round 2
  P3):** `reject_endpoint_keyed`'s write-then-refuse (its "set
  `configVersion: 3`" arm can dead-end on a v2-shaped settings, though its
  "fix `keys.json5` by hand" arm converges); the reshape tripwire's marker
  advice for a hand-made no-inline-credentials v2/v1-shaped file with a
  stray `defaultProfile` (nothing is written, the advice can misfit); a
  multi-provider providers-carrying interleave, where the flat key strands
  under a warning that names the hand fix (nest it under the baseUrl);
  an empty/null `providers` key or one on a nameless profile (the coarse
  providers test counts them as v3-shaped — they keep the marker path and
  can end load-failing).

### Carried over unchanged (ADR 0008 / #31)

JSON5 dialect, `Decimal` normalization, BOM stripping, the fixed
`"invalid JSON5"` error; never-echo hygiene, names-only errors,
`@derive {Inspect, except: [:api_key]}`; atomic tmp-0600+rename writes and
lstat symlink guards; keys.json5 0600 at create and repaired on load;
settings.json5 stays 0600 as free hardening; `oauth.json5` reserved and
posture-only; backups inherit sensitivity; stray inline `apiKey` tolerated,
warned, never a fallback; duplicate profile names first-wins at load; env-only
configs; newer-version best-effort load; the status-bar label
`nickname (profile)` (ADR 0006 contract — provider ambiguity in that label is
noted below as a future slice); the README's no-provider TUI mode.

### Wizard model step: the fetch is the primary path (issue #64 amendment)

The owner hit the manual path because the fetched list was an aside behind a
three-option menu. Entering a working key now goes straight to the fetch: the
key write and the `/models` fetch travel as one ordered action pair the runner
executes in order, and a refused key write drops the fetch behind it (the
issue #39 bounce gate — a key that is not on disk must not fetch). The
`:model_choice` step is deleted. Manual entry is the explicit fallback — esc
while fetching, the picker's last option, or the keyless path — and a failed
fetch (including an empty list) lands on manual entry with a short reason on
screen. Reasons are classes or statuses from the fetch layer ("HTTP 500",
"timed out"), never response-body content. Every result carries its
request's identity — see the
[issue #87 amendment](#wizard-fetch-identity-a-result-belongs-to-one-generation-issue-87-amendment).

### Wizard back navigation: Esc returns to the previous step (issue #65 amendment)

A wrong entry at step N>1 had no way back — esc either skipped forward or did
nothing, and the only exit was ctrl+q's whole-run abort. Esc now walks BACK one
step through the wizard's spine, side-effect-free, with the entry preserved.

- **The back-edge map:** `:profile_name → :welcome`, `:provider →
  :profile_name`, `:custom_url → :provider` (the pre-existing edge), `:label →
  :provider`, `:key → :label` (replacing the old esc-skips arm — a blank Enter
  still skips forward to the model step), `:model_pick → :key`,
  `:model_manual → :key`, `:mcp_name → :loop`, `:mcp_command → :mcp_name`,
  `:mcp_args → :mcp_command`, `:mcp_token → :mcp_args`. The map is the spine,
  not a history stack: a step's esc destination is fixed.
- **First screen:** esc at `:welcome` is a no-op. **Rejected alternative —
  abort-with-confirm:** a destructive confirm on the most common accidental
  key, when a quit path already exists (ctrl+q, taught by the welcome hint),
  is friction with no recovery the confirm buys. Deliberate abort stays
  ctrl+q's job.
- **The loop pops the last provider:** finishing a provider snapshots the
  fetch state onto it (`fetched` — a pending-map key `settings_doc/1` never
  writes out; its fields are explicit). Esc at `:loop` with providers
  non-empty undoes the finish: the last provider returns as pending with
  `models: []` (the pick is what is being undone) and `fetched` restored from
  the snapshot, landing at `:model_pick` when that snapshot is non-empty —
  the provider finished from the picker — else `:model_manual`. With no
  providers, esc returns to `:provider`. Consecutive providers cannot
  cross-contaminate the list: the key enter resets `fetched` at `:fetching`,
  and every `:model_manual` entry clears it.
- **The one exception:** esc at `:fetching` stays the manual fallback, not
  back navigation — there is no earlier step to return to mid-fetch — and a
  fetch result landing after that esc stays inert.
- **The rules:** an esc-back emits no actions; nothing re-validates on
  return; re-accepting a step re-executes its action (the key write is an
  idempotent merge into keys.json5). Esc at `:done` is a no-op trap: the
  config is already written, and backing out would offer a re-write the
  writer must refuse.
- **Draft/choice memory:** the wizard keeps a per-step `%{draft, choice}`
  snapshot — recorded on every edit (typing, backspace, and bracketed
  paste) and every picker move — and every transition restores the
  destination's remembered draft/choice when present, the passed-in prefill
  being the default, not an override; a restore can never point past the
  destination's list (the picker re-clamps when a refetch arrives smaller).
  Back-then-forward is therefore lossless. One deliberate exception: the
  loop's "add another provider" arm still resets the provider menu to its
  top — a NEW provider's choice starts fresh (pre-#65 behavior), while
  esc-then-forward within a provider restores. Provider-scoped memory (`:label`, `:key`, the model steps) is
  dropped wherever a new provider's pending is built (the provider-enter
  preset arm and the custom_url-enter arm), so a stale edit never leaks
  into the next provider; `:custom_url`/`:provider`/`:profile_name` memory
  survives across providers — as does the MCP sub-flow's, a re-entered
  server entry pre-filling the previous one's drafts — and memory never
  leaves the process: it is inspect-excluded with the draft and pending
  (the never-echo rule).

### Wizard fetch identity: a result belongs to one generation (issue #87 amendment)

The wizard's `/models` results carried no provider identity, and
`models_arrived` gated on `step == :fetching` alone — so a stale result
could repopulate the picker under the wrong provider: a slow fetch from a
previous provider selection landing while the current one waits (the #64
loop re-entry made this reachable), or — same endpoint — the pre-edit
key's list landing after esc-back and a key edit, whichever delivery won
the race. The user then picks a model the current provider does not serve.

- **Identity at creation:** every fetch result is tagged where it is born —
  the supervised task sends `{:wizard_models, {base_url, epoch}, result}`.
  `base_url` is the provider identity; `epoch` is a monotonic fetch
  generation the wizard's key-enter issues (`fetch_epoch + 1`, carried by
  the `{:fetch_models, {base_url, key, epoch}}` action). A result feeds
  the picker only when its tag equals `{pending.base_url, fetch_epoch}`;
  `models_arrived/3` enforces the match with the pin-free guard form
  (`tag == {base_url, epoch}` — cross-argument pins are illegal in a
  `def` head). A refused write spends its epoch with no fetch in flight
  (the #64 gate drops the action); the next enter issues a fresh one, so
  epochs are never reused within a run.
- **Mismatch policy — inert, not refetch, not a visible refusal.** A
  superseded generation's result is dropped; the wizard stays at
  `:fetching` and the CURRENT generation's own result decides the screen.
  This is safe because delivery is guaranteed for every failure class the
  fetch layer can produce — `Catalog.fetch/3` returns an error tuple for
  every HTTP/transport outcome and rescues internal raises — and a failed
  task spawn — the bare `Task.Supervisor.start_child` call could `:exit`
  on a dead supervisor and strand the wizard at `:fetching` forever — now
  follows `start_suggest`'s guarded form and delivers
  `{:error, "could not start"}`, landing on the manual fallback with the
  usual note. (A raw `:throw`/`:exit` escaping the rescue would leave the
  wizard waiting; esc-to-manual stays the escape — no known path produces
  one.) **Refetch was rejected** because a duplicate fetch is
  already in flight — the current epoch's own HTTP request. **A visible
  refusal was rejected** because nothing is wrong and no remedy exists:
  the drop is invisible by design, and every generation's outcome
  (picker, or manual entry with the class-phrase note) is the visible
  surface — the same rule the #65 amendment set for results the wizard
  moved past.
- **Staleness policy — one fetch generation, session-scoped, never
  persisted.** A fetched list is valid only for the exact
  `{provider, epoch}` that fetched it. It is invalidated by: the next
  key-enter (a new epoch; entering `:fetching` also resets `fetched`),
  entering manual entry (which clears `fetched`), and any provider change
  (a new pending; provider-scoped memory drops with it). Nothing is
  cached across runs: `fetched` and `fetch_epoch` are process state,
  `fetch_epoch` resets with the struct, a restarted wizard starts empty,
  and in-flight results cannot cross process death. The loop's esc-pop
  restore is not staleness: the snapshot rides the provider draft, so it
  can only ever re-present the SAME provider's list — and a re-fetch from
  the key step issues a new epoch that supersedes it.
- **Hygiene riders from the review:** the guarded spawn above, and the
  wizard's fetch tests run hermetically — the two suites that fired real
  HTTP at the Z.AI preset endpoint now walk the custom-provider path into
  the fleet's loopback standin (`SSEServer`), which also makes their
  post-retry arms deterministic (a scripted picker instead of
  "whichever arm the live endpoint yields").
- Red-first proof: the wrong-provider arm populated the picker on
  pre-fix main (`:model_pick` ≠ `:fetching`; TUI-level: the picker held
  `STALE-LIST` instead of the standin's answer). Post-fix, a
  two-generation same-endpoint repro (the issue's executed scenario,
  ordering forced by a scripted slow first connection) lands the stale
  list first and the picker ends holding only the refetch's list.

## Alternatives considered

- **Amending ADR 0008 in place** (the #31 style) — v3 rewrites the schema,
  selection, and migration while adding onboarding; a dedicated record keeps
  0008 the honest v1/v2 history. Also practical: 0008 is a file the keys-split
  PR owns in flight; this lane starts clean.
- **Keys keyed by provider label** instead of baseUrl — rejected (owner
  decision): labels are optional, mutable cosmetics; the endpoint is identity.
- **`--provider` flag** — deferred: `defaultProvider` + hand-edit covers the
  startup case, and runtime in-TUI switching is the future slice that solves
  it without a third selection flag to keep coherent.
- **Env-var names in a separate overrides map** (Octofriend's
  `defaultApiKeyOverrides`) — rejected: `$REF` values in keys.json5 are one
  mechanism, shared with `mcp.token`, with no new field to explain; the strict
  `$[A-Z_][A-Z0-9_]*` shape disambiguates literal keys that start with `$`.
- **Wizard writes everything at done** — rejected: per-step key writes make
  abort-resume fall out for free and match "written straight into keys.json5";
  both orders are equally atomic.
- **Onboarding on file-absence only** — rejected: the state-based rule
  (zero profiles + env cannot complete) preserves env-only parity and handles
  emptied configs without a file-existence matrix to maintain.
- **`settings` moved to provider level** — rejected: the open map is v2
  forward-compatibility machinery; moving it churns migration for one wrinkle
  (a profile-level `defaultModel` may name another provider's model — it warns
  and falls back), and provider-scoped settings can arrive later inside the
  same open map without a migration.
- **A `--profile <unknown>` warn-and-continue** (v2 behavior) — rejected:
  deliberate selection is the point of the lane; the env-only corner keeps the
  old behavior where it is the only behavior that makes sense.
- **Blocking catalog fetch at startup** (Octofriend's literal pattern — the
  app waits) — rejected: an offline or slow provider would stall every launch
  for the timeout; async-after-mount keeps startup latency flat, and fail-open
  makes the wait pointless anyway.
- **Fetching every profile's providers** at startup — rejected: menus of
  non-active personas have no consumer this lane (startup-only selection);
  the fetch set is the active profile's providers and widens with the runtime
  picker.
- **Persisting the refreshed catalog** back to settings.json5 — rejected (owner
  rule): automatic write-back would churn the config file on every start and
  race hand-edits; the merge is in-memory per session.

## Consequences

- **ADR numbering:** this lane consumes 0009, which had been tentatively
  earmarked for Phase 4 (context & history persistence) — that work becomes
  **0010** when it lands. Recorded here per the numbering rule; no other
  displacement.
- Implementation (Phase B, sequenced **after #31 merges** — both lanes own
  `migration.ex`; rebase onto post-merge main first) touches: `config.ex`
  (v3 parse, selection, classification), `migration.ex` (v3 step + refusals,
  reusing #31's renderer/posture), a small `Onboarding` + `Presets` module,
  `application.ex` (classification wiring), the TUI (wizard screens,
  forced-selection modal), `cli.ex` (unchanged parser, new error arm),
  README, ADR 0008's pointer, and this record's status flip.
- New user-visible failure states: the deliberate-selection hard error and
  every migration refusal — each ships its remedy in the message and README.
- The wizard is the first outbound HTTP DashFloat makes besides chat
  completions — bounded (5 s), optional, and failure-soft by construction.
- The status bar can say `Sol (personal)` ambiguously across providers in one
  profile — accepted for this lane; `nickname (profile/provider)` is a named
  future slice for the runtime-switching work.
- v3 settings.json5 is structurally incapable of holding a secret even with
  MCP in the picture — the `token` field *is* a reference; the #31 guarantee
  survives its first real test.

## Test plan (the issue's Done-when, refined)

All under tmp-dir discipline (the real `~/.config/dashfloat` is off-limits);
network only via the existing loopback-server pattern.

1. `mix ci` exits 0 (the full gate: format, warnings-as-errors, credo strict,
   dialyzer, coverage floor).
2. **v2→v3 no-loss:** a realistic multi-profile v2 directory (≥2 profiles with
   distinct and shared baseUrls, keys.json5 keyed by name, one env-keyed
   keyless profile, a pre-existing `.bak`) migrates in one load with every
   credential value present **exactly** in keys.json5 at
   `keys[profile][baseUrl]` — and in no live settings file; both backups
   byte-preserved at 0600.
3. **`--profile <unknown>`** errors listing the valid profile names; same for
   `DASHFLOAT_PROFILE`; env-only with zero profiles still starts.
4. **No `defaultProfile`** with ≥2 profiles returns the forced-selection
   classification (modal state); with exactly one profile it auto-selects; an
   unknown `defaultProfile` warns and lands in the forced state.
5. **Fresh-HOME wizard end to end:** driven through profile name → preset →
   key paste → model (loopback `/models`, plus the manual-fallback arm) →
   done; settings.json5 and keys.json5 exist, both 0600, and the entered key
   reloads as the effective credential.
6. **Patch coverage 100%** on the diff (excoveralls JSON vs the merge-base
   diff, the established mechanics).
7. **Chain:** v1 directory loads straight through to v3 in one run; each
   refusal refuses with files byte-unchanged and a remedy in the message
   (duplicate names + keys; key without baseUrl; models without baseUrl; the
   v3-shape tripwires; unparseable keys.json5); re-run after refusal converges
   once the remedy is applied.
8. **`$REF` keys:** resolve from env at load; unresolvable warns (variable
   name only) and the field errors as missing; a `$`-prefixed literal that
   does not match the env shape stays a literal.
9. **Parse and selection:** label defaults to the URL host; duplicate labels
   first-wins; absent/unknown `defaultProvider` falls back with a warning;
   two-pass model lookup scoped to the active provider's menu; literal
   `mcp.token` warns and the entry is ignored; profile-level `settings` rides
   verbatim.
10. **Wizard mechanics:** key input masked; skip-everything writes the minimal
    valid config and never loops; abort before the key step writes nothing,
    abort after it leaves exactly the merged keys.json5; a completed wizard's
    immediate write is resumed by a skip on re-run.
11. **Env-only parity and guards:** no files + complete env starts with no
    wizard; wizard/modal under non-interactive stdin errors with instructions,
    never hangs.
12. **Warning parity:** an active provider unkeyed in an existing keys.json5
    warns; silent when keys.json5 is absent or `DASHFLOAT_API_KEY` keys it.
13. **Standing catalog refresh:** loopback `/models` for two providers (both
    land); fail-open arms — timeout, non-2xx, garbage body — leave menus
    untouched and the app unharmed; a key-less provider is fetched **without**
    an Authorization header and still fail-opens; merge rules — an id
    collision never overrides the user's entry but refreshes `context` when
    the catalog reports one, a catalog-only id is added with nickname = id;
    the async task's landing message updates the UI state (wiring), and
    nothing is ever written back to settings.json5.
14. **Hand-vandalized configs (the tolerance family):** every edge above —
    `defaultProfile` deleted / not-a-string / unknown (warning asserted in
    BOTH classification arms), `profiles` not-a-list / empty / non-object /
    nameless entries, providers/mcp junk entries, keys.json5 non-string
    values and non-object profile maps, a 0-byte settings.json5, unparseable
    settings and keys — each asserting the specified degradation, the
    warning, no crash, and no file content rewritten as a side effect of
    loading.

Existing config/migration tests pin v1/v2 semantics and are updated to the v3
truth in the same PR — the no-loss and hygiene assertions they already carry
are the ones this plan builds on.
