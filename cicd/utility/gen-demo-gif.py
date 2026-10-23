#!/usr/bin/env python3

##	Purpose: Draw the README's demo gif. Each command in a TOML scenario is
##		typed into a fake terminal the way a person types, mistakes and all,
##		then run for real against the release binary, so the output shown
##		can't go stale. 50 fps: the cursor eases between cells, and output
##		scrolls smoothly once it reaches the bottom. The loop ends on a cut to
##		black. Pillow only, so nothing opens a window or needs a screen.
##		From convert-base-v2's gen-demo-gif.py, with shcl's expected exit codes.
##	Syntax: gen-demo-gif.py --scenario FILE --out FILE --bin PATH [--seed N] [--font NAME] [--quiet]
##	Exit: 0 wrote the gif; 1 a step, the leak check or the frame timing failed; 2 skipped, no Pillow or no font.
##	History: At bottom of script.

##	Copyright © 2026 t00mietum (CryptogID: ปʬϝღถɔ4რఠΔթะ9ƾǝu)
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


from __future__ import annotations

import argparse
import getpass
import io
import os
import random
import re
import secrets
import shlex
import shutil
import socket
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any, NamedTuple, NoReturn

try:
    import tomllib
except ImportError:
    sys.stderr.write("gen-demo-gif: needs python 3.11 or newer, for tomllib\n")
    sys.exit(2)
try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:
    sys.stderr.write("gen-demo-gif: Pillow isn't installed\n")
    sys.exit(2)


##	960x540, and the window fills it but for a black edge. Square corners.
CANVAS_W, CANVAS_H = 960, 540
MARGIN = 4
TITLE_H = 34
PAD = 12

Rgb = tuple[int, int, int]
Span = tuple[str, str]  # (text, THEME key)
Step = dict[str, Any]

THEME: dict[str, Rgb] = {
    "outer": (0, 0, 0),
    "border": (58, 58, 62),
    "titlebar": (44, 44, 48),
    "titletxt": (150, 150, 152),
    "bg": (30, 32, 30),
    "fg": (166, 227, 161),
    "gray": (148, 148, 148),
    "dim": (106, 112, 106),
}
TRAFFIC_LIGHTS: list[Rgb] = [(158, 96, 92), (158, 142, 92), (105, 148, 100)]
##	Dimmer than fg, and across the wheel from green. 2 picked per seed.
IDENT_TINTS: list[Rgb] = [
    (196, 148, 108),
    (160, 136, 200),
    (112, 178, 196),
    (198, 140, 156),
    (170, 166, 108),
]
IDENT_USERS = ["mika", "joss", "arlo", "remy", "kai", "nova", "wren", "finn"]
IDENT_HOSTS = ["basalt", "kestrel", "onyx", "lyra", "quartz", "mesa", "flint", "juno"]

WPM_LETTERS = (160, 200)
WPM_DIGITS = 100
WPM_NOTES = (268, 302)
FLAG_PAUSE_MS = (200, 380)  # a beat of thought before a -flag
TYPO_RATE = 0.018  # per letter, at most 2 fixes a command
BLINK_MS = 530
##	A gif delay is in centiseconds, and browsers bump 0 and 1 up to 10, so 2
##	is as fast as it goes.
FRAME_MS = 20
SCROLL_RATE = 448  # px/s
GLIDE_FRAMES = 3

QWERTY_ROWS = ["1234567890", "qwertyuiop", "asdfghjkl", "zxcvbnm"]
ANSI_RE = re.compile(r"\x1b(\[[0-9;?]*[ -/]*[@-~]|\][^\x07\x1b]*(\x07|\x1b\\)|.)")
HOME_MARK = ".gen-demo-gif"


class KeyEvent(NamedTuple):
    action: str  # "type", "bs" or "pause"
    text: str | None
    delay: float  # ms


class TypedLine(NamedTuple):
    text: str
    color: str  # "fg" a command, "dim" a note
    wpm: tuple[float, float]
    typos: bool
    scale: float


class Ident(NamedTuple):
    user: str
    host: str


def skip(msg: str) -> NoReturn:
    ##	2 is a skip the stage warns about and gets past.
    sys.stderr.write(f"gen-demo-gif: {msg}\n")
    sys.exit(2)


def fail(msg: str) -> NoReturn:
    sys.stderr.write(f"gen-demo-gif: {msg}\n")
    sys.exit(1)


def optimize_gif(path: Path) -> bool:
    ##	Lossless: gifsicle can make single unchanged pixels transparent, where
    ##	Pillow writes one changed box per frame. Pixels and delays don't change.
    tmp = path.with_name(path.name + ".gifsicle")
    try:
        res = subprocess.run(
            ["gifsicle", "-O2", "--no-warnings", str(path), "-o", str(tmp)],
            capture_output=True,
            text=True,
            timeout=600,
        )
        if res.returncode == 0 and tmp.stat().st_size > 0:
            tmp.replace(path)
            return True
    except (OSError, subprocess.TimeoutExpired):
        pass
    tmp.unlink(missing_ok=True)
    return False


def find_font(prefs: list[str], size: float) -> tuple[ImageFont.FreeTypeFont, str]:
    ##	fc-match always answers with something, so the family has to match
    ##	before it's taken. Plain "monospace" takes whatever it gets.
    for name in [*prefs, "monospace"]:
        try:
            out = subprocess.run(
                ["fc-match", "-f", "%{file}\t%{family}\t%{style}", name],
                capture_output=True,
                text=True,
                timeout=10,
            ).stdout
        except (OSError, subprocess.TimeoutExpired):
            break
        path, family, style = ([*out.split("\t"), "", ""])[:3]
        want = re.sub(r"[^a-z]", "", name.lower())
        got = re.sub(r"[^a-z]", "", (family + style).lower())
        if path and (name == "monospace" or want in got):
            try:
                return ImageFont.truetype(path, size), f"{family.split(',')[0]} {style.split(',')[0]}".strip()
            except OSError:
                continue
    skip("no monospace font found")


def load_scenario(path: str) -> dict[str, Any]:
    ##	Scenario, TOML:
    ##	  title, prog, seed, font = [...]   window title, name typed, typing seed, fonts to try
    ##	  end_hold = 2.0, end_black = 3.0    seconds on the last frame, then on black
    ##	  home_as = "/home/{user}"           what the demo home shows as in output
    ##	  setup = "..."                      runs first in the demo home, unseen
    ##	  [[map]] find = 're', put = 'text'  applied to output after the home, in order
    ##	  [[step]]
    ##	    note = "..." or [...]            typed as # comments first
    ##	    show = "{prog} ..."              the command as typed. No show: run unseen
    ##	    run = "{bin} ..."                what runs, default show. $? is the last shown step's
    ##	    expect_exit = 0                  anything else fails the render
    ##	    pause = 2.6                      read time after the output, seconds
    ##	    overflow = "wrap"                or "truncate"
    ##	    clear = true                     start on a blank screen. Default: when the output wouldn't fit
    ##	    recall = true                    the last command comes back, as with the up arrow,
    ##	                                     and the rest of show is typed
    ##	    scrollrate, linems, gap, preenter, typescale, notepause
    try:
        with open(path, "rb") as f:
            sc = tomllib.load(f)
    except (OSError, tomllib.TOMLDecodeError) as e:
        fail(f"scenario: {e}")
    if not sc.get("step"):
        fail("scenario has no [[step]]")
    for step in sc["step"]:
        if not step.get("show") and not step.get("run") and not step_notes(step):
            fail("scenario has a step with no show, run or note")
    for m in sc.get("map", []):
        try:
            re.compile(m["find"])
            str(m["put"])
        except (KeyError, re.error) as e:
            fail(f"scenario: bad [[map]]: {e}")
    return sc


def step_notes(step: Step) -> list[str]:
    note = step.get("note", [])
    return [note] if isinstance(note, str) else list(note)


def demo_env(home: Path) -> dict[str, str]:
    ##	A home of its own, so nothing from the box running it gets in.
    env = {k: v for k, v in os.environ.items() if not k.startswith(("XDG_", "TUKFS_"))}
    env["HOME"] = str(home)
    env["PWD"] = str(home)
    for var, sub in (
        ("XDG_CONFIG_HOME", ".config"),
        ("XDG_CACHE_HOME", ".cache"),
        ("XDG_DATA_HOME", ".local/share"),
        ("XDG_STATE_HOME", ".local/state"),
    ):
        env[var] = str(home / sub)
    return env


def expand(cmd: str, binpath: str, here: str) -> str:
    for name, val in (("{bin}", binpath), ("{prog}", binpath), ("{here}", here)):
        cmd = cmd.replace(name, shlex.quote(val))
    return cmd


def run_cmd(cmd: str, home: Path, env: dict[str, str]) -> tuple[int, str]:
    ##	stderr down the same pipe, so lines come in the order a terminal shows them.
    try:
        res = subprocess.run(
            ["bash", "-c", cmd],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            errors="replace",
            timeout=60,
            cwd=home,
            env=env,
        )
    except subprocess.TimeoutExpired:
        fail(f"timed out: {cmd}")
    return res.returncode, res.stdout


class Scrubber:
    ##	Output is from a temp dir on this box, so the dir is shown as a generic
    ##	home, and this box's names as the prompt's. Then anything personal still
    ##	left fails the render rather than going into the README.
    def __init__(self, sc: dict[str, Any], home: Path, binpath: str, prog: str, ident: Ident) -> None:
        shown_home = str(sc.get("home_as", "/home/{user}")).replace("{user}", ident.user)
        homes = sorted({str(home), str(home.resolve())}, key=len, reverse=True)
        self.literal = [(binpath, prog), *((h, shown_home) for h in homes)]
        self.tokens: list[tuple[re.Pattern[str], str]] = []
        for real, fake in ((socket.gethostname(), ident.host), (getpass.getuser(), ident.user)):
            if len(real) >= 2:
                self.tokens.append((token_re(real), fake))
        self.maps = [(re.compile(m["find"]), str(m["put"])) for m in sc.get("map", [])]
        self.leaks = {getpass.getuser(), os.environ.get("HOME", ""), str(home), str(home.resolve())}
        self.leaks |= {str(Path(tempfile.gettempdir()).resolve()), "/mnt/", "/tmp/", "/media/", "/run/user"}
        self.leaks = {s for s in self.leaks if len(s) >= 3}
        self.leak_tokens = [token_re(socket.gethostname()), token_re(socket.getfqdn())]

    def __call__(self, text: str) -> str:
        for real, fake in self.literal:
            text = text.replace(real, fake)
        for pat, fake in self.tokens:
            text = pat.sub(fake, text)
        for pat, put in self.maps:
            text = pat.sub(put, text)
        return text

    def leak(self, text: str) -> str | None:
        for s in self.leaks:
            if s in text:
                return s
        for pat in self.leak_tokens:
            if pat.search(text):
                return pat.pattern
        return None


def token_re(word: str) -> re.Pattern[str]:
    ##	A whole token only. Checksums are base64url, so a host name can't be
    ##	found inside one.
    return re.compile(rf"(?<![A-Za-z0-9_.-]){re.escape(word)}(?![A-Za-z0-9_-])")


def run_all(sc: dict[str, Any], binpath: str, here: str, home: Path, scrub: Scrubber) -> list[list[str]]:
    ##	Every command runs before the first frame, in order, in one home.
    env = demo_env(home)
    if sc.get("setup"):
        rc, out = run_cmd(expand(sc["setup"], binpath, here), home, env)
        if rc:
            fail(f"setup exited {rc}: {out.strip()}")
    last_rc = 0
    outs: list[list[str]] = []
    for step in sc["step"]:
        cmd = step.get("run", step.get("show", ""))
        if not cmd:
            outs.append([])
            continue
        rc, out = run_cmd(f"(exit {last_rc}); " + expand(cmd, binpath, here), home, env)
        ##	A renamed flag would print an error, and the gif would show it as
        ##	if it were the tool working.
        want = int(step.get("expect_exit", 0))
        if rc != want:
            fail(f"step exited {rc}, not {want}: {cmd}\n{out}")
        if step.get("show"):
            last_rc = rc
        else:
            out = ""
        lines = [scrub(ln.expandtabs(8).rstrip()) for ln in ANSI_RE.sub("", out).rstrip("\n").split("\n")]
        outs.append(lines if out else [])
    return outs


def make_home() -> tuple[Path, str]:
    home = Path(tempfile.mkdtemp(prefix="gen-demo-gif.")).resolve()
    token = secrets.token_hex(16)
    (home / HOME_MARK).write_text(token + "\n")
    return home, token


def remove_home(home: Path, token: str) -> None:
    ##	rm -rf only on the dir make_home made: right under the temp dir, by its
    ##	name, ours, no link, and with the mark it wrote.
    base = Path(tempfile.gettempdir()).resolve()
    try:
        got = (home / HOME_MARK).read_text().strip()
        ok = (
            home.is_absolute()
            and home.parent == base
            and re.fullmatch(r"gen-demo-gif\.[A-Za-z0-9_]{6,}", home.name) is not None
            and not home.is_symlink()
            and home.resolve() == home
            and home.stat().st_uid == os.getuid()
            and str(home) not in ("/", "/tmp", os.environ.get("HOME", "/"))
            and got == token
        )
    except OSError:
        ok = False
    if not ok:
        sys.stderr.write(f"gen-demo-gif: left {home}, it doesn't look like the one made here\n")
        return
    shutil.rmtree(home)


def type_events(
    text: str,
    rng: random.Random,
    wpm_range: tuple[float, float],
    typos: bool = True,
    scale: float = 1.0,
) -> list[KeyEvent]:
    ##	Letters at the command's speed with jitter, digits slower, a beat before
    ##	a -flag, and the odd wrong key noticed and fixed.
    wpm = rng.uniform(*wpm_range) * scale
    events: list[KeyEvent] = []
    fixes = 0
    lead_len = len(text.partition(" ")[0])
    for i, ch in enumerate(text):
        if ch.isdigit():
            delay = 60000.0 / (WPM_DIGITS * scale * 5) * rng.uniform(0.82, 1.22)
        else:
            delay = 60000.0 / (wpm * 5) * rng.uniform(0.70, 1.34)
            if i < lead_len:
                delay *= 0.78  # the program's name is muscle memory
        if ch == "-" and (i == 0 or text[i - 1] == " "):
            delay += rng.uniform(*FLAG_PAUSE_MS)
        if typos and fixes < 2 and ch.isalpha() and rng.random() < TYPO_RATE:
            events.append(KeyEvent("type", neighbor_key(ch, rng), delay))
            overshoot = None
            if i + 1 < len(text) and text[i + 1].isalpha() and rng.random() < 0.4:
                overshoot = text[i + 1]
                events.append(KeyEvent("type", overshoot, 60000.0 / (wpm * 5)))
            events.append(KeyEvent("pause", None, rng.uniform(320, 640)))
            for _ in range(2 if overshoot else 1):
                events.append(KeyEvent("bs", None, rng.uniform(95, 150)))
            events.append(KeyEvent("type", ch, rng.uniform(140, 260)))
            fixes += 1
            continue
        events.append(KeyEvent("type", ch, delay))
    return events


def neighbor_key(ch: str, rng: random.Random) -> str:
    for row in QWERTY_ROWS:
        pos = row.find(ch.lower())
        if pos < 0:
            continue
        pick = rng.choice([row[j] for j in (pos - 1, pos + 1) if 0 <= j < len(row)])
        return pick.upper() if ch.isupper() else pick
    return ch


def build_palette(user_tint: Rgb, host_tint: Rgb) -> Image.Image:
    ##	One table for every frame, with short ramps from each text color to the
    ##	background, so antialiased edges map without dithering.
    def blend(a: Rgb, b: Rgb, k: float) -> Rgb:
        r, g, bl = (round(a[i] + (b[i] - a[i]) * k) for i in range(3))
        return r, g, bl

    t = THEME
    colors = [*t.values(), user_tint, host_tint, *TRAFFIC_LIGHTS]
    for c in (t["fg"], t["gray"], t["dim"], user_tint, host_tint):
        for k in (0.22, 0.45, 0.68, 0.86):
            colors.append(blend(t["bg"], c, k))
    for k in (0.35, 0.7):
        colors.append(blend(t["titlebar"], t["titletxt"], k))
    colors = list(dict.fromkeys(colors))
    colors = (colors + [(0, 0, 0)] * 256)[:256]
    pal = Image.new("P", (1, 1))
    pal.putpalette([v for c in colors for v in c])
    return pal


class Screen:
    ##	Scrollback plus the line being typed, seen through a window scrolled by
    ##	the pixel.
    def __init__(self, font: ImageFont.FreeTypeFont, title: str, prompt: list[Span], pal: Image.Image) -> None:
        self.font, self.title, self.prompt, self.pal = font, title, prompt, pal
        self.show_prompt = True  # off while a command's output comes in
        ascent, descent = font.getmetrics()
        self.cw = font.getlength("0")
        self.lh = ascent + descent + 3
        self.win_w = CANVAS_W - 2 * MARGIN
        self.win_h = CANVAS_H - 2 * MARGIN
        self.term_x = MARGIN + PAD
        self.term_y = MARGIN + TITLE_H + PAD
        self.cols = int((self.win_w - 2 * PAD) // self.cw)
        self.rows = int((self.win_h - TITLE_H - 2 * PAD) // self.lh)
        self.view_w = self.win_w - 2 * PAD
        self.view_h = self.rows * self.lh
        self.lines: list[list[Span]] = []
        self.typed = ""
        self.typed_key = "fg"  # dim while a note is typed
        self.scroll = 0.0  # px
        self._live: tuple[str, str, list[list[Span]]] | None = None

    def put(self, spans: list[Span]) -> None:
        self.lines.append(spans)

    def wrap(self, text: str, key: str = "fg", overflow: str = "wrap") -> list[list[Span]]:
        if overflow == "truncate" and len(text) > self.cols:
            return [[(text[: self.cols - 1], key), ("~", "dim")]]
        rows = [text[i : i + self.cols] for i in range(0, max(len(text), 1), self.cols)]
        return [[(r, key)] for r in rows]

    def wrap_spans(self, spans: list[Span]) -> list[list[Span]]:
        ##	A long command wraps the way a terminal wraps it, colors kept.
        rows: list[list[list[str]]] = []
        row: list[list[str]] = []
        used = 0
        for text, key in spans:
            for ch in text:
                if used + 1 > self.cols and row:
                    rows.append(row)
                    row, used = [], 0
                if row and row[-1][1] == key:
                    row[-1][0] += ch
                else:
                    row.append([ch, key])
                used += 1
        rows.append(row)
        return [[(t, k) for t, k in r] for r in rows]

    def live_rows(self) -> list[list[Span]]:
        if self._live is None or self._live[:2] != (self.typed, self.typed_key):
            self._live = (self.typed, self.typed_key, self.wrap_spans([*self.prompt, (self.typed, self.typed_key)]))
        return self._live[2]

    def clear(self) -> None:
        ##	The screen resets, with no `clear` typed.
        self.lines = []
        self.scroll = 0.0

    def rest_scroll(self) -> float:
        rows = len(self.lines) + (len(self.live_rows()) if self.show_prompt else 0)
        return max(0.0, rows * self.lh - self.view_h)

    def cursor_target(self) -> tuple[float, float]:
        live = self.live_rows()
        x = self.font.getlength("".join(t for t, _ in live[-1]))
        return x, (len(self.lines) + len(live) - 1) * self.lh - self.scroll

    def render(self, cursor: tuple[float, float] | None, colors: dict[str, Rgb]) -> Image.Image:
        img = Image.new("RGB", (CANVAS_W, CANVAS_H), THEME["outer"])
        d = ImageDraw.Draw(img)
        x0 = y0 = MARGIN
        d.rectangle([x0, y0, x0 + self.win_w - 1, y0 + self.win_h - 1], fill=THEME["bg"], outline=THEME["border"])
        d.rectangle([x0 + 1, y0 + 1, x0 + self.win_w - 2, y0 + TITLE_H], fill=THEME["titlebar"])
        for i, c in enumerate(TRAFFIC_LIGHTS):
            dot_x = x0 + 18 + i * 20
            d.ellipse([dot_x, y0 + 12, dot_x + 11, y0 + 23], fill=c)
        tw = d.textlength(self.title, font=self.font)
        d.text(
            (x0 + (self.win_w - tw) / 2, y0 + (TITLE_H - self.lh) / 2 + 1),
            self.title,
            font=self.font,
            fill=THEME["titletxt"],
        )

        ##	A layer the size of the view, so lines part way out clip at its edges.
        layer = Image.new("RGB", (self.view_w, self.view_h), THEME["bg"])
        ld = ImageDraw.Draw(layer)
        content = self.lines + (self.live_rows() if self.show_prompt else [])
        first = max(0, int(self.scroll // self.lh))
        last = min(len(content), int((self.scroll + self.view_h) // self.lh) + 2)
        for i in range(first, last):
            x = 0.0
            y = round(i * self.lh - self.scroll)
            for text, key in content[i]:
                ld.text((x, y), text, font=self.font, fill=colors[key])
                x += ld.textlength(text, font=self.font)
        if cursor is not None:
            cx, cy = cursor
            ld.rectangle([cx + 1, cy + 1, cx + self.cw, cy + self.lh - 3], fill=THEME["fg"])
        img.paste(layer, (self.term_x, self.term_y))
        return img.quantize(palette=self.pal, dither=Image.Dither.NONE)


def after_first_image(gif: bytes) -> int:
    ##	Offset past the first image: header and color table, extensions, then
    ##	the image descriptor, its table and its data.
    pos = 13
    if gif[10] & 0x80:
        pos += 3 << ((gif[10] & 7) + 1)
    while gif[pos] == 0x21:
        pos += 2
        while gif[pos]:
            pos += gif[pos] + 1
        pos += 1
    if gif[pos] != 0x2C:
        raise ValueError("no image in encoded batch")
    flags = gif[pos + 9]
    pos += 10
    if flags & 0x80:
        pos += 3 << ((flags & 7) + 1)
    pos += 1
    while gif[pos]:
        pos += gif[pos] + 1
    return pos + 1


def frame_delays(gif: bytes) -> list[int]:
    ##	Each frame's delay in ms, read off its graphic control block.
    pos = 13
    if gif[10] & 0x80:
        pos += 3 << ((gif[10] & 7) + 1)
    delays: list[int] = []
    pending = 0
    while pos < len(gif) and gif[pos] != 0x3B:
        if gif[pos] == 0x21:
            if gif[pos + 1] == 0xF9:
                pending = int.from_bytes(gif[pos + 4 : pos + 6], "little") * 10
            pos += 2
            while gif[pos]:
                pos += gif[pos] + 1
            pos += 1
        elif gif[pos] == 0x2C:
            flags = gif[pos + 9]
            pos += 10
            if flags & 0x80:
                pos += 3 << ((flags & 7) + 1)
            pos += 1
            while gif[pos]:
                pos += gif[pos] + 1
            pos += 1
            delays.append(pending)
            pending = 0
        else:
            raise ValueError(f"bad gif block at {pos}")
    return delays


class Movie:
    ##	Frames with their times. A frame the same as the one before makes that
    ##	one longer. Times round to whole 50 fps frames, the rest carried, so typing
    ##	keeps its pace. Encoded 32 at a time, each batch behind the last frame
    ##	of the one before, since held raw they ran to over a GB.
    BATCH = 32

    def __init__(self) -> None:
        self.durs: list[int] = []
        self._rem = 0.0
        self._pending: list[Image.Image] = []
        self._last_bytes: bytes | None = None
        self._lead: Image.Image | None = None
        self._done = 0
        self._gif: list[bytes] = []

    def add(self, img: Image.Image, ms: float) -> None:
        ms += self._rem
        dur = max(FRAME_MS, round(ms / FRAME_MS) * FRAME_MS)
        self._rem = ms - dur if ms > FRAME_MS else 0.0
        raw = img.tobytes()
        if raw == self._last_bytes:
            self.durs[-1] += dur
            return
        self._last_bytes = raw
        if len(self._pending) >= self.BATCH:
            self._encode()
        self._pending.append(img)
        self.durs.append(dur)

    def _encode(self) -> None:
        frames = self._pending
        durs = self.durs[self._done : self._done + len(frames)]
        if self._lead is not None:
            frames = [self._lead, *frames]
            durs = [self.durs[self._done - 1], *durs]
        buf = io.BytesIO()
        frames[0].save(
            buf, format="GIF", save_all=True, append_images=frames[1:], duration=durs, loop=0, optimize=False
        )
        gif = buf.getvalue()
        cut = after_first_image(gif) if self._lead is not None else 0
        self._gif.append(gif[cut:-1])  # one trailer, at the end
        self._done += len(self._pending)
        self._lead = self._pending[-1]
        self._pending = []

    def save(self, path: Path) -> None:
        if self._pending:
            self._encode()
        with open(path, "wb") as f:
            f.writelines(self._gif)
            f.write(b";")


def main() -> None:
    ap = argparse.ArgumentParser(description="Draw a demo gif of a CLI from a TOML scenario.")
    ap.add_argument("--scenario", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--bin", required=True)
    ap.add_argument("--seed", type=int, default=None)
    ap.add_argument("--font", default="")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    sc = load_scenario(args.scenario)
    binpath = str(Path(args.bin).resolve())
    if not os.access(binpath, os.X_OK):
        fail(f"no program to run at {args.bin}")
    rng = random.Random(args.seed if args.seed is not None else sc.get("seed", 11))
    prog = sc.get("prog", Path(binpath).name)

    prefs = [args.font] if args.font else list(sc.get("font", []))
    prefs += ["Monaspace Argon SemiBold", "JetBrains Mono", "Cascadia Mono", "DejaVu Sans Mono"]
    font, font_name = find_font([p for p in prefs if p], float(sc.get("fontsize", 15)))

    user_tint, host_tint = rng.sample(IDENT_TINTS, 2)
    ident = Ident(rng.choice(IDENT_USERS), rng.choice(IDENT_HOSTS))
    prompt: list[Span] = [
        (ident.user, "user"),
        ("@", "gray"),
        (ident.host, "host"),
        (":", "gray"),
        ("~", "gray"),
        ("$ ", "gray"),
    ]
    colors = dict(THEME, user=user_tint, host=host_tint)
    scr = Screen(font, sc.get("title", prog), prompt, build_palette(user_tint, host_tint))

    here = str(Path(args.scenario).resolve().parent)
    home, token = make_home()
    try:
        scrub = Scrubber(sc, home, binpath, prog, ident)
        step_out = run_all(sc, binpath, here, home, scrub)
    finally:
        remove_home(home, token)

    typed = [step.get("show", "").replace("{prog}", prog) for step in sc["step"]]
    typed += [n for step in sc["step"] for n in step_notes(step)]
    for i, ln in enumerate([ln for lines in step_out for ln in lines] + typed):
        hit = scrub.leak(ln)
        if hit:
            fail(f"line {i + 1} of the output or script shows {hit!r}")
        if any(ord(c) < 0x20 or ord(c) > 0x7E for c in ln):
            fail(f"line {i + 1} has a character the font may not draw: {ln!r}")

    mov = Movie()
    shown = list(scr.cursor_target())

    def snap(ms: float, cursor: bool = True) -> None:
        mov.add(scr.render((shown[0], shown[1]) if cursor else None, colors), ms)

    def glide_cursor(ms: float) -> None:
        ##	Ease toward the cell, then sit for the rest of the keystroke. The
        ##	glide never takes longer than the keystroke does.
        tx, ty = scr.cursor_target()
        x0, y0 = shown
        steps = max(1, min(int(ms // FRAME_MS), GLIDE_FRAMES))
        glide_ms: float = steps * FRAME_MS
        rest = ms - glide_ms
        if rest < FRAME_MS:
            glide_ms, rest = ms, 0.0
        for s in range(1, steps + 1):
            k = s / steps
            k = k * k * (3.0 - 2.0 * k)
            shown[0] = x0 + (tx - x0) * k
            shown[1] = y0 + (ty - y0) * k
            snap(glide_ms / steps)
        shown[0], shown[1] = tx, ty
        if rest:
            snap(rest)

    def settle(rate: float, cursor: bool = True) -> None:
        step = rate * FRAME_MS / 1000.0
        while abs(scr.rest_scroll() - scr.scroll) >= 0.5:
            d = scr.rest_scroll() - scr.scroll
            scr.scroll += (1 if d > 0 else -1) * min(abs(d), step)
            shown[:] = scr.cursor_target()
            snap(FRAME_MS, cursor)
        scr.scroll = scr.rest_scroll()
        shown[:] = scr.cursor_target()

    def emit(out_lines: list[str], rate: float, line_ms: float, overflow: str) -> None:
        ##	Lines go in as the view catches up, rather than settling after each
        ##	one, so the scroll keeps one speed instead of stuttering at every line.
        step = rate * FRAME_MS / 1000.0
        pending = [row for text in out_lines for row in scr.wrap(text, "fg", overflow)]
        while True:
            if pending and scr.rest_scroll() - scr.scroll <= step + 0.5:
                scr.put(pending.pop(0))
                if scr.rest_scroll() - scr.scroll <= 0.5:
                    snap(line_ms, cursor=False)  # still room, nothing scrolls
                    continue
            d = scr.rest_scroll() - scr.scroll
            if d <= 0.5:
                break
            scr.scroll += min(d, step)
            snap(FRAME_MS, cursor=False)
        scr.scroll = scr.rest_scroll()

    def blink_pause(total_ms: float) -> None:
        on = True
        left = total_ms
        while left > 0:
            step = min(BLINK_MS, left)
            snap(step, cursor=on)
            on = not on
            left -= step

    snap(700)
    last_cmd = ""
    for idx, step in enumerate(sc["step"]):
        rate = float(step.get("scrollrate", SCROLL_RATE))
        line_ms = float(step.get("linems", 26))
        overflow = step.get("overflow", "wrap")
        rows_out = sum(len(scr.wrap(t, "fg", overflow)) for t in step_out[idx])
        rows_in = len(step_notes(step)) + (1 if step.get("show") else 0) + rows_out + 2
        if step.get("clear", rows_in > scr.rows) and scr.lines:
            scr.clear()
            shown[:] = scr.cursor_target()
            snap(260)
        typing = [TypedLine("# " + n, "dim", WPM_NOTES, False, 1.0) for n in step_notes(step)]
        if step.get("show"):
            typing.append(
                TypedLine(
                    step["show"].replace("{prog}", prog),
                    "fg",
                    WPM_LETTERS,
                    True,
                    float(step.get("typescale", 1.0)),
                )
            )
        for line, key, wpm, typos, scale in typing:
            scr.typed_key = key
            if key == "fg" and step.get("recall"):
                ##	Up arrow: the last command comes back whole, and only the
                ##	rest is typed.
                if not last_cmd or not line.startswith(last_cmd):
                    fail(f"recall: {line!r} doesn't start with the last command")
                snap(rng.uniform(380, 520))
                scr.typed = last_cmd
                glide_cursor(rng.uniform(260, 360))
                line = line[len(last_cmd) :]
            for event in type_events(line, rng, wpm, typos, scale):
                if event.action == "type" and event.text:
                    scr.typed += event.text
                elif event.action == "bs":
                    scr.typed = scr.typed[:-1]
                glide_cursor(event.delay)
            snap(rng.uniform(260, 480) if key == "fg" else 130)  # a beat before Enter
            if key == "fg" and step.get("preenter"):
                blink_pause(1000 * float(step["preenter"]))
            for row in scr.wrap_spans([*scr.prompt, (scr.typed, key)]):
                scr.put(row)
            if key == "fg":
                last_cmd = scr.typed
            scr.typed = ""
            if key == "dim":
                if scr.rest_scroll() > scr.scroll + 0.5:
                    settle(rate)
                else:
                    glide_cursor(130)
                snap(140)
                if step.get("notepause"):
                    blink_pause(1000 * float(step["notepause"]))
                continue
            ##	The prompt comes back only once the output is all in, as in a shell.
            scr.show_prompt = False
            if scr.rest_scroll() > scr.scroll + 0.5:
                settle(rate, cursor=False)
            out_lines = ([""] if step.get("gap") else []) + step_out[idx]
            emit(out_lines, rate, line_ms, overflow)
            ##	A blank line before the next prompt, to read it apart.
            if out_lines and out_lines[-1].strip():
                scr.put([("", "fg")])
            scr.show_prompt = True
            shown[:] = scr.cursor_target()
            if scr.rest_scroll() > scr.scroll + 0.5:
                settle(rate)
            snap(60)
            blink_pause(1000 * float(step.get("pause", 2.6)))
        if not step.get("show"):
            blink_pause(1000 * float(step.get("pause", 2.6)))

    ##	A still last frame, then a cut to black, so the loop's seam is plain.
    ##	The black is one frame, where a fade would be dozens.
    hold_ms = 1000 * float(sc.get("end_hold", 2.0))
    black_ms = 1000 * float(sc.get("end_black", 3.0))
    if hold_ms > 0:
        snap(hold_ms)
    if black_ms > 0:
        mov.add(
            Image.new("RGB", (CANVAS_W, CANVAS_H), (0, 0, 0)).quantize(palette=scr.pal, dither=Image.Dither.NONE),
            black_ms,
        )

    out = Path(args.out)
    mov.save(out)
    squeezed = optimize_gif(out)
    delays = frame_delays(out.read_bytes())
    if not delays or min(delays) != FRAME_MS or any(d % FRAME_MS for d in delays):
        fail(f"frame times aren't all whole 50 fps frames: shortest {min(delays, default=0)} ms")
    if not args.quiet:
        secs = sum(delays) / 1000.0
        kb = out.stat().st_size // 1024
        print(
            f"gen-demo-gif: {len(delays)} frames, {secs:.1f} s loop, 50 fps, {kb} KiB"
            f"{'' if squeezed else ' (no gifsicle, so bigger)'}, font {font_name}, "
            f"{scr.cols}x{scr.rows} cells, shown as {ident.user}@{ident.host}"
        )


if __name__ == "__main__":
    main()


##	History:
##		- 2026-10-23: Copied from convert-base-v2's, cut down to ASCII output with
##		  one font. Steps check their exit code, $? is the last shown step's, a
##		  step with no show runs unseen, and output is shown with the temp home
##		  as a generic one and the box's names as the prompt's. Anything
##		  personal left fails it. 3 s of black at the end, and every frame time
##		  checked to be whole 50 fps frames.
