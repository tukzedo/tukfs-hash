#!/usr/bin/env bash

#  shellcheck disable=2034  ## 'variable appears unused.' cpu_why is read by the scripts that source this.

##	Purpose:
##		How many jobs a step gets, and the low priority all of it runs at,
##		worked out here for cicd.bash and every script it starts.
##			fCpuCap [heavy]   set and export CPU_CAP, CARGO_BUILD_JOBS and
##			                  RUST_TEST_THREADS: half the logical CPUs, or a
##			                  quarter when the 1-minute load is over half the
##			                  CPU count. heavy is a quarter, busy or not, for
##			                  the leak checks, sanitizer builds and soak.
##			                  Never under 1. A CPU_CAP the caller set wins
##			                  over all of it. cpu_why says what it went by.
##			fCpuLow           nice 19 and the idle I/O class for this shell,
##			                  which every process it starts then inherits.
##		TUKFS_CPU_AUTO=1 marks a CPU_CAP as worked out here, so a script the
##		run starts works its own out again rather than take it as the caller's.
##		TUKFS_LOADAVG reads another file in place of /proc/loadavg, for a test.
##		A container gets CPU_CAP and nice from ctr-image.bash.
##	History: At bottom of script.

##	Copyright © 2026 t00mietum (CryptogID: ปʬϝღถɔ4რఠΔթะ9ƾǝu)
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


cpu_cores="$(nproc 2>/dev/null || echo 2)"
[[ "${cpu_cores}" =~ ^[1-9][0-9]{0,4}$ ]] || cpu_cores=2
cpu_given=""
if [[ "${TUKFS_CPU_AUTO:-}" != 1 && "${CPU_CAP:-}" =~ ^[1-9][0-9]{0,3}$ ]]; then cpu_given="${CPU_CAP}"; fi
cpu_why=""

fCpuCap(){   ## fCpuCap [heavy]
	local l1="" n=0 hundredths=0
	if [[ -n "${cpu_given}" ]]; then
		CPU_CAP="${cpu_given}"; cpu_why="CPU_CAP set by the caller"
	else
		{ read -r l1 _ < "${TUKFS_LOADAVG:-/proc/loadavg}"; } 2>/dev/null || true
		## Matched before arithmetic sees it.
		if [[ "${l1}" =~ ^([0-9]{1,6})\.([0-9]{2})$ ]]; then
			hundredths=$(( 10#${BASH_REMATCH[1]} * 100 + 10#${BASH_REMATCH[2]} ))
		else
			l1="unknown"
		fi
		if [[ "${1:-}" == heavy ]]; then
			n=$((cpu_cores / 4)); cpu_why="a quarter, for a heavy step"
		elif ((hundredths * 2 > cpu_cores * 100)); then
			n=$((cpu_cores / 4)); cpu_why="a quarter, since the load of ${l1} is over half"
		else
			n=$((cpu_cores / 2)); cpu_why="half, at a load of ${l1}"
		fi
		((n >= 1)) || n=1
		CPU_CAP="${n}"
		export TUKFS_CPU_AUTO=1
	fi
	export CPU_CAP CARGO_BUILD_JOBS="${CPU_CAP}" RUST_TEST_THREADS="${CPU_CAP}"
}

fCpuLow(){
	renice -n 19 -p "$$" >/dev/null 2>&1 || echo "warning: could not lower the CPU priority" >&2
	if command -v ionice >/dev/null 2>&1; then
		ionice -c 3 -p "$$" >/dev/null 2>&1 || echo "warning: could not lower the I/O priority" >&2
	fi
	return 0
}


##	History:
##		- 2026-10-25: Created, from cicd.bash's half the cores: a quarter when
##		  busy or for a heavy step, rechecked before each step, and nice 19
##		  with idle I/O.
