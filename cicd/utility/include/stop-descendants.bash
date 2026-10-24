#!/usr/bin/env bash

##	Purpose:
##		Stops what a script started before its EXIT trap takes away the files
##		those processes use. A TERM to the script's PID alone runs its EXIT
##		trap at once and leaves its children running, over a temp dir that's
##		about to go. Sourced by cicd.bash and the leak checks.
##	Functions:
##		fStopDescendants   kill the containers this run started, then TERM
##		                   every process under this shell, wait up to
##		                   TUKFS_STOP_WAIT seconds (30) for them to go, KILL
##		                   the rest, and kill any container that came up
##		                   meanwhile. A KILLed `docker run` leaves its
##		                   container up, and one whose client is a few levels
##		                   down is killed before the script that knew its ID
##		                   gets to it. A PID in stop_keep is passed over, with
##		                   what it started, such as the tee a script logs
##		                   through. It ignores INT, TERM, HUP and PIPE from
##		                   then on, since it runs from an EXIT trap.
##		fStopCidfile       a new, unused file name for a `docker run
##		                   --cidfile`, into stop_cidfile. It's in
##		                   TUKFS_CID_DIR when that's set, which cicd.bash sets
##		                   to a dir in its run's temp dir, so a stop of the
##		                   whole run finds every container in it.
##		The containers are the ones named in stop_cidfiles, and for cicd.bash
##		in stop_cid_dir. They're killed by ID, and only those.
##	History: At bottom of script.

##	Copyright © 2026 t00mietum (CryptogID: ปʬϝღถɔ4რఠΔթะ9ƾǝu)
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


## Container ID files, from --cidfile. The caller removes one once its run ends.
declare -a stop_cidfiles=() stop_keep=()
stop_cid_dir=""; stop_cidfile=""
stop_cid_n=0

fStopCidfile(){
	local dir="${TUKFS_CID_DIR:-${1:-}}"
	[[ -n "${dir}" && -d "${dir}" ]] || return 1
	stop_cid_n=$((stop_cid_n + 1))
	stop_cidfile="${dir}/ctr_$$_${stop_cid_n}_${RANDOM}.cid"
	[[ ! -e "${stop_cidfile}" ]]
}

## docker kill, then docker rm in case --rm didn't get to it. A 64-hex ID
## only, read from a file of this run's.
fStopContainers(){
	local engine="${TUKFS_DOCKER:-docker}" f cid=""
	local -a files=("${stop_cidfiles[@]}")
	if [[ -n "${stop_cid_dir}" && -d "${stop_cid_dir}" ]]; then
		for f in "${stop_cid_dir}"/ctr_*.cid; do [[ -f "${f}" ]] && files+=("${f}"); done
	fi
	for f in "${files[@]}"; do
		cid=""; { read -r cid < "${f}"; } 2>/dev/null || true
		[[ "${cid}" =~ ^[0-9a-f]{64}$ ]] || continue
		if "${engine}" kill "${cid}" >/dev/null 2>&1; then echo "[ cleanup: killed container ${cid:0:12} ]" >&2; fi
		"${engine}" rm "${cid}" >/dev/null 2>&1 || true
	done
	return 0
}

## Alive, and not a zombie waiting for its parent to reap it.
fStopAlive(){
	local line=""
	{ read -r line < "/proc/$1/stat"; } 2>/dev/null || return 1
	line="${line##*) }"
	[[ "${line:0:1}" != [ZX] ]]
}

## Builtins only, so the walk itself starts no process that would be on the list.
fStopDescendants(){
	local f line pid ppid wait="${TUKFS_STOP_WAIT:-30}" i=0 left=0
	local -A kids=() keep=()
	local -a todo=() found=()
	## A subshell running a trap it took with it isn't the script.
	[[ "${BASHPID}" == "$$" && -d /proc/self ]] || return 0
	## A second signal, or a write to a reader that's gone, would end the trap
	## part way. timeout signals the script, then its group.
	trap '' INT TERM HUP PIPE
	[[ "${wait}" =~ ^[0-9]{1,4}$ ]] || wait=30
	## First, so a client that won't go doesn't hold the rest up.
	fStopContainers
	for f in /proc/[0-9]*/stat; do
		{ read -r line < "${f}"; } 2>/dev/null || continue
		pid="${f#/proc/}"; pid="${pid%/stat}"
		## The name in parens can hold spaces, so the fields start after its last ')'.
		line="${line##*) }"; line="${line#* }"; ppid="${line%% *}"
		kids["${ppid}"]+=" ${pid}"
	done
	for pid in "${stop_keep[@]}"; do keep["${pid}"]=1; done
	todo=($$)
	while ((${#todo[@]})); do
		pid="${todo[0]}"; todo=("${todo[@]:1}")
		for f in ${kids[${pid}]:-}; do
			if [[ -z "${keep[${f}]:-}" ]]; then found+=("${f}"); todo+=("${f}"); fi
		done
	done
	if ((${#found[@]})); then
		kill -TERM "${found[@]}" 2>/dev/null || true
		for ((i = 0; i < wait * 5; i++)); do
			left=0
			for pid in "${found[@]}"; do if fStopAlive "${pid}"; then left=$((left + 1)); fi; done
			((left)) || break
			sleep 0.2 || true
		done
		if ((left)); then
			for pid in "${found[@]}"; do if fStopAlive "${pid}"; then kill -KILL "${pid}" 2>/dev/null || true; fi; done
		fi
		printf '[ cleanup: stopped %s process(es) the run left%s ]\n' "${#found[@]}" "$( ((left)) && echo ", ${left} by KILL after ${wait} s")" >&2
	fi
	fStopContainers
	stop_cidfiles=()
	return 0
}


##	History:
##		- 2026-10-23: Copied into tukfs-hash from shcl's cicd, without the container parts.
##		- 2026-10-23: The container part back, for the leak check image.
##		- 2026-10-23: Containers first and last, and every one in the run's
##		  cid dir, since a TERM during CodeQL left its container up.
##		- 2026-10-24: Ignores INT, TERM, HUP and PIPE, so the cleanup after it
##		  runs to the end.
