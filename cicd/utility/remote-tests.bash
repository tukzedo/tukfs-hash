#!/usr/bin/env bash

##	Purpose:
##		The unit tests and the integration test on a test box of another arch,
##		such as vmDebARM64, on the release build of it. The box is held through
##		the host lock, and put back the way it was found, by the VM state
##		helper's wrap, REMOTE_VM_WRAP in config.bash. Its work folder goes under
##		the box's temp root, made and removed there by box-side.bash.
##		The test binaries come from release-build.bash bins, before the box is
##		taken, so it isn't held through a container start.
##	Syntax:
##		remote-tests.bash HOST TARGET BINARY
##		REMOTE_LOCK_WAIT in config.bash is how long to wait for a box someone
##		else holds.
##	Exit: 0 = passed, 1 = a test failed, 3 = skipped, with "SKIP: <why>" as
##	      the last line, or the why alone in the file TUKFS_SKIP_WHY names,
##	      2 = can't run.
##	History: At bottom of script.

##	Copyright © 2026 t00mietum (CryptogID: ปʬϝღถɔ4რఠΔթะ9ƾǝu)
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


set -Eeuo pipefail

me="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${me}/include/leak-common.bash"

sshTo=(ssh -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=30 -o ServerAliveCountMax=4)

## To TUKFS_SKIP_WHY where the caller gives one, which says it itself.
fSkip(){ if [[ -n "${TUKFS_SKIP_WHY:-}" ]]; then printf '%s\n' "$*" > "${TUKFS_SKIP_WHY}"; else echo "SKIP: $*"; fi; exit 3; }

## Under the wrap, which holds HOST and has it up. Leaves "reached" once ssh
## answers, "skip" with the reason when the box can't take the tests, and
## "rc" with how the tests went.
fHeld(){   ## fHeld HOST STAGE_PARENT
	local host="$1" st="$2" out="" dir="" rc=0
	if ! "${sshTo[@]}" "${host}" true < /dev/null; then
		echo "${host} is up but doesn't answer ssh" > "${st}/skip"; return 0
	fi
	: > "${st}/reached"
	out="$("${sshTo[@]}" "${host}" bash -s -- make < "${st}/stage/box-side.bash")" || { echo "${host}: no work folder there" >&2; echo 1 > "${st}/rc"; return 1; }
	case "${out}" in
		missing=*) echo "${host} lacks ${out#missing=}, which the integration test needs" > "${st}/skip"; return 0 ;;
		dir=/*)    dir="${out#dir=}" ;;
		*)         echo "${host}: box-side.bash said: ${out}" >&2; echo 1 > "${st}/rc"; return 1 ;;
	esac
	echo "work folder: ${host}:${dir}"
	if tar -C "${st}/stage" -cf - . | "${sshTo[@]}" "${host}" "tar -C '${dir}' -xf -"; then
		fBg "${sshTo[@]}" "${host}" bash "${dir}/box-side.bash" test "${dir}" || rc=$?
	else
		echo "${host}: could not copy the tests over" >&2; rc=1
	fi
	## test removes it itself. This is for when it never got that far.
	"${sshTo[@]}" "${host}" bash -s -- gone "${dir}" < "${st}/stage/box-side.bash" > /dev/null 2>&1 || true
	echo "${rc}" > "${st}/rc"
	return "${rc}"
}

if [[ "${1:-}" == --held ]]; then
	(($# == 3)) || exit 2
	trap 'fStopDescendants' EXIT
	fStopOnSignals
	fHeld "$2" "$3"
	exit $?
fi

(($# == 3)) || { echo "usage: remote-tests.bash HOST TARGET BINARY" >&2; exit 2; }
host="$1"; target="$2"; bin="$3"
[[ "${host}" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "remote-tests: bad host name: ${host}" >&2; exit 2; }
[[ -f "${bin}" ]] || { echo "remote-tests: no build at ${bin}" >&2; exit 2; }
wrap="${REMOTE_VM_WRAP:-}"
[[ -n "${wrap}" && -x "${wrap}" ]] || fSkip "${host}: no VM state helper on this box to hold it with"
command -v ssh > /dev/null 2>&1 || fSkip "${host}: no ssh on this box"

trap 'fStopDescendants; fScratchGone || true' EXIT
fStopOnSignals
fScratchMake remote || exit 2
stage="${scratch}/stage"
mkdir -p -- "${stage}/unit" "${stage}/tests" "${stage}/src" "${stage}/cicd/utility/include" || exit 2
mapfile -t exes < <("${me}/release-build.bash" bins "${target}" | grep -E '^/.+/deps/[^/]+$' || true)
((${#exes[@]})) || { echo "remote-tests: no ${target} test binaries from release-build.bash bins" >&2; exit 1; }
cp -- "${exes[@]}" "${stage}/unit/"
cp -- "${bin}" "${stage}/${EXE_NAME}"
## What integration.bash reads from the tree beside it: the stop include, and
## the copyright line it checks --version against.
cp -- "${root}/tests/integration.bash" "${stage}/tests/"
cp -- "${root}/src/main.rs" "${stage}/src/"
cp -- "${here}/utility/include/stop-descendants.bash" "${stage}/cicd/utility/include/"
cp -- "${me}/libtest-quiet.bash" "${me}/box-side.bash" "${stage}/"
chmod 0755 -- "${stage}/${EXE_NAME}" "${stage}/unit/"* "${stage}/tests/integration.bash" "${stage}/libtest-quiet.bash"
echo "${host}: ${#exes[@]} unit test binary(s) and ${bin##*/}, as ${EXE_NAME}"

rc=0
fBg "${wrap}" wrap "${host}" --wait "${REMOTE_LOCK_WAIT:-900}" --why "${APP_NAME}: ${target} tests" \
	-- "${me}/remote-tests.bash" --held "${host}" "${scratch}" || rc=$?
## A stop of this script stays a stop.
if ((rc > 128)); then exit "${rc}"; fi
if [[ -s "${scratch}/skip" ]]; then fSkip "$(< "${scratch}/skip")"; fi
if [[ ! -e "${scratch}/reached" ]]; then
	fSkip "${host} wasn't reached (exit ${rc}): held elsewhere past ${REMOTE_LOCK_WAIT:-900} s, not a guest that starts here, or no ssh"
fi
got=1; { read -r got < "${scratch}/rc"; } 2> /dev/null || true
## The wrap's own 1 on a pass means the box wasn't put back, which isn't the
## tests' fault.
if [[ "${got}" == 0 && "${rc}" != 0 ]]; then echo "WARNING: ${host} wasn't put back as it was found (exit ${rc}); see the lines above"; fi
[[ "${got}" == 0 ]] || exit 1
exit 0


##	History:
##		- 2026-10-25: Created, for the arm64 tests on vmDebARM64.
