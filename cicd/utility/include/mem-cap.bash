#!/usr/bin/env bash

#  shellcheck disable=2034  ## 'variable appears unused.' mem_ctr_args is read by ctr-image.bash.

##	Purpose:
##		The memory cap for cicd.bash and every container it starts, so a
##		runaway step dies alone, before the OOM killer reaches for the
##		desktop. A step killed at the cap exits 137, and fails.
##			fMemCap           set mem_cap from CICD_MEM_CAP, a docker size
##			                  such as 24g, or none for no cap, which leaves
##			                  mem_cap empty. Unset or empty is the default,
##			                  a third of MemTotal, 4g to 32g. Anything else
##			                  says so on one line and returns 1, as does a
##			                  size under 512m, which can't run a step.
##			fMemCtrArgs       mem_ctr_args for a docker run: --memory and
##			                  --memory-swap both at the cap, so no swap, and
##			                  --oom-score-adj 1000, first in line for the OOM
##			                  killer. Empty for none. Returns 1 on a bad
##			                  CICD_MEM_CAP.
##			fMemScope SCRIPT [ARG...]
##			                  exec bash SCRIPT ARG... in a systemd user scope
##			                  with MemoryMax at the cap, no swap, and under
##			                  choom 1000. Once: TUKFS_MEM_SCOPE marks a run
##			                  already in it. Returns, having done nothing,
##			                  for none, or where there's no user systemd or
##			                  no choom, as on a bare CI runner or another OS.
##		No step needs more than the default. The peaks on b23 to 2026-11-08,
##		page cache included, were CodeQL 15.1 GB, ASan 2.0 GB, Miri 1.6 GB
##		and the tests 1.5 GB.
##		TUKFS_MEMINFO reads another file in place of /proc/meminfo, for a test.
##	History: At bottom of script.

##	Copyright © 2026 t00mietum (CryptogID: ปʬϝღถɔ4რఠΔթะ9ƾǝu)
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


mem_cap=""
mem_ctr_args=()

fMemCap(){
	local kb="" g=0
	mem_cap="${CICD_MEM_CAP:-}"
	if [[ "${mem_cap}" == none ]]; then mem_cap=""; return 0; fi
	if [[ -z "${mem_cap}" ]]; then
		kb="$(awk '/^MemTotal:/ { print $2; exit }' "${TUKFS_MEMINFO:-/proc/meminfo}" 2>/dev/null || true)"
		[[ "${kb}" =~ ^[0-9]{1,12}$ ]] || kb=0
		g=$((kb / 3 / 1048576)); ((g <= 32)) || g=32; ((g >= 4)) || g=4
		mem_cap="${g}g"
	fi
	## Matched, never read as arithmetic, so x[$(cmd)] can't run.
	if [[ ! "${mem_cap}" =~ ^[1-9][0-9]{0,14}[kmgKMG]?$ ]]; then
		echo "CICD_MEM_CAP '${CICD_MEM_CAP:-}' isn't a size such as 24g, or none" >&2
		mem_cap=""; return 1
	fi
	mem_cap="${mem_cap,,}"
	## Floor of 512m. 15 digits at most, so k and bytes can't overflow; m and g need no scaling.
	local n="${mem_cap%[kmg]}" u="${mem_cap:${#mem_cap}-1}"
	case "${u}" in
		g) ;;
		m) ((n >= 512)) || u=small ;;
		k) ((n >= 524288)) || u=small ;;
		*) ((n >= 536870912)) || u=small ;;
	esac
	if [[ "${u}" == small ]]; then
		echo "CICD_MEM_CAP '${CICD_MEM_CAP:-}' is under the 512m floor (32 means 32 bytes; did you mean 32g?)" >&2
		mem_cap=""; return 1
	fi
}

fMemCtrArgs(){
	mem_ctr_args=()
	fMemCap || return 1
	[[ -z "${mem_cap}" ]] || mem_ctr_args=(--memory "${mem_cap}" --memory-swap "${mem_cap}" --oom-score-adj 1000)
	return 0
}

## The containers are dockerd's children, outside the scope, so fMemCtrArgs
## caps them apart. OOMPolicy continue, so a step the kernel kills fails,
## and the run's cleanup still runs. systemd wants the suffix upper case.
fMemScope(){   ## fMemScope SCRIPT [ARG...]
	local -a props=()
	[[ -z "${TUKFS_MEM_SCOPE:-}" ]] || return 0
	fMemCap || return 1
	[[ -n "${mem_cap}" ]] || return 0
	command -v systemd-run >/dev/null 2>&1 || return 0
	command -v choom >/dev/null 2>&1 || return 0
	props=(-p "MemoryMax=${mem_cap^^}" -p MemorySwapMax=0 -p OOMPolicy=continue)
	systemd-run --user --scope --quiet "${props[@]}" true >/dev/null 2>&1 || return 0
	export TUKFS_MEM_SCOPE="${mem_cap}"
	exec systemd-run --user --scope --quiet "${props[@]}" choom -n 1000 -- bash "$@"
}


##	History:
##		- 2026-11-10: A floor of 512m.
##		- 2026-11-09: Created. CICD_MEM_CAP, no swap and oom-score-adj 1000
##		  for each container, and the run on the host in a user scope.
