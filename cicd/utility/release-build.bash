#!/usr/bin/env bash

#  shellcheck disable=1091  ## 'Not following.' The includes are checked on their own.
#  shellcheck disable=2034  ## 'variable appears unused.' ctr_step is read by ctr-image.bash.

##	Purpose:
##		The release builds, in the release image from cicd/container-release,
##		so the glibc they need is GLIBC_FLOOR and not whatever the box has.
##		Each target builds into REL_TARGET_DIR/<target>/release. arm64 is
##		cross-built, and its tests run under qemu-user in the same image.
##		- build: the release binary for each target.
##		- test: the unit tests for each target.
##		- bins: the path of each target's unit test binary, one a line, for
##		  a run on a box of that arch. Builds them first where needed.
##		--host builds on the box instead, into REL_HOST_TARGET_DIR, for when
##		there's no image. Then it needs the box's glibc, and only the box's
##		own target builds, since there's no cross gcc. cicd.bash picks it.
##	Syntax:
##		release-build.bash [--host] build|test|bins TARGET...
##		CPU_CAP sets the jobs and test threads (default half the cores, or a
##		quarter when the box is busy).
##	Exit: 0 = done, 1 = a build or test failed, 2 = can't run.
##	History: At bottom of script.

##	Copyright © 2026 t00mietum (CryptogID: ปʬϝღถɔ4რఠΔթะ9ƾǝu)
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


set -Eeuo pipefail

me="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${me}/include/leak-common.bash"
## Not a leak check, so not held to a quarter.
fCpuCap
trap 'fStopDescendants; fScratchGone || true' EXIT

fUsage(){ echo "usage: release-build.bash [--host] build|test|bins TARGET..." >&2; exit 2; }
onHost=0
if [[ "${1:-}" == --host ]]; then onHost=1; shift; fi
mode="${1:-}"
[[ "${mode}" == build || "${mode}" == test || "${mode}" == bins ]] || fUsage
shift
(($#)) || fUsage
for t in "$@"; do
	[[ " ${REL_TARGETS[*]} " == *" ${t} "* ]] || { echo "release-build: ${t} isn't one of ${REL_TARGETS[*]}" >&2; exit 2; }
	if ((onHost)) && [[ "${t}" != "$(uname -m)-unknown-linux-gnu" ]]; then
		echo "release-build: ${t} cross-builds only in the release image" >&2; exit 2
	fi
done

targetDir="${REL_TARGET_DIR}"
if ((onHost)); then
	targetDir="${REL_HOST_TARGET_DIR}"
elif ((! in_image)); then
	ctr_step="release-${mode}"
	source "${here}/utility/include/ctr-image.bash"
	fCtrUseRelease
	why="$(fCtrWhyNot)"
	[[ -z "${why}" ]] || { echo "release-build: ${why}; --host builds on the box, with its glibc" >&2; exit 2; }
	fScratchMake rel || exit 2
	fCtrReady "${scratch}" || exit 2
	fCtrFetch "${scratch}"
	rc=0
	fCtrRunSelf "${scratch}" "${REL_TARGET_DIR}" "${me}/release-build.bash" "${mode}" "$@" || rc=$?
	fScratchGone || true
	exit "${rc}"
fi

for t in "$@"; do
	if [[ "${mode}" == build ]]; then
		cargo build --release --locked -j "${CPU_CAP}" --target "${t}" --target-dir "${targetDir}" || exit 1
		continue
	fi
	## The image mounts the target dir at the same path, so these hold outside.
	if [[ "${mode}" == bins ]]; then
		cargo test --release --locked --no-run -j "${CPU_CAP}" --target "${t}" --target-dir "${targetDir}" --message-format json \
			| sed -n 's/.*"executable":"\([^"]*\)".*/\1/p' || exit 1
		continue
	fi
	## The pass lines were shown by the tests stage, so only what failed and
	## the counts.
	fScratchMake test || exit 2
	log="${scratch}/test.log"; rc=0
	TMPDIR="${scratch}" cargo test --release --locked -j "${CPU_CAP}" --target "${t}" --target-dir "${targetDir}" \
		-- --test-threads "${CPU_CAP}" >"${log}" 2>&1 || rc=$?
	grep -E '^test result:|FAILED|panicked|^failures:|^---- |^error' "${log}" || true
	fScratchGone || true
	((rc == 0)) || { echo "release-build: the ${t} tests exited ${rc}" >&2; exit 1; }
done


##	History:
##		- 2026-10-23: Created, for the glibc floor.
##		- 2026-10-25: Half the cores, or a quarter when busy.
##		- 2026-10-25: --host, for a box with no docker.
##		- 2026-10-25: bins, for the arm64 tests on vmDebARM64.
