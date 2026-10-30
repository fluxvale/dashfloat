# 0008 — Config layout v2: single-file JSON5 with profiles

- **Status:** Accepted; **amended 2026-10-25** ([issue #29](https://github.com/fluxvale/dashfloat/issues/29) —
  credentials split back out into `keys.json5` + `oauth.json5`,
  `settings.json5` de-secreted; see
  [Amendment (2026-10-25, issue #29)](#amendment-2026-10-25-issue-29-credentials-split-back-out)
  below); **partially superseded 2026-10-26** by
  [ADR 0009](0009-config-v3-persona-profiles.md) ([issue #32](https://github.com/fluxvale/dashfloat/issues/32) —
  the schema, selection, and migration sections: profiles become personas
  bundling `providers[]` + `mcp[]`, `keys.json5` becomes endpoint-keyed,
  selection turns deliberate with onboarding). ADR 0009 keeps this record's
  JSON5 dialect, error hygiene, atomic writes, posture principles, and
  no-loss invariant verbatim.
- **Date:** 2026-10-24
- **Implements:** [issue #22](https://github.com/fluxvale/dashfloat/issues/22).
- **Supersedes:** the *Provider config — one endpoint, file + env* section of
  [ADR 0005](0005-llm-streaming-engine.md). Nothing else in ADR 0005 changes:
  the load-once-in-Application contract, the mount-opt handoff, and the
  never-echo-values error rule all stand, now fed by the loader defined here.
- **Extends:** [ADR 0006](0006-ui-truth-and-rendering.md) — the status-bar
  model field becomes the *label* field (`"nickname (profile)"`).

## Context

The v1 config is a single `~/.config/dashfloat/config.json`
(`base_url`, `model`, `api_key`) with per-field `DASHFLOAT_*` env overrides. It
describes exactly one endpoint with one credential and no names. Two problems:

1. **One provider, several subscriptions.** Terence runs a work Codex
   subscription and a personal one. No harness models this natively; users
   juggle env vars or config swaps. Profiles — named per-subscription setups,
   each pairing an endpoint, a credential, its own settings, and its own model
   menu — make the same provider usable twice in one config, first-class.
2. **Unnamed models.** A fleet of model ids is unreadable in a status bar.
   Octofriend's proven layout names every models-list entry (`nickname`,
   `model`, `context`, per-model extras) and the files are hand-edited JSON5:
   unquoted keys, single quotes, trailing commas, `//` comments.

The reference lives on this machine (`~/.config/octofriend/`, inspected for
structure only; no values were copied). Two layout iterations on this ADR
landed on the consolidated shape below: **one config file**, chosen over a
keys/main file pair because profiles (not files) are the organizing concept —
a credential is an attribute of a subscription, so it lives inside its
profile. The file is `settings.json5` (Terence's call over mirroring
`octofriend.json5`'s filename); the dialect is octofriend's JSON5.

## Decision

### File layout

One file: `~/.config/dashfloat/settings.json5` (`XDG_CONFIG_HOME` honored via
`:filename.basedir/1`) — everything in it, including credentials, so **the
file is created 0600 and repaired to 0600 on load**. No `keys.json5`, no
`oauth.json5`: OAuth storage returns *if* an OAuth flow is ever built
(footgun-free, because the loader described here never reads such a file).
JSON5 throughout; hand-editing is the primary workflow (a leading UTF-8 BOM is
stripped before decoding — editors add one silently).

*(Reversed by the
[keys-split amendment](#amendment-2026-10-25-issue-29-credentials-split-back-out):
credentials live in a sibling `keys.json5`, `settings.json5` carries no
credential material, and a reserved `oauth.json5` exists by name. The
profiles/schema/selection machinery below stands unchanged unless the
amendment says otherwise.)*

### JSON5 parsing (verify-first outcome)

**Chosen: hex [`json5`](https://hex.pm/packages/json5) 0.4.1** (MIT,
leex/yecc + combine parser), default Combine backend — the spec-rigorous one.
Verified against octofriend-shaped input before adoption: unquoted keys, single
quotes, trailing commas, `//` and `/* */` comments, single-line maps, duplicate
keys (last wins), hex/`+`/leading-dot numbers all behave; `NaN`/`Infinity`
literals are rejected and **escape sequences (`\n`, `\u0041`) are not
translated** — both fine: the schema's values (URLs, ids, nicknames, keys) are
plain strings and octofriend files use no escapes. Decode errors return
`{:error, reason}` whose text never contains input content — safe next to
secrets. A number literal the library cannot represent (e.g. `1e10000`)
raises `Decimal.Error` **whose message quotes the literal**; the wrapper
rescues it into the same fixed error string, so neither the crash nor the
leak can reach startup. The README's "slow" warning is irrelevant here:
config decodes once at startup.

**Number caveat:** the library returns every number as `Decimal` for
precision. `DashFloat.Config.JSON5` (thin wrapper) normalizes `Decimal` to
integers/floats so consumers never see it, and rewrites parser errors to
`"invalid JSON5"` (the raw reason is position-only noise).

**Dependency override:** `json5` pins `decimal "~> 2.0.0"` — which resolves to
exactly 2.0.0, a version carrying two MEDIUM DoS advisories
(EEF-CVE-2026-32686, EEF-CVE-2026-97853; unbounded exponent/allocation in
`Decimal.new`/`round`). DashFloat overrides to `decimal "~> 3.2"` (both
advisories fixed in 3.x). Verified: json5 0.4.1 compiles clean against
decimal 3.2.0 and its decode output is identical across the probe matrix. If
`json5` ever bumps its pin, drop the override. Exposure would in any case be
theoretical — the only JSON5 input is the user's own config file — but a
flagged dependency in the lock is a cost with no offsetting benefit.

**Rejected:** `lumis_wasm_json5` (Lumis-ecosystem tree-sitter WASM, not a
general-purpose parser); a vendored/hand-rolled parser or JSON-with-comments
preprocessor (the issue forbids silently hand-rolling one; an upstream-tested
parser is strictly better); Jason (no JSON5 support — the whole point).

### Schema

`settings.json5` (placeholder values shown):

```json5
{
  configVersion: 1,
  yourName: 'Terence',           // optional, reserved (no consumer yet)
  profiles: [
    {
      name: 'work',
      baseUrl: 'https://provider.example/v1',
      apiKey: 'PLACEHOLDER',     // the credential lives in its profile
      settings: { defaultModel: 'Flash' },   // optional, open map
      models: [                  // this profile's menu, in order
        { nickname: 'Sol', model: 'glm-5.3', context: 524288 },
        { nickname: 'Flash', model: 'glm-5.3-flash', context: 196608 },
      ],
    },
    {                            // same provider twice: the differentiator
      name: 'personal',
      baseUrl: 'https://provider.example/v1',
      apiKey: 'PLACEHOLDER',
      models: [{ nickname: 'Sol', model: 'glm-5.3', context: 262144 }],
    },
  ],
}
```

- A **profile** is a named subscription setup: `name` (required, unique —
  duplicates warn and are skipped), `baseUrl` (the endpoint; env may
  substitute if absent), `apiKey` (the credential; env may substitute),
  `models` (this profile's menu, in file order), and an optional open
  `settings` map. Known settings keys today: `defaultModel` only. **Unknown
  settings keys are tolerated with a warning** so future dimensions (tool
  permissions, confirmation policy, persona, context defaults) slot in without
  another config migration. No behavior couples to settings in this lane
  beyond `defaultModel` selection.
- A **models entry** carries `nickname` (defaults to the model id when
  omitted), `model` (required), `context` (optional positive integer;
  unusable values are nil, never errors — ADR 0006 rule), and free-form extras
  (octofriend files carry `modalities`, `reasoning`, `type`) which are
  tolerated silently for forward compatibility. (Amended by
  [ADR 0018](0018-image-attachments.md): the entry may also carry `images:
  true` — a strict boolean flag marking the model image-capable; absent,
  `false`, or junk-with-warning means not.)
- `yourName` is parsed by nothing yet — storage shape.
- `configVersion` of this layout is `1`. A *newer* version warns and the load
  proceeds best-effort; an older/absent one is tolerated.

### Model addressing and selection (startup-time only)

**A model is addressed by nickname + profile** — `Sol (work)` — matching the
status-bar vocabulary. Selection at startup:

1. **Active profile** = `--profile <name>` CLI flag, else `DASHFLOAT_PROFILE`
   env (non-blank), else the first `profiles` entry. A flag/env profile that
   matches no defined profile — including when no profiles exist at all —
   warns and is used anyway: the effective fields can still be completed by
   other env vars. Duplicate profile names warn and the **first definition
   wins**.
2. **Model menu** = the active profile's `models`, in file order.
3. **Selected model** = the entry named by `--model <nickname>`, else the
   profile's `settings.defaultModel`, else the **first menu entry**. Named
   lookup is **two-pass — nickname first, then model id** — so when entry A's
   id collides with entry B's nickname, B wins (nicknames are the
   user-facing address). A miss at either named step warns and falls back to
   the profile default; a present-but-unusable `defaultModel` (a number, a
   blank) warns too; a `--model` against a model-less profile warns that the
   flag was discarded.

`DashFloat.CLI.parse/1` turns argv into `[profile: name, model: name]` —
`--profile work`, `--profile=work`, `--model Sol`, `--model=Sol`; a switch
without a value or an unrecognized argument warns and is ignored, and the
warning carries the argument's **name only** — `--api-key=<secret>` is exactly
the typo this parser sits next to, and values never reach logs. The
Application parses argv once at startup and hands the result to
`DashFloat.Config.load/1`; the UI and agent remain untouched by argv.

**Out of scope, as named future slices:** runtime in-TUI profile/model
switching (the schema and selection semantics leave room for it), any
behavioral settings, and an OAuth flow (whose token storage would arrive as a
profile attribute in this same file).

### Effective provider fields and precedence

The `DashFloat.Config.t()` struct keeps its consumer-facing shape
(`base_url`, `model`, `api_key`, `context_tokens`) and gains `nickname` and
`profile`. Resolution per field, **file < env** exactly as v1:

| Field | File source (overridden by env) | Env var |
| --- | --- | --- |
| `base_url` | active profile's `baseUrl` | `DASHFLOAT_BASE_URL` |
| `model` | selected entry's `model` | `DASHFLOAT_MODEL` |
| `api_key` | active profile's `apiKey` | `DASHFLOAT_API_KEY` |
| `context_tokens` | selected entry's `context` | `DASHFLOAT_CONTEXT_TOKENS` |

*(The `api_key` row's file source is `keys[profile.name]` since the
[keys-split amendment](#amendment-2026-10-25-issue-29-credentials-split-back-out);
env precedence is unchanged.)*

A blank env var counts as absent (v1 rule). `nickname` has no env override —
it is file vocabulary. Env-only configs (no config file at all) keep working,
as in v1. Missing required fields after the merge yield `{:error, message}`
naming **only field names** — never values (v1 rule, unchanged); a profile
without an `apiKey` therefore surfaces as `api_key` in that message.

### Security posture

- The one file holds the secrets, so it is **0600**: migration creates it with
  mode 0600 from the moment content can land in it, and **load repairs a
  too-permissive file back to 0600 with a warning** — before parsing, so a
  hand-made file that is both malformed and too permissive (the most likely
  first-write shape) is still repaired. Repair and tightening are best
  effort — a failure never blocks a load. A **symlinked** config warns and is
  loaded as-is — chmod must never follow a link out of the config directory
  onto a file the loader does not own.
- `@derive {Inspect, except: [:api_key]}` stays, so a UI crash logging state
  still cannot print the key.
- Error and warning messages carry paths, field names, and profile *names* —
  never credential values and never endpoints' values. (Profile names are
  user-facing vocabulary — the status bar shows them — not secrets.)

### Migration (one-time, automatic, idempotent)

`Migration.maybe_migrate/1` runs as the first step of every load:

- **Trigger:** migrates only when a **non-empty** `settings.json5` is absent
  AND legacy `config.json` is present. A non-empty `settings.json5` is the
  migration marker; an empty one (crash debris or an empty user file —
  writes are atomic, so this version cannot produce it) carries no data and
  is migrated over.
- **Product:** the legacy triple becomes the **default profile** —
  `settings.json5` = `configVersion: 1`, `profiles: [{ name: 'default',
  baseUrl: <base_url>, apiKey: <api_key>, models: [{ nickname: <model>,
  model: <model>, context: <context_tokens>? }] }]` (the legacy model id
  doubles as the nickname; `context` written only when the legacy file had a
  usable one — in the integer or decimal-string shape v1 accepted). The file
  is **pretty JSON via Jason** — a strict JSON5 subset — because the json5
  library's encoder does not escape string values, and a quote inside a
  credential must not corrupt the generated file.
- **Atomic write:** content is written to a private `settings.json5.tmp`
  (created empty under 0600) and *renamed* into place — no crash can leave a
  torn or zero-byte marker; a failed write removes the tmp and returns
  `{:error, "cannot write …"}` (paths only), never a raise.
- **Backup:** after the new file is written, `config.json` is *renamed* to
  `config.json.bak` — never deleted. An existing `.bak` is never clobbered;
  the legacy file is then simply left in place (inert — the loader ignores it
  once `settings.json5` exists) with a warning. Whichever of the two holds
  the legacy credential is **tightened to 0600** (best effort): secrets are
  0600 wherever they live, not just in their primary home. *(Clarified
  2026-10-25, issue #28: a pre-existing `.bak` is tightened too — it
  plausibly holds an older credential; never clobbered, always tightened.
  The load path repairs a leftover too-permissive `.bak` in an
  already-migrated directory the same way, and every tightening chmod is
  lstat-guarded — never through a symlink.)*
- **Failure safety:** malformed or incomplete legacy JSON → `{:error, …}`
  naming the problem (field names only) with **nothing written**; any
  filesystem failure during the write is an `{:error, _}`, not a crash —
  startup must always reach its config-error path.
- **Idempotent:** the second run sees the marker and is a no-op.

### Status-bar label contract

`DashFloat.TUI.State.provider_label/1` replaces `provider_model/1` as the
status-bar field (ADR 0006's model slot): `"nickname (profile)"` — e.g.
`Sol (work)` — falling back to the bare nickname when no profile resolved,
then the model id, then `—` (view fallback unchanged). The context-usage
denominator still reads `context_tokens` off the provider.

**Superseded:** the field moved to the footer in
[ADR 0015](0015-input-surface-cursor-stats-ghost.md) §2 (issue #67) and its
shape became `provider - model` in
[ADR 0015](0015-input-surface-cursor-stats-ghost.md)'s 2026-10-31 amendment
(issue #109).

## Alternatives considered

- **Amend ADR 0005 in place** — the config contract change (layout, profiles,
  migration, security posture) is larger than the section it replaces; a
  dedicated record keeps the streaming ADR about streaming. ADR 0005 keeps a
  one-line pointer.
- **A `keys.json5` + `dashfloat.json5` pair** (octofriend's split, adapted to
  profile-keyed secrets) — the second iteration of this ADR; superseded by the
  single file. The split buys 0644-vs-0600 separation, but profiles already
  bound credentials to subscriptions, the two-file dance complicated migration
  (partial-layout states needed guards), and one chmod target is simpler to
  keep honest than two. *(Reversed by the
  [keys-split amendment](#amendment-2026-10-25-issue-29-credentials-split-back-out):
  the split is the layout after all — not for 0644-vs-0600 separation, but
  because a settings file that cannot hold a credential makes every backup,
  example, and dotfile sync structurally incapable of leaking one. The
  migration complexity the original rejection feared is handled by the
  amendment's split-marker and merge rules.)*
- **CLI `--model` as a full addressing scheme** (profile+nickname pairs like
  `work/Sol`) — `--profile` already scopes the menu; `--model <nickname>`
  under it fell out naturally and is enough. Not gold-plated further.
- **Runtime profile/model switching UI** — explicitly out of scope for this
  lane (selection at startup only); recorded above as a named future slice.
- **Behavioral settings now** (tool permissions, persona, confirmation
  policy) — storage shape and selection only; coupling behavior is future
  work that must not require another migration (hence the open settings map
  with warning-level tolerance).

## Consequences

- `mix.lock` grows `json5` and its transitive tree (`combine`,
  `decimal` 3.2 override, `nimble_parsec`, `unicode`, `unicode_set`);
  dependency compile time increases in CI, runtime cost is one startup-time
  decode.
- `Config.load/2,3` now takes the config **directory**, not a file path — an
  internal API break; all in-repo callers updated in the same change.
- Hand-edited configs may be written in any JSON5 dialect subset the library
  supports; the few constructs it rejects (`NaN`, `Infinity`, untranslated
  escapes) are outside the schema.
- The `decimal` override is a standing maintenance item: re-evaluate when
  `json5` releases (see above).
- Secrets have exactly one home, chmod-checked at creation and at every load,
  asserted by tests. Migration never destroys user data — the legacy file
  survives as a backup rename.

---

## Amendment (2026-10-25, issue #29): credentials split back out

**Status:** Accepted. **Reverses** the file-layout and security-posture
sections above (the "one file holds the secrets" decision, and the `keys.json5`
alternative rejection). Everything else — profiles, the schema's non-credential
fields, model selection, precedence (file < env), the never-echo-values rule,
the JSON5 dialect choice — stands.

### Why the reversal

The single-file layout made every copy of `settings.json5` a secrets-bearing
artifact: the 2026-10-25 backup-perms incident (issue #28) was exactly this
failure mode — a legacy file that *had* held a credential was copied
world-readable. Hardening every copy is whack-a-mole; **a settings file that
cannot hold a credential makes every backup, example, dotfile sync, and export
structurally incapable of leaking one. Nothing to remember, nothing to
redact.** Owner decision same day, after the PA's recommendation: "continue to
have a keys.json5 and an oauth.json5 so we can be secure."

### Decision

**Layout** in `~/.config/dashfloat/` (`XDG_CONFIG_HOME` honored):

| File | Contents | Mode |
| --- | --- | --- |
| `settings.json5` | `configVersion`, `yourName`, profiles (`name`, `baseUrl`, `settings`, `models`) — NO credential material | 0600 anyway (free) |
| `keys.json5` | API keys keyed by PROFILE NAME — the only home for keys | 0600 always: create + repair |
| `oauth.json5` | reserved for a future OAuth flow; absence-tolerant, never read by this loader | 0600 when present (posture-only) |

`configVersion` 2 is the split marker. The effective API key is
`DASHFLOAT_API_KEY` > `keys[active profile name]` — precedence otherwise
unchanged; a profile whose key is missing yields the existing field-names-only
error.

**Stray inline credentials: tolerate-and-warn, value IGNORED — never a
fallback.** A stray `apiKey` in settings.json5 warns:
`settings.json5: profile "<name>": apiKey is ignored — API keys live in
keys.json5, keyed by profile name`. Falling back to it would make the
structural guarantee cosmetic.

**Backups inherit the source's sensitivity** — the principle: any backup of a
file that ever held credentials is 0600. `config.json.bak`, a pre-split
`settings.json5.bak`, the legacy file before its rename: all 0600 wherever
they live (issue #28's rider, generalized).

### Migration v2 (idempotent, atomic tmp+rename, both paths)

1. **Legacy** (no non-empty `settings.json5`, `config.json` present): renders
   the de-secreted settings + `keys.json5` `%{'default': <key>}`, writes keys
   BEFORE settings (the credential reaches its new home before the marker file
   exists), then renames the legacy file to `config.json.bak` — all #28
   rider behavior verbatim (never clobber an existing `.bak`, tighten it and
   the legacy file, symlink-safe chmod, non-regular files left alone).
2. **In-place split** (a `settings.json5` older than v2 has inline `apiKey`
   fields): copy the file byte-exact to `settings.json5.bak` (0600 — a COPY,
   not a rename: a rename-first crash window would leave no settings.json5 and
   nothing to re-trigger; a copy leaves the original to converge on re-run),
   write `keys.json5` from the collected keys, then rewrite settings de-secreted
   at `configVersion` 2. A v1 file with no inline credential field is
   byte-untouched — rewriting it churns user formatting for nothing.

**Split ordering is crash-convergent:** renders (pure) run before any write;
backup → keys → de-secreted rewrite; the credential always has its new home
before the old one is emptied. A failed backup copy is a warning, not an error
(the keys still land first); a failed keys write aborts before the settings
rewrite.

**Merge rules:** a pre-existing `keys.json5` WINS over collected keys (it is
the user's explicit new home; the old values survive in the backup) — never
rewritten. A malformed existing `keys.json5` is a migration error: never
destroy unreadable data. Symlinked or non-regular `settings.json5`/`keys.json5`
skip the split with a warning — tmp+rename would sever the link; split by hand.

### General JSON5 renderer

`DashFloat.Config.JSON5.render/1` renders a whole decoded map (sorted keys,
bare identifier keys, 2-space indent, trailing commas, `quote_value`
semantics), so tolerated content — `yourName`, unknown top-level keys, models
extras — survives a rewrite losslessly; only formatting is lost. An
unrepresentable string (a backslash, or both quote kinds — the Combine
backend processes no escapes) fails the render naming the value's PATH (e.g.
`profiles[0].apiKey`), never its content. Bare keys also dodge the parser's
ECMA reserved words (`default:` as a bare key is unreadable — verified
against the dep, and "default" is a keys.json5 key). The legacy path keeps its
up-front per-field representability checks so its field-name error survives.

### Consequences of the amendment

- Three files share one posture (`DashFloat.Config.Posture`): 0600 at
  creation, best-effort repair on load before anything parses a file,
  regular-files-only, lstat-guarded (never chmod through a symlink; a
  directory by a secrets name keeps its own semantics). The `.tmp` staging
  paths get the same guard — a pre-planted `keys.json5.tmp` symlink is
  refused, never written through. *(Amended 2026-10-29 by
  [ADR 0014](0014-session-persistence.md) §7: staging names are now unique
  per write, `<path>.tmp.<random>` — the guard stands, and a planted
  symlink at any predictable name has nothing to intercept.)*
- `DashFloat.Config.load/2,3` reads both `settings.json5` and `keys.json5`
  (missing = empty map; malformed = load error naming the file; invalid
  UTF-8 included — any parser crash degrades to the fixed error string, so
  startup always reaches its config-error path); the `Config.t()` struct,
  env overrides, and consumers are untouched.
- **A credential is never silently lost** (review fix-round rule, proven
  cell-by-cell by a table-driven sweep test over the constructible
  pre-state matrix — keys.json5 × backup × v1 shape, crash states modeled
  as pre-states since writes are tmp+rename atomic): every inline
  credential the split removes gets a home — a keys.json5 slot with exactly
  that value, or the byte-exact backup. The decision is made from the
  backup's ACTUAL outcome (`:written`/`:identical`/`:kept`/`:failed`),
  never from a prediction, and completes before the one destructive step
  (the settings rewrite). It REFUSES when a pre-existing keys.json5 wins
  without holding a value (a differing value under a collected name, a
  duplicate-name loser keys.json5 cannot key by name, a root-level or
  blank-name credential) and no usable backup exists. Both unblocks are
  real and tested: adding the key under its name to keys.json5 clears the
  refusal, a `settings.json5.bak` byte-identical to the current file (the
  crash-recovery state) converges automatically, and moving a stale `.bak`
  aside lets the next start write a fresh backup. Warnings claim only what
  has already happened (the "backed up first" clause only follows an actual
  backup write).
- The LOAD path surfaces historical loss: a profile with no key under its
  name in an existing keys.json5 warns at startup (names only, respecting
  the loader's own precedence — a profile completed by
  `DASHFLOAT_API_KEY` is keyed and stays silent; quiet when keys.json5 is
  absent entirely). The refusal-unblock sidecar `settings.json5.bak.old`
  is part of the same posture: the load tightens it like every other
  secrets-bearing leftover, so the documented `mv` remedy cannot strand a
  world-readable credential copy. A symlinked `settings.json5.bak` is
  lstat-guarded (never read through — a self-referential link would
  masquerade as a byte-exact backup while the rewrite empties the only
  real copy): it counts as no backup and feeds the loss decision.
- A ROOT-level `apiKey` is stripped by the split and warned by the loader
  exactly like a profile-level stray — nothing credential-shaped rides into
  live v2 settings unwarned.
- The legacy file is tightened to 0600 BEFORE the legacy migration writes
  anything, and the load path tightens a leftover never-renamed
  `config.json` beside a complete layout — the crash window between the
  settings write and the backup rename can no longer strand a world-readable
  credential that re-runs (marker present) would never touch.
- Rendered keys are fully anchored identifiers (a trailing-newline key must
  render quoted, not silently rename to its prefix) and dodge the parser's
  ECMA reserved words.
- The grep-able invariant: after any migration or load, the live
  `settings.json5` contains no credential value — asserted across both
  migration paths; by-design backups hold old values at 0600, which is the
  principle working, not a leak.
