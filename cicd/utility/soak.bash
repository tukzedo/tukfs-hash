#!/usr/bin/env bash

##	Purpose:
##		The soak test, src/soak.rs: scan a small tree, change a file, scan
##		again, then status and accept, 20 rounds in one process, failing when
##		the Rust heap or SQLite's at round 20 is past round 10 by more than
##		its margin. A plain debug build with --features soak, in a build dir
##		of its own, and only that test, since dhat counts every thread's
##		heap. Its table of both heaps by round goes in cicd/artifacts/soak/,
##		and when the heap grew, dhat's profile of it too, for dh_view.html.
##		On the host, like the integration test, with the toolchain
##		rust-toolchain.toml pins and dhat from Cargo.lock. A scan plans its
##		workers from the root's disks, which it finds through /dev, and a
##		container has none of the host's.
##	Syntax:
##		soak.bash
##	Exit: 0 = clean, 1 = the heap grew or the test failed, 2 = can't run.
##	History: At bottom of script.

##	Copyright © 2026 t00mietum (CryptogID: ปʬϝღถɔ4რఠΔթะ9ƾǝu)
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


set -Eeuo pipefail

me="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${me}/include/leak-common.bash"
trap 'fStopDescendants; fScratchGone || true' EXIT

if (($#)); then echo "soak: takes no arguments (see the header)" >&2; exit 2; fi
fLeakSandbox "${me}/soak.bash"
start="${SECONDS}"
art="${root}/cicd/artifacts/soak"
mkdir -p -- "${art}" "${LEAK_DIR}"

fScratchMake soak || exit 2
mkdir -p -- "${scratch}/tmp"
## Last run's, so a profile left by a failure isn't read as this one's.
rm -f -- "${art}/dhat-heap.json" "${art}/soak.txt"
rc=0
env -u RUSTFLAGS TMPDIR="${scratch}/tmp" TUKFS_SOAK_OUT="${art}" \
	cargo test -j "${CPU_CAP}" --locked --features soak --target-dir "${LEAK_DIR}/soak" \
	-- --exact soak::the_heap_holds_steady --test-threads 1 --nocapture >"${scratch}/soak.log" 2>&1 || rc=$?
if ((rc != 0)); then
	grep -E -A 4 'panicked|^test result|^error' "${scratch}/soak.log" || tail -n 40 "${scratch}/soak.log"
	if [[ -f "${art}/soak.txt" ]]; then cat "${art}/soak.txt"; fi
	if [[ -f "${art}/dhat-heap.json" ]]; then echo "soak: dhat's profile is in cicd/artifacts/soak/dhat-heap.json"; fi
	echo "soak: the soak test exited ${rc}" >&2
	exit 1
fi
grep -q '^test result: ok\. 1 passed' "${scratch}/soak.log" || { tail -n 20 "${scratch}/soak.log"; echo "soak: the soak test didn't run" >&2; exit 1; }
echo "soak: OK: $(tail -n 1 "${art}/soak.txt"); the table is in cicd/artifacts/soak/soak.txt ($((SECONDS - start)) s)"


##	History:
##		- 2026-10-23: Created.
##		- 2026-11-02: In the test sandbox.
