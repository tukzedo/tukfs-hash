#!/usr/bin/env bash

##	Purpose:
##		A scratch dir for one leak check, under TMPDIR, which in a cicd run is
##		the run's own temp dir. Its removal is the only rm -rf the leak checks
##		do, and it's guarded the way cicd.bash's fSafeRm is.
##			fScratchMake KIND   make <TMPDIR>/tukfs-hash-leak_<KIND>_<stamp>_<pid>
##			                    with this shell's token in its mark, into scratch
##			fScratchGone        remove it, but only when the path can only be
##			                    one, it has no links on the way, and the mark
##			                    holds the token
##	History: At bottom of script.

##	Copyright © 2026 t00mietum (CryptogID: ปʬϝღถɔ4რఠΔթะ9ƾǝu)
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


scratch=""
scratch_mark=".leak-run"
scratch_token="$$-${RANDOM}${RANDOM}-${EPOCHREALTIME}"

fScratchMake(){   ## fScratchMake KIND
	local base="" d="" stamp=""
	[[ "${1:-}" =~ ^[a-z0-9]+$ ]] || { echo "fScratchMake: bad kind: ${1:-}" >&2; return 1; }
	base="$(realpath -e -- "${TMPDIR:-/tmp}")" || return 1
	printf -v stamp '%(%Y%m%d-%H%M%S)T' -1
	d="${base}/tukfs-hash-leak_$1_${stamp}_$$"
	mkdir -- "${d}" || return 1
	printf '%s\n' "${scratch_token}" > "${d}/${scratch_mark}" || return 1
	scratch="${d}"
}

fScratchGone(){
	local p="${scratch}" real="" got="" fhs=""
	scratch=""
	[[ -n "${p}" ]] || return 0
	if [[ "${p}" != /* || "${p}" == *..* || "${p}" == *//* || "${p}" == *$'\n'* ]]; then
		printf 'cleanup: refused, bad path: "%s"\n' "${p}" >&2; return 1
	fi
	if ! [[ "${p}" =~ ^(/[A-Za-z0-9._+-]+)+/tukfs-hash-leak_[a-z0-9]+_[0-9]{8}-[0-9]{6}_[0-9]+$ ]]; then
		printf 'cleanup: refused, not a leak check scratch dir: %s\n' "${p}" >&2; return 1
	fi
	for fhs in / /bin /boot /dev /etc /home /lib /lib64 /media /mnt /opt /proc /root /run /sbin /srv /sys /tmp /usr /var "${HOME:-/}"; do
		if [[ "${p%/}" == "${fhs%/}" ]]; then printf 'cleanup: refused, system folder: %s\n' "${p}" >&2; return 1; fi
	done
	[[ -e "${p}" || -L "${p}" ]] || return 0
	real="$(realpath -e -- "${p}" 2>/dev/null || true)"
	if [[ "${real}" != "${p}" || ! -d "${p}" || -L "${p}" || ! -O "${p}" ]]; then
		printf 'cleanup: refused, a link, not a folder, or not ours: %s\n' "${p}" >&2; return 1
	fi
	{ read -r got < "${p}/${scratch_mark}"; } 2>/dev/null || true
	if [[ "${got}" != "${scratch_token}" ]]; then printf 'cleanup: not removed, no mark from this run: %s\n' "${p}" >&2; return 1; fi
	## cargo's registry and a failed test can leave files read-only.
	if ! rm -rf --one-file-system -- "${p}" 2>/dev/null; then
		chmod -R u+rwX -- "${p}" 2>/dev/null || true
		rm -rf --one-file-system -- "${p}" 2>/dev/null || { printf 'cleanup: could not remove all of %s\n' "${p}" >&2; return 1; }
	fi
}


##	History:
##		- 2026-10-23: Created, from cicd.bash's fSafeRm.
