#!/usr/bin/env python3

##	Purpose: Test IDs. Every test the pipeline runs has one, and prints it on
##		its status line. An ID is the test's creation time in seconds since
##		2000-01-01 00:00 UTC, in base 62 (0-9, A-Z, a-z), padded to 6
##		characters, so IDs sort by age. Tests from the same second got the
##		next free second, in file order.
##		From shcl's cicd/utility/test-ids.py.
##	Syntax:
##		test-ids.py new [COUNT]   print COUNT fresh IDs (default 1)
##		test-ids.py when ID ...   print the time each ID stands for
##		test-ids.py find ID ...   print where each ID is defined
##		test-ids.py check         every test has an ID, and no 2 share one
##	Exit: 0 = clean, 1 = a check failed, 2 = usage.
##	History: At bottom of script.

##	Copyright © 2026 t00mietum (CryptogID: ปʬϝღถɔ4რఠΔթะ9ƾǝu)
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


from __future__ import annotations

import fnmatch
import re
import subprocess
import sys
import time
from datetime import UTC, datetime
from pathlib import Path

DIGITS = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
EPOCH_2000 = 946684800
WIDTH = 6
ID = r"[0-9A-Za-z]{6}"
repo = Path(__file__).resolve().parents[2]


def encode(secs: int) -> str:
    out = ""
    while secs:
        secs, digit = divmod(secs, 62)
        out = DIGITS[digit] + out
    return out.rjust(WIDTH, "0")


def decode(tid: str) -> int:
    secs = 0
    for ch in tid:
        secs = secs * 62 + DIGITS.index(ch)
    return secs


def fWhen(tid: str) -> str:
    stamp = datetime.fromtimestamp(EPOCH_2000 + decode(tid), tz=UTC)
    return stamp.strftime("%Y-%m-%d %H:%M:%S UTC")


##	A Rust test's ID is the first line of its body, the line after its fn
##	line, past any attributes.
RUST_GLOB = "src/*.rs"
RUST_TEST = r"^\s*#\[test\]$"
RUST_ID = rf'^\s*let _id = test_id\("({ID})"\);$'
##	Every #[test] in a tracked file. One outside RUST_GLOB would run with no
##	ID and nothing here saying so.
STRAY = r"^\s*#\[test\]"
##	The integration test's checks: check, expect and skip calls, each with its
##	ID as the first word. A skip stands for a check that didn't run, so its
##	ID has to be one a check has. A word that's a positional parameter is a
##	helper passing it on.
IT_FILE = "tests/integration.bash"
IT_CALL = re.compile(r"(?:^|;|&&|\|\||\bthen\b|\belse\b|\bdo\b|\{)\s*(check|expect|skip|ok|bad)\s+(\S+)")
IT_HELPER = r'^"\$\{[1-9]\}"$'


def fLiveLines(path: Path) -> list[str]:
    return ["" if line.lstrip().startswith("#") else line for line in path.read_text(encoding="utf-8").splitlines()]


def fScan() -> tuple[list[tuple[str, str, int]], list[str]]:
    found: list[tuple[str, str, int]] = []
    bad: list[str] = []

    placed = set()
    for path in sorted(repo.glob(RUST_GLOB)):
        rel = str(path.relative_to(repo))
        placed.add(rel)
        lines = path.read_text(encoding="utf-8").splitlines()
        for n, line in enumerate(lines):
            if not re.match(RUST_TEST, line):
                continue
            m = n + 1
            while m < len(lines) and (not lines[m].strip() or lines[m].lstrip().startswith("#[")):
                m += 1
            hit = re.match(RUST_ID, lines[m + 1]) if m + 1 < len(lines) else None
            if hit is None:
                bad.append(f"{rel}:{n + 1}: a test with no ID line under its fn line")
                continue
            found.append((hit.group(1), rel, m + 2))

    tracked = (
        subprocess.run(["git", "-C", str(repo), "ls-files", "-z"], capture_output=True, check=True)
        .stdout.decode()
        .split("\0")
    )
    for rel in sorted(t for t in tracked if fnmatch.fnmatch(t, "*.rs") and t not in placed):
        for n, line in enumerate((repo / rel).read_text(encoding="utf-8").splitlines()):
            if re.match(STRAY, line):
                bad.append(f"{rel}:{n + 1}: a test outside {RUST_GLOB}, where nothing here looks")

    skips: list[tuple[str, str, int]] = []
    for n, line in enumerate(fLiveLines(repo / IT_FILE)):
        for hit in IT_CALL.finditer(line):
            word, first = hit.group(1), hit.group(2)
            if re.match(IT_HELPER, first):
                continue
            if word in ("ok", "bad"):
                bad.append(f"{IT_FILE}:{n + 1}: {word} called outside check and expect")
            elif not re.fullmatch(ID, first):
                bad.append(f"{IT_FILE}:{n + 1}: a {word} with no ID first")
            elif word == "skip":
                skips.append((first, IT_FILE, n + 1))
            else:
                found.append((first, IT_FILE, n + 1))
    have = {tid for tid, _, _ in found}
    for tid, file, line in skips:
        if tid not in have:
            bad.append(f"{file}:{line}: skip {tid} is no check's ID")
    return found, bad


def fCheck() -> int:
    found, bad = fScan()
    now = time.time() - EPOCH_2000 + 86400
    first: dict[str, str] = {}
    for tid, file, line in found:
        at = f"{file}:{line}"
        if tid in first:
            bad.append(f"{at}: ID {tid} is already used at {first[tid]}")
            continue
        first[tid] = at
        ## Nothing here is older than the repo, and nothing is from the future.
        if not 26 * 365 * 86400 < decode(tid) < now:
            bad.append(f"{at}: ID {tid} stands for {fWhen(tid)}")
    for problem in bad:
        print(f"test-ids: {problem}", file=sys.stderr)
    if bad:
        print(
            f"test-ids: {len(bad)} problem(s). A new test takes its ID from `cicd/utility/test-ids.py new`.",
            file=sys.stderr,
        )
        return 1
    print(f"test-ids: OK ({len(found)} tests)")
    return 0


def fNew(count: int) -> int:
    used = {tid for tid, _, _ in fScan()[0]}
    secs = int(time.time() - EPOCH_2000)
    while count:
        tid = encode(secs)
        secs += 1
        if tid in used:
            continue
        print(tid)
        count -= 1
    return 0


def main() -> int:
    args = sys.argv[1:]
    if not args or args[0] in ("-h", "--help"):
        for line in Path(__file__).read_text(encoding="utf-8").splitlines():
            if line.startswith("##\tHistory"):
                break
            if line.startswith("##"):
                print(line[2:].replace("\t", "", 1))
        return 0 if args else 2
    cmd, rest = args[0], args[1:]
    if cmd == "new" and len(rest) <= 1 and all(a.isdigit() and int(a) > 0 for a in rest):
        return fNew(int(rest[0]) if rest else 1)
    if cmd == "when" and rest and all(re.fullmatch(ID, a) for a in rest):
        for tid in rest:
            print(f"{tid}  {fWhen(tid)}")
        return 0
    if cmd == "find" and rest:
        found = fScan()[0]
        rc = 0
        for tid in rest:
            hits = [f"{file}:{line}" for t, file, line in found if t == tid]
            if not hits:
                print(f"{tid}  not found", file=sys.stderr)
                rc = 1
            for hit in hits:
                print(f"{tid}  {hit}")
        return rc
    if cmd == "check" and not rest:
        return fCheck()
    print(f"test-ids: bad arguments: {' '.join(args)} (try --help)", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())


##	History:
##		2026-10-23  Created from shcl's, in seconds, for the Rust tests and the
##		            integration test's checks.
