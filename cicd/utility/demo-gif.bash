#!/usr/bin/env bash

#  shellcheck disable=1091  ## 'Not following.' The include is checked on its own.

##	Purpose:
##		- The demo gif stage: gen-demo-gif.py draws the scenario against the
##		  release binary into the run's temp dir. The gif is GFS-rotated into
##		  ROTATE_DIR, and copied to OUT when it differs from what's there.
##		- No python3, Pillow or monospace font is a warning and exit 0, so the
##		  run goes on. A step that exits wrong, or output with anything
##		  personal in it, fails.
##		- ROTATE_DIR is resolved before anything goes in it, and has to end
##		  in /demo/gif with no link inside the private dir. Nothing is written
##		  anywhere else but OUT and TMPDIR, and nothing is removed here but by
##		  the rotation.
##	Syntax:
##		demo-gif.bash BIN SCENARIO OUT ROTATE_DIR STAMP
##		Run from the repo root, with TMPDIR the run's temp dir.
##	History: At bottom of script.

##	Copyright © 2026 t00mietum (CryptogID: ปʬϝღถɔ4რఠΔթะ9ƾǝu)
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


set -Eeuo pipefail

usage="usage: demo-gif.bash BIN SCENARIO OUT ROTATE_DIR STAMP"
bin="${1:?${usage}}"; scenario="${2:?${usage}}"; out="${3:?${usage}}"; rotateDir="${4:?${usage}}"; stamp="${5:?${usage}}"
meDir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${meDir}/include/gfs-rotate.bash"

fWarn(){ echo "[ WARNING: demo gif skipped: $* ]"; exit 0; }

[[ "${stamp}" =~ ^[0-9]{8}-[0-9]{6}$ ]] || { echo "demo-gif: bad stamp: ${stamp}" >&2; exit 1; }
[[ -x "${bin}" ]] || { echo "demo-gif: no release binary at ${bin}" >&2; exit 1; }
[[ -f "${scenario}" ]] || { echo "demo-gif: no scenario at ${scenario}" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || fWarn "python3 isn't installed"
python3 -c 'import PIL' 2>/dev/null || fWarn "Pillow isn't installed"
command -v gifsicle >/dev/null 2>&1 || echo "[ NOTE: no gifsicle, so the gif comes out bigger ]"
work="$(realpath -e -- "${TMPDIR:-}" 2>/dev/null || true)"
[[ -n "${work}" && "${work}" == */tukfs-hash/* ]] || { echo "demo-gif: TMPDIR isn't a cicd run dir: ${TMPDIR:-}" >&2; exit 1; }

t0="${EPOCHREALTIME}"
gif="${work}/demo_${stamp}.gif"
rc=0
env -u DISPLAY -u WAYLAND_DISPLAY python3 "${meDir}/gen-demo-gif.py" --scenario "${scenario}" --out "${gif}" --bin "${bin}" || rc=$?
case "${rc}" in
	0) ;;
	2) fWarn "see the line above" ;;
	*) echo "demo-gif: gen-demo-gif.py failed (${rc})" >&2; exit 1 ;;
esac
us=$(( ${EPOCHREALTIME/./} - ${t0/./} ))
printf 'demo gif drawn in %d.%d s\n' $((us / 1000000)) $((us % 1000000 / 100000))

## The private dir is a link to somewhere else entirely, so it's resolved, and
## the rest of the way has to be plain dirs. Made only once there's a gif.
rotReal=""
if [[ "${rotateDir}" != */demo/gif ]]; then
	echo "demo-gif: ${rotateDir} doesn't end in /demo/gif" >&2; exit 1
fi
privReal="$(realpath -e -- "${rotateDir%/demo/gif}" 2>/dev/null || true)"
if [[ -z "${privReal}" || ! -d "${privReal}" ]]; then
	echo "[ NOTE: no private dir at ${rotateDir%/demo/gif}, so no rotated copy ]"
else
	case "$(findmnt -no FSTYPE -T "${privReal}" 2>/dev/null || true)" in
		ntfs|ntfs3|fuseblk|apfs|hfs|hfsplus) echo "[ NOTE: ${privReal} is on NTFS, APFS or HFS+, so no rotated copy ]" ;;
		*)
			for d in "${privReal}/demo" "${privReal}/demo/gif"; do
				if [[ -L "${d}" ]] || { [[ -e "${d}" ]] && [[ ! -d "${d}" ]]; }; then
					echo "demo-gif: ${d} is a link or not a dir" >&2; exit 1
				fi
			done
			mkdir -p -- "${privReal}/demo/gif" || { echo "demo-gif: could not make ${privReal}/demo/gif" >&2; exit 1; }
			rotReal="$(realpath -e -- "${privReal}/demo/gif")"
			[[ "${rotReal}" == "${privReal}/demo/gif" ]] || { echo "demo-gif: ${privReal}/demo/gif resolves to ${rotReal}" >&2; exit 1; }
			;;
	esac
fi

newest="${gif}"
if [[ -n "${rotReal}" ]]; then
	## Born "frequent". The rotation gives it another role, by the stamp.
	cp -- "${gif}" "${rotReal}/demo_${stamp}_frequent.gif"
	gfs_rotate "${rotReal}" demo gif >/dev/null
	newest="$(compgen -G "${rotReal}/demo_${stamp}_*.gif" || true)"
	newest="${newest%%$'\n'*}"
	[[ -n "${newest}" ]] || { echo "demo-gif: the new gif went missing from ${rotReal} in the rotation" >&2; exit 1; }
	echo "rotated: ${newest}"
fi

if cmp -s -- "${newest}" "${out}"; then
	echo "${out} is already this gif"
else
	mkdir -p -- "$(dirname -- "${out}")"
	cp -- "${newest}" "${out}.tmp.$$"
	mv -f -- "${out}.tmp.$$" "${out}"
	echo "updated ${out} ($(stat -c %s -- "${out}") bytes)"
fi


##	History:
##		- 2026-10-23: Created, from shcl's gif stage.
