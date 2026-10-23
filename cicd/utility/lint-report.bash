#!/usr/bin/env bash

#  shellcheck disable=2155  ## 'Declare and assign separately.' Cumbersome and unnecessary here.
#  shellcheck disable=2086  ## 'Double quote to prevent word splitting.' OK for integer flags.

##	Purpose:
##		Show the warnings and errors from the newest cicd run log. cicd tees each
##		run to cicd/artifacts/lint/run_<ts>.log (gitignored, GFS-rotated); this
##		greps out the warning and error lines so they can be dealt with. Two modes:
##		plain, which reports on the newest log, and --check, for a look at session
##		start that says nothing new until a new run has happened.
##		- --check prints one "SEEN ..." line when the newest log is the one the
##		  .lint-seen marker beside it names. Otherwise it prints "NEW ..." and the
##		  lines found, and records the marker.
##		- A log with neither the done line nor an abort line is still running or
##		  was cut off. It's reported as such and not recorded, so the next look
##		  reads it again.
##		- cicd never touches the marker.
##	Syntax:
##		lint-report.bash [--check] [--force] [--no-mark] [--dir DIR] [--file LOG]
##		  --check     gate on the .lint-seen marker; print SEEN and stop if not newer
##		  --force     with --check, report even if already seen
##		  --no-mark   with --check, don't update the marker
##		  --dir DIR   log directory (default: cicd/artifacts/lint next to this script)
##		  --file LOG  report on this log instead of the newest in DIR
##	Exit: 0 normal, 2 skip (no dir or no logs).
##	History: At bottom of script.

##	Copyright (c) 2026 Bubbles
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


set -Eeuo pipefail

meDir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
dir="${meDir}/../artifacts/lint"
file=""; check=0; force=0; noMark=0

while (($#)); do case "$1" in
	--check)    check=1; shift ;;
	--force)    force=1; shift ;;
	--no-mark)  noMark=1; shift ;;
	--dir)      dir="${2:-}"; shift 2 ;;
	--file)     file="${2:-}"; shift 2 ;;
	-h|--help)  sed -n '/^##	Purpose:/,/^##	History:/p' "${BASH_SOURCE[0]}" | sed '$d; s/^##\t\{0,1\}//'; exit 0 ;;
	*) echo "lint-report: unknown option: $1" >&2; exit 2 ;;
esac; done

fSkip() { echo "lint-report: $1" >&2; exit 2; }

## Newest run_<ts>[_role].log by timestamp. The role suffix GFS rotation adds
## is ignored, since the timestamp doesn't change.
fNewest() {
	local d="$1" best="" newest="" f b t
	for f in "${d}"/run_*.log; do
		[[ -e "${f}" ]] || continue
		b="$(basename "${f}")"; t="${b#run_}"; t="${t%%_*}"; t="${t%.log}"
		if [[ "${t}" > "${best}" ]]; then best="${t}"; newest="${f}"; fi
	done
	[[ -n "${newest}" ]] || return 1
	printf '%s\t%s\n' "${best}" "${newest}"
}

if [[ -n "${file}" ]]; then
	[[ -f "${file}" ]] || fSkip "no such file: ${file}"
	log="${file}"; b="$(basename "${file}")"; ts="${b#run_}"; ts="${ts%%_*}"; ts="${ts%.log}"
else
	[[ -d "${dir}" ]] || fSkip "no log dir: ${dir}"
	nb="$(fNewest "${dir}")" || fSkip "no run logs in ${dir}"
	ts="${nb%%$'\t'*}"; log="${nb#*$'\t'}"
fi

## How old the log is, so a SEEN or a clean report standing on a run from a
## fortnight ago reads as one.
fAge() {
	local secs=$(( $(date +%s) - $(stat -c %Y "$1" 2>/dev/null || echo 0) ))
	if ((secs < 0)); then secs=0; fi
	if   ((secs < 5400));   then printf '%dm' $(( secs / 60 ))
	elif ((secs < 172800)); then printf '%dh' $(( secs / 3600 ))
	else                         printf '%dd' $(( secs / 86400 )); fi
}
age="$(fAge "${log}")"

## SEEN only when the marker names the newest log exactly. --file isn't the
## newest log, so it never moves the marker.
marker="${dir}/.lint-seen"
if ((check)) && ((! force)) && [[ -z "${file}" ]]; then
	seen=""; [[ -f "${marker}" ]] && seen="$(tr -d '[:space:]' < "${marker}" 2>/dev/null || true)"
	if [[ -n "${ts}" && "${ts}" == "${seen}" ]]; then
		echo "SEEN $(basename "${log}")  (nothing newer, ${age} old)"; exit 0
	fi
fi

## Finished means the last line is the done line, or the run printed one of the
## two abort lines.
lastLine="$(grep -v '^[[:space:]]*$' "${log}" 2>/dev/null | tail -n 1 || true)"
finished=0
if [[ "${lastLine}" == *"CI/CD: done."* ]] || grep -qE '^\[ FAILED: |CICD ABORTED' "${log}" 2>/dev/null; then finished=1; fi

## Before the body, so a caller that closes stdout early still records the look.
if ((check)) && ((! noMark)) && ((finished)) && [[ -z "${file}" && "${ts}" =~ ^[0-9]{8}-[0-9]{6}$ ]]; then
	printf '%s\n' "${ts}" > "${marker}" 2>/dev/null || echo "lint-report: could not write marker: ${marker}" >&2
fi

## Warnings. Drop the "0 warnings" noise, and the echoed command lines that hold
## the word, such as clippy's `-D warnings`.
warns="$(grep -inE 'warning|rustsec-|vulnerab|unmaintained|yanked' "${log}" 2>/dev/null \
	| grep -viE 'generated 0 warnings|: 0 warnings|no warnings|0 warnings emitted|-D warnings' || true)"
if [[ -n "${warns}" ]]; then n=$(printf '%s\n' "${warns}" | grep -c .); else n=0; fi

## A failed run is never clean. Case-sensitive, since each tool says it one way
## and the lower-case words turn up in passing output. markdownlint says
## "error MD033/...", with no colon.
errs="$(grep -nE '(^|[^[:alnum:]_-])error(\[|:)| error MD[0-9]{3}/|\bSC[0-9]{4}\b|test result: FAILED|^FAIL\b|panicked at|CICD ABORTED|^\[ FAILED: ' "${log}" 2>/dev/null || true)"
if [[ -n "${errs}" ]]; then e=$(printf '%s\n' "${errs}" | grep -c .); else e=0; fi

lead=""; ((check)) && lead="NEW "
if ((e)); then
	echo "${lead}FAILED $(basename "${log}")  (${e} error line(s), ${n} warning line(s), ${age} old)"
	echo
	printf '%s\n' "${errs}"
	if ((n)); then echo; printf '%s\n' "${warns}"; fi
elif ((! finished)); then
	echo "${lead}INCOMPLETE $(basename "${log}")  (no done or abort line: still running, or cut off; ${n} warning line(s) so far, ${age} old)"
	if ((n)); then echo; printf '%s\n' "${warns}"; fi
elif ((n)); then
	echo "${lead}FLAG $(basename "${log}")  (${n} warning line(s), ${age} old)"
	echo
	printf '%s\n' "${warns}"
else
	echo "${lead}CLEAN $(basename "${log}")  (0 warnings, ${age} old)"
fi


##	History:
##		- 2026-07-09: Created.
##		- 2026-09-02: The echoed `-D warnings` of a nested clippy run isn't a finding.
##		- 2026-09-14: A failed run reports FAILED with its error lines. The marker
##		  moves only on the newest log, and SEEN needs an exact match.
##		- 2026-09-19: Every line says how old the log is. `[ FAILED: ... ]` counts as
##		  a failure, and a log with no done or abort line is INCOMPLETE.
##		- 2026-10-23: Copied into tukfs-hash from shcl's cicd. Under --check every
##		  report that isn't SEEN starts with NEW. markdownlint's error lines count.
