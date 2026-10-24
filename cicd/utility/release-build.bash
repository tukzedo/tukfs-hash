#!/usr/bin/env bash

#  shellcheck disable=1091  ## 'Not following.' The includes are checked on their own.
#  shellcheck disable=2154  ## 'referenced but not assigned.' The REL_ settings and in_image come from config.bash, through leak-common.bash.

##	Purpose:
##		The release builds, in the release image from cicd/container-release,
##		so the glibc they need is GLIBC_FLOOR and not whatever the box has.
##		Each target builds into REL_TARGET_DIR/<target>/release. arm64 is
##		cross-built, and its tests run under qemu-user in the same image.
##		- build: the release binary for each target.
##		- test: the unit tests for each target.
##		There's no host fallback, since a build on the host would need the
##		host's glibc. --no-release leaves the whole stage out instead.
##	Syntax:
##		release-build.bash build|test TARGET...
##		CPU_CAP sets the jobs and test threads (default half the cores).
##	Exit: 0 = done, 1 = a build or test failed, 2 = can't run.
##	History: At bottom of script.

##	Copyright © 2026 t00mietum (CryptogID: ปʬϝღถɔ4რఠΔթะ9ƾǝu)
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


set -Eeuo pipefail

me="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${me}/include/leak-common.bash"
trap 'fStopDescendants; fScratchGone || true' EXIT

fUsage(){ echo "usage: release-build.bash build|test TARGET..." >&2; exit 2; }
mode="${1:-}"
[[ "${mode}" == build || "${mode}" == test ]] || fUsage
shift
(($#)) || fUsage
for t in "$@"; do
	[[ " ${REL_TARGETS[*]} " == *" ${t} "* ]] || { echo "release-build: ${t} isn't one of ${REL_TARGETS[*]}" >&2; exit 2; }
done

if ((! in_image)); then
	source "${here}/utility/include/ctr-image.bash"
	fCtrUseRelease
	why="$(fCtrWhyNot)"
	[[ -z "${why}" ]] || { echo "release-build: ${why}, and the release builds need the release image" >&2; exit 2; }
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
		cargo build --release --locked -j "${CPU_CAP}" --target "${t}" --target-dir "${REL_TARGET_DIR}" || exit 1
		continue
	fi
	## The pass lines were shown by the tests stage, so only what failed and
	## the counts.
	fScratchMake test || exit 2
	log="${scratch}/test.log"; rc=0
	TMPDIR="${scratch}" cargo test --release --locked -j "${CPU_CAP}" --target "${t}" --target-dir "${REL_TARGET_DIR}" \
		-- --test-threads "${CPU_CAP}" >"${log}" 2>&1 || rc=$?
	grep -E '^test result:|FAILED|panicked|^failures:|^---- |^error' "${log}" || true
	fScratchGone || true
	((rc == 0)) || { echo "release-build: the ${t} tests exited ${rc}" >&2; exit 1; }
done


##	History:
##		- 2026-10-23: Created, for the glibc floor.
