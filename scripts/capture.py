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
    probe       idle byte-rate: 0 bytes over the window == 0 renders/s

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
from PIL import Image, ImageDraw, ImageFont

COLS, ROWS = 80, 24

# The scripted assistant reply: enough words to make streaming visible,
# short enough to keep turns snappy. Dripped one token at a time.
REPLY_TOKENS = (
    "Elixir ` processes ` run ` independently ` , ` supervised ` by ` the ` "
    "VM ` . ` A ` crash ` in ` one ` never ` touches ` the ` rest ` ."
).split(" ` ")

GHOST_TEXT = "what happened next?"
TITLE_TEXT = "composer demo"

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
        if emoji is not None and not glyph_covered(font, ch.data):
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


def write_compact_fixture(scratch: str) -> str:
    """The compact-session fixture: a session file whose two user/assistant
    turns carry ~20 KB messages (~5000 heuristic tokens each, bytes/4) and
    no anchor. Resumed under a 20000-token window the estimate (~20000)
    sits over the 80% trigger (16000) with two droppable turns — /compact
    drops exactly the oldest one. Returns the session id."""
    session_id = str(uuid.uuid4())
    messages = []
    for turn in ("one", "two"):
        filler = f"turn {turn} filler " + "x" * 19985
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

    def _sse(self, req):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        for token in REPLY_TOKENS:
            frame = {"choices": [{"delta": {"content": token + " "}}]}
            self.wfile.write(f"data: {json.dumps(frame)}\n\n".encode())
            self.wfile.flush()
            time.sleep(0.13)
        # The usage frame mirrors what a real provider reports: the request's
        # own size in tokens (bytes/4 over the messages — the same heuristic
        # ADR 0022 §1 uses between frames), so the footer's tokens-used span
        # grows turn over turn as the conversation accumulates. A
        # list-content message (an image turn, ADR 0018 §2) counts its
        # parts' bytes through content_bytes.
        prompt_tokens = sum(content_bytes(m.get("content"))
                            for m in req.get("messages", [])) // 4
        usage = {"choices": [], "usage": {
            "prompt_tokens": prompt_tokens, "completion_tokens": 34}}
        self.wfile.write(f"data: {json.dumps(usage)}\n\n".encode())
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()


class App:
    """The real TUI under a real pty, plus the capture operations."""

    def __init__(self, mix_args=("run", "--no-halt"), no_ghost=False,
                 context=524288, resume=None, images=False, cols=COLS,
                 rows=ROWS):
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
        self._alt = False  # saw the app enter the alternate screen

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), MockHandler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        port = self.server.server_address[1]

        scratch = scratch_dir()
        os.makedirs(f"{scratch}/dashfloat", exist_ok=True)
        base = f"http://127.0.0.1:{port}/v1"
        # The images flag rides the models entry (ADR 0018 §1): the attach
        # scenarios pin it true (capable) or leave it off (incapable).
        images_field = ", images: true" if images else ""
        with open(f"{scratch}/dashfloat/settings.json5", "w") as f:
            f.write(
                "{\n"
                "  configVersion: 3,\n"
                "  defaultProfile: 'demo',\n"
                "  yourName: 'demo',\n"
                "  profiles: [{\n"
                "    name: 'demo',\n"
                "    defaultProvider: 'mock',\n"
                "    providers: [{\n"
                "      label: 'mock',\n"
                f"      baseUrl: '{base}',\n"
                f"      models: [{{ nickname: 'Sol', model: 'glm-5.3', "
                f"context: {context}{images_field} }}],\n"
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
            self._chunks.append((now, chunk))
            self.feed(chunk)
            if self.sink:
                self.sink(chunk)

    def wait_boot(self, timeout=120):
        """Boot + first frame + quiet: >= 600 ms of silence after >= 800 B,
        with the alternate screen entered (compile noise lands BEFORE the
        alt screen and can silence for a beat mid-build — without the alt
        gate a cold first run "boots" mid-compile and the first exchange
        times out)."""
        deadline = time.monotonic() + timeout
        last = self._total
        quiet_since = None
        while time.monotonic() < deadline:
            time.sleep(0.1)
            if self._total != last:
                last = self._total
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

    def wait_for(self, needle: str, timeout=30):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if needle in self.text():
                return True
            time.sleep(0.1)
        raise TimeoutError(f"screen never showed {needle!r}")

    def wait_quiet(self, window=0.8):
        last, since = -1, None
        while True:
            time.sleep(0.1)
            if self._total != last:
                last, since = self._total, None
                continue
            since = since or time.monotonic()
            if time.monotonic() - since >= window:
                return

    def send(self, data: bytes):
        os.write(self.master, data)

    def type(self, text: str, per_key=0.06):
        for ch in text:
            self.send(ch.encode())
            time.sleep(per_key)

    def probe(self, window_ms: int) -> int:
        """Bytes the app pushes to the terminal with NO input — the idle
        render rate at the terminal boundary. 0 == no renders."""
        before = self._total
        time.sleep(window_ms / 1000)
        return self._total - before

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
        saved = (self.screen, self.stream, self._alt)
        self.screen, self.stream, self._alt = replay, pyte.ByteStream(replay), False
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
            frames.append(img.quantize(colors=128))
        frames[0].save(path, save_all=True, append_images=frames[1:],
                       duration=int(step), loop=0, optimize=True)
        print(f"gif    {path} ({os.path.getsize(path)} bytes, "
              f"{len(frames)} frames @ {fps}fps)")
        self.screen, self.stream, self._alt = saved

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
    CONTEXT_SPAN = re.compile(r"[\d.]+[kmb]?/[\d.]+[kmb]? · [\d.]+%")

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

    def scenario_ghost(self):
        self.scenario_mid_session()
        self.wait_for(GHOST_TEXT, timeout=10)
        time.sleep(0.4)                # the ghost's render to land

    def scenario_compact_session(self):
        self.type("/compact")
        self.send(b"\r")
        self.wait_for("dropped 1 oldest turn(s)")
        self.wait_quiet()              # the entry settled; composer empty

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
            if title and "📎" in title:
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

    # The composer block's title row (the bordered input's top line, which
    # carries the pending chip) — the first row of the composer block; the
    # block's title sits directly above the draft row.
    def composer_title(self) -> str:
        for i, row in enumerate(self.screen.display):
            if row.lstrip().startswith("❯"):
                return row.rstrip()
        return ""

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
                             "slash-autocomplete", "attach",
                             "attach-refusal", "reading-session",
                             "resume-session"])
    ap.add_argument("--out", default=None)
    # The compact-session flow shoots TWO stills: --out after the drop,
    # --out2 after the follow-up no-op command (its below-trigger entry).
    ap.add_argument("--out2", default=None)
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
    args = ap.parse_args()
    if args.mode in ("still", "gif") and not args.out:
        ap.error(f"{args.mode} requires --out FILE")

    set_palette(args.palette)

    # The compact-session scenario boots from a fixture session file written
    # BEFORE the app starts: a 20000-token window whose trigger the resumed
    # transcript (two ~20 KB turns, no anchor) sits over. The resume-session
    # fixture (#107) is the same trick: two short user/assistant turns.
    resume = None
    if args.scenario == "compact-session":
        resume = write_compact_fixture(scratch_dir())
    elif args.scenario == "resume-session":
        resume = write_reading_fixture(scratch_dir())

    context = args.context or (
        20000 if args.scenario == "compact-session" else 524288)
    images = args.scenario == "attach"
    app = App(no_ghost=args.no_ghost, context=context, resume=resume,
              images=images, cols=args.cols, rows=args.rows)

    def assert_claims():
        if args.style_claim:
            app.assert_style_claim(args.style_claim)
        if args.margin is not None:
            app.assert_margin(args.margin)

    try:
        if args.mode == "probe":
            if args.after_exchange:
                app.scenario_mid_session()
            print(f"probe  window={args.window_ms}ms "
                  f"{'after-exchange' if args.after_exchange else 'fresh-session'} "
                  f"bytes={app.probe(args.window_ms)}")
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
            elif args.scenario == "slash-autocomplete":
                app.type("/")
                time.sleep(0.4)        # the popup renders
                assert "/compact" in app.text(), \
                    "the command popup never rendered"
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
            if args.scenario != "compact-session":
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
