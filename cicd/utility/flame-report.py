#!/usr/bin/env python3

##	Purpose: Summarize the newest tukfs-hash profiler flamegraph - where a scan
##		spends its CPU by subsystem, the self-time hot spots, the call buckets,
##		and the caller chain of the top leaves - by parsing the pprof/inferno
##		SVG (its fg:w attribute = raw sample counts).
##		Runs two ways: plain (print the report, meant to run every cicd run) and
##		--check (print only when the newest flamegraph is newer than the one last
##		recorded in a local marker, then record it - meant for session startup so
##		a look is a no-op until there is something new to read).
##		From shcl's cicd/utility/flame-report.py.
##	Syntax: flame-report.py [--check [--force] [--no-mark]] [--dir DIR | --file SVG] [--top N]
##	Exit: 0 = reported, or SEEN; 2 = no dir, no graph, or one that won't parse.
##	History: At bottom of script.

##	Copyright © 2026 t00mietum (CryptogID: ปʬϝღถɔ4რఠΔթะ9ƾǝu)
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


from __future__ import annotations

import argparse
import bisect
import contextlib
import html
import re
import sys
import time
from pathlib import Path
from typing import NoReturn

STEP = 16.0  # row height in the SVG, px, until fParse reads the real one off the rows
SELF_TOP = 22  # self-time leaders to list
INCL_TOP = 14  # inclusive-time buckets to list
CHAIN = 4  # leaves whose caller chain we walk up to the root
SEEN_FILE = ".flame-seen"  # marker basename, kept in the profiling dir, which git ignores

NAME_RE = re.compile(r"flame_(\d{8}-\d{6})_\w+\.svg$")
FRAME_RE = re.compile(r"<title>(.*?)</title><rect ([^>]*?)/>", re.S)
ATTR_RES = {key: re.compile(re.escape(key) + r'="([\d.]+)"') for key in ("y", "fg:x", "fg:w")}
SAMPLES_RE = re.compile(r"\s*\(\d[\d,]* samples.*$")
SUBTITLE_RE = re.compile(r'<text id="subtitle"[^>]*>(.*?)</text>', re.S)
##	Runtime frames every stack goes through, which say nothing about the scan.
NOISE_RE = re.compile(r"^<?(std|core|alloc)::|^(all|start_thread|clone3|__libc_start_\w+|_start|main)$")

##	Where a sample's self time goes: the nearest frame up its stack that
##	matches one of these, so a pwrite under SQLite is SQLite's and a statx
##	under the walk is the walk's. Keyed on tukfs-hash's own function names, in
##	src/scan.rs, src/xattr.rs and src/db.rs, and the crates' names. A rename
##	there moves time into "other" with nothing else saying so.
BUCKETS: list[tuple[str, tuple[str, ...]]] = [
    ("hashing, blake3", ("blake3",)),
    ("hashing, blake2b", ("blake2b_simd",)),
    ("SQLite", ("rusqlite::", "sqlite3", "tukfs_hash::db::")),
    ("xattr reads", ("fgetxattr", "xattr::fget", "xattr::OnFile::read")),
    ("xattr writes", ("fsetxattr", "fremovexattr", "xattr::fset", "xattr::fremove", "xattr::write_", "xattr::remove_")),
    ("file reads, with open, stat and cache drop", ("scan::read_sums", "scan::open_noatime", "scan::Worker::")),
    ("directory walk", ("scan::walk", "scan::list_dir", "scan::queue")),
]

Frame = tuple[str, float, float, float]  # (name, x, y, w) in raw samples


def fSkip(msg: str) -> NoReturn:
    ##	2 = environmental skip (no dir / unparseable) - non-fatal, matches the
    ##	cicd profiler stage, which treats such things as a warning, not a failure.
    sys.stderr.write(f"flame-report: {msg}\n")
    sys.exit(2)


def fAge(path: Path) -> str:
    ##	How old the graph is, in whichever unit reads plainest, since nobody
    ##	reads a timestamp as an age and a stale graph has been read as today's.
    try:
        secs = max(0, int(time.time() - path.stat().st_mtime))
    except OSError:
        return "?"
    if secs < 5400:
        return f"{secs // 60}m"
    if secs < 172800:
        return f"{secs // 3600}h"
    return f"{secs // 86400}d"


def fNewest(pdir: Path) -> tuple[str, str] | None:
    ##	Sort on the timestamp, NOT the role suffix: GFS rotation retags the role
    ##	(frequent -> latest -> hour/day/...) as time passes, but the timestamp in
    ##	the name is stable.
    best = None
    for entry in pdir.iterdir():
        m = NAME_RE.match(entry.name)
        if m and (best is None or m.group(1) > best[0]):
            best = (m.group(1), entry.name)
    return best


def fAttr(attrs: str, key: str) -> float | None:
    vm = ATTR_RES[key].search(attrs)
    return float(vm.group(1)) if vm else None


def fParse(path: Path) -> tuple[int, list[Frame], str]:
    ##	Skip rather than trust anything that isn't a whole graph: a file cut
    ##	off mid-write, or one whose rows aren't where the row height says,
    ##	still gives a sample count and some frames, and a report on a fraction
    ##	of the samples. The row height comes off the rows themselves; the root
    ##	and the self-time sum are the checks that a graph is all there.
    global STEP
    text = path.read_text(encoding="utf-8", errors="replace")
    m = re.search(r'total_samples="(\d+)"', text)
    total = int(m.group(1)) if m else 0
    frames: list[Frame] = []
    for fm in FRAME_RE.finditer(text):
        attrs = fm.group(2)
        y, x, w = fAttr(attrs, "y"), fAttr(attrs, "fg:x"), fAttr(attrs, "fg:w")
        if y is None or x is None or w is None:
            continue
        name = SAMPLES_RE.sub("", html.unescape(fm.group(1)))
        frames.append((name, x, y, w))
    if not total or not frames:
        fSkip(f"could not parse a flamegraph out of {path}")
    if not text.rstrip().endswith("</svg>"):
        fSkip(f"{path} doesn't end in </svg>; cut off mid-write")
    ys = sorted({fr[2] for fr in frames})
    gaps = {round(b - a, 6) for a, b in zip(ys, ys[1:], strict=False)}
    if len(gaps) > 1:
        fSkip(f"rows aren't evenly spaced in {path} (gaps {sorted(gaps)}); not a whole flamegraph")
    if gaps:
        STEP = gaps.pop()
    roots = [fr for fr in frames if fr[2] == ys[-1]]
    if len(roots) != 1 or abs(roots[0][3] - total) > 1e-6:
        fSkip(f"no single root frame spanning all {total} samples in {path}; not a whole flamegraph")
    sm = SUBTITLE_RE.search(text)
    return total, frames, html.unescape(sm.group(1)).strip() if sm else ""


def fBucket(anc: list[str]) -> str:
    for a in anc:
        for bucket, keys in BUCKETS:
            if any(k in a for k in keys):
                return bucket
    return "other"


def fAnalyze(total: int, frames: list[Frame], top: int) -> None:
    ##	Rows keyed by y and sorted by x, with the x list beside each, so a
    ##	frame's parent or children are a bisect and a short walk rather than a
    ##	scan of the whole row for every frame.
    rows: dict[float, list[Frame]] = {}
    for fr in frames:
        rows.setdefault(fr[2], []).append(fr)
    rowXs: dict[float, list[float]] = {}
    for y, row in rows.items():
        row.sort(key=lambda fr: fr[1])
        rowXs[y] = [fr[1] for fr in row]
    eps = 1e-6

    def kids(fr: Frame) -> list[Frame]:
        _, x, y, w = fr
        row = rows.get(y - STEP)
        if not row:
            return []
        out = []
        for c in row[bisect.bisect_left(rowXs[y - STEP], x - eps) :]:
            if c[1] + c[3] > x + w + eps:
                break
            out.append(c)
        return out

    def parent(fr: Frame) -> Frame | None:
        _, x, y, w = fr
        row = rows.get(y + STEP)
        if not row:
            return None
        i = bisect.bisect_right(rowXs[y + STEP], x + eps) - 1
        if i >= 0 and row[i][1] + row[i][3] >= x + w - eps:
            return row[i]
        return None

    selfOf = {fr: fr[3] - sum(c[3] for c in kids(fr)) for fr in frames}
    if abs(sum(selfOf.values()) - total) > 1 or min(selfOf.values()) < -1e-6:
        fSkip(
            f"self time sums to {sum(selfOf.values()):.0f} of {total} samples; "
            "frames are missing or misplaced, not a whole flamegraph"
        )

    selfBy: dict[str, float] = {}
    inclBy: dict[str, float] = {}
    byName: dict[str, list[Frame]] = {}
    bucketBy: dict[str, float] = {}
    for fr in frames:
        name = fr[0]
        byName.setdefault(name, []).append(fr)
        ##	Once per stack: a recursive call, or one name inlined at two depths,
        ##	sits inside itself and would be counted again.
        up = parent(fr)
        while up and up[0] != name:
            up = parent(up)
        if not up:
            inclBy[name] = inclBy.get(name, 0.0) + fr[3]
        s = selfOf[fr]
        selfBy[name] = selfBy.get(name, 0.0) + s
        if s <= 0:
            continue
        anc: list[str] = []  # self, then each caller up to the root
        cur: Frame | None = fr
        while cur:
            anc.append(cur[0])
            cur = parent(cur)
        b = fBucket(anc)
        bucketBy[b] = bucketBy.get(b, 0.0) + s

    def pct(v: float) -> str:
        return f"{v / total * 100:5.1f}%"

    ##	The run's own steps sit right under the root, one per scan.
    rootY = max(rows)
    steps = rows.get(rootY - STEP, [])
    if steps:
        print("by step:")
        for fr in sorted(steps, key=lambda fr: fr[1]):
            print(f"  {pct(fr[3])} {int(fr[3]):4d}  {fr[0]}")
        print()

    print("attribution (self-time):")
    width = max(len(b) for b, _ in BUCKETS)
    for b in [b for b, _ in BUCKETS] + ["other"]:
        print(f"  {b} {'.' * (width + 3 - len(b))}: {pct(bucketBy.get(b, 0.0))}")
    print()

    print("top self-time (where CPU actually burns):")
    for name, v in sorted(selfBy.items(), key=lambda kv: -kv[1])[:top]:
        if v < 1:
            break
        print(f"  {pct(v)} {int(v):4d}  {name}")
    print()

    print("top inclusive (call buckets, leaving out std and core):")
    rest = [(n, v) for n, v in inclBy.items() if not NOISE_RE.search(n) and all(n != s[0] for s in steps)]
    for name, v in sorted(rest, key=lambda kv: -kv[1])[:INCL_TOP]:
        print(f"  {pct(v)} {int(v):4d}  {name}")
    print()

    print(f"caller chains of the top {CHAIN} leaves (leaving out std and core):")
    for name, v in sorted(selfBy.items(), key=lambda kv: -kv[1])[:CHAIN]:
        fr = max(byName[name], key=selfOf.__getitem__)
        print(f"  {name}  ({pct(v)} self)")
        cur, depth = parent(fr), 0
        while cur and depth < 10:
            if not NOISE_RE.search(cur[0]):
                print(f"      {cur[0]}")
                depth += 1
            cur = parent(cur)


def main() -> None:
    default_dir = Path(__file__).absolute().parent.parent / "artifacts" / "profiling"

    ap = argparse.ArgumentParser(description="Summarize the newest tukfs-hash profiler flamegraph.")
    ap.add_argument("--dir", default=default_dir, type=Path, help="profiling directory (default: %(default)s)")
    ap.add_argument("--file", help="analyze this SVG instead of the newest in --dir")
    ap.add_argument("--top", type=int, default=SELF_TOP, help="self-time leaders to list")
    ap.add_argument(
        "--check", action="store_true", help="startup gate: print only if newer than the local marker, then record it"
    )
    ap.add_argument("--force", action="store_true", help="with --check, report even if already seen")
    ap.add_argument("--no-mark", action="store_true", help="with --check, don't update the marker")
    a = ap.parse_args()

    if a.file:
        path = Path(a.file)
        if not path.is_file():
            fSkip(f"no such file: {path}")
        name = path.name
        m = NAME_RE.match(name)
        ts = m.group(1) if m else ""
    else:
        if not a.dir.is_dir():
            fSkip(f"no profiling dir: {a.dir}")
        nb = fNewest(a.dir)
        if not nb:
            fSkip(f"no flamegraphs in {a.dir}")
        ts, name = nb
        path = a.dir / name

    ##	SEEN only when the marker names the newest graph exactly, and --file never
    ##	moves it: a marker ahead of every graph would silence the gate for good.
    marker = a.dir / SEEN_FILE
    if a.check and not a.force and not a.file:
        seen = ""
        with contextlib.suppress(OSError):
            seen = marker.read_text().strip()
        if ts and ts == seen:
            print(f"SEEN {name}  (nothing newer than {seen}, {fAge(path)} old)")
            return

    total, frames, subtitle = fParse(path)
    print(f"{'NEW' if a.check else 'FLAME'} {name}  ({ts or 'n/a'}, {total} samples, {fAge(path)} old)")
    if subtitle:
        ##	The profiler's own count of CPU per step. A thread in the kernel
        ##	gets fewer samples than its share, so the graph understates the
        ##	system time here, which is reads, cache drops, attributes and the
        ##	walk. Wall time past the CPU is mostly waiting on the disk.
        print(f"  {subtitle}")
        print("  the graph undercounts the system time above, and the wall time past it is mostly waiting on the disk")
    print()
    fAnalyze(total, frames, a.top)

    if a.check and not a.no_mark and not a.file and ts:
        try:
            marker.write_text(ts + "\n")
        except OSError as e:
            sys.stderr.write(f"flame-report: could not write marker: {e}\n")


if __name__ == "__main__":
    main()


##	History:
##		- 2026-10-23: Copied from shcl's. Buckets redone for a scan, nearest
##		  caller wins. The profiler's CPU line from the subtitle replaces the
##		  sidecar, and std frames are left out of the call buckets and chains.
