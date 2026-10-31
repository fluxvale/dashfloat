#!/usr/bin/env python3
"""Real-TUI capture rig for DashFloat — the capture convention (issue #91).

Drives the REAL app (`mix run --no-halt`) under a REAL pty against a
built-in OpenAI-compatible mock, renders the terminal byte stream (pyte)
to PNG stills and GIF motion (PIL), and probes the idle render rate
(bytes reaching the terminal over a window with no input).

Everything is pty-driven end to end: no widget dumps, no test-mode
buffers. The captures are ground truth for visual and motion claims.

One-time setup (any venv; kept outside the repo):

    python3 -m venv /tmp/opencode/capvenv
    /tmp/opencode/capvenv/bin/pip install pyte pillow

Usage (from a worktree root, against the CURRENT tree's code):

    scripts/capture.py still --scenario first-run  --out FILE.png
    scripts/capture.py still --scenario mid-session --no-ghost --out FILE.png
    scripts/capture.py still --scenario ghost       --out FILE.png
    scripts/capture.py still --scenario compact-session    --out FILE.png
    scripts/capture.py still --scenario slash-autocomplete --out FILE.png
    scripts/capture.py probe [--window-ms 1500] [--after-exchange]
    scripts/capture.py gif   --out FILE.gif
    scripts/capture.py gif   --scenario slash-autocomplete --out FILE.gif
    scripts/capture.py gif   --scenario growing-session --context 4096 --out FILE.gif

Reading-surface captures (issues #107 + #108):

    scripts/capture.py still --scenario reading-session --style-claim user-bold \
        --margin 2 --out FILE.png          # AFTER: user rows bold, 2-cell margin
    scripts/capture.py still --scenario reading-session --style-claim all-plain \
        --margin 1 --out FILE.png          # BEFORE: nothing bold, 1-cell margin
    scripts/capture.py still --scenario reading-session --style-claim user-bold \
        --palette light --margin 2 --out FILE.png   # bold reads on light too
    scripts/capture.py still --scenario resume-session --style-claim user-bold \
        --margin 2 --out FILE.png          # replayed turns keep the distinction
    scripts/capture.py still --scenario reading-session --cols 120 --margin 2 \
        --out FILE.png                     # wide terminal, same margin
    scripts/capture.py still --scenario slash-autocomplete --margin 2 \
        --out FILE.png                     # popup alignment at 80 cols

Provider-span captures (issue #109): point the scratch settings
at any endpoint (a REAL preset URL boots fine — the footer resolves
its label at render time; no chat request is needed — the boot-time
catalog refresh still ATTEMPTS GET {baseUrl}/models at the real endpoint
and fails open, which is offline-safe), drop the provider's label,
drive a /model switch, and ASSERT the footer span before the still
is written — a capture whose claim is unverified fails, never ships.

    scripts/capture.py still --scenario first-run --base-url https://api.z.ai/api/coding/paas/v4 \
        --expect-label "zai - Sol" --out FILE.png
    scripts/capture.py still --scenario mid-session --no-ghost --unlabeled \
        --expect-label "127.0.0.1 - Sol" --out FILE.png
    scripts/capture.py still --scenario model-switch \
        --expect-label "mock - glm-5.3-flash" --out FILE.png

Title-dialog captures (issue #106): one app run over a TITLED fixture
session (resumed) plus a SECOND fixture session holding another title.
Five stills, each asserted before it is written:

    scripts/capture.py still --scenario title-dialog \
        --out 01-dialog-open.png --out2 02-dialog-refusal.png \
        --out3 03-dialog-success.png --out4 04-dialog-esc.png \
        --out5 05-inline-unchanged.png

Scenarios:
    first-run   fresh session: composer empty, no exchanges yet
    mid-session after one completed exchange: composer empty again
                (--no-ghost pins the BLANK composer: with suggestions on,
                 the suggester's ghost lands there — the ghost is its own
                 scenario)
    ghost       after a completed exchange + suggest side-request landed
    growing-session
                two completed exchanges whose usage frames grow the
                footer's tokens-used span (issue #67 stage 2); pass a
                small --context (4096) so the percent is legible
    compact-session
                a resumed fixture session (two ~20 KB turns, no anchor) over
                the 80% trigger of its 20000-token window: /compact drops the
                oldest turn and the [context: dropped ...] entry lands
    slash-autocomplete
                the draft is "/" (still) or "/c" mid-typing (gif): the
                command popup, /compact included
    attach      the attach flow on an IMAGE-CAPABLE model (ADR 0018): the
                scratch settings carry images: true and a fixture PNG;
                Ctrl+O opens the attach prompt, the path is typed and
                attached (pending chip 📎), the prompt is submitted, the
                reply streams, and the log shows the 📎 indicator lines
                (gif: the whole interaction)
    attach-refusal
                the same attach attempt on a NON-capable model: the
                visible [images: …] refusal entry in the log (nothing sent)
    drop-image  the drag-and-drop flow (issue #112, ADR 0018 amendment) on
                an IMAGE-CAPABLE model: a bracketed-pasted image path
                becomes the [Image #1] chip (never path text), a second
                paste numbers #2, Backspace pops the newest chip, and the
                submit streams the reply with its 📎 indicator rows (gif)
    drop-refusal
                the same drop on a NON-capable model: the visible refusal,
                no chip, no typed path (still)
    idle-blink  the idle cursor blink (issue #104): no input at all, the
                composer cursor toggles at the recorded cadence — the
                frame rate is asserted in a bounded band BEFORE the gif
                (the ADR's measured renders/s)
    tab-complete
                "/mod" + Tab completes to "/model " (popup closes), then
                "/c" + down + Tab completes the ARROW-SELECTED "/compact "
                (issue #105; ADR 0020 amendment) — each act asserted
    enter-snap  a resumed 40-turn log, two wheel-ups unfollow (the tail's
                last line scrolls off), TYPING keeps the view exactly in
                place, Enter — and only Enter — re-pins to the tail
                (issue #131, reversing #110) — asserted act by act
    scrolled-stream
                a reply streaming while the view is parked two wheel-ups
                off the tail: the window freezes (only the /total grows)
                and the footer carries ttft alone — no live tok/s (issues
                #130/#131)
    breathing-gap
                two exchanges, snapped to the tail: the two blank rows of
                air above the composer are asserted before the still
                (issue #129)
    gap-scrolled
                the same air asserted two wheel-ups into mid-history —
                the gap holds in both scroll states (issue #129)
    ttft-footer
                one turn, two stills: mid-stream (ttft alone, no live
                tok/s) and after finalize (the exact `ttft Ns · N tok/s`
                pair) — both asserted before shooting (issue #130)
    reading-session
                two completed exchanges so user/assistant alternate in the
                log (issues #107/#108 stills). Asserts, before the still:
                the style claim (--style-claim: `user-bold` — user row text
                bold + accent ❯ prefix, assistant rows plain — or
                `all-plain`, the #107 bug shape) and, when --margin N is
                passed, that every rendered row starts at column N and ends
                N clear of the right edge.
    resume-session
                boots from a fixture session (user+assistant turns) via
                --resume and asserts the replayed log keeps the SAME
                style claim — replay rides the one styler
    resume-picker
                the /resume picker (issue #128): /resume opens the modal
                over two fixtures — the titled newest first, the preview
                row second — ↓ moves, ⏎ adopts, and the replayed log
                renders the adopted turns (still or GIF; the GIF is the
                motion capture)
    exit-print  the exit print (issue #127): one exchange persists and
                auto-titles the session, Ctrl+Q exits, and the printed
                command lands on the post-exit screen (the still); the
                printed line is then run VERBATIM (shlex word-split, the
                shell's own paste semantics) in a second app over the
                same scratch store, which must reopen and replay that
                session
    model-switch
                /model → the catalog picker opens, ↓ picks the other
                entry, ⏎ swaps — the footer's model part follows the pick
                (issue #109); pair with --expect-label to assert it
    title-dialog
                a resumed TITLED fixture session (issue #106): bare /title
                opens the dialog pre-filled, a held title refuses IN the
                dialog naming the holder id, a free title renames and
                closes, Esc cancels untouched, and /title <name> inline
                still lands its entry with no dialog — five stills, every
                act asserted before its still is written
    probe       idle frame-rate: bursts of tiny one-cell diffs, ~2/s
                since the idle blink (issue #104) — bounded, never large;
                0 bursts would mean the blink died
    reasoning-block (issue #78, GIF): a "think" prompt streams the mock's
                reasoning_content — the live block grows in its bounded
                tail window, collapses to the one summary line at finalize,
                Ctrl+R expands it into the scrollable window, arrow keys
                scroll INSIDE, Ctrl+R folds it back — asserted act by act
    reasoning-stills (issue #78): the collapsed and expanded states, one
                app run, two stills (--out collapsed, --out2 expanded);
                pair with --palette light for the light capture
    reasoning-scroll (issue #78, GIF): thinking streaming while the view
                is parked two wheel-ups off the tail: the window freezes
                (the #131 principle holds for the block's live growth too)
    reasoning-resume (issue #78): a thinking turn persists, the app exits,
                and a resumed run replays the block from the STORED
                content — expanded, the inner scroll reaches the stored
                tail (the full thinking survived); the session file's
                reasoning_content is asserted against the fixture text

The scratch root is hermetic: XDG_CONFIG_HOME and XDG_DATA_HOME both point
at it, so settings, keys, and session files (including the compact-session
fixture) land in the scratch — never in the user's real ~/.config or
~/.local/share.

The mock answers SSE streams (`stream: true`), the suggest side-request,
the auto-title side-request, and /models — enough for a full session.
"""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import pty
import select
import struct
import sys
import termios
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pyte
import re
import shlex
from PIL import Image, ImageDraw, ImageFont

COLS, ROWS = 80, 24

# The scripted assistant reply: enough words to make streaming visible,
# short enough to keep turns snappy. Dripped one token at a time.
REPLY_TOKENS = (
    "Elixir ` processes ` run ` independently ` , ` supervised ` by ` the ` "
    "VM ` . ` A ` crash ` in ` one ` never ` touches ` the ` rest ` ."
).split(" ` ")

# The scripted thinking (issue #78): enough newline-separated lines to
# overflow the block's 8-row window, dripped as reasoning_content deltas
# before the answer. A prompt containing "think" (case-insensitive) opts
# the mock's reply into a thinking phase — every other scenario is
# byte-identical to before.
REASONING_LINES = [
    "consider what the user is really asking",
    "the question is about Elixir processes",
    "recall that processes are isolated",
    "supervision trees provide restarts",
    "links propagate exits, monitors do not",
    "a crash in one process cannot touch another",
    "the VM supervises the supervisors",
    "message passing is the only shared state",
    "mailboxes are per-process and ordered",
    "so the answer should lead with isolation",
    "then explain the supervision machinery",
    "keep it short — two sentences will do",
    "check the wording for accuracy",
    "supervised is the right adjective here",
    "the VM is the BEAM instance",
    "no need to mention schedulers",
    "the tail marker line is thinking alpha",
    "the tail marker line is thinking bravo",
    "the tail marker line is thinking charlie",
    "the tail marker line is thinking delta",
    "the tail marker line is thinking echo",
    "the tail marker line is thinking foxtrot",
    "the tail marker line is thinking golf",
    "the tail marker line is thinking hotel",
]
REASONING_TAIL_MARK = "thinking hotel"

GHOST_TEXT = "what happened next?"
TITLE_TEXT = "composer demo"

# The /title-dialog scenario's script (issue #106): the resumed fixture's
# own title (the pre-fill proof), a title a SECOND fixture session holds
# (the refusal names its holder id), a free title (the success), and the
# inline rename (the unchanged form).
TITLE_FIXTURE_TITLE = "Resume Me"
TITLE_HOLDER_TITLE = "Held Name"
TITLE_FREE_TITLE = "Fresh Name"
TITLE_INLINE_TITLE = "Inline Name"

FONT_CANDIDATES = [
    "/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf",
    "/usr/share/fonts/noto/NotoSansMono-Light.ttf",
]
FONT_CANDIDATES_BOLD = [
    "/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationMono-Bold.ttf",
]
# Emoji coverage (U+1F4CE 📎 et al.) the mono fonts lack: the first of
# these that exists draws any glyph the primary font cannot — a rig-side
# rendering fallback, the app's bytes are unchanged.
FONT_CANDIDATES_EMOJI = [
    "/usr/share/fonts/noto/NotoColorEmoji.ttf",
    "/usr/share/fonts/truetype/noto/NotoColorEmoji.ttf",
]
# CJK coverage (BMP-wide Han/Hangul glyphs — issue #139's footer captures)
# the mono fonts likewise lack: an outline font drawn at the cell's own
# size, same rig-side fallback idea as the emoji one.
FONT_CANDIDATES_CJK = [
    "/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc",
    "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
]

# A conventional dark-terminal palette; pyte names -> hex.
PALETTE = {
    "default": "#c5c8c6",
    "black": "#1d1f21",
    "red": "#cc6666",
    "green": "#b5bd68",
    "yellow": "#f0c674",
    "blue": "#81a2be",
    "magenta": "#b294bb",
    "cyan": "#8abeb7",
    "white": "#c5c8c6",
    "bright-black": "#6e6e6e",
    "bright-red": "#cc6666",
    "bright-green": "#b5bd68",
    "bright-yellow": "#f0c674",
    "bright-blue": "#81a2be",
    "bright-magenta": "#b294bb",
    "bright-cyan": "#8abeb7",
    "bright-white": "#ffffff",
}
DEFAULT_FG = "#c5c8c6"
DEFAULT_BG = "#1d1f21"

# A conventional light-terminal palette (#107): light bg, dark fg — the
# bold-default-fg user rows must read legible here too.
LIGHT_PALETTE = {
    "default": "#383a42",
    "black": "#383a42",
    "red": "#ca1243",
    "green": "#50a14f",
    "yellow": "#c18401",
    "blue": "#4078f2",
    "magenta": "#a626a4",
    "cyan": "#0184bc",
    "white": "#383a42",
    "bright-black": "#a0a1a7",
    "bright-red": "#ca1243",
    "bright-green": "#50a14f",
    "bright-yellow": "#c18401",
    "bright-blue": "#4078f2",
    "bright-magenta": "#a626a4",
    "bright-cyan": "#0184bc",
    "bright-white": "#090a0f",
}
LIGHT_DEFAULT_FG = "#383a42"
LIGHT_DEFAULT_BG = "#fafafa"

# Which family is active (set_palette): bold text approximates the way a
# terminal brightens bold glyphs — on a light palette the honest direction
# is darker, or bold would LOSE contrast and the capture would lie.
_LIGHT = False
_DARK_SCHEME = (PALETTE, DEFAULT_FG, DEFAULT_BG)
_LIGHT_SCHEME = (LIGHT_PALETTE, LIGHT_DEFAULT_FG, LIGHT_DEFAULT_BG)


def set_palette(name: str):
    global PALETTE, DEFAULT_FG, DEFAULT_BG, _LIGHT
    PALETTE, DEFAULT_FG, DEFAULT_BG = (
        _LIGHT_SCHEME if name == "light" else _DARK_SCHEME)
    _LIGHT = name == "light"


def color(value: str | None, fallback: str) -> str:
    if value in (None, "default"):
        return fallback
    if value in PALETTE:
        return PALETTE[value]
    if isinstance(value, str) and len(value) == 6:
        try:
            int(value, 16)
            return "#" + value
        except ValueError:
            pass
    return fallback


def cell_colors(ch) -> tuple[str, str]:
    """(fg, bg) hex for a pyte char, applying reverse video the way a real
    terminal does — a reversed default-on-default cell is a solid block of
    the default foreground (the classic TUI idle cursor)."""
    fg = color(ch.fg, DEFAULT_FG)
    bg = color(ch.bg, DEFAULT_BG)
    if getattr(ch, "reverse", False):
        fg, bg = bg, fg
    return fg, bg


def paint(draw, metrics, ch, px, py):
    """One terminal cell: background block first, then the glyph — from the
    emoji font, scaled into the cell, when the primary mono font cannot
    draw it (coverage probe via getmask; an empty mask is the tofu the app
    never sent)."""
    cell_w, cell_h, font = metrics
    fg, bg = cell_colors(ch)
    if bg != DEFAULT_BG:
        draw.rectangle([px, py, px + cell_w, py + cell_h], fill=bg)
    if ch.data and ch.data != " ":
        emoji = emoji_font()
        if not glyph_covered(font, ch.data):
            # CJK first, but only when the CJK font actually covers the
            # glyph (same .notdef probe as the primary font): the emoji
            # strike stays the fallback for everything the outline fonts
            # lack too — 📎 must keep its color font, never go tofu.
            cjk = cjk_font(font.size)
            if cjk is not None and glyph_covered(cjk, ch.data):
                draw.text((px, py), ch.data, font=cjk,
                          fill=fg if not ch.bold else _bold_fg(fg))
            elif emoji is not None:
                draw_emoji(draw, emoji, ch.data, px, py, cell_w, cell_h)
        else:
            draw.text((px, py), ch.data, font=font,
                      fill=fg if not ch.bold else _bold_fg(fg))


# Coverage probe: a missing glyph renders the font's .notdef — the same
# mask as U+0378, a permanently unassigned codepoint no font maps. Byte-
# equal masks (or an empty mask) mean "not covered — try the emoji font".
_NOTDEF_MASKS: dict[int, bytes | None] = {}


def glyph_covered(font, text: str) -> bool:
    raw = mask_bytes(font.getmask(text))
    if id(font) not in _NOTDEF_MASKS:
        _NOTDEF_MASKS[id(font)] = mask_bytes(font.getmask("\u0378"))
    notdef = _NOTDEF_MASKS[id(font)]
    return raw is not None and raw != notdef


def mask_bytes(mask) -> bytes | None:
    """An ImagingCore mask as bytes — None for the empty mask."""
    return bytes(mask) if mask.size else None


# The emoji fallback font, resolved once per process (the None memo means
# "no emoji font on this machine — render exactly as before").
_EMOJI_FONT = None
_EMOJI_RESOLVED = False


def emoji_font():
    global _EMOJI_FONT, _EMOJI_RESOLVED
    if not _EMOJI_RESOLVED:
        _EMOJI_RESOLVED = True
        for path in FONT_CANDIDATES_EMOJI:
            if os.path.exists(path):
                try:
                    # CBDT bitmap strikes: 109 is the size Pillow accepts
                    # for NotoColorEmoji; the draw scales it into the cell.
                    _EMOJI_FONT = ImageFont.truetype(path, 109)
                except OSError:
                    _EMOJI_FONT = None
                break
    return _EMOJI_FONT


_CJK_FONTS: dict[int, object] = {}


def cjk_font(size):
    """The first installed CJK outline font at `size` — memoized per size
    (the .ttc is ~19 MB; reopening it per uncovered cell would crawl in a
    GIF replay) — or None when no candidate exists or loads."""
    if size not in _CJK_FONTS:
        _CJK_FONTS[size] = None
        for path in FONT_CANDIDATES_CJK:
            if os.path.exists(path):
                try:
                    _CJK_FONTS[size] = ImageFont.truetype(path, size)
                    break
                except OSError:
                    continue
    return _CJK_FONTS[size]


def draw_emoji(draw, font, glyph, px, py, cell_w, cell_h):
    """Render the emoji at its fixed strike onto a scratch image, thumbnail
    to the cell, paste — the only way a CBDT color font fits a cell."""
    scratch = Image.new("RGBA", (160, 160), (0, 0, 0, 0))
    sdraw = ImageDraw.Draw(scratch)
    try:
        sdraw.text((8, 8), glyph, font=font, embedded_color=True)
        box = scratch.getbbox()
        if not box:
            return  # nothing rendered — leave the cell as-is
        crop = scratch.crop(box)
        crop.thumbnail((cell_w, cell_h))
        draw._image.paste(crop, (px, py), crop)
    except (ValueError, OSError):
        pass


def _brighten(hexcolor: str) -> str:
    r, g, b = (int(hexcolor[i:i + 2], 16) for i in (1, 3, 5))
    return "#%02x%02x%02x" % (min(255, r + 48), min(255, g + 48), min(255, b + 48))


def _darken(hexcolor: str) -> str:
    r, g, b = (int(hexcolor[i:i + 2], 16) for i in (1, 3, 5))
    return "#%02x%02x%02x" % (max(0, r - 48), max(0, g - 48), max(0, b - 48))


def _bold_fg(hexcolor: str) -> str:
    """Bold glyphs read as a pushed-toward-the-extreme fg: brighter on a
    dark palette, darker on a light one (_LIGHT)."""
    return _darken(hexcolor) if _LIGHT else _brighten(hexcolor)


def scratch_dir() -> str:
    """The per-run scratch root: config and data (XDG_CONFIG_HOME and
    XDG_DATA_HOME) both live here, so captures never touch the user's
    real home."""
    return f"/tmp/opencode/dashfloat-capture-{os.getpid()}"


def write_compact_fixture(scratch: str, turn_bytes: int = 20_000) -> str:
    """The compact-session fixture: a session file whose two user/assistant
    turns carry `turn_bytes`-sized messages (~bytes/4 heuristic tokens each)
    and no anchor. Resumed under a 20000-token window the default fixture
    (~20000 tokens) sits over the 80% trigger (16000) with two droppable
    turns — /compact drops exactly the oldest one. `turn_bytes` >1.7 MiB
    crosses the trigger of the SEEDED 1M window (issue #111's stock capture).
    Returns the session id."""
    session_id = str(uuid.uuid4())
    messages = []
    for turn in ("one", "two"):
        filler = f"turn {turn} filler " + "x" * (turn_bytes - 15)
        messages.append({"role": "user", "content": filler})
        messages.append({"role": "assistant", "content": filler})
    sessions = f"{scratch}/dashfloat/sessions"
    os.makedirs(sessions, exist_ok=True)
    with open(f"{sessions}/{session_id}.json", "w") as f:
        json.dump({
            "version": 1,
            "id": session_id,
            "created_at": "2026-10-30T00:00:00Z",
            "messages": messages,
        }, f)
    return session_id


def write_image_fixture(scratch: str) -> str:
    """The attach-flow fixture image (ADR 0018): a few hundred bytes with a
    PNG magic header — nothing decodes the image (the data URL is base64 of
    whatever bytes are there), so a stub payload is honest. Returns the
    ABSOLUTE path (the attach prompt's typed input)."""
    path = f"{scratch}/shot.png"
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + b"\x11" * 300)
    return path


def write_snap_fixture(scratch: str, turns: int = 40) -> str:
    """The typing-snap fixture (issue #110): `turns` numbered user/assistant
    exchanges — enough wrapped rows to overflow any 24-row viewport several
    times, with a UNIQUE tail ("turn <last> done") the capture can prove
    visible-or-not. Returns the session id."""
    session_id = str(uuid.uuid4())
    words = ["one", "two", "three", "four", "five", "six", "seven",
             "eight", "nine", "ten"]
    messages = []
    for n in range(1, turns + 1):
        body = f"turn {words[(n - 1) % 10]} of the snap fixture, line {n}"
        messages.append({"role": "user", "content": f"question {n}"})
        messages.append({"role": "assistant", "content": body})
    messages[-1]["content"] += " — turn forty done"
    sessions = f"{scratch}/dashfloat/sessions"
    os.makedirs(sessions, exist_ok=True)
    with open(f"{sessions}/{session_id}.json", "w") as f:
        json.dump({
            "version": 1,
            "id": session_id,
            "created_at": "2026-10-31T00:00:00Z",
            "messages": messages,
        }, f)
    return session_id


def write_reading_fixture(scratch: str) -> str:
    """The resume-session fixture (#107): two short user/assistant turns.
    Resumed with --resume, the log is rebuilt by replay — the capture
    proves the replayed user rows keep the bold/accent styling."""
    session_id = str(uuid.uuid4())
    messages = [
        {"role": "user", "content": "what is elixir?"},
        {"role": "assistant",
         "content": "Elixir processes run independently, supervised by the VM."},
        {"role": "user", "content": "and the supervision tree?"},
        {"role": "assistant", "content": "A crash in one never touches the rest."},
    ]
    sessions = f"{scratch}/dashfloat/sessions"
    os.makedirs(sessions, exist_ok=True)
    with open(f"{sessions}/{session_id}.json", "w") as f:
        json.dump({
            "version": 1,
            "id": session_id,
            "created_at": "2026-10-31T00:00:00Z",
            "messages": messages,
        }, f)
    return session_id


TITLED_MESSAGES = [
    {"role": "user", "content": "what is elixir?"},
    {"role": "assistant",
     "content": "Elixir processes run independently, supervised by the VM."},
]


def write_titled_fixture(scratch: str, title: str, messages=None) -> str:
    """A titled session file (the /title dialog's fixture, issue #106): the
    map carries a `title` (the ADR 0023 additive field), resumable like the
    compact fixture. Returns the session id."""
    session_id = str(uuid.uuid4())
    sessions = f"{scratch}/dashfloat/sessions"
    os.makedirs(sessions, exist_ok=True)
    with open(f"{sessions}/{session_id}.json", "w") as f:
        json.dump({
            "version": 1,
            "id": session_id,
            "created_at": "2026-10-31T00:00:00Z",
            "title": title,
            "messages": messages if messages is not None else TITLED_MESSAGES,
        }, f)
    return session_id


PICKER_MESSAGES = [
    {"role": "user", "content": "fixture question one"},
    {"role": "assistant",
     "content": "Fixture answer one — replayed by the picker."},
    {"role": "user", "content": "fixture question two"},
    {"role": "assistant",
     "content": "Fixture answer two, also replayed."},
]


def write_picker_fixture(scratch: str, title, age_seconds: int) -> str:
    """One /resume-picker fixture (issue #128): a session stamped
    `age_seconds` ago (the relative-time row reads a real bucket), titled
    when `title` is a string, else previewing its first question. The two
    fixture turns are unique needles the capture can prove replayed."""
    session_id = str(uuid.uuid4())
    sessions = f"{scratch}/dashfloat/sessions"
    os.makedirs(sessions, exist_ok=True)
    body = {
        "version": 1,
        "id": session_id,
        "created_at": time.strftime(
            "%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - age_seconds)),
        "pin": {"profile": "demo", "model": "glm-5.3", "base_url": None},
        "messages": PICKER_MESSAGES,
    }
    if title is not None:
        body["title"] = title
    with open(f"{sessions}/{session_id}.json", "w") as f:
        json.dump(body, f)
    return session_id


def content_text(content) -> str:
    """A message's content as text, tolerating content-parts lists (ADR
    0018 §2): an image turn's user message carries
    [{"type": "text", ...}, {"type": "image_url", ...}] — the text parts
    concatenate, the data URLs are skipped (their base64 would drown the
    signal)."""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "".join(
            part.get("text", "")
            for part in content
            if isinstance(part, dict) and part.get("type") == "text"
        )
    return ""


def content_bytes(content) -> int:
    """The content's byte length for the mock usage frame — a list-content
    message counts its parts (text bytes + data-URL bytes), mirroring the
    accounting heuristic (ADR 0022 §1) that list-content messages weigh by
    their parts."""
    if isinstance(content, str):
        return len(content.encode())
    if isinstance(content, list):
        total = 0
        for part in content:
            if not isinstance(part, dict):
                continue
            if part.get("type") == "text":
                total += len((part.get("text") or "").encode())
            elif part.get("type") == "image_url":
                url = part.get("image_url") or {}
                total += len((url.get("url") or "").encode())
        return total
    return 0


class MockHandler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass  # silence — the mock never talks over the capture

    # The interaction-surface captures (issues #133/#134/#135): a FIFO of
    # scripted episodes — ("tools", [(id, name, args_json), ...]) a
    # tool-calling episode, ("text", "...") that prose. DEAD, kept only so
    # the episode-dependent scenarios still enqueue: nothing pops this
    # queue (the consumer was lost in the #133–#135 era; #142 deleted its
    # unused corpse and this note replaced the false claim), so those
    # scenarios cannot regenerate — see issue #143 for the wire-or-drop
    # decision. The vet's own fresh-context completion is detected by its
    # instruction and answered with VET_REPLY (issue #135's still).
    EPISODES: list = []
    VET_REPLY = '{"decision":"confirm","reason":"deletes files outside the project"}'

    def _json(self, payload, status=200):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.endswith("/models"):
            self._json({"data": [{"id": "glm-5.3"}, {"id": "glm-5.3-flash"}]})
        else:
            self._json({}, 404)

    def do_POST(self):
        if not self.path.endswith("/chat/completions"):
            self._json({}, 404)
            return
        length = int(self.headers.get("Content-Length", 0))
        req = json.loads(self.rfile.read(length) or b"{}")
        system = " ".join(content_text(m.get("content", ""))
                          for m in req.get("messages", [])
                          if m.get("role") == "system")
        if req.get("stream") is True:
            self._sse(req)
        elif "title" in system:
            self._json({"choices": [{"message": {"content": TITLE_TEXT}}]})
        else:
            self._json({"choices": [{"message": {"content": GHOST_TEXT}}]})

    # The AUTO safety check (ADR 0016 §6): a fresh-context user message
    # whose prose is the vetter's static instruction.
    @staticmethod
    def is_vet_request(req):
        users = [m for m in req.get("messages", []) if m.get("role") == "user"]
        if not users:
            return False
        return "safety check" in content_text(users[-1].get("content", ""))

    def _sse(self, req):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        # A realistic first-token delay (issue #130): the request's own
        # network + prefill latency before decode begins — ttft reads
        # honestly instead of rounding to 0.
        time.sleep(0.3)
        # The thinking phase (issue #78): a "think" prompt drips the
        # reasoning lines first, one delta per line at the reply's cadence.
        users = [m for m in req.get("messages", [])
                 if m.get("role") == "user"]
        thinks = any("think" in content_text(m.get("content", "")).lower()
                     for m in users)
        reasoning_deltas = 0
        if thinks:
            for i, line in enumerate(REASONING_LINES):
                # No trailing newline on the last line — the wrapped row
                # count the captures assert is exactly len(REASONING_LINES).
                tail = "\n" if i < len(REASONING_LINES) - 1 else ""
                frame = {"choices": [{"delta": {
                    "reasoning_content": line + tail}}]}
                self.wfile.write(f"data: {json.dumps(frame)}\n\n".encode())
                self.wfile.flush()
                time.sleep(0.09)
                reasoning_deltas += 1
        for token in REPLY_TOKENS:
            frame = {"choices": [{"delta": {"content": token + " "}}]}
            self.wfile.write(f"data: {json.dumps(frame)}\n\n".encode())
            self.wfile.flush()
            time.sleep(0.13)
        self._usage_and_done(req, reasoning_deltas)

    def _usage_and_done(self, req, reasoning_deltas):
        # The usage frame mirrors what a real provider reports: the request's
        # own size in tokens (bytes/4 over the messages — the same heuristic
        # ADR 0022 §1 uses between frames), so the footer's tokens-used span
        # grows turn over turn as the conversation accumulates. A
        # list-content message (an image turn, ADR 0018 §2) counts its
        # parts' bytes through content_bytes.
        prompt_tokens = sum(content_bytes(m.get("content"))
                            for m in req.get("messages", [])) // 4
        usage = {"choices": [], "usage": {
            "prompt_tokens": prompt_tokens,
            "completion_tokens": 34 + reasoning_deltas}}
        self.wfile.write(f"data: {json.dumps(usage)}\n\n".encode())
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()


class App:
    """The real TUI under a real pty, plus the capture operations."""

    # The stock-config capture (issue #111) pins the REAL Z.AI preset URL:
    # the seeded window keys on it, and the scenario makes no provider
    # request (a resumed /compact is offline; the catalog refresh 401s
    # fail-open with the fake key).
    ZAI_BASE_URL = "https://api.z.ai/api/coding/paas/v4"

    def __init__(self, mix_args=("run", "--no-halt"), no_ghost=False,
                 context=524288, resume=None, images=False, cols=COLS,
                 rows=ROWS, base_url=None, unlabeled=False, model="glm-5.3",
                 nickname="Sol"):
        self.cols, self.rows = cols, rows
        self.sink = None  # callable(bytes) set during read loop
        self.screen = pyte.Screen(cols, rows)
        self.stream = pyte.ByteStream(self.screen)
        # The FULL byte history from boot (t, chunk): a GIF replay must
        # start at boot so static chrome (borders, labels, footer, log)
        # exists in every frame — replaying only the recorded window's
        # diffs would silently drop it (#91 review finding).
        self._chunks: list[tuple[float, bytes]] = []
        self._mark: float | None = None  # the GIF window's start time
        self._total = 0
        self._loud_total = 0   # bytes of LOUD writes only (see _read)
        self._last_loud = time.monotonic()
        self._alt = False  # saw the app enter the alternate screen
        # GIF-replay freeze (delta re-review): while gif() replays the byte
        # history into its own screen, the reader thread must NOT feed new
        # bytes into the same pyte stream — the interleaving reorders the
        # stream (a later diff applied, then an earlier one re-applied)
        # and blanks cells in the painted frames. The feed lock makes the
        # freeze+swap atomic against the reader's record+feed; frozen
        # bytes are queued and drained into the live screen on exit.
        self._frozen = 0
        self._feed_lock = threading.Lock()

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), MockHandler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        port = self.server.server_address[1]

        scratch = scratch_dir()
        os.makedirs(f"{scratch}/dashfloat", exist_ok=True)
        # --base-url (issue #109): point the scratch settings at any
        # endpoint — a REAL preset URL boots fine, no chat request is
        # sent until a prompt is submitted and the footer resolves its
        # label at render time (the mount-time catalog refresh still
        # attempts GET {baseUrl}/models there and fails open — offline-safe,
        # silent).
        base = base_url or f"http://127.0.0.1:{port}/v1"
        # --unlabeled (issue #109): drop the settings label AND the
        # defaultProvider that names it — the provider entry degrades to
        # its URL host (ADR 0015 §2's amendment, rung c).
        label_field = "" if unlabeled else "      label: 'mock',\n"
        default_field = "" if unlabeled else "    defaultProvider: 'mock',\n"
        # The images flag rides the models entry (ADR 0018 §1): the attach
        # scenarios pin it true (capable) or leave it off (incapable).
        # context=None writes NO context field — the stock wizard shape
        # whose window must resolve from seed/default (issue #111).
        images_field = ", images: true" if images else ""
        context_field = f", context: {context}" if context is not None else ""
        with open(f"{scratch}/dashfloat/settings.json5", "w") as f:
            f.write(
                "{\n"
                "  configVersion: 3,\n"
                "  defaultProfile: 'demo',\n"
                "  yourName: 'demo',\n"
                "  profiles: [{\n"
                "    name: 'demo',\n"
                f"{default_field}"
                "    providers: [{\n"
                f"{label_field}"
                f"      baseUrl: '{base}',\n"
                f"      models: [{{ nickname: '{nickname}', model: '{model}'"
                f"{context_field}{images_field} }}],\n"
                "    }],\n"
                "  }],\n"
                "}\n"
            )
        with open(f"{scratch}/dashfloat/keys.json5", "w") as f:
            f.write("{ demo: { '%s': 'capture-mock-key' } }\n" % base)

        env = dict(os.environ)
        env.update({
            "XDG_CONFIG_HOME": scratch,
            # Sessions land under the XDG data dir (Session.dir/0) — point
            # it at the scratch too, so resume fixtures and saves stay
            # hermetic (never the user's ~/.local/share).
            "XDG_DATA_HOME": scratch,
            "TERM": "xterm-256color",
            # Dev may recompile on entry; keep that noise out of the boot.
            "MIX_ENV": "dev",
        })
        # The scenarios' premises (a stock config with NO context anywhere,
        # a specific model id) are env-sensitive: an ambient DASHFLOAT_*
        # pin in the operator's shell would silently reconfigure the
        # capture (issue #111 review F4). Scrub the lot — the scratch
        # settings and keys are the whole config.
        for var in list(env):
            if var.startswith("DASHFLOAT_"):
                del env[var]
        if no_ghost:
            env["DASHFLOAT_SUGGEST"] = "false"
        if resume:
            mix_args = ("run", "--no-halt", "--", "--resume", resume)
        self.pid, self.master = pty.fork()
        if self.pid == 0:
            os.chdir(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
            os.execvpe("mix", ["mix", *mix_args], env)

        fcntl.ioctl(self.master, termios.TIOCSWINSZ,
                    struct.pack("HHHH", self.rows, self.cols, 0, 0))
        self._alive = True
        self._reader = threading.Thread(target=self._read, daemon=True)
        self._reader.start()
        self.wait_boot()

    # -- plumbing ---------------------------------------------------------

    ALT_ENTER = b"\x1b[?1049h"

    # A real frame (full draw, redraw, streamed chunk) is comfortably over
    # this; the idle cursor blink's diff (issue #104) is a single reversed
    # cell plus cursor handling — a few dozen bytes, never this big.
    # KNOWN CAVEAT (review F7): a mid-stream spinner-only tick frame could
    # in principle land under this too — no scenario waits for quiet
    # mid-stream today; if one ever does, wait_for a content needle
    # instead of wait_quiet.
    QUIET_CHUNK_BYTES = 96

    def feed(self, chunk: bytes):
        """Feed the terminal emulator, discarding anything the app wrote
        BEFORE entering the alternate screen (boot logger noise lands
        there; the alt screen is where the TUI lives)."""
        if not self._alt and self.ALT_ENTER in chunk:
            pre, post = chunk.split(self.ALT_ENTER, 1)
            self.stream.feed(pre)
            self.screen.reset()
            self.stream.feed(self.ALT_ENTER + post)
            self._alt = True
        else:
            self.stream.feed(chunk)

    def _read(self):
        while self._alive:
            try:
                ready, _, _ = select.select([self.master], [], [], 0.05)
            except OSError:
                break
            if not ready:
                continue
            try:
                chunk = os.read(self.master, 65536)
            except OSError:
                break
            if not chunk:
                break
            now = time.monotonic()
            self._total += len(chunk)
            # "Loud" writes are real frames (full draws, redraws, stream
            # chunks); anything smaller is the idle cursor blink's
            # one-cell diff (issue #104) — periodic, tiny, and never a
            # reason to keep waiting for quiet.
            if len(chunk) >= self.QUIET_CHUNK_BYTES:
                self._loud_total += len(chunk)
                self._last_loud = now
            # The feed lock makes record+feed atomic against gif()'s
            # freeze+swap: a chunk is either fed live BEFORE the freeze or
            # drained into the live screen AFTER the replay — never fed
            # into the replay stream mid-loop, and never dropped.
            with self._feed_lock:
                self._chunks.append((now, chunk))
                if not self._frozen:
                    self.feed(chunk)
            if self.sink:
                self.sink(chunk)

    def wait_boot(self, timeout=120):
        """Boot + first frame + quiet: >= 600 ms with no LOUD write after
        >= 800 B, with the alternate screen entered (compile noise lands
        BEFORE the alt screen and can silence for a beat mid-build —
        without the alt gate a cold first run "boots" mid-compile and the
        first exchange times out). Since the idle blink (issue #104) an
        idle app still emits a tiny one-cell diff ~2x/s forever — those
        never reset the quiet window (QUIET_CHUNK_BYTES)."""
        deadline = time.monotonic() + timeout
        last_loud = self._loud_total
        quiet_since = None
        while time.monotonic() < deadline:
            time.sleep(0.1)
            if self._loud_total != last_loud:
                last_loud = self._loud_total
                quiet_since = None
                continue
            if self._total > 800 and self._alt:
                quiet_since = quiet_since or time.monotonic()
                if time.monotonic() - quiet_since >= 0.6:
                    if "first run" in self.text():
                        raise RuntimeError(
                            "the app booted the onboarding wizard — "
                            "the scratch config was not picked up")
                    return
        raise TimeoutError("app never booted quietly")

    def text(self) -> str:
        return "\n".join(row.rstrip() for row in self.screen.display)

    def wait_gone(self, needle: str, timeout=30, hold=1.0):
        """The inverse of wait_for: block until `needle` has been off the
        screen for `hold` seconds — a single absent poll can race a row
        mid-redraw, so absence must HOLD (a stream finalizing, an activity
        row retiring) before a capture asserts the settled state."""
        deadline = time.monotonic() + timeout
        gone_since = None
        while time.monotonic() < deadline:
            if needle in self.text():
                gone_since = None
            else:
                gone_since = gone_since or time.monotonic()
                if time.monotonic() - gone_since >= hold:
                    return True
            time.sleep(0.1)
        raise TimeoutError(f"screen never lost {needle!r}")

    def wait_for(self, needle: str, timeout=30):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if needle in self.text():
                return True
            time.sleep(0.1)
        raise TimeoutError(f"screen never showed {needle!r}")

    def wait_quiet(self, window=0.8):
        """No LOUD write for `window` seconds. The idle blink's one-cell
        diffs (issue #104) never count — quiet means "nothing substantive
        changed", not "zero bytes"."""
        while time.monotonic() - self._last_loud < window:
            time.sleep(0.05)

    def send(self, data: bytes):
        os.write(self.master, data)

    def type(self, text: str, per_key=0.06):
        for ch in text:
            self.send(ch.encode())
            time.sleep(per_key)

    # A real bracketed paste (issue #112's drop flow): the terminal wraps
    # the payload in ESC[200~ … ESC[201~ — the exact bytes a terminal
    # emits when a dropped file's path lands in the composer.
    def paste(self, text: str):
        self.send(b"\x1b[200~" + text.encode() + b"\x1b[201~")

    # One wheel notch (SGR mouse encoding, button 64 = up / 65 = down) —
    # what mouse capture delivers to the app (issue #21's amendment).
    def wheel(self, direction: str):
        button = 64 if direction == "up" else 65
        self.send(f"\x1b[<{button};40;10M".encode())

    def probe(self, window_ms: int) -> int:
        """Bytes the app pushes to the terminal with NO input — the idle
        render rate at the terminal boundary. 0 == no renders. Since the
        idle blink (issue #104) a fresh idle app emits a SMALL periodic
        diff at ~2/s: the probe is now a bounded-rate probe — use
        frame_rate() to count the bursts."""
        before = self._total
        time.sleep(window_ms / 1000)
        return self._total - before

    def frame_rate(self, window_ms: int) -> tuple[int, int]:
        """(bursts, bytes) the app pushed with NO input over the window:
        chunks grouped into bursts by a 120 ms gap each count as one
        rendered frame — the idle blink's measured renders/s (issue #104).
        ~2 bursts over a 1 s window is the recorded 500 ms cadence."""
        start = time.monotonic()
        time.sleep(window_ms / 1000)
        writes = [(t, c) for t, c in self._chunks if t >= start]
        bursts = 0
        last_t = None
        nbytes = 0
        for t, c in writes:
            nbytes += len(c)
            if last_t is None or t - last_t > 0.12:
                bursts += 1
            last_t = t
        return bursts, nbytes

    # -- rendering --------------------------------------------------------

    def _font(self, size=15, bold=False):
        candidates = FONT_CANDIDATES_BOLD if bold else FONT_CANDIDATES
        for path in candidates:
            if os.path.exists(path):
                return ImageFont.truetype(path, size)
        return ImageFont.load_default()

    def _metrics(self, scale=1, base=15):
        # The scale multiplies the FONT SIZE (not just the cell pitch) so
        # box-drawing runs stay contiguous — a 2x render is a real 2x.
        font = self._font(base * scale)
        cell_w = round(font.getlength("M"))
        cell_h = sum(font.getmetrics())
        return (cell_w, cell_h, font)

    def render(self, scale=2, crop_rows=None) -> Image.Image:
        metrics = self._metrics(scale)
        cell_w, cell_h, _ = metrics
        rows = crop_rows or self.rows
        img = Image.new("RGB", (self.cols * cell_w, rows * cell_h), DEFAULT_BG)
        draw = ImageDraw.Draw(img)
        for y in range(rows):
            for x in range(self.cols):
                paint(draw, metrics, self.screen.buffer[y][x],
                      x * cell_w, y * cell_h)
        return img

    def screenshot(self, path: str, crop_rows=None):
        self.render(crop_rows=crop_rows).save(path)
        print(f"still  {path} ({os.path.getsize(path)} bytes)")

    def gif(self, path: str, fps=10, crop_rows=12, min_span=0.0):
        """Render the marked window as frames. The replay screen is fed the
        FULL byte history from boot up to each frame's horizon, so every
        frame carries the complete UI (static chrome included); the window
        itself starts at the mark. `min_span` (seconds) extends the frame
        count past the last byte event — an idle app emits nothing, but the
        final state must still fall inside a frame horizon (Pillow merges
        pixel-identical frames, so trailing duplicates cost nothing)."""
        if self._mark is None:
            raise RuntimeError("no recording mark was set")
        metrics = self._metrics(scale=2)
        cell_w, cell_h, _ = metrics
        frames = []
        step = 1000 / fps
        replay = pyte.Screen(self.cols, self.rows)
        # Freeze the reader's feed FIRST, atomically with the stream swap
        # (see _frozen/_feed_lock): the replay below drives this stream in
        # order; any byte the reader thread feeds concurrently reorders the
        # stream and corrupts frames. try/finally guarantees the live
        # screen is restored and the queued bytes drained even on error.
        with self._feed_lock:
            self._frozen += 1
            live_fed = len(self._chunks)
            saved = (self.screen, self.stream, self._alt)
            self.screen, self.stream, self._alt = replay, pyte.ByteStream(replay), False
        try:
            events = list(self._chunks)
            # Catch the replay screen up to the window's start.
            while events and events[0][0] < self._mark:
                _, chunk = events.pop(0)
                self.feed(chunk)
            window = [e for e in events if e[0] >= self._mark]
            n_frames = max(
                1,
                int((window[-1][0] - self._mark) * 1000 / step),
                int(min_span * 1000 / step),
            )
            for i in range(n_frames):
                horizon = self._mark + (i + 1) * step / 1000
                while events and events[0][0] <= horizon:
                    _, chunk = events.pop(0)
                    self.feed(chunk)
                img = Image.new("RGB", (self.cols * cell_w, crop_rows * cell_h), DEFAULT_BG)
                draw = ImageDraw.Draw(img)
                top = self.rows - crop_rows
                for y in range(top, self.rows):
                    for x in range(self.cols):
                        paint(draw, metrics, replay.buffer[y][x],
                              x * cell_w, (y - top) * cell_h)
                frames.append(img)
        finally:
            self.screen, self.stream, self._alt = saved
            # Drain the queued bytes into the restored live screen — in a
            # caught-up loop: chunks may keep arriving (the blink) while
            # the drain runs, and the freeze guarantees no concurrent feed.
            seen = live_fed
            while True:
                chunks = list(self._chunks)
                if len(chunks) <= seen:
                    break
                for _, chunk in chunks[seen:]:
                    self.feed(chunk)
                seen = len(chunks)
            with self._feed_lock:
                self._frozen -= 1

        # One SHARED palette for every frame (delta re-review): letting
        # Pillow convert each RGB frame to GIF P-mode independently
        # remapped static dim cells frame-to-frame — the hint row's ↑
        # flickered between blank and a phantom block. Quantizing once
        # (frame 0's median-cut palette, every later frame mapped into
        # it, no dither) keeps identical source cells identical in
        # every frame.
        palettes = frames[0].quantize(colors=255, method=Image.MEDIANCUT)
        frames = [f.quantize(palette=palettes, dither=Image.Dither.NONE) for f in frames]
        frames[0].save(path, save_all=True, append_images=frames[1:],
                       duration=int(step), loop=0, optimize=False)
        print(f"gif    {path} ({os.path.getsize(path)} bytes, "
              f"{len(frames)} frames @ {fps}fps)")

    # -- scenarios --------------------------------------------------------

    # -- reading-surface claims (issues #107 + #108) ----------------------

    def find_row(self, needle: str):
        """The screen row containing `needle`, or None."""
        for y, row in enumerate(self.screen.display):
            if needle in row:
                return y
        return None

    def row_cells(self, y: int, x0: int, x1: int):
        return [self.screen.buffer[y][x] for x in range(x0, x1)]

    # The style claim under test (#107): `user-bold` — the user row's text
    # rides the bold :user role behind an accent ❯ prefix whose fg differs
    # from the body's default fg; `all-plain` — the #107 bug shape, nothing
    # in either row bold. Assistant rows are plain in both.
    def assert_style_claim(self, claim: str):
        user_y = self.find_row("❯ what is elixir?")
        assert user_y is not None, "the user turn never rendered"

        row = self.screen.display[user_y]
        gx = row.index("❯")            # the log's left inset, wherever it is
        body = "what is elixir?"
        prefix = self.row_cells(user_y, gx, gx + 2)
        text = self.row_cells(user_y, gx + 2, gx + 2 + len(body))

        reply_y = self.find_row("supervised by")
        assert reply_y is not None, "the assistant reply never rendered"
        reply = self.row_cells(reply_y, 0, self.cols)

        if claim == "user-bold":
            assert all(c.bold for c in text), "the user row's text is not bold"
            assert all(c.bold for c in prefix), "the ❯ prefix is not bold"
            assert prefix[0].fg != text[0].fg, \
                "the ❯ prefix does not contrast with the default-fg body"
            assert not any(c.bold for c in reply), \
                "the assistant reply row picked up bold"
            print(f"claim  user-bold: prefix fg={prefix[0].fg!r} bold, "
                  f"body fg={text[0].fg!r} bold, reply plain")
        else:
            assert not any(c.bold for c in text), \
                "unexpected: the user row's text is bold"
            assert not any(c.bold for c in reply), \
                "unexpected: the assistant reply row is bold"
            print("claim  all-plain: user and assistant rows carry the same "
                "plain weight (the #107 bug shape)")

    # The margin claim (#108): every rendered row starts at column N and
    # ends N clear of the right edge — the whole chrome, popup included.
    def assert_margin(self, margin: int):
        for y, row in enumerate(self.screen.display):
            stripped = row.rstrip()
            if not stripped.strip():
                continue
            first = len(row) - len(row.lstrip())
            last = len(stripped) - 1
            assert first >= margin, \
                f"row {y} starts at column {first} (< {margin}): {row!r}"
            assert last <= self.cols - 1 - margin, \
                f"row {y} ends at column {last} (> {self.cols - 1 - margin}): {row!r}"
        print(f"claim  margin {margin}: rows within columns "
              f"[{margin}, {self.cols - 1 - margin}] on a {self.cols}x{self.rows} pty")

    # The #129 breathing gap: the composer's top border row, and the N
    # rows directly above it must be ENTIRELY blank (the two-row air between
    # the transcript and the composer cluster — holds in every scroll
    # state, since the gap is a fixed region of the split).
    def composer_top_y(self) -> int:
        for y, row in enumerate(self.screen.display):
            if row.lstrip().startswith("╭") and "❯" in row:
                return y
        raise AssertionError("the composer's top border row never rendered")

    def assert_gap(self, rows: int):
        top = self.composer_top_y()
        for y in range(max(top - rows, 0), top):
            row = self.screen.display[y]
            assert not row.strip(), \
                f"row {y} intrudes into the {rows}-row breathing gap: {row!r}"
        print(f"claim  gap {rows}: rows {top - rows}..{top - 1} blank above "
              f"the composer border on a {self.cols}x{self.rows} pty")

    # Two completed exchanges so user and assistant rows alternate (#107).
    def scenario_reading_session(self):
        for question in ("what is elixir?",
                         "and how do supervisors keep it reliable?"):
            self.type(question)
            self.send(b"\r")
            self.wait_for("rest")      # the scripted reply's last word
            self.wait_quiet()          # the turn finalized

    # The replay claim (#107): the fixture session booted with --resume;
    # the replayed log must show both roles before the styling is asserted.
    def scenario_resume_session(self):
        assert self.find_row("❯ what is elixir?") is not None, \
            "the replayed user turn never rendered"
        assert self.find_row("supervised by") is not None, \
            "the replayed assistant turn never rendered"
        assert self.find_row("A crash in") is not None, \
            "the replayed log is incomplete (the second turn is missing)"

    def scenario_mid_session(self):
        self.type("what is elixir?")
        self.send(b"\r")
        self.wait_for("rest")          # the reply's last word landed
        self.wait_quiet()              # the turn finalized; composer empty

    # Two completed exchanges over a small window: the footer's tokens-used
    # span grows across turns (issue #67 stage 2). Asserted on the CONTEXT
    # SPAN itself — the whole row would let cwd slashes and rate jitter
    # satisfy a guard that proves nothing — so a mock that stopped reporting
    # usage fails the capture, never a GIF where the count stands still.
    # The second question is longer so the growth moves the used label, not
    # just the percent's decimal.
    def scenario_growing_session(self) -> list[str]:
        seen = []
        for question in (
            "what is elixir?",
            "and how do supervisors, links, and process registries fit "
            "together — please walk me through the whole supervision tree "
            "story in detail, from restart strategies to process isolation",
        ):
            self.type(question)
            self.send(b"\r")
            self.wait_for("rest")      # the scripted reply's last word
            self.wait_quiet()
            seen.append(self.context_value())
        assert all(seen), \
            f"the footer's context span never populated: {seen}"
        assert seen[0] != seen[1], \
            f"the footer's context span never grew: {seen}"
        return seen

    # The `used/window · percent` portion of the footer row — the cwd's
    # slashes and the rate's decimals must not be able to satisfy a guard.
    # `~` before the denominator marks the documented-default window
    # (issue #111) — the visible note.
    CONTEXT_SPAN = re.compile(r"[\d.]+[kmb]?/~?[\d.]+[kmb]? · [\d.]+%")

    def context_value(self) -> str:
        match = self.CONTEXT_SPAN.search(self.footer_span())
        return match.group(0) if match else ""

    def footer_span(self) -> str:
        """The footer row — the LAST row whose first glyph is ❯ (user log
        echoes start with ❯ too; the footer sits under the composer)."""
        for row in reversed(self.screen.display):
            if row.lstrip().startswith("❯"):
                return row.rstrip()
        return ""

    # Issue #109: /model → pick the other catalog entry → the footer's
    # model part follows the pick (the label is a render-time read of the
    # swapped provider). wait_footer_label at the shoot site is the
    # assertion — a pick that never lands fails the capture.
    def scenario_model_switch(self):
        self.type("/model")
        self.send(b"\r")               # the command runs; the picker opens
        self.wait_for("Models", timeout=10)
        time.sleep(0.6)                # a readable beat on the open picker
        self.send(b"\x1b[B")           # ↓ — the second catalog entry
        time.sleep(0.4)
        self.send(b"\r")               # ⏎ — pick it; the footer follows

    def wait_footer_label(self, expected: str, timeout=10):
        """Assert-then-shoot for the provider span (issue #109): the footer
        must read `expected` before any still is written — a capture whose
        claim is unverified fails here, never ships."""
        deadline = time.monotonic() + timeout

        while time.monotonic() < deadline:
            if expected in self.footer_span():
                print(f"label  footer={self.footer_span()!r}")
                return

            time.sleep(0.1)

        raise AssertionError(
            f"the footer's provider span never read {expected!r}: "
            f"{self.footer_span()!r}")

    # The /resume picker (issue #128): /resume opens the modal over the two
    # fixtures — the TITLED newest first, the preview row second — then ↓
    # selects the second and ⏎ adopts it. Asserted before any capture: the
    # picker's rows, their order, and (post-Enter) the adopted transcript's
    # own needles rendered by replay.
    PICKER_TITLE_ROW = "Titled fixture session"
    PICKER_PREVIEW_ROW = "fixture question one"

    def scenario_resume_picker(self):
        self.type("/resume")
        self.send(b"\r")
        self.wait_for("Sessions", timeout=10)
        self.wait_for(self.PICKER_TITLE_ROW, timeout=10)
        self.wait_for(self.PICKER_PREVIEW_ROW, timeout=10)

        text = self.text()
        titled = text.index(self.PICKER_TITLE_ROW)
        preview = text.index(self.PICKER_PREVIEW_ROW)
        assert titled < preview, \
            "the picker is not most-recent first: the titled (newer) " \
            "fixture must lead"
        time.sleep(0.6)                # a readable beat on the open picker

        self.send(b"\x1b[B")           # ↓ — the preview (older) fixture
        time.sleep(0.4)
        self.send(b"\r")               # ⏎ — adopt it

        self.wait_for("❯ fixture question two", timeout=10)
        self.wait_for("Fixture answer two, also replayed.", timeout=10)
        self.wait_quiet()              # the replay settled

    # The exit print (issue #127): one exchange persists (and auto-titles)
    # the session, Ctrl+Q quits, and the print lands on the normal screen
    # after the alt screen leaves. Returns the printed command line; the
    # caller reopens with it VERBATIM (shlex — exactly what a shell passes).
    def scenario_exit_print(self) -> str:
        self.scenario_mid_session()
        # The auto-title nudge lands after the settled turn (ADR 0023 §8) —
        # the exit print's TITLE form is the capture's subject.
        self.wait_for(f"[session titled: {TITLE_TEXT}]", timeout=10)
        self.wait_quiet()

        self.send(b"\x11")             # Ctrl+Q — the clean exit
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            try:
                pid, _status = os.waitpid(self.pid, os.WNOHANG)
            except ChildProcessError:
                break                  # already reaped elsewhere
            if pid == self.pid:
                break
            time.sleep(0.1)
        else:
            raise TimeoutError("the app never exited on Ctrl+Q")

        # The print is post-alt-screen bytes: find it in the RAW stream,
        # then prove it rendered on the (main-screen) emulator too.
        tail = b"".join(c for _t, c in self._chunks)
        assert b"\x1b[?1049l" in tail, "the app never left the alt screen"
        needle = b"dashfloat --resume"
        at = tail.rindex(needle)
        line = tail[at:].split(b"\n")[0].decode(errors="replace").strip()
        assert line.startswith("dashfloat --resume"), line
        print(f"print  {line!r}")
        assert "resume this session with:" in self.text(), \
            "the lead-in line never rendered on the post-exit screen"
        return line

    def scenario_ghost(self):
        self.scenario_mid_session()
        self.wait_for(GHOST_TEXT, timeout=10)
        time.sleep(0.4)                # the ghost's render to land

    def scenario_compact_session(self):
        self.type("/compact")
        self.send(b"\r")
        self.wait_for("dropped 1 oldest turn(s)")
        self.wait_quiet()              # the entry settled; composer empty

    # The stock-config capture (issue #111): settings exactly as the wizard
    # writes them (no `context` anywhere) against the REAL Z.AI preset URL,
    # a resumed fixture whose two ~1.75 MiB turns sit over the seeded 1M
    # window's 80% trigger. The seeded window must drive BOTH surfaces: the
    # drop entry names 1048576 and the footer's denominator reads 1m — no
    # 'no context window configured', no tokens-only degradation. Offline:
    # /compact is a local pass; the catalog refresh 401s fail-open.
    def scenario_stock_compact(self):
        self.type("/compact")
        self.send(b"\r")
        self.wait_for("dropped 1 oldest turn(s)")
        self.wait_for("of 1048576")
        self.wait_quiet()
        # The drop's persist pushes the context snapshot — the footer's
        # first span on a resumed session — and its denominator must be the
        # seeded window, not a degradation.
        span = self.context_value()
        assert "/1m" in span, \
            f"the seeded 1M window never reached the footer: {span!r}"

    # The documented-default capture (issue #111): a custom provider whose
    # model no source knows (not configured, not in /models metadata, not
    # seeded). The footer must show used/~window · pct — the visible note —
    # and /compact's reply carries the note naming the remedy, never the
    # bare refusal.
    def scenario_default_window(self):
        self.scenario_mid_session()
        span = self.context_value()
        assert "~131.1k" in span, \
            f"the assumed-window marker never reached the footer: {span!r}"
        self.type("/compact")
        self.send(b"\r")
        self.wait_for("window assumed")
        self.wait_for("DASHFLOAT_CONTEXT_TOKENS")
        self.wait_quiet()

    # The attach flow (ADR 0018 §5): Ctrl+O opens the one-line attach
    # prompt, the fixture's ABSOLUTE path is typed (the completion path is
    # exercised by the driven tests; here the full path is typed directly),
    # Enter attaches. ASSERTED before returning: the pending chip landed in
    # the composer block's title and the footer carries the capability
    # glyph — a keystroke lost in flight must fail the capture, not ship a
    # still where nothing attached.
    def attach_fixture(self) -> str:
        return write_image_fixture(scratch_dir())

    def scenario_attach(self) -> str:
        path = self.attach_fixture()
        assert "📎" in self.footer_span() or "📎" in self.text(), \
            "the image-capable model's footer never showed the 📎 glyph"
        self.send(b"\x0f")             # Ctrl+O — the attach prompt opens
        self.wait_for("attach", timeout=10)
        time.sleep(1.0)                # a readable beat on the open prompt
        # per_key slow enough to read in the GIF — the path is the payload
        self.type(path, per_key=0.06)
        self.send(b"\r")               # Enter — attach
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            title = self.composer_title()
            if title and "[Image #1]" in title:
                break
            time.sleep(0.1)
        else:
            raise TimeoutError("the pending-attachment chip never landed "
                               "in the composer title")
        self.type("what is this?")
        self.send(b"\r")
        self.wait_for("rest")          # the scripted reply's last word
        self.wait_quiet()
        assert "shot.png" in self.text(), \
            "the submitted turn's 📎 indicator line never rendered"
        return path

    # The refusal surface (ADR 0018 §4): the same attach attempt on a
    # non-capable model — the refusal entry lands in the log and NOTHING
    # was sent (the mock's reply never streams).
    def scenario_attach_refusal(self):
        path = self.attach_fixture()
        self.send(b"\x0f")             # Ctrl+O
        self.wait_for("attach", timeout=10)
        self.type(path, per_key=0.01)
        self.send(b"\r")
        self.wait_for("[images:", timeout=10)
        self.wait_quiet()
        assert "rest" not in self.text(), \
            "the refusal still streamed a reply — a request went out"

    # The drop scenarios (issue #112; ADR 0018's 2026-10-31 amendment): a
    # bracketed-pasted path to an existing image file becomes a numbered
    # chip. drop-image runs on the CAPABLE model (chip -> send -> wire),
    # drop-refusal on the default non-capable one (visible refusal).
    def scenario_drop_image(self) -> str:
        path = self.attach_fixture()
        second = path.replace("shot.png", "second.jpg")
        with open(second, "wb") as f:
            f.write(b"\x89PNG\r\n\x1a\n" + b"\x22" * 120)

        def wait_title(needle, pop=None, timeout=10):
            # Waits until the composer title contains `needle` — and, when
            # `pop` is given, does NOT contain it (the popped chip).
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                title = self.composer_title()
                if pop is not None:
                    if needle in title and pop not in title:
                        return
                elif needle in title:
                    return
                time.sleep(0.1)
            raise TimeoutError(f"composer title never reached {needle!r}")

        self.paste(path + "\r\n")
        wait_title("[Image #1]")
        assert path not in self.text(), \
            "the dropped path typed into the composer as literal text"

        self.paste(second)
        wait_title("[Image #1] [Image #2]")

        # Backspace on the empty draft pops the newest chip (and
        # renumbers); the settle beat holds the popped state long enough
        # to be its own GIF frame (hostile review F5).
        self.send(b"\x7f")
        wait_title("[Image #1]", pop="[Image #2]")
        time.sleep(0.8)
        # ...and the re-drop restores two
        self.paste(second)
        wait_title("[Image #1] [Image #2]")

        self.type("what is this?")
        self.send(b"\r")
        self.wait_for("rest")          # the scripted reply's last word
        self.wait_quiet()
        assert "shot.png" in self.text(), \
            "the submitted turn's 📎 indicator line never rendered"
        return path

    def scenario_drop_refusal(self):
        path = self.attach_fixture()
        self.paste(path)
        self.wait_for("[images:", timeout=10)
        self.wait_quiet()
        assert "[Image" not in self.composer_title(), \
            "a refused drop still landed a chip"
        assert path not in self.text(), \
            "the refused drop typed its path into the composer"
        assert "rest" not in self.text(), \
            "the refusal still streamed a reply — a request went out"

    # -- the interaction surface (issues #133/#134/#135, ADR 0028) --------

    # Enqueue the scripted episodes the mock pops one per chat connection
    # (a tool-calling episode, then the post-answer reply).
    def script(self, *episodes):
        MockHandler.EPISODES.extend(episodes)

    UP, DOWN, SPACE, ENTER, ESC = (b"\x1b[A", b"\x1b[B", b" ", b"\r", b"\x1b")

    # The approval as a choice question (#133): the composer is replaced by
    # "Approve write_file?" with [Approve, Reject] — the preview stays the
    # evidence in the log — arrows move, Enter answers, the tool runs and
    # the result rows in. Each act asserted before recording.
    def scenario_approve_choice(self):
        self.script(
            ("tools", [("call_w", "write_file",
                        json.dumps({"path": "tmp/capture-approve.txt",
                                    "content": "approved by the choice widget\n"}))]),
            ("text", "File written."))
        self.type("add the capture fixture file")
        self.send(b"\r")
        self.wait_for("Approve write_file?", timeout=10)
        assert self.find_row("❯ Approve") is not None, \
            "the approval's Approve option never rendered"
        assert self.find_row("  Reject") is not None, \
            "the approval's Reject option never rendered"
        assert self.find_row("↑↓ move · ⏎ answer · esc reject") is not None, \
            "the approval's hint row is clipped — the keys are unreadable"
        self.wait_quiet()
        # Move to Reject and back — the motion the GIF must show — then
        # approve.
        self.send(self.DOWN)
        time.sleep(0.4)
        assert self.find_row("❯ Reject") is not None, \
            "Down never moved the approval's selection to Reject"
        self.send(self.UP)
        time.sleep(0.4)
        self.send(self.ENTER)
        self.wait_for("write_file → ok", timeout=10)
        self.wait_for("File written.", timeout=10)
        self.wait_quiet()

    # The model's question, single-select (#134): the same widget asks the
    # user, Enter returns the answer as the tool result, and the model acts
    # on it in the next episode's reply.
    def scenario_question_single(self):
        self.script(
            ("tools", [("call_q", "question", json.dumps({
                "question": "Which database should the config target?",
                "options": [{"label": "Postgres", "description": "the sturdy default"},
                            {"label": "SQLite"}],
                "multiple": False}))]),
            ("text", "SQLite it is — minimal setup, one file."))
        self.type("set up the database config for me")
        self.send(b"\r")
        self.wait_for("Which database should the config target?", timeout=10)
        assert self.find_row("❯ Postgres") is not None, \
            "the question's first option never rendered selected"
        assert self.find_row("SQLite") is not None, \
            "the question's second option is clipped"
        assert self.find_row("↑↓ move · ⏎ answer · esc dismiss") is not None, \
            "the question's hint row is clipped"
        self.wait_quiet()
        self.send(self.DOWN)
        time.sleep(0.4)
        self.send(self.ENTER)
        self.wait_for("question → answered: SQLite", timeout=10)
        self.wait_for("SQLite it is", timeout=10)
        self.wait_quiet()

    # The model's question, multi-select (#134): space toggles, Enter
    # answers every checked label in option order.
    def scenario_question_multi(self):
        self.script(
            ("tools", [("call_m", "question", json.dumps({
                "question": "Which runtimes need setup docs?",
                "options": [{"label": "Elixir"}, {"label": "Rust"},
                            {"label": "Python"}],
                "multiple": True}))]),
            ("text", "Docs for Elixir and Python, coming up."))
        self.type("write setup docs for the runtimes i use")
        self.send(b"\r")
        self.wait_for("Which runtimes need setup docs?", timeout=10)
        assert self.find_row("[ ] Elixir") is not None, \
            "the multi question's checkboxes never rendered"
        assert self.find_row("[ ] Python") is not None, \
            "the multi question's last option is clipped"
        assert self.find_row("space toggle") is not None, \
            "the multi question's hint row is clipped"
        self.wait_quiet()
        self.send(self.SPACE)          # check Elixir
        time.sleep(0.4)
        assert self.find_row("[x] Elixir") is not None, \
            "Space never checked Elixir"
        self.send(self.DOWN)
        time.sleep(0.3)
        self.send(self.DOWN)
        time.sleep(0.3)
        self.send(self.SPACE)          # check Python
        time.sleep(0.4)
        assert self.find_row("[x] Python") is not None, \
            "Space never checked Python"
        self.send(self.ENTER)
        self.wait_for("answered: Elixir, Python", timeout=10)
        self.wait_for("Docs for Elixir and Python", timeout=10)
        self.wait_quiet()

    # AUTO never asks (#135): the dangerous call auto-rejects with the
    # safety check's reason — the preview receipt, the [auto: rejected]
    # entry, the tool-result row — and NO approval ever renders. Still
    # capture (the transcript record, not motion).
    def scenario_auto_reject(self):
        self.script(
            ("tools", [("call_x", "execute_command",
                        json.dumps({"command": "rm -rf /tmp/precious"}))]),
            ("text", "Understood — that command was refused. I will list what "
                     "is safe to delete instead."))
        self.type("/mode auto")
        self.send(b"\r")
        self.wait_for("[mode: Build → Auto]", timeout=10)
        self.type("clean up the precious directory")
        self.send(b"\r")
        self.wait_for("[auto: rejected execute_command — deletes files "
                      "outside the project]", timeout=15)
        self.wait_for("auto-rejected: deletes files outside the project",
                      timeout=10)
        self.wait_for("Understood — that command", timeout=10)
        assert self.find_row("Approve execute_command?") is None, \
            "AUTO prompted an approval — the leak the issue reports"
        assert self.find_row("Approve this change?") is None, \
            "AUTO armed the confirming activity row"
        self.wait_quiet()

    # The Tab-complete flow (issue #105; ADR 0020 amendment): "/mod" + Tab
    # completes to the highlighted head "/mode " (registry order — mode
    # precedes model; popup closes), then "/c" + down + Tab completes the
    # ARROW-SELECTED "/compact " — both asserted before the GIF is
    # written. (pyte rows are padded, so the trailing typed space is
    # asserted by the popup's closure + the completed name; the unit tests
    # pin the space byte itself.)
    def scenario_tab_complete(self):
        assert "❯" in self.composer_title(), "composer never rendered"
        self._mark = time.monotonic()
        self.type("/mod", per_key=0.4)
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            screen = self.text()
            if "show or switch" in screen and "pick a model" in screen:
                break
            time.sleep(0.1)
        else:
            raise TimeoutError("the narrowed /mod popup never rendered")
        self.send(b"\t")
        while time.monotonic() < deadline:
            if self.draft_text().rstrip() == "/mode":
                break
            time.sleep(0.1)
        else:
            raise TimeoutError("Tab never completed the command")
        assert "pick a model" not in self.text(), \
            "the popup survived the completion"
        # second beat: the arrow-selected match completes, not the head
        for _ in range(6):
            self.send(b"\x7f")
        time.sleep(0.3)
        self.type("/c", per_key=0.4)
        while time.monotonic() < deadline:
            if "compact now" in self.text():
                break
            time.sleep(0.1)
        else:
            raise TimeoutError("the /c popup never rendered")
        self.send(b"\x1b[B")           # Down — select /compact
        time.sleep(0.4)
        self.send(b"\t")
        while time.monotonic() < deadline:
            if self.draft_text().rstrip() == "/compact":
                break
            time.sleep(0.1)
        else:
            raise TimeoutError("Tab never completed the arrow-selected match")
        assert "compact now" not in self.text(), \
            "the popup survived the second completion"

    # The composer's draft row: the first row INSIDE the input box — the
    # row directly under the title border row, stripped of its "│ " border
    # prefix AND suffix (the row renders as "│ /model … │").
    def draft_text(self) -> str:
        for i, row in enumerate(self.screen.display):
            s = row.rstrip()
            if s.lstrip().startswith("╭") and "❯" in s:
                if i + 1 < len(self.screen.display):
                    return self.screen.display[i + 1].strip().strip("│").strip()
        return ""

    # The typing-snap flow (issue #110): resume a long log, wheel up
    # unfollows (the position span reads L..-../.. and the tail's last
    # line scrolls off), one keystroke re-pins to the tail, and the last
    # line is visible again.
    # Enter-only re-pin (issue #131, reversing #110): scroll back, TYPE —
    # the view must stay EXACTLY in place (the owner is reading earlier
    # context while composing) — then Enter, and only then does the view
    # snap to the tail. The scenario asserts each act before the GIF is
    # recorded; the mark lands BEFORE the wheel-ups so the GIF carries the
    # scroll-back state itself (hostile review F1, kept from #110's rig).
    POSITION_SPAN = re.compile(r"\bL\d+-\d+/\d+\b")

    def position_span(self) -> str:
        match = self.POSITION_SPAN.search(self.text())
        return match.group(0) if match else ""

    def scroll_away_from_tail(self):
        """Two wheel-ups off the tail; asserts the unfollowed span and the
        tail's unique line being gone. Returns the frozen span."""
        assert "follow L" in self.text(), \
            "the resumed log never reached a follow state"
        self._mark = self._mark or time.monotonic()
        self.wheel("up")
        self.wheel("up")
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if "follow" not in self.text():
                break
            time.sleep(0.1)
        else:
            raise TimeoutError("the wheel never unfollowed the tail")
        span = self.position_span()
        assert span, f"the scrolled position span never rendered: {self.text()[:120]!r}"
        assert "turn forty done" not in self.text(), \
            "the tail's last line is still visible after scrolling away"
        return span

    def scenario_enter_snap(self):
        span = self.scroll_away_from_tail()

        # TYPING: the view stays EXACTLY in place — same span, still
        # unfollowed, the tail still out of sight (the #110 behavior is
        # gone; this assert is the reversal's whole claim).
        self.type("hi there", per_key=0.4)
        time.sleep(0.4)
        assert "follow" not in self.text(), \
            "typing re-pinned the transcript (#131 violation)"
        assert self.position_span() == span, \
            f"typing moved the view: {span!r} -> {self.position_span()!r}"
        assert "turn forty done" not in self.text(), \
            "typing snapped the tail back into view (#131 violation)"

        # ENTER — the one re-pin: the view returns to follow, the echo and
        # then the reply arrive at the tail.
        self.send(b"\r")
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if "follow L" in self.text():
                break
            time.sleep(0.1)
        else:
            raise TimeoutError("Enter never re-pinned the log to the tail")
        self.wait_for("hi there")
        self.wait_for("rest")
        self.wait_quiet()

    # A reply arriving while scrolled up must not yank the view either
    # (issue #131's verify-and-record clause): submit re-pins (that is
    # Enter's own rule), then the wheel parks the view mid-reply and the
    # streaming tokens land BELOW it — the span freezes while the footer's
    # ttft ticks in.
    def scenario_scrolled_stream(self):
        self.type("stream while I read")
        self.send(b"\r")
        self.wait_for("processes")        # tokens are arriving
        self.wheel("up")
        self.wheel("up")
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if "follow" not in self.text():
                break
            time.sleep(0.1)
        else:
            raise TimeoutError("the wheel never unfollowed mid-stream")
        span = self.position_span()
        assert span, "the scrolled position span never rendered"
        window = re.match(r"L\d+-\d+", span).group(0)   # not the /total —
        # the total grows as the reply wraps; the WINDOW is the invariant.
        time.sleep(1.6)                   # ~12 more tokens land below
        now = self.position_span()
        assert now.startswith(window + "/"), \
            f"a streaming reply yanked the parked view: {span!r} -> {now!r}"
        assert re.search(r"ttft \d+(\.\d+)?s", self.footer_span()), \
            f"no ttft span while streaming: {self.footer_span()!r}"

    # The #130 footer, both cadences asserted before their stills: while
    # streaming ttft shows ALONE (no live tok/s — the owner's refinement),
    # and after the turn ends the whole-response average appears beside it
    # in the issue's exact format.
    def scenario_ttft_footer(self, mid: str, after: str):
        self.type("hello ttft")
        self.send(b"\r")
        self.wait_for("processes")        # mid-stream: tokens are flowing
        time.sleep(0.3)                   # a few more land (a real window)
        footer = self.footer_span()
        assert re.search(r"ttft \d+(\.\d+)?s", footer), \
            f"no ttft span mid-stream: {footer!r}"
        assert "tok/s" not in footer, \
            f"a live tok/s showed mid-stream (#130 violation): {footer!r}"
        self.screenshot(mid)

        self.wait_for("rest")
        # The frozen average exists only once the agent's idle phase lands
        # (finalize freezes the rate) — the activity row retiring is the
        # visible edge of that.
        self.wait_gone("Streaming")
        self.wait_quiet()
        footer = self.footer_span()
        assert re.search(r"ttft \d+(\.\d+)?s · \d+(\.\d+)? tok/s", footer), \
            f"the finished turn's footer lacks the exact format: {footer!r}"
        self.screenshot(after)

    # The composer block's title row (the bordered input's top line, which
    # carries the pending chips). The row is the box's TOP BORDER with the
    # title span inlaid — "╭❯ [Image #1] ───…" — NOT the footer's "❯ cwd"
    # row (which also starts with the glyph; a first cut matched it and the
    # attach asserts passed on the footer's 📎 capability glyph instead).
    def composer_title(self) -> str:
        for row in self.screen.display:
            s = row.rstrip()
            if s.lstrip().startswith("╭") and "❯" in s:
                return s.strip()
        return ""

    # -- the /title dialog (issue #106) ------------------------------------

    def dialog_top(self):
        """The screen row carrying the dialog box's title border, or None."""
        for y, row in enumerate(self.screen.display):
            if "Session title" in row:
                return y
        return None

    def dialog_box_rows(self) -> list[str]:
        """The dialog's rows from its top border down (the box is 7 rows at
        the default 80x24 pty: border, five inner, border)."""
        top = self.dialog_top()
        assert top is not None, "the /title dialog never opened"
        return self.screen.display[top:top + 7]

    def dialog_draft_row(self) -> str:
        """The box's first inner row — the ❯ draft line."""
        return self.dialog_box_rows()[1]

    def clear_dialog_draft(self):
        """Backspace the draft empty (a pre-filled dialog starts here)."""
        for _ in range(40):
            self.send(b"\x7f")
        time.sleep(0.5)
        assert "❯ █" in self.dialog_draft_row(), \
            f"the dialog draft never cleared: {self.dialog_draft_row()!r}"

    def wait_dialog_contains(self, needle: str, timeout=10):
        """Assert-then-shoot for the IN-dialog render: `needle` must appear
        inside the box's rows — a log line beneath never satisfies this."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            box = "\n".join(self.dialog_box_rows())
            if needle in box:
                return
            time.sleep(0.1)
        raise TimeoutError(f"the dialog box never showed {needle!r}: "
                           f"{self.dialog_box_rows()!r}")

    def wait_dialog_gone(self, timeout=10):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.dialog_top() is None:
                return
            time.sleep(0.1)
        raise TimeoutError("the /title dialog never closed")

    def titled_entry_count(self) -> int:
        return self.text().count("session titled")

    def scenario_title_dialog(self, holder_id: str, stills: list[str]):
        # The resumed titled session is on screen (the replayed log) before
        # anything is typed.
        self.wait_for("supervised by")
        self.wait_quiet()

        # Act 1 — bare /title opens the dialog PRE-FILLED with the fixture's
        # title; asserted on the draft row before the still is taken.
        self.type("/title")
        self.send(b"\r")
        self.wait_for("Session title")
        time.sleep(0.5)                # a readable beat on the open dialog
        assert f"❯ {TITLE_FIXTURE_TITLE}█" in self.dialog_draft_row(), \
            f"the dialog never pre-filled with {TITLE_FIXTURE_TITLE!r}: " \
            f"{self.dialog_draft_row()!r}"
        print(f"claim  pre-fill: draft row {self.dialog_draft_row().strip()!r} "
              f"carries the fixture title")
        self.screenshot(stills[0])

        # Act 2 — a title the SECOND fixture session holds refuses IN the
        # dialog, naming the holder id (not as a log line only).
        self.clear_dialog_draft()
        self.type(TITLE_HOLDER_TITLE)
        self.send(b"\r")
        self.wait_dialog_contains("already taken")
        self.wait_dialog_contains(holder_id)
        assert TITLE_HOLDER_TITLE in self.dialog_draft_row(), \
            "the refusal lost the draft"
        print(f"claim  in-dialog refusal: box names the holder {holder_id}, "
              f"draft kept")
        self.screenshot(stills[1])

        # Act 3 — a free title: the dialog closes and the entry lands.
        self.clear_dialog_draft()
        self.type(TITLE_FREE_TITLE)
        self.send(b"\r")
        self.wait_dialog_gone()
        self.wait_for(f"[session titled: {TITLE_FREE_TITLE}]")
        self.wait_quiet()
        print(f"claim  success: dialog closed, "
              f"[session titled: {TITLE_FREE_TITLE}] landed")
        self.screenshot(stills[2])

        # Act 4 — Esc cancels: dialog gone, nothing renamed.
        titled_before = self.titled_entry_count()
        self.type("/title")
        self.send(b"\r")
        self.wait_for("Session title")
        time.sleep(0.4)
        self.send(b"\x1b")             # Esc
        self.wait_dialog_gone()
        self.wait_quiet()
        assert self.titled_entry_count() == titled_before, \
            "Esc renamed something"
        print("claim  esc: dialog closed, the titled-entry count unchanged")
        self.screenshot(stills[3])

        # Act 5 — the inline form is unchanged: the entry lands, no dialog.
        self.type("/title " + TITLE_INLINE_TITLE)
        self.send(b"\r")
        self.wait_for(f"[session titled: {TITLE_INLINE_TITLE}]")
        self.wait_quiet()
        assert self.dialog_top() is None, "the inline form opened a dialog"
        print("claim  inline: /title <name> entry landed, no dialog")
        self.screenshot(stills[4])

    # -- the reasoning block (issue #78) -----------------------------------

    # The block's header row ("◔ Thinking · …") on screen, or None.
    def thinking_row(self):
        for y, row in enumerate(self.screen.display):
            if "◔ Thinking" in row:
                return y
        return None

    def wait_thinking(self, timeout=15):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.thinking_row() is not None:
                return self.thinking_row()
            time.sleep(0.1)
        raise TimeoutError("the thinking block never rendered")

    def assert_block_footer(self, first, last, total):
        """The expanded block's `└ first–last/total` position footer."""
        row = self.thinking_row()
        assert row is not None, "the thinking block never rendered"
        needle = f"└ {first}–{last}/{total}"
        found = any(needle in r for r in self.screen.display)
        assert found, f"the block footer never read {needle!r}: " + \
            repr([r.rstrip() for r in self.screen.display if "└" in r])
        print(f"claim  block window {first}–{last} of {total}")

    def scenario_reasoning_block(self):
        # The turn: reasoning streams first (the live tail window), then the
        # answer. The GIF mark is set by the caller BEFORE the submit.
        self.type("think about elixir")
        self.send(b"\r")
        self.wait_thinking()
        self.wait_for("thinking", timeout=15)      # live rows are visible
        # The live block's auto-follow: the LAST reasoning line is on screen
        # while the first is not (the window holds the tail).
        self.wait_for(REASONING_TAIL_MARK, timeout=15)
        assert "consider what the user" not in self.text(), \
            "the live block shows its head — the tail window broke"
        print("claim  live: tail window auto-follows the streaming thinking")

        self.wait_for("rest")                      # the answer's last word
        self.wait_gone("Streaming")
        self.wait_quiet()
        # Finalize collapsed the block to the one summary line.
        row = self.thinking_row()
        assert row is not None, "the collapsed summary line never rendered"
        assert "tokens" in self.screen.display[row], \
            f"the summary carries no stats: {self.screen.display[row]!r}"
        assert REASONING_TAIL_MARK not in self.text(), \
            "finalize left the block's content on screen (flood)"
        print(f"claim  collapsed: {self.screen.display[row].strip()!r}")

        # Expand: the 8-row window + position footer, focused.
        self.send(b"\x12")                        # Ctrl+R
        self.wait_for("↑↓ scroll", timeout=10)
        self.assert_block_footer(1, 8, len(REASONING_LINES))
        time.sleep(0.6)                            # a readable beat, expanded

        # Inner scroll: keys move the window to the tail.
        for _ in range(2):
            self.send(b"\x1b[B")                  # Down
            time.sleep(0.35)
        self.send(b"\x1b[F")                      # End — the block's tail
        time.sleep(0.5)
        self.assert_block_footer(len(REASONING_LINES) - 7,
                                 len(REASONING_LINES), len(REASONING_LINES))
        assert REASONING_TAIL_MARK in self.text(), \
            "the inner scroll never reached the stored tail"
        print("claim  inner scroll: end reaches the thinking's tail")
        time.sleep(0.6)

        # Collapse: the content leaves the log again.
        self.send(b"\x12")
        self.wait_gone("↑↓ scroll", timeout=10)
        assert REASONING_TAIL_MARK not in self.text(), \
            "collapse left the block's content on screen"
        print("claim  collapsed again: the one summary line returns")

    def scenario_reasoning_stills(self, collapsed: str, expanded: str):
        self.scenario_reasoning_block_until_collapsed()
        self.screenshot(collapsed)
        self.send(b"\x12")                        # Ctrl+R — expand
        self.wait_for("↑↓ scroll", timeout=10)
        time.sleep(0.5)
        self.screenshot(expanded)

    # The reasoning-block scenario's first half, stopping at the collapsed
    # summary (the stills' shared setup).
    def scenario_reasoning_block_until_collapsed(self):
        self.type("think about elixir")
        self.send(b"\r")
        self.wait_thinking()
        self.wait_for("rest")
        self.wait_gone("Streaming")
        self.wait_quiet()
        row = self.thinking_row()
        assert row is not None and "tokens" in self.screen.display[row], \
            f"the collapsed summary line never rendered: " \
            f"{self.screen.display[row] if row else None!r}"

    # The no-yank claim for the block's live growth (issue #78 over #131):
    # park the view two wheel-ups, let thinking stream, and require the
    # position WINDOW to freeze while the /total grows.
    def scenario_reasoning_scroll(self):
        self.type("think while I read")
        self.send(b"\r")
        self.wait_thinking()
        self.wheel("up")
        self.wheel("up")
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if "follow" not in self.text():
                break
            time.sleep(0.1)
        else:
            raise TimeoutError("the wheel never unfollowed during thinking")
        span = self.position_span()
        window = re.match(r"L\d+-\d+", span).group(0)
        # The parked view reads the FIXTURE's tail; the LIVE thinking grows
        # below the window — its tail must be out of sight the whole time.
        assert REASONING_TAIL_MARK not in self.text(), \
            "the parked view shows the live thinking tail"

        # ~15 more reasoning lines land under the frozen window.
        time.sleep(2.0)
        now = self.position_span()
        assert now.startswith(window + "/"), \
            f"the thinking block's live growth yanked the parked view: " \
            f"{span!r} -> {now!r}"
        assert int(now.split("/")[1]) > int(span.split("/")[1]), \
            "the /total never grew — no thinking streamed under the window"
        print(f"claim  no-yank: window {window} frozen, "
              f"/total {span.split('/')[1]} -> {now.split('/')[1]}")
        # Let the turn settle (the GIF wants the full interaction). The
        # answer's words land below the parked window — the activity row's
        # retirement is the visible edge of the turn's end.
        self.wait_gone("Streaming", timeout=30)
        self.wait_quiet()

    # The persistence truth (issue #78): the session file carries the FULL
    # thinking; a resumed run replays the block from it and the inner
    # scroll reaches the stored tail.
    def scenario_reasoning_resume(self, still: str):
        self.scenario_reasoning_block_until_collapsed()
        self.wait_for(f"[session titled: {TITLE_TEXT}]", timeout=10)
        self.wait_quiet()

        session_id = self.session_id_on_disk()
        stored = self.stored_reasoning(session_id)
        assert stored is not None, \
            "the saved session carries no reasoning_content"
        assert REASONING_TAIL_MARK in stored, \
            "the saved reasoning is not the full thinking"
        assert len(stored.splitlines()) >= len(REASONING_LINES), \
            f"the saved reasoning lost lines: {len(stored.splitlines())}"
        print(f"claim  persisted: reasoning_content has "
              f"{len(stored.splitlines())} lines, tail present")

        self.send(b"\x11")                        # Ctrl+Q — exit
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            try:
                pid, _status = os.waitpid(self.pid, os.WNOHANG)
            except ChildProcessError:
                break
            if pid == self.pid:
                break
            time.sleep(0.1)
        else:
            raise TimeoutError("the app never exited on Ctrl+Q")

        reopened = App(no_ghost=True, resume=session_id)
        try:
            reopened.wait_for("think about elixir", timeout=30)
            row = reopened.wait_thinking(timeout=10)
            # Replayed blocks carry no stats (replay is pure).
            assert "tokens" not in reopened.screen.display[row], \
                f"a replayed block carries stats: {reopened.screen.display[row]!r}"
            print(f"claim  replayed: {reopened.screen.display[row].strip()!r}")

            reopened.send(b"\x12")                # Ctrl+R — expand
            reopened.wait_for("↑↓ scroll", timeout=10)
            reopened.assert_block_footer(1, 8, len(REASONING_LINES))
            reopened.send(b"\x1b[F")              # End — the stored tail
            time.sleep(0.5)
            reopened.assert_block_footer(len(REASONING_LINES) - 7,
                                         len(REASONING_LINES),
                                         len(REASONING_LINES))
            assert REASONING_TAIL_MARK in reopened.text(), \
                "the resumed block's inner scroll never reached the tail"
            print("claim  resumed: inner scroll reaches the STORED tail")
            time.sleep(0.3)
            reopened.screenshot(still)
        finally:
            reopened.close()

    def session_id_on_disk(self) -> str:
        sessions = f"{scratch_dir()}/dashfloat/sessions"
        ids = [f[:-5] for f in os.listdir(sessions) if f.endswith(".json")]
        assert len(ids) == 1, f"expected one session file, saw {ids}"
        return ids[0]

    def stored_reasoning(self, session_id: str):
        path = f"{scratch_dir()}/dashfloat/sessions/{session_id}.json"
        with open(path) as f:
            body = json.load(f)
        for m in body.get("messages", []):
            if m.get("role") == "assistant" and "reasoning_content" in m:
                return m["reasoning_content"]
        return None

    def close(self):
        self._alive = False
        try:
            self.send(b"\x11")  # Ctrl+Q
            time.sleep(0.5)
        except OSError:
            pass
        try:
            os.close(self.master)
        except OSError:
            pass
        try:
            os.kill(self.pid, 15)
        except ProcessLookupError:
            pass
        self.server.shutdown()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["still", "probe", "gif"])
    ap.add_argument("--scenario", default="first-run",
                    choices=["first-run", "mid-session", "ghost",
                             "growing-session", "compact-session",
                             "stock-compact", "default-window",
                             "slash-autocomplete", "attach",
                             "attach-refusal", "reading-session",
                             "resume-session", "resume-picker",
                             "exit-print", "model-switch",
                             "title-dialog", "idle-blink", "tab-complete",
                             "breathing-gap", "gap-scrolled", "ttft-footer",
                             "enter-snap", "scrolled-stream",
                             "drop-image", "drop-refusal",
                              "reasoning-block", "reasoning-stills",
                              "reasoning-scroll", "reasoning-resume"])
    ap.add_argument("--out", default=None)
    # The compact-session flow shoots TWO stills: --out after the drop,
    # --out2 after the follow-up no-op command (its below-trigger entry).
    ap.add_argument("--out2", default=None)
    # The title-dialog flow (issue #106) shoots FIVE stills in one app run:
    # --out open, --out2 refusal, --out3 success, --out4 esc, --out5 inline.
    ap.add_argument("--out3", default=None)
    ap.add_argument("--out4", default=None)
    ap.add_argument("--out5", default=None)
    ap.add_argument("--window-ms", type=int, default=1500)
    ap.add_argument("--after-exchange", action="store_true")
    # Override the per-model context window the scratch settings carry
    # (issue #67 stage 2): the default 524288 leaves the footer's percent
    # rounding to 0 — a small honest window (8192) makes the span legible.
    ap.add_argument("--context", type=int, default=None)
    # The mid-session STILL must show a BLANK composer: with suggestions
    # enabled the suggester lands a ghost there (#91 review finding) —
    # pass --no-ghost to pin the blank state (the ghost state is its own
    # scenario).
    ap.add_argument("--no-ghost", action="store_true")
    # The pty size (#108): a wide capture is a real 120-column pty
    # (TIOCSWINSZ + pyte Screen), not a crop of an 80-column one.
    ap.add_argument("--cols", type=int, default=COLS)
    ap.add_argument("--rows", type=int, default=ROWS)
    # The terminal palette the still is painted with (#107): `light` swaps
    # the rig's PALETTE/DEFAULT_FG/DEFAULT_BG to a light scheme — the app's
    # bytes are unchanged, only the rendering.
    ap.add_argument("--palette", choices=["dark", "light"], default="dark")
    # The #107 style claim the still must prove: `user-bold` (user rows bold
    # behind an accent ❯ prefix, assistant rows plain) or `all-plain` (the
    # bug shape a BEFORE capture is expected to show).
    ap.add_argument("--style-claim", choices=["user-bold", "all-plain"],
                    default=None)
    # The #108 margin claim: every rendered row starts at column N and ends
    # N clear of the right edge. Skipped when omitted.
    ap.add_argument("--margin", type=int, default=None)
    # Issue #109: point the scratch settings' provider at any endpoint
    # (and write the matching keys entry), drop its label, and assert the
    # footer's provider span before the still is written.
    ap.add_argument("--base-url", default=None,
                    help="override the scratch settings' provider baseUrl")
    ap.add_argument("--model", default=None,
                    help="override the scratch settings' model name (outranks "
                         "the scenario's own choice, like --base-url)")
    ap.add_argument("--nickname", default=None,
                    help="override the scratch settings' model nickname "
                         "(default Sol) — the footer shows the nickname")
    ap.add_argument("--unlabeled", action="store_true",
                    help="drop the provider's settings label — the host degrades in")
    ap.add_argument("--expect-label", default=None,
                    help="assert the footer's provider span reads this before shooting")
    args = ap.parse_args()
    if args.mode in ("still", "gif") and not args.out:
        ap.error(f"{args.mode} requires --out FILE")
    # The assert-then-shoot guarantee holds only where ONE still is written
    # at the end (compact-session writes both stills inside its scenario;
    # gif/probe write no still) — reject the combos rather than silently
    # weakening the guarantee (issue #109).
    if args.expect_label and (args.mode != "still" or args.scenario in ("compact-session", "title-dialog")):
        ap.error("--expect-label needs still mode and a scenario that shoots "
                 "once, at the end")

    set_palette(args.palette)

    # The compact-session scenario boots from a fixture session file written
    # BEFORE the app starts: a 20000-token window whose trigger the resumed
    # transcript (two ~20 KB turns, no anchor) sits over. The stock-compact
    # capture (issue #111) instead resumes turns sized past the SEEDED 1M
    # window's trigger, under the real Z.AI preset URL with NO configured
    # context — the wizard's exact output. The resume-session (#107) and
    # title-dialog (#106) fixtures ride the same trick.
    resume = None
    holder_id = None
    base_url = None
    model = "glm-5.3"
    context = args.context
    if args.scenario == "compact-session":
        resume = write_compact_fixture(scratch_dir())
        context = context or 20000
    elif args.scenario == "stock-compact":
        base_url = App.ZAI_BASE_URL
        model = "glm-5.3-flash"
        context = context  # None unless pinned — the stock shape has none
        # Turn bytes chosen so the two-turn total (est = turn_bytes) sits
        # over the seeded window's trigger (838 860) while the single
        # remaining turn (turn_bytes/2) lands under it: one clean drop,
        # no oversize survivor.
        resume = write_compact_fixture(scratch_dir(), turn_bytes=1_200_000)
    elif args.scenario == "default-window":
        model = "custom-unknown-model"
        context = context  # None unless pinned
    elif args.scenario == "resume-session":
        resume = write_reading_fixture(scratch_dir())
    elif args.scenario in ("enter-snap", "gap-scrolled", "scrolled-stream",
                           "reasoning-scroll"):
        # A 40-turn fixture log overflows the 24-row viewport several
        # times over — the scroll-back state is real (issues #110/#131).
        resume = write_snap_fixture(scratch_dir())
    elif args.scenario == "title-dialog":
        # A holder session owns "Held Name"; the resumed fixture is titled
        # "Resume Me" — the dialog must pre-fill from it (issue #106).
        holder_id = write_titled_fixture(scratch_dir(), TITLE_HOLDER_TITLE)
        resume = write_titled_fixture(scratch_dir(), TITLE_FIXTURE_TITLE)
    elif args.scenario == "resume-picker":
        # The /resume picker's fixtures (issue #128): the TITLED session is
        # the newer (it must lead the picker), the untitled one previews
        # its first question instead.
        write_picker_fixture(scratch_dir(), "Titled fixture session", 30 * 60)
        write_picker_fixture(scratch_dir(), None, 3 * 60 * 60)

    if context is None and args.scenario not in ("stock-compact", "default-window"):
        context = 524288
    images = args.scenario in ("attach", "drop-image")
    # The CLI flags (issue #109's precedent) outrank a scenario's own
    # choices.
    app = App(no_ghost=args.no_ghost, context=context, resume=resume,
              images=images, cols=args.cols, rows=args.rows,
              base_url=args.base_url or base_url, unlabeled=args.unlabeled,
              model=args.model or model,
              nickname=args.nickname or "Sol")

    def assert_claims():
        if args.style_claim:
            app.assert_style_claim(args.style_claim)
        if args.margin is not None:
            app.assert_margin(args.margin)

    try:
        if args.mode == "probe":
            if args.after_exchange:
                app.scenario_mid_session()
            # Since the idle blink (issue #104) the probe's honest reading
            # is the BOUNDED rate: bursts of tiny one-cell diffs, ~2/s at
            # the recorded 500 ms cadence, zero anything larger.
            bursts, nbytes = app.frame_rate(args.window_ms)
            print(f"probe  window={args.window_ms}ms "
                  f"{'after-exchange' if args.after_exchange else 'fresh-session'} "
                  f"frames={bursts} bytes={nbytes} "
                  f"({1000 * bursts / max(args.window_ms, 1):.1f} frames/s)")
        elif args.mode == "still":
            if args.scenario == "mid-session":
                app.scenario_mid_session()
            elif args.scenario == "ghost":
                app.scenario_ghost()
            elif args.scenario == "growing-session":
                seen = app.scenario_growing_session()
                print(f"footer  turn1={seen[0]!r} turn2={seen[1]!r}")
            elif args.scenario == "compact-session":
                # Both stills in one run: the drop, then the follow-up
                # no-op command's below-trigger entry.
                app.scenario_compact_session()
                app.screenshot(args.out)
                if args.out2:
                    app.type("/compact")
                    app.send(b"\r")
                    app.wait_for("at or under the 80% trigger")
                    app.wait_quiet()
                    app.screenshot(args.out2)
            elif args.scenario == "stock-compact":
                app.scenario_stock_compact()
            elif args.scenario == "default-window":
                app.scenario_default_window()
            elif args.scenario == "slash-autocomplete":
                app.type("/")
                time.sleep(0.4)        # the popup renders
                assert "/compact" in app.text(), \
                    "the command popup never rendered"
                # The popup-fit claim (review F1): the widest registry row
                # renders WHOLE at 80 cols — no mid-word clipping inside
                # the box.
                assert "compact now if over the 80% trigger" in app.text(), \
                    "the /compact row clips inside the popup at 80 cols"
                assert "input history survives" in app.text(), \
                    "the /clear row clips inside the popup at 80 cols"
                assert_claims()
            elif args.scenario == "reading-session":
                app.scenario_reading_session()
                time.sleep(0.3)        # a settled beat on the final state
                assert_claims()
            elif args.scenario == "resume-session":
                app.scenario_resume_session()
                time.sleep(0.3)        # a settled beat on the replayed log
                assert_claims()
            elif args.scenario == "attach":
                app.scenario_attach()
            elif args.scenario == "attach-refusal":
                app.scenario_attach_refusal()
            elif args.scenario == "drop-refusal":
                app.scenario_drop_refusal()
            elif args.scenario == "auto-reject":
                # The transcript record (#135): preview receipt, the
                # [auto: rejected] entry with the check's reason, the
                # auto-rejected result row, the model's adaptation — and
                # the scenario itself asserts NO approval ever rendered.
                app.scenario_auto_reject()
            elif args.scenario == "model-switch":
                app.scenario_model_switch()
            elif args.scenario == "resume-picker":
                app.scenario_resume_picker()
                assert_claims()
            elif args.scenario == "exit-print":
                # The exit print (issue #127): the still is the POST-EXIT
                # screen — the normal screen the print lands on — shot
                # before the paste-verbatim round trip boots a second app.
                line = app.scenario_exit_print()
                app.screenshot(args.out)
                reopened = App(no_ghost=args.no_ghost, context=context,
                               cols=args.cols, rows=args.rows,
                               mix_args=("run", "--no-halt", "--",
                                         *shlex.split(line)[1:]))
                try:
                    reopened.wait_for("❯ what is elixir?", timeout=30)
                    reopened.wait_for("supervised by", timeout=30)
                    print(f"paste  reopened with {line!r} — "
                          "the printed command is verbatim-runnable")
                finally:
                    reopened.close()
            elif args.scenario == "breathing-gap":
                # The tail state (issue #129): two exchanges, snapped to
                # the tail, the two-row air asserted above the composer —
                # the IDLE layout (no activity row between gap and input).
                app.scenario_reading_session()
                app.wait_gone("Streaming")
                time.sleep(0.3)
                app.assert_gap(2)
            elif args.scenario == "gap-scrolled":
                # The mid-history state (issue #129): parked two wheel-ups
                # off the tail, the SAME two rows of air still hold.
                app.scroll_away_from_tail()
                time.sleep(0.3)
                app.assert_gap(2)
            elif args.scenario == "ttft-footer":
                # Two stills in one run (issue #130): mid-stream (ttft
                # alone) and after the turn (the exact paired format).
                if not (args.out and args.out2):
                    ap.error("ttft-footer shoots two stills: --out (mid) "
                             "and --out2 (after) are both required")
                app.scenario_ttft_footer(args.out, args.out2)
            elif args.scenario == "scrolled-stream":
                app.scenario_scrolled_stream()
            elif args.scenario == "reasoning-stills":
                if not (args.out and args.out2):
                    ap.error("reasoning-stills shoots two stills: --out "
                             "(collapsed) and --out2 (expanded) are required")
                app.scenario_reasoning_stills(args.out, args.out2)
            elif args.scenario == "reasoning-resume":
                app.scenario_reasoning_resume(args.out)
            elif args.scenario == "title-dialog":
                # Five stills in one app run (issue #106): open, refusal,
                # success, esc, inline — each act asserts before it shoots.
                stills = [args.out, args.out2, args.out3, args.out4, args.out5]
                if not all(stills):
                    ap.error("title-dialog shoots five stills: "
                             "--out .. --out5 are all required")
                app.scenario_title_dialog(holder_id, stills)
            if args.expect_label:
                app.wait_footer_label(args.expect_label)
            if args.scenario not in ("compact-session", "title-dialog",
                                     "exit-print", "ttft-footer",
                                     "reasoning-stills", "reasoning-resume"):
                app.screenshot(args.out)
        elif args.scenario == "slash-autocomplete":
            # The popup opening AND narrowing: "/" opens the full list, "c"
            # narrows it to /clear + /compact. The narrowed state is ASSERTED
            # before recording — a keystroke lost in flight must fail the
            # capture, not ship a GIF where nothing happens (#92 review).
            app._mark = time.monotonic()
            app.type("/c", per_key=0.5)
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                screen = app.text()
                if "compact" in screen and "/help" not in screen:
                    break
                time.sleep(0.1)
            else:
                raise TimeoutError("the narrowed command popup never rendered")
            time.sleep(0.5)                # a settled beat on the narrowed list
            # 16 rows: the narrowed popup rides higher than the full list,
            # and /clear + /compact must be legible in the final frame.
            app.gif(args.out, crop_rows=16, min_span=1.5)
        elif args.scenario == "attach":
            # The whole attach interaction: Ctrl+O opens the prompt, the
            # path types in, Enter attaches (chip lands), the question
            # submits, the reply streams. The scenario asserts the chip
            # and the indicator BEFORE the render — a lost keystroke
            # fails the capture. FULL frame (24 rows): the log indicator
            # and reply sit near the top, above any bottom-row crop.
            app._mark = time.monotonic()
            app.scenario_attach()
            time.sleep(0.5)            # a settled beat on the final state
            app.gif(args.out, crop_rows=24, min_span=1.0)
        elif args.scenario == "idle-blink":
            # The idle cursor blink (issue #104), the motion capture: no
            # input at all — the composer's cursor toggles on its own
            # timer. The rate is ASSERTED before the GIF: the measured
            # renders/s is ADR 0006's recorded cost (a capture whose
            # number is off fails, not ships).
            app.wait_quiet()
            bursts, nbytes = app.frame_rate(2000)
            rate = bursts / 2.0
            assert 1.2 <= rate <= 3.0, \
                f"idle frame rate {rate:.1f}/s outside the bounded band " \
                f"(bursts={bursts}, bytes={nbytes})"
            assert nbytes < 512, \
                f"idle bytes {nbytes} over 2 s are not a one-cell diff"
            app._mark = time.monotonic()
            time.sleep(3.2)            # ~6 toggles at the 500 ms cadence
            app.gif(args.out, crop_rows=24, min_span=3.0)
            print(f"blink  measured {rate:.1f} frames/s idle "
                  f"({nbytes} bytes over 2 s)")
        elif args.scenario == "tab-complete":
            # The completion in motion (issue #105): the popup narrows,
            # Tab lands "/model ", the second beat completes the
            # arrow-SELECTED /compact. The scenario asserts each act.
            app.scenario_tab_complete()
            time.sleep(0.5)            # a settled beat on the final draft
            app.gif(args.out, crop_rows=20, min_span=1.5)
        elif args.scenario == "reasoning-block":
            # The whole block interaction: live growth -> collapse ->
            # expand -> inner scroll -> collapse, asserted act by act.
            app._mark = time.monotonic()
            app.scenario_reasoning_block()
            time.sleep(0.5)
            app.gif(args.out, crop_rows=24, min_span=1.0)
        elif args.scenario == "reasoning-scroll":
            # Parked two wheel-ups while thinking streams — the window
            # freezes (the #131 principle over the block's live growth).
            app._mark = time.monotonic()
            app.scenario_reasoning_scroll()
            time.sleep(0.5)
            app.gif(args.out, crop_rows=24, min_span=1.0)
        elif args.scenario == "enter-snap":
            # Scroll back, type (view STAYS), Enter (view snaps) — issue
            # #131's reversal of #110, asserted act by act.
            app._mark = None
            app.scenario_enter_snap()
            time.sleep(0.5)
            app.gif(args.out, crop_rows=24, min_span=1.0)
        elif args.scenario == "resume-picker":
            # The picker in motion (issue #128): /resume types in, the
            # modal opens over the fixtures, ↓ moves the highlight, ⏎
            # adopts and the log replays — the scenario asserts each act
            # before recording. Full frame: the picker and the replayed
            # log share it.
            app._mark = time.monotonic()
            app.scenario_resume_picker()
            time.sleep(0.5)            # a settled beat on the replay
            app.gif(args.out, crop_rows=24, min_span=1.0)
        elif args.scenario == "drop-image":
            # The whole drop flow (issue #112): paste -> chip #1 ->
            # paste -> #2 -> backspace pop -> re-drop -> submit -> the
            # streamed reply with its 📎 indicator rows. Full frame.
            app._mark = time.monotonic()
            app.scenario_drop_image()
            time.sleep(0.5)
            app.gif(args.out, crop_rows=24, min_span=1.0)
        elif args.scenario == "approve-choice":
            # The approval in motion (#133): the composer is replaced by
            # the choice question, Down/Up move the selection, Enter
            # approves and the tool's result rows in. Each act asserted by
            # the scenario before the GIF is written. Full frame.
            app._mark = time.monotonic()
            app.scenario_approve_choice()
            time.sleep(0.5)
            app.gif(args.out, crop_rows=24, min_span=1.0)
        elif args.scenario == "question-single":
            # The model's question in motion, single-select (#134).
            app._mark = time.monotonic()
            app.scenario_question_single()
            time.sleep(0.5)
            app.gif(args.out, crop_rows=24, min_span=1.0)
        elif args.scenario == "question-multi":
            # The multi-select flow (#134): space toggles two answers,
            # Enter returns both in option order, the model acts on them.
            app._mark = time.monotonic()
            app.scenario_question_multi()
            time.sleep(0.5)
            app.gif(args.out, crop_rows=24, min_span=1.0)
        elif args.scenario == "growing-session":
            # Mark BEFORE the first send: the GIF covers both turns — the
            # span appears with the first turn's persist and grows with the
            # second's usage frame. 12 rows keep the composer, footer, and
            # the tail of the log legible.
            app._mark = time.monotonic()
            seen = app.scenario_growing_session()
            print(f"footer  turn1={seen[0]!r} turn2={seen[1]!r}")
            time.sleep(0.5)                # a settled beat on the final count
            app.gif(args.out, crop_rows=12, min_span=1.0)
        elif args.scenario == "stock-compact":
            # The stock /compact in motion: the command types in, the drop
            # entry names the seeded 1M window, and the footer's span
            # recomputes against 1m. 14 rows: log tail + composer + footer.
            app._mark = time.monotonic()
            app.scenario_stock_compact()
            time.sleep(0.5)                # a settled beat on the final span
            app.gif(args.out, crop_rows=14, min_span=1.5)
        else:
            app.type("what is elixir?")
            app.send(b"\r")
            app.wait_for("independently")   # the turn is streaming (active)
            # Active phase: type while the turn streams — the blink is live.
            # The window covers the typing span plus a trailing beat with
            # no input, so the loop shows the cursor toggling.
            app._mark = time.monotonic()
            app.type("thanks!", per_key=0.24)
            time.sleep(0.8)                 # a trailing blink beat, no input
            app.gif(args.out)
    finally:
        app.close()


if __name__ == "__main__":
    main()
