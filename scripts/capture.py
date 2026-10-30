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
    scripts/capture.py probe [--window-ms 1500] [--after-exchange]
    scripts/capture.py gif   --out FILE.gif

Scenarios:
    first-run   fresh session: composer empty, no exchanges yet
    mid-session after one completed exchange: composer empty again
                (--no-ghost pins the BLANK composer: with suggestions on,
                 the suggester's ghost lands there — the ghost is its own
                 scenario)
    ghost       after a completed exchange + suggest side-request landed
    probe       idle byte-rate: 0 bytes over the window == 0 renders/s

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
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pyte
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
    """One terminal cell: background block first, then the glyph."""
    cell_w, cell_h, font = metrics
    fg, bg = cell_colors(ch)
    if bg != DEFAULT_BG:
        draw.rectangle([px, py, px + cell_w, py + cell_h], fill=bg)
    if ch.data and ch.data != " ":
        draw.text((px, py), ch.data, font=font,
                  fill=fg if not ch.bold else _brighten(fg))


def _brighten(hexcolor: str) -> str:
    r, g, b = (int(hexcolor[i:i + 2], 16) for i in (1, 3, 5))
    return "#%02x%02x%02x" % (min(255, r + 48), min(255, g + 48), min(255, b + 48))


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
        system = " ".join(m.get("content", "") for m in req.get("messages", [])
                          if m.get("role") == "system")
        if req.get("stream") is True:
            self._sse()
        elif "title" in system:
            self._json({"choices": [{"message": {"content": TITLE_TEXT}}]})
        else:
            self._json({"choices": [{"message": {"content": GHOST_TEXT}}]})

    def _sse(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        for token in REPLY_TOKENS:
            frame = {"choices": [{"delta": {"content": token + " "}}]}
            self.wfile.write(f"data: {json.dumps(frame)}\n\n".encode())
            self.wfile.flush()
            time.sleep(0.13)
        usage = {"choices": [], "usage": {
            "prompt_tokens": 21, "completion_tokens": 34}}
        self.wfile.write(f"data: {json.dumps(usage)}\n\n".encode())
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()


class App:
    """The real TUI under a real pty, plus the capture operations."""

    def __init__(self, mix_args=("run", "--no-halt"), no_ghost=False):
        self.sink = None  # callable(bytes) set during read loop
        self.screen = pyte.Screen(COLS, ROWS)
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

        scratch = f"/tmp/opencode/dashfloat-capture-{os.getpid()}"
        os.makedirs(f"{scratch}/dashfloat", exist_ok=True)
        base = f"http://127.0.0.1:{port}/v1"
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
                "      models: [{ nickname: 'Sol', model: 'glm-5.3', context: 524288 }],\n"
                "    }],\n"
                "  }],\n"
                "}\n"
            )
        with open(f"{scratch}/dashfloat/keys.json5", "w") as f:
            f.write("{ demo: { '%s': 'capture-mock-key' } }\n" % base)

        env = dict(os.environ)
        env.update({
            "XDG_CONFIG_HOME": scratch,
            "TERM": "xterm-256color",
            # Dev may recompile on entry; keep that noise out of the boot.
            "MIX_ENV": "dev",
        })
        if no_ghost:
            env["DASHFLOAT_SUGGEST"] = "false"
        self.pid, self.master = pty.fork()
        if self.pid == 0:
            os.chdir(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
            os.execvpe("mix", ["mix", *mix_args], env)

        fcntl.ioctl(self.master, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
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
        """Boot + first frame + quiet: >= 600 ms of silence after >= 800 B."""
        deadline = time.monotonic() + timeout
        last = self._total
        quiet_since = None
        while time.monotonic() < deadline:
            time.sleep(0.1)
            if self._total != last:
                last = self._total
                quiet_since = None
                continue
            if self._total > 800:
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
        rows = crop_rows or ROWS
        img = Image.new("RGB", (COLS * cell_w, rows * cell_h), DEFAULT_BG)
        draw = ImageDraw.Draw(img)
        for y in range(rows):
            for x in range(COLS):
                paint(draw, metrics, self.screen.buffer[y][x],
                      x * cell_w, y * cell_h)
        return img

    def screenshot(self, path: str, crop_rows=None):
        self.render(crop_rows=crop_rows).save(path)
        print(f"still  {path} ({os.path.getsize(path)} bytes)")

    def gif(self, path: str, fps=10, crop_rows=12):
        """Render the marked window as frames. The replay screen is fed the
        FULL byte history from boot up to each frame's horizon, so every
        frame carries the complete UI (static chrome included); the window
        itself starts at the mark."""
        if self._mark is None:
            raise RuntimeError("no recording mark was set")
        metrics = self._metrics(scale=2)
        cell_w, cell_h, _ = metrics
        frames = []
        step = 1000 / fps
        replay = pyte.Screen(COLS, ROWS)
        saved = (self.screen, self.stream, self._alt)
        self.screen, self.stream, self._alt = replay, pyte.ByteStream(replay), False
        events = list(self._chunks)
        # Catch the replay screen up to the window's start.
        while events and events[0][0] < self._mark:
            _, chunk = events.pop(0)
            self.feed(chunk)
        window = [e for e in events if e[0] >= self._mark]
        n_frames = max(1, int((window[-1][0] - self._mark) * 1000 / step))
        for i in range(n_frames):
            horizon = self._mark + (i + 1) * step / 1000
            while events and events[0][0] <= horizon:
                _, chunk = events.pop(0)
                self.feed(chunk)
            img = Image.new("RGB", (COLS * cell_w, crop_rows * cell_h), DEFAULT_BG)
            draw = ImageDraw.Draw(img)
            top = ROWS - crop_rows
            for y in range(top, ROWS):
                for x in range(COLS):
                    paint(draw, metrics, replay.buffer[y][x],
                          x * cell_w, (y - top) * cell_h)
            frames.append(img.quantize(colors=128))
        frames[0].save(path, save_all=True, append_images=frames[1:],
                       duration=int(step), loop=0, optimize=True)
        print(f"gif    {path} ({os.path.getsize(path)} bytes, "
              f"{len(frames)} frames @ {fps}fps)")
        self.screen, self.stream, self._alt = saved

    # -- scenarios --------------------------------------------------------

    def scenario_mid_session(self):
        self.type("what is elixir?")
        self.send(b"\r")
        self.wait_for("rest")          # the reply's last word landed
        self.wait_quiet()              # the turn finalized; composer empty

    def scenario_ghost(self):
        self.scenario_mid_session()
        self.wait_for(GHOST_TEXT, timeout=10)
        time.sleep(0.4)                # the ghost's render to land

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
                    choices=["first-run", "mid-session", "ghost"])
    ap.add_argument("--out", default=None)
    ap.add_argument("--window-ms", type=int, default=1500)
    ap.add_argument("--after-exchange", action="store_true")
    # The mid-session STILL must show a BLANK composer: with suggestions
    # enabled the suggester lands a ghost there (#91 review finding) —
    # pass --no-ghost to pin the blank state (the ghost state is its own
    # scenario).
    ap.add_argument("--no-ghost", action="store_true")
    args = ap.parse_args()
    if args.mode in ("still", "gif") and not args.out:
        ap.error(f"{args.mode} requires --out FILE")

    app = App(no_ghost=args.no_ghost)
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
            app.screenshot(args.out)
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
