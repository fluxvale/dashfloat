# Issue #78 — hostile review record

## Round 1 — the lane review (fresh-context glm-5.3, own read-only worktree, same host)

Verdict: **FIX-FIRST** — 1×P1, 1×P2, 6×P3. Full text: the reviewer's
`/tmp/opencode/df78-review-findings.md`; findings and dispositions:

| # | Severity | Finding | Disposition |
| --- | --- | --- | --- |
| 1 | P1 | The wire strip dropped only the ATOM key `:reasoning_content`; resumed sessions load STRING-keyed messages (Jason), so the next prompt after `--resume`/`/resume` leaked the full thinking on the wire — DeepSeek-class endpoints 400 (ADR 0005's own rationale). | **Fixed**: `Map.drop(&1, [:reasoning_content, "reasoning_content"])` + the resume-path regression test (`agent_test`: "a RESUMED transcript's reasoning never rides the wire"). |
| 2 | P2 | Ctrl+R/Esc expand-collapse inserts/removes ~8 display rows mid-log without touching a selection below the block — the highlight (and the OSC-52 copy) lands on the wrong content; the resize path clears for exactly this reason. | **Fixed**: `clear_selection_from/2` on both toggle arms — a selection whose anchor sits at/after the block's first row clears; one entirely above survives (rows below an anchor never move it). Test: "a selection below the expanded block clears; one above survives". |
| 3 | P3 | Wheel scoping missed the log rect's right-edge x bound. | **Fixed**: `x < log.x + log.width`. |
| 4 | P3 | The episode-cap test never proved reasoning bytes count toward the 4 MiB budget. | **Fixed**: three of the nine half-MiB blobs in the cap test are now reasoning frames. |
| 5 | P3 | No test pinned reasoning-beside-`tool_calls` persistence (the `begin_tool_batch` shape). | **Fixed**: "a tool-batch turn persists its thinking beside the tool_calls". |
| 6 | P3 | The collapsed-block wheel unit test was vacuous (no-op either way). | **Fixed**: the log is long enough to scroll now — the notch unfollows the transcript while the block's inner view stays 0. |
| 7 | P3 | `.credo.exs` prose said "50" while the value moved to 52. | **Fixed** (prose now states 52 and names issue #78's one nested field). |
| 8 | P3 | ADR live-header shorthand `<deltas>` vs the rendered `24 tokens`. | **Fixed** (the ADR now spells `<N> tokens`). |

Verified green by the reviewer (their own runs): capture (both spellings,
silent misses), the exact collapsed format, expand/collapse/one-at-a-time/
focus⇔expanded, inner keys+wheel scoped and clamped, resize re-clamp,
no-yank (frames show `L149-160` frozen while `/total` grew), finalize
collapse, statless replay, cancel/crash/DOWN keep partial thinking,
light+dark legible, no key leakage, no scope creep. The reviewer re-ran the
suite (802 passed in their checkout) and the hermetic resume capture.

## Round 2 — the delta re-check (same reviewer, fresh diff)

**Round-2 verdict: P1 and all P3s CONFIRMED** (each new test proven
revert-discriminating; no collateral from `Map.drop`). **One hole found in
the P2 fix**: `clear_selection_from/2` keyed on the selection's FROM row —
a selection SPANNING the block's first row (anchored above, dragged into
the block) survived with corrupted highlight/copy; empirically proven by
the reviewer (the copied text changed from the selected rows to the
block's `│` rows). Disposition: **fixed** — the clear now keys on the
selection's TO row: any selection reaching at or below the block's first
row clears; only one ending entirely above survives. Round-1 finding 7
(`.credo.exs` "50") was the reviewer's own false positive — the baseline
prose already read 52.

## Round 3 — the spanning fix re-checked

**Round-3 verdict: SHIP** — the `to_row >= top` predicate is correct and
complete (probe-proven: a selection spanning from above clears, one ending
strictly above survives; `Selection.range` normalization makes the
destructure sound); no other behavior changed. The reviewer's two nits
(the regression test anchoring one row too low, and this doc's duplicated
heading) were fixed in the same commit. Review closed: three rounds,
FIX-FIRST → FIX-FIRST → SHIP; the full review text lives in the lane's
session records.

---
