# 0014 — Agent Skills: discovery, progressive disclosure, and the skill tool

- **Status:** Proposed — design gate for [issue #76](https://github.com/fluxvale/dashfloat/issues/76);
  implementation waits for the owner's go.
- **Date:** 2026-10-29.
- **Implements:** [issue #76](https://github.com/fluxvale/dashfloat/issues/76) — support the
  [Agent Skills](https://agentskills.io/) open format.
- **Amends:** [ADR 0007](0007-tool-calls-and-execution.md) — the tool catalogue grows from
  five tools to six (`skill`); 0007 gains an amendment pointer when slice S2 lands.
- **Coordinates with:** [issue #71](https://github.com/fluxvale/dashfloat/issues/71)
  (system prompt — owns the seam the skills catalog injects into) and
  [issue #69](https://github.com/fluxvale/dashfloat/issues/69) (commands — owns the
  registry `/skills` and `/skill` register into). Both lanes were unbuilt at design
  time; this ADR fixes the contracts they interlock with.

## Context

The owner asked for Agent Skills support per the open standard at
[agentskills.io](https://agentskills.io/): a skill is a directory with a `SKILL.md`
(YAML frontmatter metadata + Markdown instructions), optionally bundling `scripts/`,
`references/`, and `assets/`. Agents keep many skills cheap via **progressive
disclosure**: metadata at startup, full instructions on activation, bundled files only
as needed.

Spec facts that shape the design (from the specification page, fetched 2026-10-29):

- Frontmatter: `name` (required, 1–64 chars, lowercase alphanumerics and hyphens, no
  leading/trailing/consecutive hyphen, **must match the parent directory name**),
  `description` (required, 1–1024 chars, says what the skill does and when to use it);
  optional `license`, `compatibility` (≤500 chars), `metadata` (flat string map),
  `allowed-tools` (space-separated, explicitly *experimental*).
- Recommended structure: `SKILL.md` under 500 lines / ~5000 tokens; detail pushed into
  referenced files loaded on demand.
- The spec does **not** standardize discovery directories or invocation — those are
  client decisions.

Reference implementations studied:

- **Octofriend** (source on this machine, read-only): discovers `~/.config/agents/skills`
  (user) and `<cwd>/.agents/skills` (project) plus config-supplied extra paths, walks
  recursively, validates with skip-and-log, and does progressive disclosure through a
  dynamically-described `skill` tool — the tool's *description* embeds every skill's
  name+description, and calling it returns the full `SKILL.md` body plus the skill's
  absolute directory. Its `<available_skills>` system-prompt block is dead code
  (test-only). It also offers to install a Herdr skill at startup (a distribution
  pattern, out of scope here).
- **VS Code / Copilot** (spec quickstart): looks in `.agents/skills/` by default and
  surfaces `/skills` as the list command — evidence for both the directory convention
  and the command names below.
- **Claude Code** (present on this machine): flat `~/.claude/skills/<name>/SKILL.md`,
  one level, no recursion.

DashFloat's seams today: the tool catalogue is static (`DashFloat.Tools` — one params
table drives schema and validation), `DashFloat.Agent` owns the conversation and holds
no system prompt yet (#71 will add one with named seams, and its issue already
promises a skills-injection seam), there is no command surface (#69 will add the
registry), tool execution is sandboxed to `cwd` by `DashFloat.Tools.PathPolicy`, and
mutations are confirmation-gated per ADR 0007. There is no YAML dependency.

## Decision

### 1. Format scope

Implement the spec's core: `SKILL.md` with the frontmatter contract above, bundled
files as data. Optional frontmatter fields are accepted-if-well-formed and discarded
(DashFloat has no use for them today); unknown fields are ignored (forward
compatibility). `allowed-tools` is deliberately **not honored** — see §8.

### 2. Discovery

Two fixed roots, resolved at session start (Agent `init`):

- **Project:** `<cwd>/.agents/skills/` — the convention the spec's tooling uses.
- **User:** `DashFloat.Config.config_dir()/skills` (`~/.config/dashfloat/skills`,
  `XDG_CONFIG_HOME` respected — same base as `settings.json5`).

One level deep: each child directory of a root is a skill candidate; a candidate must
contain `SKILL.md`. Dot-prefixed and symlinked child directories are skipped (a
symlinked root would make "inside the skill" ambiguous for §5). No recursion (the spec's
name-matches-directory rule implies flat layout; recursion buys nesting DashFloat does
not need), and no config-supplied extra roots in v1.

On name clash across roots, **project wins** (the closer-to-the-work skill is the one
the repo means); the shadowed user skill produces a warning. Catalog order is
alphabetical by name.

### 3. Frontmatter parsing and validation

No YAML dependency: a strict purpose-built parser for the subset the spec's fields
require — flat `key: value` scalar lines (surrounding single or double quotes optional)
plus `metadata` as one nested level of string scalars. Anything else (sequences,
multiline scalars, anchors, tags) is a validation error. Validation enforces the §1
caps and charset, `name` == directory name, and a non-empty body.

Failure posture is **skip-and-warn**: an invalid, unreadable, oversized, or duplicate
skill is excluded and produces a warning string carrying its path and reason. Bad
skills never crash a session and never silently disappear. The `SKILL.md` body is
size-gated by `stat` before reading and capped at 64 KiB (the `read_file` byte cap) —
oversized bodies are skipped and warned, not truncated: an oversized skill is author
error, and the fix is splitting per the spec's own guidance.

### 4. Progressive disclosure

Three stages, matching the spec:

1. **Metadata** — the skill names and descriptions ride the system prompt's skills
   section (the #71 seam, §7). This is the only place skills are advertised; tool
   descriptions stay static.
2. **Activation** — a new `skill` tool loads one skill: the model calls it by name and
   receives the frontmatter summary, the full body, and the skill's absolute directory
   (needed for §5).
3. **Resources** — bundled files are read on demand through the `skill` tool's optional
   `file` parameter (§5), and bundled scripts run through `execute_command` exactly as
   any command would (same confirmation gate).

### 5. The `skill` tool

- Name: `skill`. Arguments: `name` (required, non-empty string), `file` (optional,
  non-empty string — a path relative to the skill root).
- Automatic, like `read_file` — no confirmation (it only reads, and only from
  already-discovered skills).
- Success: `%{ok: true, name: ..., dir: <absolute skill dir>, content: <body>}`; with
  `file`, the content is that file's (byte-capped at 64 KiB, `truncated` flag when cut).
- `file` is contained to the skill root: relative only, no `..` segments, no component
  may be a symlink. This is why user-level skills need it — their directories sit
  outside the `PathPolicy` `cwd` sandbox, so `read_file` cannot reach them; the `skill`
  tool is their sanctioned reader. Project-level skills could be read either way; one
  mechanism for both is simpler.
- Unknown `name`: `%{ok: false, error: "unknown skill ..." }` **listing the available
  names** (or "no skills installed") so the model self-corrects in one round trip.
- The tool is advertised unconditionally (the catalogue stays static, six tools,
  present even when zero skills are installed — the error result above is the honest
  answer then). The skill directory is exposed to the model in results: scripts under
  it run only through the existing, confirmation-gated `execute_command`.

### 6. Invocation surface

- **Automatic on relevance** is primary: the model reads the catalog (§7) and calls the
  `skill` tool when a task matches a description.
- **Explicit**, via the commands registry (#69), registering two names that match the
  spec tooling's own conventions:
  - `/skills` — list name, description, and source (project/user) in the log, plus any
    discovery warnings; re-runs discovery first so newly added skills appear without a
    restart (discovery is a cheap pure scan).
  - `/skill <name>` — force-activation for the user: posts a synthetic user turn in a
    fixed form ("Use the skill \"name\" for this task."). The model still loads it
    through the `skill` tool — the proven path — rather than DashFloat injecting
    instructions out-of-band. Unknown name warns on screen.

### 7. The system-prompt seam contract (for #71)

The skills subsystem exposes `DashFloat.Skills.catalog_section/1` — a pure renderer
from discovered skills to a Markdown section: one line per skill (`name — description
(source)`), preceded by a short instruction to load a skill via the `skill` tool when —
and only when — a task matches its description. It returns an empty string for an empty
skill set, and the prompt assembler omits the section entirely then. What #71 calls the
seam is theirs to name; this function is the single thing they invoke.

### 8. Security posture

A skill is **untrusted data, never code DashFloat executes**. Concretely:

- DashFloat never runs anything from a skill directory on its own; bundled scripts run
  only when the model issues `execute_command`, under ADR 0007's confirmation gate.
  Loading a skill grants no capabilities.
- `allowed-tools` is parsed for validity and ignored — honoring it would pre-approve
  mutations and contradict ADR 0007's confirmation model. Skills must not be able to
  weaken the gates.
- The catalog shows provenance (project vs user), so the user can see when a cloned
  repo shipped skills into the session.
- Discovery reads only from the two fixed roots; no skill can widen them.
- A malicious skill body is a prompt-injection vector — the same trust class as any
  file the model reads in a repo (README, AGENTS.md). The defense is that nothing the
  instructions can say bypasses the tool gates; skip-and-warn keeps malformed content
  from entering context at all.

## Alternatives considered

- **Catalog in a dynamically-described tool** (Octofriend's live pattern): rejected —
  DashFloat's catalogue is deliberately static (one table, one contract), and #71
  already commits to a prompt seam for skills. The dead `<available_skills>` block in
  Octofriend suggests tool-description-only disclosure is an awkward fit alongside a
  prompt anyway.
- **Recursive discovery walk** (Octofriend): rejected — flat matches the spec's
  name-matches-directory rule and every local reference implementation; recursion adds
  traversal cost and symlink surface for nothing.
- **A YAML dependency** (`yamerl` & co.): rejected — the frontmatter contract is a
  handful of scalar fields; a strict ~50-line parser with reject-what-we-don't-parse
  keeps the dependency count flat and the accepted format explicit.
- **Injecting full skill bodies into the system prompt**: rejected — defeats
  progressive disclosure; the catalog is metadata only.
- **First-wins (user-root) clash precedence** (Octofriend's effective order): rejected
  in favor of project-wins — a repo shipping a same-named skill almost certainly means
  to override the user's generic one.
- **Hiding the `skill` tool when no skills exist** (Octofriend returns null): rejected
  — conditional advertisement makes the catalogue dynamic for a cosmetic win; the
  "no skills installed" error is honest and cheaper.
- **An installer/offer flow** (Octofriend's Herdr-skill offer): out of scope for v1.

## Consequences

- Six tools in every request; `skill` sits in the automatic tier next to `read_file`.
- Skills work end-to-end without #71/#69 (the tool + its self-describing errors), but
  *relevance-driven* activation needs the catalog (S3) and user-forced activation
  needs the registry (S4) — the cross-lane contracts above are what keep the three
  lanes from colliding.
- The accepted frontmatter subset is narrower than full YAML; legitimate-but-exotic
  skills are skipped with a warning that says why. Widening later is additive.
- Discovery cost at session start is two directory listings plus size-gated reads of
  the `SKILL.md` files found — bounded and synchronous in `init`.
- Biggest risk: seam-name drift with the #71 and #69 lanes (both unbuilt). Mitigated
  by the fixed contracts in §6–§7; each blocked slice re-checks the landed seam before
  wiring.

## Implementation slices

Each slice is self-sufficient; S1 → S2 are buildable immediately, S3 and S4 wait on
their lanes. Merge order is otherwise free. All slices: `mix ci` green before PR.

### S1 — `DashFloat.Skills` discovery core (pure)

New `lib/dash_float/skills.ex` + `test/dash_float/skills_test.exs`. No changes
elsewhere. A pure module (no processes): `discover(cwd) :: {skills, warnings}` where
each skill is `%DashFloat.Skills.Skill{name, description, source, dir, body}`,
`source` is `:project` | `:user`, results alphabetical by name. Implements §2–§3
exactly: roots (`DashFloat.Config.config_dir()/skills` and `<cwd>/.agents/skills`),
one-level scan skipping dot-dirs and symlinks, the strict frontmatter parser (flat
scalars + one-level `metadata` map; quotes optional; anything else invalid), spec
validation (charset `^[a-z0-9]+(-[a-z0-9]+)*$`, ≤64, name == dirname, description
1–1024, compatibility ≤500 when present, non-empty trimmed body, 64 KiB body cap via
`stat` before read), project-wins clash precedence, and a warning string (path +
reason) for every skip.

**Done when:** `mix test test/dash_float/skills_test.exs` passes and its cases cover:
a valid project skill discovered; a user+project name clash resolves to the project
skill with a warning; each of uppercase name, name ≠ dirname, missing description,
oversized description, empty body, oversized body, symlinked skill dir, and
non-frontmatter `SKILL.md` is skipped with a warning; and `mix ci` is green.

### S2 — the `skill` tool (catalogue entry, runner, agent wiring)

Touches `lib/dash_float/tools.ex` (params/description/order — six tools),
`lib/dash_float/tools/runner.ex` (a `"skill"` clause taking the discovered list from
new opts key `:skills`), `lib/dash_float/agent.ex` (`automatic?("skill")`, `skills:`
in state discovered at `init` via S1, passed through `dispatch_runner`'s opts), plus
tests. The runner implements §5: `name` required, `file` optional with
root-containment checks (relative, no `..`, no symlink components), 64 KiB content
cap with `truncated` flag, unknown-name error listing available names or reporting
"no skills installed". Warnings from discovery are dropped in this slice (no UI outlet
yet; S4 surfaces them).

**Done when:** a driven e2e test (SSEServer loopback, per-connection scripts, existing
agent-loop test pattern) shows: episode 1 returns a `skill` tool call for a fixture
skill; the follow-up request's tool message contains the body and `"ok":true`; a
second scenario's unknown-name call returns an error listing the fixture's name; unit
tests cover `file` containment (`../` rejected, absolute rejected, symlinked component
rejected); `mix ci` green.

### S3 — system-prompt catalog section (blocked on #71)

`catalog_section/1` per §7 in `DashFloat.Skills`, wired into whatever seam ADR-0071's
implementation lands (re-check its name there before wiring; the contract in §7 is
fixed). Catalog is rendered once at session start and rides every request's system
content; omitted entirely when no skills.

**Done when:** a driven e2e test asserts, via the request seam, that the outbound
system content contains the catalog line (`name — description (source)`) for a fixture
skill, and that a no-skills session's system content omits the section; `mix ci` green.

### S4 — commands: `/skills` and `/skill <name>` (blocked on #69)

Registers the two commands per §6 into the registry #69 lands (re-check its
registration shape before wiring). `/skills` re-runs discovery, updates the agent's
skill state, and renders name/description/source plus any warnings to the log via the
existing `{:entry, :system, ...}` display path; `/skill <name>` posts the fixed
synthetic user turn and warns on screen for unknown names or when no skills exist.

**Done when:** a driven e2e test shows: `/skill <name>` produces an outbound request
whose last user message is the fixed turn and the model's `skill` tool call round-trips
its body; `/skills` with an invalid fixture renders that fixture's warning line;
`/skill bogus` warns on screen; `mix ci` green.
