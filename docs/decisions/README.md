# Architecture Decision Records

This directory contains Architecture Decision Records (ADRs) for DashFloat.

## Format

Each ADR uses a lightweight Nygard-style format:

- **Status** — Accepted / Superseded / Deprecated
- **Date** — when the decision was made
- **Context** — the forces at play and the problem being solved
- **Decision** — what we chose
- **Alternatives considered** — what we rejected and why
- **Consequences** — what this decision implies, including trade-offs

## Numbering

Files are prefixed with a 4-digit padded sequence number starting at `0001`.
Numbers are never reused. Superseded ADRs keep their number and gain a link to
their replacement.

## Index

| ADR | Title | Status |
| --- | ----- | ------ |
| [0001](0001-founding-stack-and-architecture.md) | Founding stack and architecture | Accepted |
| [0002](0002-tui-skeleton.md) | TUI skeleton: process shape, event flow, and terminal lifecycle | Accepted |
| [0003](0003-ci-gate-and-coverage-ratchet.md) | CI gate and coverage ratchet | Accepted |
| [0004](0004-credo-fleet-ruleset.md) | Credo ruleset pinned to the FluxVale fleet config | Accepted |
| [0005](0005-llm-streaming-engine.md) | LLM streaming engine: SSE adapter process architecture | Accepted |
| [0006](0006-ui-truth-and-rendering.md) | UI truth & rendering: markdown log, live status, activity line, input hardening | Accepted |
| [0007](0007-tool-calls-and-execution.md) | Tool calls & execution: agent loop, five tools, path policy, confirmations | Accepted |
| [0008](0008-config-layout-profiles-json5.md) | Config layout v2: single-file JSON5 with profiles | Accepted |
| [0009](0009-config-v3-persona-profiles.md) | Config layout v3: persona profiles, endpoint-keyed keys, deliberate selection, onboarding | Accepted |
| [0010](0010-release-packaging.md) | Release packaging: core `mix release` tarballs, installer, Homebrew | Accepted |
| [0011](0011-boot-tty-and-clean-refusal.md) | Boot-time terminal detection, the clean refusal, and libsctp in the release | Accepted |
| [0012](0012-runner-dead-before-monitor-is-cancelled.md) | A runner dead before its monitor goes up is cancelled, not crashed | Accepted |
| [0013](0013-exec-pgid-tracked-at-spawn.md) | Exec's process group is tracked at spawn, not queried from the port at reap | Accepted |
| [0014](0014-session-persistence.md) | Session persistence: transcript store, resume, dangling repair, pinning | Accepted |
| [0015](0015-input-surface-cursor-stats-ghost.md) | Input surface: blinking cursor, stats footer, model-driven ghost text | Accepted |
| [0016](0016-interaction-modes.md) | Interaction modes: the confirmation boundary becomes a mode setting (Plan / Build / Auto / Unchained) | Accepted |
| [0018](0018-image-attachments.md) | Image attachments: capability flag, content parts, visible refusal | Accepted |
| [0019](0019-session-system-prompt.md) | Session system prompt: Octofriend-pattern assembly, AGENTS.md chain injection, pinned through compaction | Accepted |
| [0020](0020-command-surface.md) | Command surface: slash commands, Ctrl+P palette, runtime model/profile/mode/title switching | Accepted |
| [0021](0021-synthetic-repair-and-web-search.md) | Synthetic repair and web search: fix-json at the stream terminal, the search endpoint seam | Accepted |
| [0022](0022-context-accounting-and-compaction.md) | Context accounting and compaction: usage-frame anchor, chars/4 growth, 80% whole-turn eviction | Accepted |
| [0023](0023-session-titles-and-uuid-ids.md) | Session titles and UUID session ids: title normalization, uniqueness, resume by title, the auto-title nudge | Accepted |
