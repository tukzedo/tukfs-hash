#!/usr/bin/env bash

#  shellcheck disable=1091  ## 'Not following.' The includes are checked on their own.
#  shellcheck disable=2034  ## 'variable appears unused.' Read by the scripts that source this.
#  shellcheck disable=2154  ## 'referenced but not assigned.' scratch comes from scratch.bash.

##	Purpose:
##		What the leak checks share. Set me to the calling script's dir, then
##		source this. It sets root, here (cicd/), CPU_CAP and in_image, and
##		sources config.bash, stop-descendants.bash, scratch.bash and
##		cpu-cap.bash. CPU_CAP is a quarter of the cores, since the leak checks
##		are heavy, and the script runs at nice 19 with idle I/O.
##			fLeakInImage NAME SCRIPT RW [ARG...]
##			                    run SCRIPT ARG... in the leak check image and
##			                    exit with its exit, when docker answers and
##			                    the image can be set up. Otherwise back, with
##			                    a one-line note, to run on the host. RW is
##			                    the dirs it writes, joined by ':'. Nothing in
##			                    the image itself, or with TUKFS_NO_IMAGE set.
##			                    leak_host_note=0 leaves the note to the
##			                    caller, with the reason in leak_why.
##	History: At bottom of script.

##	Copyright © 2026 t00mietum (CryptogID: ปʬϝღถɔ4რఠΔթะ9ƾǝu)
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


root="$(cd -- "${me:?}/../.." && pwd)"
here="${root}/cicd"
cd "${root}" || exit 2
source "${here}/utility/include/cpu-cap.bash"
fCpuLow
fCpuCap heavy
export PATH="${HOME}/.cargo/bin:${PATH}"
in_image=0
if [[ -n "${TUKFS_IN_IMAGE:-}" ]]; then in_image=1; fi
source "${here}/utility/include/stop-descendants.bash"
source "${here}/utility/include/scratch.bash"
# shellcheck source=../../config.bash
source "${here}/config.bash"

## A check that can't run on the host, with no image to run it in. A missing
## docker doesn't fail a gate, but the run it's in doesn't record its tree.
fLeakHostSkip(){   ## fLeakHostSkip NAME
	if [[ -n "${TUKFS_GATE_STRICT:-}" && "${TUKFS_GATE_SKIPS:-}" == /* ]]; then echo "$1" >> "${TUKFS_GATE_SKIPS}"; fi
	return 0
}

## Why it's on the host, for a caller that sets leak_host_note=0 and says
## so itself.
leak_why=""
fLeakInImage(){
	local name="$1" script="$2" rw="$3" rc=0
	shift 3
	((in_image)) && return 0
	if [[ -n "${TUKFS_NO_IMAGE:-}" ]]; then
		leak_why="TUKFS_NO_IMAGE is set"
	else
		ctr_step="${name}"
		source "${here}/utility/include/ctr-image.bash"
		leak_why="$(fCtrWhyNot)"
	fi
	if [[ -z "${leak_why}" ]]; then
		fScratchMake ctr || exit 2
		if fCtrReady "${scratch}"; then
			fCtrFetch "${scratch}"
			fCtrRunSelf "${scratch}" "${rw}" "${script}" "$@" || rc=$?
			fScratchGone || true
			exit "${rc}"
		fi
		leak_why="the leak check image couldn't be set up"
		fScratchGone || true
	fi
	if ((${leak_host_note:-1})); then echo "note: ${name}: ${leak_why}, so on the host"; fi
	return 0
}

## On the host, the script runs again in the test sandbox, which can write
## only to the build dirs, the artifacts and TMPDIR. Miri's sysroot is kept in
## the leak dir, since home is thrown away.
fLeakSandbox(){   ## fLeakSandbox SCRIPT [ARG...]
	local tgt="" art="" tmp=""
	((in_image)) && return 0
	[[ -z "${TUKFS_IN_SANDBOX:-}" ]] || return 0
	mkdir -p -- "${root}/target" "${LEAK_DIR}" "${root}/cicd/artifacts" || exit 2
	tgt="$(realpath -e -- "${root}/target")" && art="$(realpath -e -- "${root}/cicd/artifacts")" \
		&& tmp="$(realpath -e -- "${TMPDIR:-/tmp}")" || exit 2
	cargo fetch --locked -q || echo "note: cargo fetch failed (offline?); going on with what's cached"
	exec "${here}/utility/sandbox.bash" "${tgt}" "${art}" "${tmp}" -- \
		env TUKFS_IN_SANDBOX=1 XDG_CACHE_HOME="${LEAK_DIR}/xdg-cache" "$@"
}


##	History:
##		- 2026-10-23: Created.
##		- 2026-10-25: A quarter of the cores, through cpu-cap.bash, at low
##		  priority.
##		- 2026-11-02: fLeakSandbox.
