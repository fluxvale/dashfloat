# DashFloat

A fast, robust CLI AI coding harness in Elixir — Octofriend's successor, owned
and built here.

DashFloat streams LLM responses, executes structured tool calls, and manages
coding sessions from the terminal. It is built on OTP concurrency — a pure
render-loop UI process, an agent-manager GenServer, stream-handler tasks, and
isolated subprocess execution — with an
[`ex_ratatui`](https://hex.pm/packages/ex_ratatui) TUI, packaged with core
[`mix release`](https://hexdocs.pm/mix/Mix.Tasks.Release.html) tarballs
([ADR 0010](docs/decisions/0010-release-packaging.md)).

Website: <https://dashfloat.com> — the landing page and these docs, rendered.

## Status

**Pre-alpha — Phase 2.** The LLM streaming engine is in
([ADR 0005](docs/decisions/0005-llm-streaming-engine.md)): an OpenAI-compatible
SSE client streams tokens into the existing TUI
([ADR 0002](docs/decisions/0002-tui-skeleton.md)). Next up per the
[ADR 0001](docs/decisions/0001-founding-stack-and-architecture.md) roadmap: tool
call execution, context management & history persistence.

## Install

```sh
curl -fsSL https://github.com/fluxvale/dashfloat/releases/latest/download/install.sh | sh
```

No Erlang or Elixir toolchain needed: the release bundles ERTS. The installer
verifies the tarball's sha256 before extracting, installs into
`~/.local/share/dashfloat/versions/<version>` behind a `current` symlink, puts
a shim in `~/.local/bin`, and prunes the previous version on upgrade. Pin a
version with `DASHFLOAT_VERSION=0.5.0`. On macOS, Homebrew is the native path
(`brew install fluxvale/tap/dashfloat`), and unsigned builds need a one-time
right-click-open — see the [release notes](https://github.com/fluxvale/dashfloat/releases).
Linux builds need glibc 2.34+ (Debian 12+, Ubuntu 22.04+), OpenSSL 3,
`libtinfo.so.6`, and `libstdc++.so.6`; the installer checks for those first
and names the package to install. Debian 11, Alpine/musl, Linux arm64, and
Windows are not supported yet. Packaging details:
[ADR 0010](docs/decisions/0010-release-packaging.md).

Update with `dashfloat update`: it detects how this copy was installed — an
installer layout is updated in place (checksum-verified download, atomic
swap, the new release is smoke-tested and rolled back on failure), a
Homebrew install prints the `brew upgrade dashfloat` handoff, and anything
else refuses with both options. `dashfloat update --check` only reports the
latest version (exit 0 current / 1 outdated / 2 unknown). Design:
[ADR 0026](docs/decisions/0026-update-command.md).

## Run it

Configure your providers — any OpenAI-compatible endpoints — in
`~/.config/dashfloat/settings.json5`. A profile is a persona (personal,
work) bundling several subscriptions (`providers[]`), each with its own model
menu, plus its own MCP servers; `defaultProfile` names the startup persona.
API keys live in a sibling `keys.json5`, nested per profile and keyed by the
provider's `baseUrl`, so the settings file (and every backup, dotfile sync,
or example of it) is structurally incapable of leaking a credential; both
files are 0600. An `oauth.json5` sibling is reserved for a future OAuth flow
(ignored until one exists). Legacy layouts — a v1 `config.json`, a v1
`settings.json5` with inline keys, or a v2 flat `keys.json5` — migrate
themselves on first run under a no-loss invariant: every credential value
lands somewhere retrievable or the migration refuses loudly with a remedy.
Backups inherit the source's sensitivity, so anything that ever held a
credential is 0600 wherever it lives:

```json5
// settings.json5 — no credential material, ever
{
  configVersion: 3,
  defaultProfile: 'personal',
  profiles: [
    {
      name: 'personal',
      defaultProvider: 'zai',       // optional label; absent = the first provider
      providers: [
        // label optional too — it defaults to the URL host ('api.z.ai' here)
        { label: 'zai', baseUrl: 'https://api.z.ai/api/coding/paas/v4',
          models: [{ nickname: 'glm-5.3', model: 'glm-5.3', context: 128000 }] },
        { baseUrl: 'https://api.synthetic.new/openai/v1',
          models: [{ model: 'hf:deepseek-ai/DeepSeek-V3-0324' }] },
      ],
      mcp: [                        // storage shape; tokens are env references
        { name: 'fetch', command: 'uvx', args: ['mcp-server-fetch'], token: '$FETCH_TOKEN' },
      ],
    },
  ],
}
```

```json5
// keys.json5 — the only home for API keys, keyed by endpoint
{
  personal: {
    'https://api.z.ai/api/coding/paas/v4': 'PLACEHOLDER',
    'https://api.synthetic.new/openai/v1': '$SYNTHETIC_API_KEY',  // env reference
  },
}
```

**Profile selection is deliberate:** no flag → `defaultProfile`; an unknown
`defaultProfile` (say, hand-deleted) warns and a TUI modal forces a choice;
`--profile <name>` (or `DASHFLOAT_PROFILE`) selects explicitly, and an
unknown name is a hard error listing the valid ones. With zero profiles and
no env config, a first-run wizard walks you through naming a profile, adding
a provider (Z.AI Coding Plan and Synthetic presets, or any custom
OpenAI-compatible URL), pasting a key, and picking a model — every step
skippable, files written 0600 as you go.

`DASHFLOAT_BASE_URL`, `DASHFLOAT_MODEL`, `DASHFLOAT_API_KEY`, and
`DASHFLOAT_CONTEXT_TOKENS` override the files per field (the effective API
key is `DASHFLOAT_API_KEY`, else `keys[profile][baseUrl of the active
provider]`); `--model <nickname>` selects a model within the active
provider's menu. A stray inline `apiKey` in settings.json5 is warned about
and ignored — never a fallback. The status footer names the active
provider and model `provider - model` (preset URL → `zai`/`synthetic`,
else the settings label, else the URL host). Put your provider's own base
URL in `baseUrl`;
DashFloat appends `/chat/completions`. At startup DashFloat also refreshes
the model catalog from each of the active profile's providers (`GET
{baseUrl}/models`, fail-open, in-memory): a model's reported context window
(`context_length`) refreshes the footer's denominator when your entry
carried no `context` — fetched models are not added to your menus, and
nothing is written back to your config.

**The context window resolves itself** ([ADR 0022](docs/decisions/0022-context-accounting-and-compaction.md)'s
#111 amendment): your entry's `context` (or `DASHFLOAT_CONTEXT_TOKENS`)
wins; else the provider's `/models` metadata when it carries it; else the
standard presets' seeded windows (the Z.AI GLM current generation's
documented 1M windows, Synthetic's first-party catalog); else a documented
128 Ki default — marked `~` in the footer (`1.2k/~131.1k · 0.9%`) and
noted in `/compact`'s reply, naming the key to set. A stock config shows
`used/window · percent` from boot; nothing is ever guessed silently.

Profile settings also accept a `compaction` object (e.g.
`settings: { compaction: { instructions: 'keep the design decisions' } }`) —
reserved for the upcoming compaction summaries; it is accepted without a
warning and has no effect yet.

Damaged configs degrade with warnings, never crashes: a deleted
`defaultProfile`, a mistyped `profiles` list, junk entries — each names the
field and falls back to the least-surprising working state. An unparseable
file is a loud error naming the path and is never auto-overwritten.

Details: [ADR 0009](docs/decisions/0009-config-v3-persona-profiles.md).

The v1→v2 split never loses a credential silently: if a key it is about to
remove would end up in no file (a pre-existing `keys.json5` that wins without
holding that exact value, and a `settings.json5.bak` that cannot be
re-written), startup fails with `cannot split settings.json5: … no home`.
The error's remedies are real: add the key under its profile name to
`keys.json5`, or move the stale backup aside
(`mv settings.json5.bak settings.json5.bak.old` — the next start tightens
the moved file to 0600 automatically) so the next start can write
a fresh one. A `settings.json5.bak` that is a symlink is never read
through or replaced — it counts as no backup, and the split refuses if a
key would be lost. A v1 file whose profiles carry no `providers` tree but
mix in v3-only fields — a hand-merged `defaultProfile`, or `mcp` — is
refused before anything is written; remove those fields and re-run (the
chain then migrates the file to v3 and re-derives `defaultProfile`;
re-add anything you removed, and move a root-level `apiKey` into
`keys.json5` under the profile the refusal names). A file whose profiles
already carry `providers` keeps the set-`configVersion: 3` remedy, inline
keys included — it converges there. The v2→v3 reshape follows the same
invariant (dead keys only drop behind a fresh `keys.json5.bak`; duplicate
profile names with keys, keyless endpoints, and v3-shaped files missing
`configVersion: 3` all refuse with remedies in the message). Details:
[ADR 0008](docs/decisions/0008-config-layout-profiles-json5.md) and
[ADR 0009](docs/decisions/0009-config-v3-persona-profiles.md). Then:

```sh
dashfloat
```

From a source checkout, `mix run --no-halt` runs the same TUI.

Type a prompt and press Enter: tokens stream into the log and the status bar
flips Streaming → Idle when the reply completes. Press Esc mid-stream to cancel
— the partial reply is kept and a gray `[cancelled]` line marks it. Shift+Enter
inserts a newline on terminals that report enhanced key events (kitty
protocol, modifyOtherKeys) — on others, use Alt+Enter. Up/Down walk input
history, PageUp/PageDown and the mouse wheel scroll the log. Ctrl+Q quits; a
double Ctrl+C does too (one press shows a prompt, the second within two
seconds exits). Click-drag over the log selects text — highlighted live,
copied to your system clipboard on release via OSC 52 (works over SSH). Hold
Shift while dragging to use the terminal's own selection instead.

Without a provider configured the TUI still starts; submitting logs the setup
instructions instead of a reply. This live-key run is the manual smoke step —
the test suite is offline and deterministic (recorded SSE fixtures plus a
loopback server).

**The reading surface stays parked.** The transcript snaps to its tail only
when you send — Enter on a message or a slash command alike; typing, pasting,
a dropped attachment, a scroll — all of it leaves the view exactly where the
reader parked it, and a reply streaming in while you are scrolled up never
yanks it back (the [ADR 0006](docs/decisions/0006-ui-truth-and-rendering.md)
amendment). The status footer reports honest speed ([ADR
0015](docs/decisions/0015-input-surface-cursor-stats-ghost.md)'s #130
amendment): `ttft 1.4s` (send → first token) appears with the turn's first
streamed token, and a completed reply is joined by `32 tok/s` — a
whole-response average, total tokens over the reply's own decode window,
never the live instantaneous value that flatters the tail. Both spans
persist after the turn ends and retire at the next send; when the footer
gets tight, the cwd drops before either stat does. A two-row gap breathes
between the transcript and the composer.

**Model thinking gets a block of its own** ([ADR
0005](docs/decisions/0005-llm-streaming-engine.md) + [ADR
0006](docs/decisions/0006-ui-truth-and-rendering.md) amendments). While the
model reasons, a live eight-row window grows in place, tail-following; when
the reply lands it collapses to one summary line — `◔ Thinking · 342 tokens
· 8.1s`. Ctrl+R expands the most recent block: arrows, PageUp/PageDown, Home
and End scroll inside it while it holds focus (Enter still sends, typing
still reaches the composer), the wheel scrolls inside when the notch lands
on the block, and Esc or Ctrl+R folds it back. A thinking turn's full
reasoning is saved with the session and replays on resume as the same
collapsed block.

![The reasoning block: live growth, the collapsed summary line, Ctrl+R expand, scrolling inside, collapse](https://raw.githubusercontent.com/fluxvale/dashfloat/main/docs/screenshots/78/01-reasoning-block.gif)

**Tool calls are structured and gated.** Seven tools ship — `read_file`,
`list_directory`, `write_file`, `edit_file`, `execute_command`, `web_search`
(needs a Synthetic key), and `question` — under four interaction modes cycled
with Shift+Tab ([ADR 0016](docs/decisions/0016-interaction-modes.md)): Plan
previews a call and never runs it, Build (the default) runs safe calls and
asks before anything else, Auto never asks, and Unchained runs everything
unchecked. `/mode` selects by name.

**Asking renders as a choice in the input field** ([ADR
0028](docs/decisions/0028-choice-widget-and-ask-user.md)). An approval
replaces the composer with `Approve write_file?` and a fixed [Approve,
Reject] set — arrows move, Enter answers, Esc rejects — and any draft you
were typing sits underneath and returns after. The model can ask you
directly through the same widget: its `question` tool renders labelled
options — single-select with arrows + Enter, multi-select with Space
toggling (an empty submit means "none of these"), and Esc answers an
explicit `cancelled`, never a silent drop. The answer returns to the model
as the tool's result, in every mode.

![An approval rendered as a multiple-choice question in the composer](https://raw.githubusercontent.com/fluxvale/dashfloat/main/docs/screenshots/133/approve-as-choices.gif)

**Auto mode runs or refuses.** Safe calls execute silently, and anything the
safety check flags — or a check that itself fails — is refused on the spot,
the reason recorded in the transcript and returned to the model as
`{"ok":false,"blocked":"auto","reason":…}` so it can adapt.

**Sessions persist.** Every turn is saved under
`~/.local/share/dashfloat/sessions/` (`XDG_DATA_HOME` respected) — one JSON
file per session, mode 0600, because a transcript carries code and tool
output read from your disk. Each session is named by a time-sorting UUID id
(`0192ab4c-1e5f-7d3a-9b8c-2d4e6f8a1b3c`); list them with
`ls ~/.local/share/dashfloat/sessions/`. Name a new session at start with
`dashfloat --title "My session"`, and pick a conversation back up with
`dashfloat --resume <id-or-title>` — the id is the UUID file name, the title
is the session's unique title (a title that would duplicate another session's
is refused at creation or rename, so a title resolves to one session or the
resume refuses) — the transcript replays in the log and your next send continues
it. Sessions created by older versions are renamed to UUID ids automatically
at startup. A session records the profile and model it started under;
resuming under a different one warns and continues, and the session keeps its
pin. When the configured context window is roughly 80% full, the oldest
complete turns are dropped to stay inside it — a visible notice names the
count, and the session file records what was dropped. A malformed or
newer-version session file refuses loudly, naming the path — it is never
auto-deleted or rewritten. Details:
[ADR 0014](docs/decisions/0014-session-persistence.md).

Getting back in is one command. Quitting with a session behind you prints
the way back — `dashfloat --resume <title>` (the title, shell-quoted) or,
untitled, `dashfloat --resume <id>`; nothing prints when nothing persisted.
From inside a session, `/resume` opens a keyboard-navigable picker over
saved sessions — title or first-message preview, relative time, profile ·
model, most recent first; Enter switches in place, Esc cancels untouched.
Design: [ADR 0027](docs/decisions/0027-exit-resume-command-and-resume-picker.md).

![The /resume session picker](https://raw.githubusercontent.com/fluxvale/dashfloat/main/docs/screenshots/128/01-resume-picker.gif)

## Stack

- [Elixir](https://elixir-lang.org) 1.20 / Erlang/OTP 29
- [`ex_ratatui`](https://hex.pm/packages/ex_ratatui) — TUI (Rustler-backed
  ratatui bindings, precompiled NIFs)
- [`req`](https://hex.pm/packages/req) — HTTP / SSE streaming
- [`jason`](https://hex.pm/packages/jason) — JSON

## Development

```sh
mix ci
```

`mix ci` is the whole gate — the same list CI runs, so local and CI cannot
drift ([ADR 0003](docs/decisions/0003-ci-gate-and-coverage-ratchet.md)):
format, compile with warnings as errors, `credo --strict`, `dialyzer`, and the
test suite under ExCoveralls with a coverage floor (`coveralls.json`). It
fetches any missing deps itself — there is deliberately no separate
`mix deps.get` first, as it would silently repair a stale lock before the gate
could catch it. Coverage counts shipped code only: the test harness
(`test/`) is excluded via `skip_files`, so the floor guards `lib/`.

CI runs it on every pull request and every push to `main`, uploads the HTML
coverage report as an artifact, and sends the JSON report to Codecov. The
required branch-protection check is **Wait for CI**. See
[AGENTS.md](AGENTS.md) for the repository conventions.

## License

MIT — see [LICENSE](LICENSE).
