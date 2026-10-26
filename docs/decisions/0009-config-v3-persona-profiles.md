# 0009 — Config layout v3: persona profiles, endpoint-keyed keys, deliberate selection, onboarding

- **Status:** Proposed — Phase A design record for [issue #32](https://github.com/fluxvale/dashfloat/issues/32);
  flips to Accepted when the design review signs off and the implementing PR
  merges.
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

### First-run onboarding wizard (UX spec)

Modeled on Octofriend's first-time setup: a step-by-step modal wizard,
conversational plain copy, provider presets, key by paste **or** env-var
reference, sensible skips everywhere, ending with working files on disk. It
runs in the Application start path *before* the main TUI mounts — the wizard
is startup UI in the migration tradition (the sanctioned exception to "UI
performs no file I/O": it holds state; its writes go through the config
layer's atomic writer), and when it finishes the app loads normally and starts
under the new profile. Key inputs render masked; no step ever echoes a value.

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
  The fetch is the wizard's only outbound call and is optional end to end —
  the offline test suite exercises it via the existing loopback-server pattern
  and the fallback.
- **W5 Optional loops** — "add another provider?" (W2 again under the same
  profile), "add an MCP server?" (`name`, `command`, space-separated `args`,
  optional token env-var name stored as `$REF`), or "done". All skippable.
- **Done** — write `settings.json5` (configVersion 3, `defaultProfile` = W1's
  name, the profile with its providers and MCP entries) atomically at 0600;
  one summary line; the app starts under the new profile. Skipping everything
  still yields a valid minimal config — settings.json5 with one named,
  provider-less profile — so onboarding never loops.

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
  - **v3-shaped ambiguity tripwires:** a profile carrying `providers` or
    `mcp`, or a top-level `defaultProfile`, without `configVersion: 3` — the
    file looks v3 already and reshaping it as v2 would silently orphan its
    provider tree (remedy: set `configVersion: 3`);
  - an unparseable existing keys.json5, or renderer-unrepresentable strings —
    refused by path, never clobbered.
- **Idempotent:** the marker makes re-runs no-ops; a crash mid-migration
  leaves v2 intact (tmp+rename atomicity) and the re-run converges.

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

Existing config/migration tests pin v1/v2 semantics and are updated to the v3
truth in the same PR — the no-loss and hygiene assertions they already carry
are the ones this plan builds on.
