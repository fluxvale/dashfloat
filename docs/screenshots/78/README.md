# Issue #78 — the reasoning block: capture evidence

All captures driven by `scripts/capture.py` against the real TUI under a
real pty, over the mock's `reasoning_content` stream (a prompt containing
"think"). Every act is ASSERTED before its frame/still ships.

| File | Claim |
| --- | --- |
| `01-reasoning-block.gif` | The whole interaction: the live block grows in its auto-following 8-row tail window (head out of sight, tail visible), finalize collapses to `◔ Thinking · 24 tokens · 2.1s`, Ctrl+R expands (`└ 1–8/24`), arrow keys scroll inside, `End` reaches `└ 17–24/24` and the stored tail, Ctrl+R folds back to the one summary line. |
| `02-reasoning-no-yank.gif` | The #131 principle over the block's live growth: the view parked two wheel-ups off the tail freezes (`L149-160` held) while the thinking streams below (`/total 166 → 172`). |
| `03-collapsed-dark.png` / `05-collapsed-light.png` | The collapsed form: one summary line, thinking absent from the chat, both palettes. |
| `04-expanded-dark.png` / `06-expanded-light.png` | The expanded form: hinted header, `│`-railed 8-row window, `└` position footer, chat lines intact below. |
| `07-resume-expanded-tail.png` | Resume truth: the session file carries the full 24-line `reasoning_content`; the resumed app replays a statless block (`◔ Thinking`), and the inner scroll reaches the STORED tail. |

The glyph is `◔` (both rig fonts cover it; the first cut's `✻` rendered blank
in the mono fonts — measured, then replaced).
