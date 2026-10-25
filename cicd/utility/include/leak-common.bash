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
## shellcheck source=../../config.bash
source "${here}/config.bash"

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


##	History:
##		- 2026-10-23: Created.
##		- 2026-10-25: A quarter of the cores, through cpu-cap.bash, at low
##		  priority.
