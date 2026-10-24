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
