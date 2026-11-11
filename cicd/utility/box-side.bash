#!/usr/bin/env bash

##	Purpose:
##		The test box's side of remote-tests.bash, which sends it over ssh. Plain
##		bash and coreutils, since the box has nothing of the repo but what's
##		copied to it.
##		- make: a work folder, <temp>/tukfs-hash/<stamp>_<NNN>, with the mark
##		  .box-run in it, after removing stale ones there that have the mark.
##		  <temp> is HOST_TEMP, else TMPDIR, else /tmp, or /var/tmp when that
##		  one is in memory. Prints dir=PATH, or missing=TOOLS when the box
##		  lacks what the tests need.
##		- test DIR: the unit test binaries in DIR/unit, then the integration
##		  test on DIR/tukfs-hash, at low priority, then removes DIR.
##		- gone DIR: removes DIR, for when test never ran.
##	Syntax:
##		box-side.bash make|test DIR|gone DIR
##	Exit: 0 = done or passed, 1 = a test failed, 2 = can't run.
##	History: At bottom of script.

##	Copyright © 2026 t00mietum (CryptogID: ปʬϝღถɔ4რఠΔթะ9ƾǝu)
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


set -Euo pipefail

proj="tukfs-hash"
## What the integration test calls besides coreutils.
needs=(python3 sqlite3 getfattr setfattr b2sum)
temp="$(realpath -e -- "${HOST_TEMP:-${TMPDIR:-/tmp}}" 2>/dev/null)" || { echo "box-side: no temp root" >&2; exit 2; }
## The scan refuses a filesystem in memory, as on Debian's tmpfs /tmp, so
## then the on-disk one.
case "$(stat -f -c %T -- "${temp}" 2>/dev/null)" in
	tmpfs|ramfs) if [[ -d /var/tmp && -w /var/tmp ]]; then temp="$(realpath -e -- /var/tmp)"; fi ;;
esac
base="${temp}/${proj}"
## What make leaves in each folder it makes. Without it a folder isn't ours,
## such as a cicd run's, a kept integration test's, or one made by hand.
mark=".box-run"

## BASE/<stamp>_<NNN>, as fMake names them.
fRunDir(){ [[ "${base}" == /?* && "${1%/*}" == "${base}" && "${1##*/}" =~ ^[0-9]{8}-[0-9]{6}_[0-9]{3}$ ]]; }
## A folder, ours, that fMake marked.
fMarked(){ [[ -d "${1}" && ! -L "${1}" && -O "${1}" && -f "${1}/${mark}" && ! -L "${1}/${mark}" ]]; }

## Only a run folder of this script's, right under base, with no links, ours,
## and with the mark.
fSafeRm(){
	local p="${1:-}" real=''
	if [[ "${#}" -ne 1 || -z "${p}" || "${p}" == *..* || "${p}" == *//* || "${p}" == *$'\n'* ]]; then
		printf 'safe-rm: refused, bad path: "%s"\n' "${p}" >&2; return 1
	fi
	p="${p%/}"
	if ! fRunDir "${p}"; then
		printf 'safe-rm: refused, not a run folder: %s\n' "${p}" >&2; return 1
	fi
	if [[ -L "${p}" ]]; then printf 'safe-rm: refused, a link: %s\n' "${p}" >&2; return 1; fi
	real="$(realpath -e -- "${p}" 2> /dev/null)" || { printf 'safe-rm: refused, not there: %s\n' "${p}" >&2; return 1; }
	if [[ "${real}" != "${p}" ]]; then printf 'safe-rm: refused, goes through a link: %s\n' "${p}" >&2; return 1; fi
	if ! fMarked "${p}"; then
		printf 'safe-rm: refused, not one make made: %s\n' "${p}" >&2; return 1
	fi
	## The mark goes last, so a removal that fails partway leaves a folder the
	## sweep still knows (2026110210514819).
	find "${p}" -mindepth 1 -maxdepth 1 ! -name "${mark}" -exec rm -rf --one-file-system -- {} + &&
		rm -f -- "${p}/${mark}" && rmdir -- "${p}"
}

fMake(){
	local t d pid missing="" stamp n=1
	for t in "${needs[@]}"; do command -v "${t}" > /dev/null 2>&1 || missing+=" ${t}"; done
	if [[ -n "${missing}" ]]; then echo "missing=${missing# }"; return 0; fi
	mkdir -p -- "${base}" || return 2
	## Made by make, older than 2 days, and nothing left running from it. Not
	## at once, since make's PID in run.pid is gone before test starts.
	for d in "${base}"/*_[0-9][0-9][0-9]; do
		fMarked "${d}" || continue
		[[ -n "$(find "${d}" -maxdepth 0 -mmin +2880 2> /dev/null)" ]] || continue
		## Only a plain file is read, since a FIFO would hang it (2026111011092325).
		pid=""; [[ -f "${d}/run.pid" && ! -L "${d}/run.pid" ]] && { read -r pid < "${d}/run.pid"; } 2> /dev/null || true
		if [[ "${pid}" =~ ^[0-9]+$ && -d "/proc/${pid}" ]]; then continue; fi
		fSafeRm "${d}" || true
	done
	printf -v stamp '%(%Y%m%d-%H%M%S)T' -1
	printf -v d '%s/%s_%03d' "${base}" "${stamp}" "${n}"
	while ! mkdir -- "${d}" 2> /dev/null; do
		n=$((n + 1)); ((n < 1000)) || { echo "box-side: no free run folder in ${base}" >&2; return 2; }
		printf -v d '%s/%s_%03d' "${base}" "${stamp}" "${n}"
	done
	if ! : > "${d}/${mark}"; then rmdir -- "${d}" 2> /dev/null; echo "box-side: could not mark ${d}" >&2; return 2; fi
	echo "$$" > "${d}/run.pid"
	echo "dir=${d}"
}

## Half the cores, or a quarter when the 1-minute load is over half of them.
fCap(){
	local cores load
	cores="$(nproc)"; read -r load _ < /proc/loadavg
	awk -v c="${cores}" -v l="${load}" 'BEGIN { n = (l > c / 2) ? int(c / 4) : int(c / 2); print (n < 1) ? 1 : n }'
}

## Global, since the EXIT trap runs after fTest has returned.
testDir=""
fTest(){
	local dir="$1" cap t fails=0
	if ! { fRunDir "${dir}" && fMarked "${dir}"; }; then echo "box-side: not a run folder make made: ${dir}" >&2; return 2; fi
	testDir="${dir}"
	trap 'fSafeRm "${testDir}" || true' EXIT
	## So the EXIT trap runs on a stop or a dropped link too.
	trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 141' PIPE; trap 'exit 143' TERM
	echo "$$" > "${dir}/run.pid"
	cap="$(fCap)"
	mkdir -- "${dir}/tmp" || return 2
	## HOST_TEMP too, since the integration test takes it over TMPDIR.
	export TMPDIR="${dir}/tmp" TEMP="${dir}/tmp" TMP="${dir}/tmp" HOST_TEMP="${dir}/tmp" RUST_TEST_THREADS="${cap}"
	echo "on $(uname -n) ($(uname -m)), ${cap} of $(nproc) cores, in ${dir} ($(stat -f -c %T -- "${dir}"))"
	for t in "${dir}"/unit/*; do
		[[ -f "${t}" ]] || continue
		echo "unit tests: ${t##*/}"
		nice -n 19 ionice -c 3 "${dir}/libtest-quiet.bash" "${t}" --test-threads "${cap}" || fails=1
	done
	echo "integration test: ${dir}/tukfs-hash"
	nice -n 19 ionice -c 3 "${dir}/tests/integration.bash" "${dir}/tukfs-hash" || fails=1
	return "${fails}"
}

case "${1:-}" in
	make) fMake ;;
	test) (($# == 2)) || exit 2; fTest "$2" ;;
	gone) (($# == 2)) || exit 2; fSafeRm "$2" ;;
	*)    echo "usage: box-side.bash make|test DIR|gone DIR" >&2; exit 2 ;;
esac


##	History:
##		- 2026-10-25: Created, for the arm64 tests on vmDebARM64.
##		- 2026-10-25: HOST_TEMP for the integration test.
##		- 2026-10-28: The .box-run mark and an owner check, so make's sweep and
##		  the removals take only folders make made.
##		- 2026-11-07: The mark is removed last, so a removal that fails
##		  partway leaves the folder for the sweep.
##		- 2026-11-10: make's sweep reads run.pid only when it's a plain file.
