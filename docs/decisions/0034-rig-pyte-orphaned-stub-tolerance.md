# 0034 — The rig's pyte screen tolerates orphaned wide-char stubs

- **Status:** Accepted
- **Date:** 2026-11-02
- **Issue:** [#160](https://github.com/fluxvale/dashfloat/issues/160)

## Context

Issue #160 (surfaced by the #143 lane's full-menu smoke) reported the three
image scenarios — `attach` (still + gif), `drop-image` (gif) — dying inside
pyte 0.8.2 under Python 3.14: `screens.py`'s `display` property raising
`IndexError: string index out of range` at `wcwidth(char[0])`.

The mechanism, established on the lane: pyte renders every wide (2-cell)
glyph as a lead cell plus a `data=""` stub cell. When the app's redraw
reaches the terminal as two pty chunks — the first overwriting a wide
glyph's lead cell with a narrow one, the second rewriting the stub — the
stub is **orphaned** between the chunks, and `display`'s `char[0]`
IndexErrors on the empty string. The rig's poller (`wait_for` → `text()` →
`display`, deliberately outside the feed lock) can always land in that
window. The image scenarios are the locus because their 📎 rows are the
only content that is *both* wide *and* dynamically rewritten next to narrow
text; the CJK scenarios type wide text append-only, so they never orphan.

Investigation on the lane disproved the Python-3.14 attribution:

- The crash is **not** deterministic on 3.14 — the same three scenarios
  passed three consecutive runs on Python 3.14.8 + pyte 0.8.2 in the
  unmodified worktree. The #143 lane's reds were the race landing, not a
  version gate.
- pyte's only Python-version-sensitive input is `unicodedata`
  (combining classification, NFC) — and the app's byte stream contains no
  combining marks, so the interpreter version cannot change what pyte
  parses or renders. All widths come from the `wcwidth` package's fixed
  tables, which are pure Python.
- The app's own width classifier (`DashFloat.TUI.Wrap`) agrees with
  wcwidth on every glyph the scenarios emit (📎 = 2, CJK = 2, ❯ = 1), so
  there is no layout disagreement to desync the stream either.

## Decision

1. The rig drives a **`RigScreen(pyte.Screen)`** whose `display` property
   renders an orphaned stub as a blank cell — exactly what a real terminal
   shows for a wide glyph's leftover continuation cell — instead of
   indexing `char[0]`. Every other cell renders through pyte 0.8.2's own
   semantics, byte-identically (verified against stock `pyte.Screen` on
   narrow, wide, and end-of-row-wrap content). Both screen construction
   sites — the live screen and the GIF replay screen — use it.
2. The rig venv's setup line in `capture.py`'s docstring pins its packages
   exactly (`pyte==0.8.2 wcwidth==0.9.4 pillow==13.0.0`): the rig's
   rendering is only reproducible across capture lanes if every lane runs
   the same width tables and image encoder.

## Alternatives considered

- **Bump pyte to a release supporting Python 3.14** (the issue's first
  candidate) — no such release exists: 0.8.2 (2024) is the latest, and
  the fix exists only on unreleased master (whose rendering semantics
  did change — grapheme clusters, per-cluster `wcswidth`; untested
  against this rig's asserted frames). A git-commit pin would also make
  the venv setup fragile.
- **Pin the rig venv to Python 3.13** (the issue's second candidate) —
  treats a symptom the interpreter does not cause. The race exists on
  every Python version; the pin would add rig tooling (a version manager
  constraint or a second interpreter) and leave the crash latent for the
  next loaded overnight run.
- **Upstream first** — correct long-term, but the rig must be whole now;
  the shim is ~12 lines. When a pyte release finally lands, removing it
  is a deliberate diff, not a free deletion: master survives empty
  stubs but yields nothing for them (the row renders one char shorter),
  where `RigScreen` preserves the column with a blank.

## Consequences

- The rig no longer crashes on pyte's own transient intermediate state,
  on any Python version; the three image scenarios are green and the
  full menu (41 invocations: every argparse scenario in primary mode plus
  the secondary gif/probe modes) stays green.
- A still or GIF frame captured mid-redraw may show a one-cell blank
  where a wide glyph's lead was just overwritten — honest: that is the
  instant's real terminal state, and later frames carry the settled row.
- Rebuilding the venv without the pins (the old unpinned line) may
  silently change rendering across lanes; the docstring setup is the
  documented reproducible path.
