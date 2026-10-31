# Changelog

All notable changes to DashFloat are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project adheres
to [Semantic Versioning](https://semver.org/). A version's date is the date its
tag was cut (`git for-each-ref --sort=creatordate refs/tags`).

Maintenance: every release-prep lane updates this file in the same PR as the
version bump — the release-notes template in `.github/workflows/release.yml`
and this changelog must never drift. The date of a pending section is filled in
when its tag is cut.

## [Unreleased]

### Added

- Quitting DashFloat with an ongoing session prints the command that reopens it — `dashfloat --resume <title-or-id>`, the title (shell-quoted) when one is set, else the UUIDv7 id; nothing prints when nothing persisted (#127).
- `/resume` opens a keyboard-navigable picker over saved sessions — title or first-message preview, relative time, provider · model, most recent first; Enter switches in place, Esc cancels untouched (#128).
- `dashfloat update` checks the latest GitHub release against the running version and updates the installation: install.sh installs are replaced in place (sha256-verified download, atomic swap, a start-up smoke of the new release, rollback on failure), Homebrew installs print the `brew upgrade dashfloat` handoff, and anything else refuses with both options (#122).
- `dashfloat update --check` is the scriptable form — prints the latest version, exits 0 when current, 1 when outdated, 2 when the check itself failed (offline and rate-limited are visible refusals).

### Changed

- Dependency bump: `ex_ratatui` 0.17.1 → 0.19.0 (`rustler_precompiled` rides to 0.10.1; OTP 29 now loads its own NIF-2.18 precompile instead of the 2.17 ABI build). Rendered output verified pixel-identical by frame-hash comparison of pty captures, and the idle cursor blink re-measured at its recorded 2.0 renders/s / ~50 B per frame.

## [0.4.0] - 2026-10-31

### Added

- Herdr support: inside a Herdr pane DashFloat reports its state — idle, working, or blocked with the pending decision named — and a restored Herdr session reopens DashFloat running the right `dashfloat --resume` command (#113).
- Context windows work out of the box: seeded windows for the stock presets, observed `context_length` from a provider's fetched model list, and a documented 131 072-token default that is visibly marked when assumed — the footer's tokens/percent and `/compact` no longer sit dead on a stock config (#111).
- Bare `/title` opens a rename dialog pre-filled with the live title; a refused rename renders in the dialog with the draft kept (#106).
- Tab completes the highlighted slash command while the autocomplete popup shows matches (#105).
- Dragging an image file into the terminal attaches it as a numbered `[Image #n]` chip in the composer; Backspace on an empty draft pops the newest chip (#112).

### Changed

- Transcript user entries render bold behind an accent `❯` marker — distinguishable from assistant replies on every palette, light or dark, and through session-resume replay (#107).
- The whole interface insets two cells from the screen edges instead of one — transcript, status line, composer, and popups (#108).
- The footer's model span names provider and model (`zai - glm-5.3`) instead of the profile label, updating on `/model` picks (#109).
- The composer's idle cursor blinks on a 500 ms timer (#104).
- Any composer edit snaps the transcript back to the tail; cursor focus alone does not (#110).

### Fixed

- Resuming a session saved with 0.3.0's assembled system prompt crashed at startup, and the release launcher exited 1 on any user flag (`--resume`, `--title`, … were dropped into Elixir's CLI) — both found and fixed in #116's Herdr restore work.

## [0.3.0] - 2026-10-30

### Added

- Session titles: `--title` at start, resume by id-or-title, a model-proposed title once the conversation is underway, and `/title` rename at runtime; titles are unique.
- The first-run wizard fetches the provider's model list into a keyboard-navigable picker, with manual entry as the explicit last option and ESC back-navigation that preserves answers.
- Slash commands `/model`, `/profile`, `/mode`, `/title` with `/` autocomplete and a Ctrl+P palette.
- An assembled system prompt per session, with `AGENTS.md` discovery from the working directory up to the git root.
- Synthetic fix-json repair for malformed tool calls and a `web_search` tool — both need a Synthetic key.
- A bright idle cursor on every terminal palette; the placeholder hint shows only before the first exchange.
- `/compact` manual compaction with visible feedback; at or under the ~80% trigger it reports where the context stands.
- Live footer context stats: tokens used and percent of the context window.
- Image attachments via Ctrl+O (PNG, JPEG, GIF, WebP up to 10 MiB), validated before they sit in the composer and refused visibly on non-image-capable models.

## [0.2.0] - 2026-10-30

### Added

- Session persistence and resume: every turn is saved as it happens; `dashfloat --resume <id>` replays the transcript and the next message continues it.
- A sharper composer: a cursor that blinks while the agent works, a dim footer with working directory, active model, and live tok/s, and a greyed next-input suggestion (Tab accepts).
- Context accounting and ~80% drop-oldest compaction, with a visible notice naming the dropped-turn count.
- Interaction modes Plan / Build / Auto / Unchained on Shift+Tab; modes bind what the agent may do unattended, explicit answers always outrank them.

## [0.1.1] - 2026-10-29

### Added

- LGPL-2.1-or-later redistribution notice for the bundled `libsctp.so.1` in the release notes.

### Fixed

- The first-run wizard was unreachable in the release; a headless boot now refuses cleanly (exit 1, no crash dump) instead of spewing.
- The exec group-kill leak and the pre-monitor runner misreport.
- The v1+v3 config interleave is refused before the split writes anything; refusal blame is honest, model-id enumeration works, and remedies are glyph-wrapped.
- Release smokes: bullseye's apt points at the Debian archive, binutils installs before the Linux artifact smoke, and `/etc/os-release` no longer clobbers the version.

## [0.1.0] - 2026-10-27

### Added

- Initial packaged release: a CLI AI coding harness in the terminal — a markdown-rendered transcript with live status truth, and tool calls parsed, confirmed, executed, and round-tripped.
- json5 profile configuration: persona profiles, endpoint-keyed keys split into `keys.json5`/`oauth.json5`, auto-migration, onboarding, deliberate selection, and model catalog refresh.
- Terminal UI: comfortable margins, word-wrapped log, mouse selection/copy and wheel scrolling routed to the log, and a double Ctrl+C exit guard.
- First-run wizard for provider setup, with write refusals surfaced and completion gated on real writes.
- Packaging per ADR 0010: `mix release` tarballs for Linux x86_64 and macOS (aarch64 + x86_64), a sha256-verifying installer, and Homebrew-ready artifacts; plus a static landing and docs site at dashfloat.com.
