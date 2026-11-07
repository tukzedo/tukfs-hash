#!/usr/bin/env bash

##	Purpose:
##		The parser fuzz tests, each unit test named fuzz_*, for SECS of wall
##		time each: the mount table, zfs diff and btrfs find-new output, lists,
##		dates, and the xattr values. They run in every unit test run too, for
##		1 s each. Each case is a pure function of its seed, and a failure
##		prints the TUKFS_FUZZ_SEED that runs it again. On the host, from the
##		same release build as the unit tests, a quarter of the cores at a time.
##	Syntax:
##		fuzz.bash SECS
##	Exit: 0 = clean, 1 = a case failed, 2 = can't run.
##	History: At bottom of script.

##	Copyright © 2026 t00mietum (CryptogID: ปʬϝღถɔ4რఠΔթะ9ƾǝu)
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


set -Eeuo pipefail

me="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${me}/include/leak-common.bash"
trap 'fStopDescendants; fScratchGone || true' EXIT

secs="${1:-}"
if (($# != 1)) || ! [[ "${secs}" =~ ^[0-9]+$ ]]; then echo "usage: fuzz.bash SECS" >&2; exit 2; fi
fLeakSandbox "${me}/fuzz.bash" "$@"
start="${SECONDS}"
fScratchMake fuzz || exit 2
mkdir -p -- "${scratch}/tmp"
rc=0
TMPDIR="${scratch}/tmp" TUKFS_FUZZ_SECS="${secs}" \
	cargo test -j "${CPU_CAP}" --release --locked -- fuzz_ --test-threads "${CPU_CAP}" >"${scratch}/fuzz.log" 2>&1 || rc=$?
grep -E '^(PASS|FAIL) ' "${scratch}/fuzz.log" || true
if ((rc != 0)); then
	grep -E -A 4 'panicked|^error' "${scratch}/fuzz.log" || tail -n 40 "${scratch}/fuzz.log"
	echo "fuzz: a case failed (exit ${rc})" >&2
	exit 1
fi
## A filter that matched nothing would pass on nothing.
n="$(grep -cE '^PASS [0-9a-z]{5} .*::fuzz_' "${scratch}/fuzz.log" || true)"
if ((n < 1)); then tail -n 20 "${scratch}/fuzz.log"; echo "fuzz: no fuzz test ran" >&2; exit 1; fi
echo "fuzz: OK: ${n} parsers, ${secs} s each ($((SECONDS - start)) s)"


##	History:
##		- 2026-10-26: Created.
##		- 2026-11-02: In the test sandbox.
