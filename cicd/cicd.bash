#!/usr/bin/env bash

#  shellcheck disable=2016  ## 'Expressions don't expand in single quotes, use double quotes for that.' I know, and I often want an explicit '$'.
#  shellcheck disable=2034  ## 'variable appears unused.' Complains about valid use of variable indirection.
#  shellcheck disable=2329  ## 'This function is never invoked.' False hit on the EXIT trap's function.

##	- Purpose: Local CI/CD pipeline. Generic engine; the project's settings
##	  are in config.bash.
##	- Stages, fail-fast (an error stops the run before the next stage):
##	   0. remote sync (fast-forward from upstream before anything is built)
##	   1. format (in place; check-only in the backlog runs and merge gate)
##	   2. build (debug)
##	   3. lint (clippy, shellcheck over every tracked *.bash, markdownlint over
##	      every tracked .md, PSScriptAnalyzer over every tracked .ps1, ruff
##	      and mypy over every tracked .py, then LINT_EXTRA, such as the test ID check)
##	   4. tests (cargo test, then the integration test once per test root),
##	      then the slow leak checks
##	   5. profiler (a flamegraph of a scan, from an in-process sampler, into
##	      PROFILE_OUT_DIR, and flame-report.py's summary of it)
##	   6. release builds (native, cross targets, packages, release checks),
##	      into RELEASE_ARTIFACT_DIR with a sha256 sums file, or the run's
##	      temp dir in the backlog runs and merge gate. Without the image, the
##	      native one alone, on the host, with the box's glibc
##	   7. other hosts (the unit tests and the integration test on a box of
##	      each other arch, on stage 6's build of it, held through the host
##	      lock and put back as it was found. A box that isn't there is a SKIP)
##	   8. dogfood (the native release build, and the dogfood runner)
##	   9. demo gif (a scenario run against the release build, drawn as a
##	      fake terminal, GFS-rotated, and copied to GIF_OUT when it changed)
##	  10. backup + publish to git
##	   Only the stages that run are numbered and counted, so "Step 2 of 5"
##	   is the second of 5 in this run. The plan at the start lists the ones
##	   off, with the flag or reason. Each step opens with a timed "Starting"
##	   line and closes with PASS or FAIL and its name. Cleanup comes last.
##	- Syntax:
##	  cicd/cicd.bash [options]
##	  Options:
##	   With no options a run does every stage config.bash has on.
##	   --quick             leave out the steps config.bash lists in QUICK_SKIP,
##	                       the leak checks but the fast ones, the profiler
##	                       and demo gif
##	   --long              everything a run with no options does, and the
##	                       leak checks that take hours, of which there are
##	                       none yet. Also --slow. Not with --quick
##	   The next 3 never sync, dogfood, publish, commit, push, install, rewrite
##	   a tracked file, or prompt. The format stage only checks, and a missing
##	   tool fails the run.
##	   --backlog-run-quick [AREA...]
##	                       what a backlog worker runs before it commits:
##	                       format check, build, lint, unit and integration
##	                       tests. Or only the areas named, listed at the end.
##	                       --gate is another name for it
##	   --backlog-run-full  what a backlog round runs at its end: every check
##	                       of a run with no options. The release set and the
##	                       gif are made in the temp dir and go nowhere
##	   --merge-gate        the same checks, which the pre-push hook runs on a
##	                       push to main. --ci is another name for it
##	   --list              print the plan the other options make, and the
##	                       test IDs its steps would print, and run nothing
##	   --no-container      run the steps that use an image on the host
##	   --no-remote         skip the other hosts, the arm64 tests on
##	                       vmDebARM64
##	   --keep-temp         keep the run's temp dirs and containers, and print
##	                       where they are. The next runs' sweep leaves the
##	                       dirs for 2 days
##	   --leakcheck         add the leak checks a run with no options has to
##	                       --quick or --backlog-run-quick
##	   --no-leakcheck      leave the leak checks out of any run. Not with
##	                       --leakcheck, or with a leak check area
##	   --no-codeql         leave out the leak check steps that name codeql,
##	                       and keep the rest. Not with an area that has only
##	                       those
##	   -q, --quiet         unattended and quiet: no preflight block, and cargo
##	                       and the publisher get their own quiet flags. Stage
##	                       lines, results and warnings still print
##	   -y, --yes           unattended, not quiet
##	   -m, --message MSG   publish with this commit message. Also --msg MSG,
##	                       and -m=MSG
##	   --no-sync           skip the remote sync
##	   --no-fmt            skip the format stage
##	   --no-debug          skip the debug build
##	   --no-lint           skip the lint stage
##	   --no-tests          skip the tests stage, leak checks included
##	   --no-cross          skip the cross targets; the native release still
##	                       builds
##	   --no-package        skip the packages
##	   --no-profile        skip the profiler
##	   --no-release        skip the release builds, and the dogfood and gif
##	                       made from them
##	   --no-dogfood        skip the dogfood install
##	   --no-gif            skip the demo gif
##	   --no-publish        skip the backup + publish
##	   --no-freeze         run stages 2-7 in the checkout, not in a copy
##	   -h, --help          show this help
##	- An area named with the --no- option that takes its step out, and a plan
##	  with no steps at all, are refused rather than run as nothing.
##	- With none of -q, -y, -m or --no-publish, the run asks once at the start
##	  for the commit message. Blank opens git's editor at publish, and Ctrl+C
##	  stops the whole run.
##	- Publish refuses when the checkout no longer holds the tree the run
##	  tested, other than the demo gif it drew, or when the upstream has
##	  commits the run didn't take.
##	- The job count is half the logical CPUs, or a quarter when the 1-minute
##	  load is over half the CPU count, checked at the start and at each step.
##	  The leak checks get a quarter, busy or not. Never under 1. It goes to
##	  every tool that runs in parallel as CPU_CAP, CARGO_BUILD_JOBS and
##	  RUST_TEST_THREADS, and to containers as --cpus. A CPU_CAP set by the
##	  caller wins. utility/include/cpu-cap.bash works it out.
##	- Everything runs at nice 19 in the idle I/O class, containers too, which
##	  also get --cpu-shares 256.
##	- A run at least as thorough as the merge gate records the tree it tested
##	  once the release checks pass (utility/green-tree.bash), and the pre-push
##	  hook lets a push of that tree through without running the gate again.
##	  --quick, --backlog-run-quick, any --no- option that drops a check, a
##	  missing tool and a missing test root each keep a run from recording.
##	- Each run works in <HOST_TEMP>/tukfs-hash/<YYYYmmDD-HHMMSS>_<NNN>, or
##	  under config.bash's RUN_TMP_ROOT when HOST_TEMP isn't set, then
##	  TMPDIR, with TMPDIR, TEMP and TMP pointed into it, so what a failed
##	  test leaves goes with it. It has the run's PID in run.pid. It's
##	  removed at the end, even when the run fails or is stopped, and only by
##	  fSafeRm, and so are the run's containers, by their dev.run label. A
##	  stop kills the running ones first. Each run also removes this
##	  project's run dirs whose run is gone, such as a killed run's.
##	  --keep-temp keeps the dir and the containers, and says where, and the
##	  sweep leaves a kept dir for 2 days.
##	- Stages 2-7 run from a copy of the tree taken after the format stage,
##	  uncommitted work included, so a merge, checkout or edit during a run
##	  can't reach them. The copy sits in the run's temp dir.
##	- Reuse: copy the cicd/ directory into another project and edit config.bash.

##	History: At bottom of script.

##	Copyright © 2026 t00mietum (CryptogID: ปʬϝღถɔ4რఠΔթะ9ƾǝu)
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


set -Eeuo pipefail

## One compound command, which bash reads to its end before any of it runs, so
## an edit to this file during a run can't be read at the old offset.
{

## GIT_DIR and friends, from a hook run in a linked worktree, would point every
## git call here at the wrong repo.
for gitVar in $(git rev-parse --local-env-vars 2>/dev/null || true); do unset "${gitVar}"; done

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "${here}/.." && pwd)"

## rustup's cargo has to win over Debian's /bin/cargo, which ignores
## rust-toolchain.toml.
export PATH="${HOME}/.cargo/bin:${PATH}"

## The box usually has something else running. Before config.bash, which
## reads CPU_CAP.
source "${here}/utility/include/cpu-cap.bash"
fCpuLow
fCpuCap

## Settings config.bash may leave out.
LEAKCHECK_STEPS=(); CROSS_TARGETS=(); QUICK_SKIP=(); FROZEN_LINKS=(); CACHE_DIRS=(); SHELLCHECK_EXTRA=(); MARKDOWN_SKIP=()
RELEASE_CHECKS=(); DOGFOOD_DESTS=(); DOGFOOD_RUNNERS=(); PS_LINT_CMD=(); PY_LINT_CMD=(); PY_FMT_CHECK_CMD=(); PY_TYPE_CMD=(); LINT_EXTRA=()
TEST_ID_LIST_CMD=(); REMOTE_HOSTS=(); REMOTE_VM_WRAP=''; REMOTE_LOCK_WAIT=900
PROFILE_ENABLE=0; PACKAGE_ENABLE=0; DOGFOOD_ENABLE=0; GIF_ENABLE=0
PROFILE_BUILD_CMD=(); PROFILE_TIMED=(); PROFILE_BIN=''; PROFILE_OUT_DIR=''; PROFILE_ROOT=''; PROFILE_CHECK=''; PROFILE_WORKLOAD_GEN=''
PACKAGE_CMD=''; GIF_CMD=''; GIF_OUT=''; RELEASE_ARTIFACT_DIR=''; RELEASE_NATIVE_OSARCH='native'
## -q for eval'd config strings that pass it on to a tool. Empty otherwise.
QUIET_FLAG=""

# shellcheck source=config.bash
source "${here}/config.bash"

## Set for the run a run starts on its frozen copy: TUKFS_RUN_PART=build runs
## stages 2-7 only. It records no tree, since the gif comes after it, in the
## run that started it. The pre-push hook sets TUKFS_GATE_REV to the commit being pushed, which is then
## what gets copied, with nothing uncommitted.
## TUKFS_STEP_PLAN is the outer run's step numbers, so the copy's steps count
## on from its.
run_part="${TUKFS_RUN_PART:-}"; gate_rev="${TUKFS_GATE_REV:-}"; plan_given="${TUKFS_STEP_PLAN:-}"
unset TUKFS_RUN_PART TUKFS_GREEN_TREE TUKFS_GATE_REV TUKFS_STEP_PLAN
case "${run_part}" in ''|build) ;; *) echo "TUKFS_RUN_PART=${run_part}: not build" >&2; exit 2 ;; esac
if [[ -n "${plan_given}" && ! "${plan_given}" =~ ^[0-9]+( [a-z]+=[0-9]+)*$ ]]; then echo "TUKFS_STEP_PLAN=${plan_given}: not a step plan" >&2; exit 2; fi
if [[ -n "${gate_rev}" && ! "${gate_rev}" =~ ^[0-9a-f]{40}$ ]]; then echo "TUKFS_GATE_REV=${gate_rev}: not a full commit hash" >&2; exit 2; fi
inner_run=0
if [[ -n "${run_part}" ]]; then inner_run=1; fi

source "${here}/utility/include/frozen-tree.bash"
source "${here}/utility/include/stop-descendants.bash"
source "${here}/utility/include/gfs-rotate.bash"
source "${here}/utility/include/ctr-image.bash"
cd "${root}"
stamp="$(date +%Y%m%d-%H%M%S)"
started=${SECONDS}


#•••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••
## Options

assume_yes=0; quiet=0; gate_mode=0; quick=0; slow=0; cli_message=""; sync_enable=1; gate_partial=0
leakcheck_flag=0; no_leakcheck=0; no_codeql=0; no_freeze=0; fmt_off=0; debug_off=0; lint_off=0; tests_off=0; release_off=0
unit_off=0; it_off=0; keep_temp=0; list_only=0; no_container=0; remote_off=0
## bq, bf or mg for --backlog-run-quick, --backlog-run-full and --merge-gate.
## gate_mode is set for all 3: check only, strict, and nothing written back.
mode=""; mode_flag=""
declare -a areas=()
## Why a stage is off, for the plan. The first reason given stays.
declare -A off_why=()
fOffWhy(){ local k; for k in "${@:2}"; do [[ -n "${off_why["${k}"]:-}" ]] || off_why["${k}"]="$1"; done; }
fMode(){   ## fMode MODE FLAG
	if [[ -n "${mode}" && "${mode}" != "$1" ]]; then echo "${mode_flag} and $2 can't go together (try --help)" >&2; exit 2; fi
	mode="$1"; mode_flag="$2"; gate_mode=1; assume_yes=1
}
## The options the run on the frozen copy takes over.
inner_pass=()
while (($#)); do case "$1" in
	--gate)                   echo "[ --gate is another name for --backlog-run-quick ]"; set -- --backlog-run-quick "${@:2}" ;;
	--ci)                     echo "[ --ci is another name for --merge-gate ]"; set -- --merge-gate "${@:2}" ;;
	--backlog-run-quick)      fMode bq "$1"; shift
	                          while (($#)) && [[ "$1" != -* ]]; do areas+=("$1"); shift; done ;;
	--backlog-run-full)       fMode bf "$1"; shift ;;
	--merge-gate)             fMode mg "$1"; shift ;;
	--quick)                  quick=1; inner_pass+=("$1"); shift ;;
	--slow|--long)            slow=1; inner_pass+=("$1"); shift ;;
	--no-container)           no_container=1; inner_pass+=("$1"); shift ;;
	--no-remote)              remote_off=1; fOffWhy "$1" remote; gate_partial=1; inner_pass+=("$1"); shift ;;
	--keep-temp)              keep_temp=1; inner_pass+=("$1"); shift ;;
	--list)                   list_only=1; shift ;;
	--leakcheck)              leakcheck_flag=1; inner_pass+=("$1"); shift ;;
	--no-leakcheck)           no_leakcheck=1; gate_partial=1; inner_pass+=("$1"); shift ;;
	--no-codeql)              no_codeql=1; gate_partial=1; inner_pass+=("$1"); shift ;;
	-q|--quiet)               quiet=1; assume_yes=1; QUIET_FLAG="-q"; export CARGO_TERM_QUIET=true; shift ;;
	-y|--yes)                 assume_yes=1; shift ;;
	--no-sync)                sync_enable=0; fOffWhy "$1" sync; shift ;;
	--no-fmt)                 fmt_off=1; fOffWhy "$1" format; gate_partial=1; inner_pass+=("$1"); shift ;;
	--no-debug)               debug_off=1; fOffWhy "$1" build; gate_partial=1; inner_pass+=("$1"); shift ;;
	--no-lint)                lint_off=1; fOffWhy "$1" lint; gate_partial=1; inner_pass+=("$1"); shift ;;
	--no-tests)               tests_off=1; LEAKCHECK_STEPS=(); fOffWhy "$1" tests; gate_partial=1; inner_pass+=("$1"); shift ;;
	--no-cross)               CROSS_TARGETS=(); gate_partial=1; inner_pass+=("$1"); shift ;;
	--no-package)             PACKAGE_ENABLE=0; gate_partial=1; inner_pass+=("$1"); shift ;;
	--no-profile)             PROFILE_ENABLE=0; fOffWhy "$1" profile; gate_partial=1; inner_pass+=("$1"); shift ;;
	## Dogfood and the gif take the release binary, so a stale one would go out.
	--no-release)             release_off=1; PACKAGE_ENABLE=0; DOGFOOD_ENABLE=0; GIF_ENABLE=0; fOffWhy "$1" release remote dogfood gif; gate_partial=1; inner_pass+=("$1"); shift ;;
	--no-dogfood)             DOGFOOD_ENABLE=0; fOffWhy "$1" dogfood; shift ;;
	--no-gif)                 GIF_ENABLE=0; fOffWhy "$1" gif; gate_partial=1; shift ;;
	--no-publish)             GIT_PUBLISH=(); fOffWhy "$1" publish; shift ;;
	--no-freeze)              no_freeze=1; shift ;;
	--message=*|--msg=*|-m=*) cli_message="${1#*=}"; shift ;;
	-m|--message|--msg)       (($# >= 2)) || { echo "$1 needs a message (try --help)" >&2; exit 2; }; cli_message="$2"; shift 2 ;;
	-h|--help)
		sed -n '/^##	- Purpose:/,/^##	History:/p' "${BASH_SOURCE[0]}" | sed '$d; s/^##	\{0,1\}//'
		echo "- Areas for --backlog-run-quick, from config.bash:"
		for _a in "${BACKLOG_AREAS[@]}"; do printf '   %-12s %s\n' "${_a%%|*}" "${_a##*|}"; done
		exit 0 ;;
	*) echo "unknown option: $1 (try --help)" >&2; exit 2 ;;
esac; done
## Two options that say opposite things are refused, rather than the last winning.
if ((leakcheck_flag && no_leakcheck)); then echo "--leakcheck and --no-leakcheck can't go together (try --help)" >&2; exit 2; fi
if ((quick && slow)); then echo "--quick and --long can't go together (try --help)" >&2; exit 2; fi
if [[ -n "${mode}" ]] && ((quick || slow)); then echo "${mode_flag} has its own steps; drop --quick and --long" >&2; exit 2; fi
if [[ -n "${gate_rev}" ]] && ((! gate_mode)); then echo "TUKFS_GATE_REV is only for --merge-gate and the backlog runs" >&2; exit 2; fi
## Each leak check by its length in config.bash: fast in every run, mid in a
## run with no options and the long modes, and long in --long alone.
_byLength=()
for _step in "${LEAKCHECK_STEPS[@]}"; do
	case "${_step%%|*}" in
		fast) ;;
		mid)  if ((quick && ! leakcheck_flag)); then continue; fi ;;
		long) if ((! slow)); then continue; fi ;;
		*)    echo "config.bash: a leak check with no length (fast, mid or long): ${_step}" >&2; exit 2 ;;
	esac
	_byLength+=("${_step#*|}")
done
LEAKCHECK_STEPS=("${_byLength[@]}")
## The release builds and the leak checks fall back to the host on this, as
## they do when docker doesn't answer.
if ((no_container)); then export TUKFS_NO_CONTAINER=1; fi
if ((keep_temp)); then export TUKFS_KEEP_TEMP=1; fi
if [[ -n "${mode}" ]]; then
	inner_pass+=("${mode_flag}")
	if [[ "${mode}" == bq ]]; then inner_pass+=("${areas[@]}"); fi
fi

## The backlog runs and the merge gate: unattended, and nothing goes out or
## back into the tree.
if ((gate_mode)); then
	## A gate that skips what it can't run stops checking the day a box loses
	## a tool, so here a missing tool fails. A test root that isn't there is
	## still a skip with a note, since not every box has one.
	gate_strict=1
	sync_enable=0
	FMT_CMD=()
	DOGFOOD_ENABLE=0; GIT_PUBLISH=()
	fOffWhy "${mode_flag}" sync dogfood publish
	## The gif is drawn, as a check, but goes nowhere the tree or the private
	## dir would see it. A rotate dir under a parent that isn't there is a note.
	gif_to_tmp=1
	if [[ "${mode}" == bq ]]; then
		GIF_ENABLE=0; fOffWhy "${mode_flag}" gif
		## Only what's named, when anything is. Each name is an area in
		## config.bash, and a leak area keeps the leak checks its text is in.
		_known=" "; _leakKept=()
		for _a in "${BACKLOG_AREAS[@]}"; do _known+="${_a%%|*} "; done
		## The step each area runs in, so an area named with the --no- option
		## that takes that step out is refused. off_why holds only the options
		## given so far.
		declare -A _areaStep=([fmt]=format [build]=build [lint]=lint [unit]=tests [it]=tests [profile]=profile [release]=release [remote]=remote)
		for _name in "${areas[@]}"; do
			[[ "${_known}" == *" ${_name} "* ]] || { echo "--backlog-run-quick: no area named ${_name} (try --help)" >&2; exit 2; }
			for _a in "${BACKLOG_AREAS[@]}"; do
				[[ "${_a%%|*}" == "${_name}" ]] || continue
				_pat="${_a#*|}"; _pat="${_pat%%|*}"
				## A leak area is in the tests step.
				_off="${off_why["${_areaStep["${_name}"]:-tests}"]:-}"
				if [[ -z "${_off}" && -n "${_pat}" ]] && ((no_leakcheck)); then _off="--no-leakcheck"; fi
				if [[ -n "${_off}" ]]; then echo "--backlog-run-quick: area ${_name} and ${_off} can't go together (try --help)" >&2; exit 2; fi
				[[ -n "${_pat}" ]] || continue
				_matched=0; _codeql=0
				for _step in "${LEAKCHECK_STEPS[@]}"; do
					[[ "${_step}" == *"${_pat}"* ]] || continue
					_matched=$((_matched + 1))
					if [[ "${_step,,}" == *codeql* ]]; then _codeql=$((_codeql + 1)); fi
					if [[ " ${_leakKept[*]} " != *" ${_step} "* ]]; then _leakKept+=("${_step}"); fi
				done
				if ((no_codeql && _matched && _codeql == _matched)); then echo "--backlog-run-quick: area ${_name} and --no-codeql can't go together (try --help)" >&2; exit 2; fi
			done
		done
		_named=" ${areas[*]} "
		_unnamed="${mode_flag}"
		if ((${#areas[@]})); then
			gate_partial=1
			_unnamed="not in the areas named"
			[[ "${_named}" == *" fmt "* ]]   || { fmt_off=1; fOffWhy "${_unnamed}" format; }
			[[ "${_named}" == *" build "* ]] || { debug_off=1; fOffWhy "${_unnamed}" build; }
			[[ "${_named}" == *" lint "* ]]  || { lint_off=1; fOffWhy "${_unnamed}" lint; }
			[[ "${_named}" == *" unit "* ]]  || unit_off=1
			[[ "${_named}" == *" it "* ]]    || it_off=1
			((leakcheck_flag)) || LEAKCHECK_STEPS=("${_leakKept[@]}")
		elif ((! leakcheck_flag)); then
			LEAKCHECK_STEPS=()
		fi
		## remote tests the release builds, so it brings them along.
		[[ "${_named}" == *" release "* || "${_named}" == *" remote "* ]] || { release_off=1; CROSS_TARGETS=(); PACKAGE_ENABLE=0; fOffWhy "${_unnamed}" release; }
		[[ "${_named}" == *" remote "* ]] || { remote_off=1; fOffWhy "${_unnamed}" remote; }
		[[ "${_named}" == *" profile "* ]] || { PROFILE_ENABLE=0; fOffWhy "${_unnamed}" profile; }
	fi
else
	gate_strict=0
	gif_to_tmp=0
	FMT_CHECK_CMD=()
fi
## The check scripts read it too, since they only report an exit code: under
## it a missing tool fails, and a check the box can't run at all, with no
## image, goes on the skip list (2026102814341405).
if ((gate_strict)); then export TUKFS_GATE_STRICT=1; else unset TUKFS_GATE_STRICT; fi
## The run that froze the tree formatted the checkout first.
if [[ "${run_part}" == build ]]; then FMT_CMD=(); fi
if ((fmt_off)); then FMT_CMD=(); FMT_CHECK_CMD=(); fi
freeze=1
if ((no_freeze || inner_run)); then freeze=0; fi
if [[ -n "${gate_rev}" ]] && ((no_freeze)); then echo "TUKFS_GATE_REV needs the frozen copy; drop --no-freeze" >&2; exit 2; fi

## --quick: each QUICK_SKIP name is plain text matched against a whole step.
fQuickSkips(){  ## fQuickSkips STEP -> 0 when a QUICK_SKIP name is in it
	local pat
	for pat in "${QUICK_SKIP[@]}"; do
		if [[ -n "${pat}" && "$1" == *"${pat}"* ]]; then return 0; fi
	done
	return 1
}
fQuickDrop(){   ## fQuickDrop ARRAY_NAME
	local -n steps_q7w="$1"
	local -a kept=()
	local step
	for step in "${steps_q7w[@]}"; do
		if ! fQuickSkips "${step}"; then kept+=("${step}"); fi
	done
	steps_q7w=("${kept[@]}")
}
## Packages stay in, since nfpm takes about a second for all of them.
if ((quick)); then
	## The other hosts too, since an emulated box takes several minutes.
	PROFILE_ENABLE=0; GIF_ENABLE=0; remote_off=1; fOffWhy --quick profile remote gif
	for list in LEAKCHECK_STEPS CROSS_TARGETS RELEASE_CHECKS IT_ROOTS; do fQuickDrop "${list}"; done
fi
## --quick kept the fast leak checks above, and --backlog-run-quick picked its own.
if ((no_leakcheck)); then LEAKCHECK_STEPS=(); fi
## CodeQL is most of a full run's time, so it goes off alone.
if ((no_codeql)); then
	_kept=()
	for _step in "${LEAKCHECK_STEPS[@]}"; do [[ "${_step,,}" == *codeql* ]] || _kept+=("${_step}"); done
	LEAKCHECK_STEPS=("${_kept[@]}")
fi

## A run at least as thorough as the merge gate records the tree it tested.
record_green=1
if ((quick || gate_partial)) || [[ "${mode}" == bq ]]; then record_green=0; fi


#•••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••
## Output

declare -i _wasLastEchoBlank=0
fEcho_ResetBlankCounter(){ _wasLastEchoBlank=0; }
fEcho_Clean(){ if [[ -n "${1:-}" ]]; then echo -e "$*"; _wasLastEchoBlank=0; elif [[ "${_wasLastEchoBlank}" == 0 ]] && echo; then _wasLastEchoBlank=1; fi; }
fEcho(){       if [[ -n "$*"     ]]; then fEcho_Clean "[ $* ]"; else fEcho_Clean ""; fi; }
fEcho_Force(){ fEcho_ResetBlankCounter; fEcho "$*"; }
_letterbox="•••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••"
fSection(){ fEcho_Clean; fEcho_Clean "${_letterbox}"; fEcho "$*"; }
## Set once the run has said how it ended, so the EXIT trap knows a stop by
## its silence. $? there is 0 after a TERM.
run_said=0
fDie(){ run_said=1; { fEcho_Force "FAILED: $*"; fStepFail; echo; } >&2; exit 1; }
## To the hundredth. EPOCHREALTIME's point follows the locale.
fNow(){ local t="${EPOCHREALTIME}"; printf '%(%Y%m%d-%H%M%S)T.%s' "${t%[.,]*}" "${t: -6:2}"; }
## A step opens with its start line and closes with a PASS or FAIL line. Only
## the steps that run get a number; step_no is filled by fStepPlan.
step_n=0; step_name=""; step_open=0; step_total=0
declare -A step_no=()
## The job count, when it's not what was last shown.
cpu_shown=""
fCpuShow(){ if [[ "${CPU_CAP}" != "${cpu_shown}" ]]; then fEcho_Clean "jobs: ${CPU_CAP} of ${cpu_cores} cores, ${cpu_why}"; cpu_shown="${CPU_CAP}"; fi; }
## In the order they run.
step_keys=(sync format build lint tests profile release remote dogfood gif publish)
declare -A step_title=([sync]="Remote sync" [format]="Format" [build]="Build (debug)" [lint]="Lint" [tests]="Tests"
	[profile]="Profiler" [release]="Release builds" [remote]="Other hosts" [dogfood]="Dogfood" [gif]="Demo gif" [publish]="Backup + publish")
## fStep KEY -> 1 when the plan has the step off, which then prints nothing.
fStep(){
	[[ -n "${step_no["$1"]:-}" ]] || return 1
	step_n="${step_no["$1"]}"; step_name="${step_title["$1"]}"; step_open=1
	fSection "$(fNow): Step ${step_n} of ${step_total}; Starting ${step_name}"
	fCpuCap; fCpuShow
}
fStepPass(){ step_open=0; fEcho_Clean "PASS ${step_name}"; fEcho_Clean; }
fStepFail(){ if ((step_open)); then step_open=0; echo "FAIL ${step_name}"; fi; }
## A step with nothing it could run. The summary at the end lists why.
fStepSkip(){ step_open=0; fEcho_Clean "SKIP ${step_name}"; fEcho_Clean; }
fMinSec(){ printf '%dm %02ds' $(($1 / 60)) $(($1 % 60)); }
## KB to a size a person reads.
fSize(){ if (($1 >= 1048576)); then printf '%d.%d GB' $(($1 / 1048576)) $(($1 % 1048576 * 10 / 1048576)); else printf '%d MB' $((($1 + 512) / 1024)); fi; }
trap 'rc=$?; run_said=1; { printf "\n[ CICD ABORTED (exit %s) at line %s: %s ]\n" "$rc" "$LINENO" "$BASH_COMMAND"; fStepFail; echo; } >&2; exit $rc' ERR

## Git that talks to the remote goes through gitsby where it's installed, so it
## uses the account the repo belongs to. Plain git on a box without it.
fGitRemote(){ if command -v gitsby >/dev/null 2>&1; then gitsby raw git "$@"; else git "$@"; fi; }

## Dogfood helpers, from shcl's engine.
## First existing and writable dir from the list; nothing when there's none.
fFirstWritableDir(){ local d; for d in "$@"; do if [[ -d "${d}" && -w "${d}" ]]; then echo "${d}"; break; fi; done; return 0; }
## 0 when a running process was started from this file. -ef compares the
## inode the exe link points at, with no process per entry. A replaced file's
## old inode doesn't match, the same as its "(deleted)" name didn't.
## Another user's exe link can't be read, as with a run through sudo, so there
## the name has to do: comm, unless argv[0] is a path to some other file.
fInUse(){   ## fInUse PATH
	local exe pid comm name="${1##*/}"
	local -a argv=()
	[[ -e "$1" ]] || return 1
	for exe in /proc/[0-9]*/exe; do
		if [[ "${exe}" -ef "$1" ]]; then return 0; fi
		[[ -e "${exe}" ]] && continue
		pid="${exe%/exe}"; comm=""
		read -r comm 2>/dev/null < "${pid}/comm" || continue
		[[ "${comm}" == "${name:0:15}" ]] || continue
		mapfile -d '' -n 1 argv 2>/dev/null < "${pid}/cmdline" || continue
		[[ "${argv[0]:-}" == /* && -e "${argv[0]}" && ! "${argv[0]}" -ef "$1" ]] && continue
		return 0
	done
	return 1
}
## Through a temp file in the same dir and a rename, so a copy started by hand
## never sees a half-written file, and the sync never sends one.
fInstallAtomic(){   ## fInstallAtomic SRC DEST_DIR NAME MODE
	local src="$1" dir="$2" name="$3" mode="$4" tmp="$2/.$3.$$.tmp"
	if cp -f -- "${src}" "${tmp}" && chmod "${mode}" -- "${tmp}" && mv -f -- "${tmp}" "${dir}/${name}"; then
		fEcho "OK: installed ${dir}/${name}"
		return 0
	fi
	rm -f -- "${tmp}"
	fEcho "WARNING: could not install ${dir}/${name}"
	return 1
}


#•••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••
## Temp dirs and their rm -rf. fSafeRmCache has the only other one.

## Every dir the run makes is <root>/tukfs-hash/<YYYYmmDD-HHMMSS>_<NNN>, with
## the run's PID in run.pid and its token in the mark file: the run's own, and
## the profiler's workload. Other folders there, such as the integration
## test's, have no mark and are left alone.
run_mark=".cicd-run"
kept_mark=".cicd-kept"
run_token="$$-${RANDOM}${RANDOM}-${EPOCHREALTIME}"
declare -a run_dirs=()   ## made by this run, removed at the end

## The checks fSafeRm makes before it removes anything, minus the mark. 0 when
## PATH could be one of this run's dirs.
fSafePath(){
	local p="${1:-}" fhs=""
	if [[ -z "${p}" || "${p}" != /* || "${p}" == *..* || "${p}" == *//* || "${p}" == *$'\n'* ]]; then
		printf 'cleanup: refused, bad path: "%s"\n' "${p}" >&2; return 1
	fi
	if ! [[ "${p}" =~ ^(/[A-Za-z0-9._+-]+)+/tukfs-hash/[0-9]{8}-[0-9]{6}_[0-9]{3}$ ]]; then
		printf 'cleanup: refused, not a cicd run dir: %s\n' "${p}" >&2; return 1
	fi
	for fhs in / /bin /boot /dev /etc /home /lib /lib64 /media /mnt /opt /proc /root /run /sbin /srv /sys /tmp /usr /var "${HOME:-/}"; do
		if [[ "${p%/}" == "${fhs%/}" ]]; then printf 'cleanup: refused, system folder: %s\n' "${p}" >&2; return 1; fi
	done
	return 0
}

## rm -rf, but only on a dir that passes fSafePath, is still where it was made
## with no links on the way, and holds the mark with TOKEN in it.
fSafeRm(){   ## fSafeRm PATH TOKEN
	local p="${1:-}" token="${2:-}" real="" got=""
	fSafePath "${p}" || return 1
	[[ -e "${p}" || -L "${p}" ]] || return 0
	real="$(realpath -e -- "${p}" 2>/dev/null || true)"
	if [[ "${real}" != "${p}" || ! -d "${p}" || -L "${p}" || ! -O "${p}" ]]; then
		printf 'cleanup: refused, a link, not a folder, or not ours: %s\n' "${p}" >&2; return 1
	fi
	{ read -r got < "${p}/${run_mark}"; } 2>/dev/null || true
	if [[ -z "${token}" || "${got}" != "${token}" ]]; then
		printf 'cleanup: not removed, no mark from this run: %s\n' "${p}" >&2; return 1
	fi
	## A test that failed can leave a dir it made read-only.
	if ! rm -rf --one-file-system -- "${p}" 2>/dev/null; then
		chmod -R u+rwX -- "${p}" 2>/dev/null || true
		rm -rf --one-file-system -- "${p}" 2>/dev/null || { printf 'cleanup: could not remove all of %s\n' "${p}" >&2; return 1; }
	fi
}

## Make one of this run's dirs under BASE/tukfs-hash/, and set made_dir to it.
## A global rather than output, since the list it adds to has to outlive a $( ).
## A plain mkdir, counting up while the name is taken.
made_dir=""
fRunDirMake(){   ## fRunDirMake BASE
	local base="" d="" t="" nnn="" n=1
	base="$(realpath -e -- "$1")" || fDie "temp root isn't there: $1"
	mkdir -p -- "${base}/tukfs-hash" || fDie "could not make ${base}/tukfs-hash"
	printf -v t '%(%Y%m%d-%H%M%S)T' -1
	while :; do
		printf -v nnn '%03d' "${n}"
		d="${base}/tukfs-hash/${t}_${nnn}"
		fSafePath "${d}" || fDie "can't make a temp dir under ${base} that the cleanup could remove"
		mkdir -- "${d}" 2>/dev/null && break
		[[ -e "${d}" ]] || fDie "could not make ${d}"
		n=$((n + 1)); ((n < 1000)) || fDie "no free temp dir name under ${base}/tukfs-hash"
	done
	run_dirs+=("${d}")
	printf '%s\n' "${run_token}" > "${d}/${run_mark}" || fDie "could not mark ${d}"
	printf '%s\n' "$$" > "${d}/run.pid" || fDie "could not write ${d}/run.pid"
	## Here too, so a kept run that's killed still waits.
	if ((keep_temp)); then : > "${d}/${kept_mark}" || true; fi
	made_dir="${d}"
}

## Remove one of this run's dirs, drop it from the list, and set gone_kb to its
## size. Not through $( ), or the list would change in a subshell only.
gone_kb=0; freed_kb=0
declare -a kept_dirs=(); kept_shown=0
fRunDirGone(){   ## fRunDirGone DIR
	local d="$1" kb="" i
	gone_kb=0
	## --keep-temp. The next runs' sweep leaves it for 2 days from the mark.
	if ((keep_temp)); then
		[[ " ${kept_dirs[*]} " == *" ${d} "* ]] || { kept_dirs+=("${d}"); : > "${d}/${kept_mark}" || true; }
		return 0
	fi
	kb="$(du -sk -- "${d}" 2>/dev/null | cut -f1 || true)"
	fSafeRm "${d}" "${run_token}" || return 1
	for i in "${!run_dirs[@]}"; do if [[ "${run_dirs[i]}" == "${d}" ]]; then unset 'run_dirs[i]'; fi; done
	run_dirs=("${run_dirs[@]}")
	if [[ "${kb}" =~ ^[0-9]{1,15}$ ]]; then gone_kb="${kb}"; fi
	return 0
}

## The frozen copy sits in the run's temp dir. git takes it down first, so its
## record goes too; whatever git leaves goes with the temp dir.
frozen_root=""; frozen_tree=""
fFrozenGone(){
	local d="${frozen_root}"
	((! keep_temp)) || return 0
	frozen_root=""
	[[ -n "${d}" ]] || return 0
	fFrozenRemove "${root}" "${d}" && return 0
	echo "cleanup: git could not remove the frozen copy at ${d}; it goes with the temp dir" >&2
	return 0
}

## HOST_TEMP, else config.bash's RUN_TMP_ROOT, else TMPDIR, the first that's
## there. The run on the frozen copy gets its starter's dir as HOST_TEMP.
run_tmp_root=""
for _b in "${HOST_TEMP:-}" "${RUN_TMP_ROOT:-}" "${TMPDIR:-}" /tmp; do
	[[ -n "${_b}" && -d "${_b}" ]] || continue
	run_tmp_root="$(realpath -e -- "${_b}" 2>/dev/null)" && break
done
[[ "${run_tmp_root}" == /* ]] || fDie "no temp root: HOST_TEMP, RUN_TMP_ROOT, TMPDIR and /tmp aren't there"
fRunDirMake "${run_tmp_root}"
run_tmp="${made_dir}"
## So what the steps write, and the runs they start, go in it.
export TMPDIR="${run_tmp}" TEMP="${run_tmp}" TMP="${run_tmp}" HOST_TEMP="${run_tmp}"
## Every container of the run is labeled with this, the outer run's name.
if ((! inner_run)) || [[ ! "${TUKFS_RUN_NAME:-}" =~ ^[0-9]{8}-[0-9]{6}_[0-9]{3}$ ]]; then export TUKFS_RUN_NAME="${run_tmp##*/}"; fi
## Every container a step starts leaves its ID here, so a stop of the run
## kills each one, however far down its client is.
if ((! inner_run)); then
	mkdir -- "${run_tmp}/cid" || fDie "could not make ${run_tmp}/cid"
	export TUKFS_CID_DIR="${run_tmp}/cid"
	stop_cid_dir="${TUKFS_CID_DIR}"
fi
## The run on the frozen copy writes into its starter's, which records.
gate_skips="${run_tmp}/gate-skips"
if ((inner_run)) && [[ "${TUKFS_GATE_SKIPS:-}" == /* ]]; then gate_skips="${TUKFS_GATE_SKIPS}"; else : > "${gate_skips}"; fi
export TUKFS_GATE_SKIPS="${gate_skips}"
## Where stage 6 puts the release set, and 7 to 9 read it. The check-only modes
## keep theirs in the outer run's temp dir, so the checkout's set stays the one
## the last run that can ship built (2026102814341427).
release_dir=""
if [[ -z "${RELEASE_ARTIFACT_DIR}" ]]; then :
elif ((! gate_mode)); then release_dir="${root}/${RELEASE_ARTIFACT_DIR}"
elif ((inner_run)) && [[ "${TUKFS_RELEASE_DIR:-}" == /* ]]; then release_dir="${TUKFS_RELEASE_DIR}"
else release_dir="${run_tmp}/release-set"; export TUKFS_RELEASE_DIR="${release_dir}"
fi
## "STEP: why" for each SKIP, for the summary at the end. The run on the frozen
## copy writes into its starter's.
skip_log="${run_tmp}/skips"
if ((inner_run)) && [[ "${TUKFS_SKIP_LOG:-}" == /* ]]; then skip_log="${TUKFS_SKIP_LOG}"; else : > "${skip_log}"; fi
export TUKFS_SKIP_LOG="${skip_log}"

## The run's containers, by its dev.run label, once it's done with them, into
## ctrs_said. A stop has killed the running ones by ID first. Only when one
## was started, so a run that had none asks docker nothing. --keep-temp keeps
## them.
ctrs_done=0; ctrs_said=""; ctrs_kb=0
fCtrsGone(){
	local engine="${TUKFS_DOCKER:-docker}" out="" line=""
	local -a ids=() limit=()
	((! ctrs_done && ! inner_run)) || return 0
	ctrs_done=1; ctrs_said=""; ctrs_kb=0
	[[ -n "${stop_cid_dir}" ]] && compgen -G "${stop_cid_dir}/name_*" >/dev/null 2>&1 || return 0
	if command -v timeout >/dev/null 2>&1; then limit=(timeout 30); fi
	out="$("${limit[@]}" "${engine}" ps -a --size --filter "label=dev.project=${APP_NAME}" --filter "label=dev.run=${TUKFS_RUN_NAME}" \
		--format '{{.ID}} {{.Size}}' 2>/dev/null || true)"
	while read -r line; do [[ "${line%% *}" =~ ^[0-9a-f]{12,64}$ ]] && ids+=("${line%% *}"); done <<< "${out}"
	((${#ids[@]})) || return 0
	if ((keep_temp)); then ctrs_said="kept (--keep-temp): ${#ids[@]} container(s) labeled dev.run=${TUKFS_RUN_NAME}"; return 0; fi
	## docker's sizes are SI, such as 12.3kB, before "(virtual ...)".
	ctrs_kb="$(awk '{ v = $2; u = v; sub(/^[0-9.]+/, "", u); sub(/[A-Za-z]+$/, "", v)
		m = (u == "kB") ? 1 : (u == "MB") ? 1e3 : (u == "GB") ? 1e6 : (u == "TB") ? 1e9 : 0; t += v * m } END { printf "%d", t / 1.024 }' <<< "${out}")"
	[[ "${ctrs_kb}" =~ ^[0-9]{1,15}$ ]] || ctrs_kb=0
	if "${limit[@]}" "${engine}" rm -f "${ids[@]}" >/dev/null 2>&1; then
		ctrs_said="${#ids[@]} container(s)"
	else
		ctrs_said="some of ${#ids[@]} container(s), labeled dev.run=${TUKFS_RUN_NAME}"
	fi
	return 0
}

## A run that stops early: whatever it started, then its dirs. fCleanup has
## done this already on a whole run. A stop says so in the form lint-report.bash
## takes for a finished run.
fRunTmpGone(){
	local d kb="" total=0 left_frozen=""
	## Before the first write, for the same reason fStopDescendants does it.
	trap '' INT TERM HUP PIPE
	if ((! run_said && ! inner_run)); then printf '\n[ CICD ABORTED (stopped) ]\n' >&2; fi
	## First, or what's still running reads a copy and a temp dir already gone.
	fStopDescendants || true
	fCtrsGone || true
	if [[ "${ctrs_said}" == kept* ]]; then printf '[ %s ]\n' "${ctrs_said}" >&2
	elif [[ -n "${ctrs_said}" ]]; then printf '[ cleanup: removed %s, about %s ]\n' "${ctrs_said}" "$(fSize "${ctrs_kb}")" >&2; fi
	ctrs_said=""
	((${#run_dirs[@]})) || { fFrozenGone || true; return 0; }
	## Measured first, while the frozen copy is still in it.
	for d in "${run_dirs[@]}"; do
		kb="$(du -sk -- "${d}" 2>/dev/null | cut -f1 || true)"
		if [[ "${kb}" =~ ^[0-9]{1,15}$ ]]; then total=$((total + kb)); fi
	done
	left_frozen="${frozen_root}"
	fFrozenGone || true
	for d in "${run_dirs[@]}"; do fRunDirGone "${d}" || true; done
	if ((keep_temp)); then
		if ((! inner_run && ! kept_shown)); then for d in "${kept_dirs[@]}"; do printf '[ kept (--keep-temp): %s ]\n' "${d}" >&2; done; fi
		return 0
	fi
	## git's record of a copy it couldn't take down, now that the dir is gone.
	if [[ -n "${left_frozen}" ]]; then fFrozenRemove "${root}" "${left_frozen}" || true; fi
	if ((! inner_run)); then printf '[ cleanup: removed this run'\''s temp files, about %s ]\n' "$(fSize "${total}")" >&2; fi
	return 0
}
trap 'fRunTmpGone || true' EXIT
fStopOnSignals


#•••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••
## Version and build number

## No `| head -1`: under pipefail an early-quitting reader kills the writer with
## SIGPIPE, so the quit belongs in sed.
fVersion(){ sed -n '/^version *= *"/{ s/^version *= *"\(.*\)".*/\1/p; q; }' "${root}/${VERSION_MANIFEST}"; }

## The build number a binary prints after its version: minutes from 2000-01-01
## UTC to a unix time, rounded, and also in lower-case Crockford base32.
fBuildNumber(){   ## fBuildNumber EPOCH_SECONDS
	local digits="0123456789abcdefghjkmnpqrstvwxyz" n out=""
	## Anything but a count of seconds since 2000 would print a build that looks
	## real. The digits test also comes before any arithmetic reads it.
	if [[ ! "${1:-}" =~ ^[0-9]{1,15}$ ]] || ((10#$1 < 946684800)); then
		echo "fBuildNumber: not a time since 2000: '${1:-}'" >&2
		return 1
	fi
	n=$(( (10#$1 - 946684800 + 30) / 60 ))
	while :; do
		out="${digits:n % 32:1}${out}"
		n=$((n / 32))
		((n > 0)) || break
	done
	printf '%s\n' "${out}"
}

## From the commit, not the clock, so a rebuild of one commit gives the same
## bytes. Every cargo call in the run sees the same value, so none rebuilds
## over it.
## A release is a commit tagged v<version>, so tag before building one. Any
## other build prints its date too.
build_number=""; build_release=""; build_date=""
commit_time="$(git -C "${root}" log -1 --format=%ct "${gate_rev:-HEAD}" 2>/dev/null || true)"
if [[ -n "${commit_time}" ]]; then
	build_number="$(fBuildNumber "${commit_time}")" || fDie "no build number from the commit time"
	export "${BUILD_ENV_NAME}=${build_number}"
	commit_tags="$(git -C "${root}" tag --points-at "${gate_rev:-HEAD}" 2>/dev/null || true)"
	if [[ $'\n'"${commit_tags}"$'\n' == *$'\n'"v$(fVersion)"$'\n'* ]]; then
		build_release=1
	else
		build_date=" ($(date -d "@$(( (10#${commit_time} - 946684800 + 30) / 60 * 60 + 946684800 ))" +%F))"
	fi
	export "${BUILD_RELEASE_ENV_NAME}=${build_release}"
	## The packages' mtimes, and anything else that would read the clock.
	export SOURCE_DATE_EPOCH="${commit_time}"
fi


#•••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••
## Plan, and the one question

publish_msg=""
if   [[ -n "${cli_message}" ]];            then publish_msg="${cli_message}"
elif [[ -n "${PUBLISH_AUTO_MESSAGE:-}" ]]; then publish_msg="${PUBLISH_AUTO_MESSAGE}"
elif ((assume_yes));                       then publish_msg="${APP_NAME} CI/CD ${stamp}"
fi

fOnOff(){ if (($1)); then echo "${2}"; else echo "(off${3:+, $3})"; fi; }

## Which steps run, numbered in order, and why each other one is off. The run
## on the frozen copy takes the numbers of the run that started it.
declare -a steps_on=() steps_off=()
step_plan=""
fStepOn(){   ## fStepOn KEY -> 0 when the step runs
	case "$1" in
		sync)    ((sync_enable)) ;;
		format)  if ((gate_mode)); then ((${#FMT_CHECK_CMD[@]})); else ((${#FMT_CMD[@]})); fi ;;
		build)   ((! debug_off)) ;;
		lint)    ((! lint_off)) ;;
		tests)   ((! tests_off)) && ((! unit_off || ! it_off || ${#LEAKCHECK_STEPS[@]})) ;;
		profile) ((PROFILE_ENABLE && ${#PROFILE_BUILD_CMD[@]})) ;;
		release) ((! release_off)) ;;
		remote)  ((! release_off && ! remote_off && ${#REMOTE_HOSTS[@]})) ;;
		dogfood) ((DOGFOOD_ENABLE && ${#DOGFOOD_DESTS[@]})) ;;
		gif)     ((GIF_ENABLE)) && [[ -n "${GIF_CMD}" ]] ;;
		publish) ((${#GIT_PUBLISH[@]})) ;;
		*)       return 1 ;;
	esac
}
fStepPlan(){
	local k why n=0
	local -a words=()
	if ((inner_run)) && [[ -n "${plan_given}" ]]; then
		read -r -a words <<< "${plan_given}"
		step_total="${words[0]}"
		for k in "${words[@]:1}"; do step_no["${k%%=*}"]="${k#*=}"; done
		return 0
	fi
	for k in "${step_keys[@]}"; do
		if fStepOn "${k}"; then
			n=$((n + 1)); step_no["${k}"]="${n}"; step_plan+=" ${k}=${n}"
			steps_on+=("${step_title["${k}"]}")
			continue
		fi
		why="${off_why["${k}"]:-}"
		## Only the areas turn the unit and integration tests off.
		if [[ -z "${why}" && "${k}" == tests ]] && ((unit_off && it_off)); then why="not in the areas named"; fi
		steps_off+=("${step_title["${k}"]}: ${why:-off in config.bash}")
	done
	step_total="${n}"; step_plan="${n}${step_plan}"
}
fStepPlan
case "${mode}" in
	bq) run_kind="backlog run, quick${areas[*]:+: ${areas[*]}}" ;;
	bf) run_kind="backlog run, full" ;;
	mg) run_kind="merge gate" ;;
	*)  run_kind="local CI/CD"; ((! quick)) || run_kind+=", quick" ;;
esac
if ((list_only || (! quiet && ! inner_run))); then
	fEcho_Clean
	fEcho_Clean "${APP_NAME} ${run_kind}"
	fEcho_Clean
	fEcho_Clean "Repo root ......: ${root}"
	fEcho_Clean "Version ........: v$(fVersion)${build_number:+ build ${build_number}${build_date}}"
	fEcho_Clean "Jobs ...........: ${CPU_CAP} of ${cpu_cores} cores, ${cpu_why}; checked again at each step"
	cpu_shown="${CPU_CAP}"
	fEcho_Clean "Temp dir .......: ${run_tmp}"
	fEcho_Clean "Remote sync ....: $(fOnOff "${sync_enable}" 'fast-forward when behind; stop when diverged')"
	fEcho_Clean "Format .........: $( ((gate_mode)) && echo "${FMT_CHECK_CMD[*]:-(skipped)}" || echo "${FMT_CMD[*]:-(skipped)}")"
	fEcho_Clean "Build (debug) ..: $( ((debug_off)) && echo '(skipped)' || echo "${BUILD_CMD[*]}")"
	fEcho_Clean "Lint ...........: $( ((lint_off)) && echo '(skipped)' || echo "${LINT_CMD[*]}, shellcheck, markdownlint, PSScriptAnalyzer, ruff, mypy$( ((${#LINT_EXTRA[@]})) && echo ", ${#LINT_EXTRA[@]} more")")"
	_its=""; for _r in "${IT_ROOTS[@]}"; do _its+="${_r%%|*} (${_r#*|}), "; done
	fEcho_Clean "Tests ..........: $( ((tests_off || unit_off)) && echo '(skipped)' || echo "${TEST_CMD[*]}")"
	fEcho_Clean "Integration ....: $( ((tests_off || it_off)) && echo '(skipped)' || echo "${_its%, }")"
	fEcho_Clean "Leak checks ....: $( ((${#LEAKCHECK_STEPS[@]})) && echo "${#LEAKCHECK_STEPS[@]}, at the end of the tests" || echo '(none in this run)')"
	fEcho_Clean "Profiler .......: $(fOnOff "${PROFILE_ENABLE}" "${#PROFILE_TIMED[@]} step(s) on a tree under ${PROFILE_ROOT:-the temp dir} -> ${PROFILE_OUT_DIR:-(nowhere)}/")"
	if ((release_off)); then
		fEcho_Clean "Release ........: (skipped)"
	else
		_rel="${RELEASE_NATIVE_OSARCH}"; for _t in "${CROSS_TARGETS[@]}"; do _t="${_t#*|}"; _rel+=", ${_t%%|*}"; done
		if ((no_container)); then _rel="${RELEASE_NATIVE_OSARCH} on the host, with its glibc"; fi
		if [[ -z "${release_dir}" ]]; then _relTo="(nowhere)"; elif ((gate_mode)); then _relTo="the run's temp dir"; else _relTo="${RELEASE_ARTIFACT_DIR}"; fi
		fEcho_Clean "Release ........: ${_rel}, into ${_relTo}"
		fEcho_Clean "Release checks .: ${#RELEASE_CHECKS[@]}"
	fi
	fEcho_Clean "Packages .......: $(fOnOff "${PACKAGE_ENABLE}" '.deb and .rpm')"
	if ((DOGFOOD_ENABLE)) && ((${#DOGFOOD_DESTS[@]})); then
		_dfd="$(fFirstWritableDir "${DOGFOOD_DESTS[@]}")"
		if [[ -n "${_dfd}" ]]; then _dfd="${_dfd}/${EXE_NAME}"; else _dfd="(no writable dest; skips)"; fi
		fEcho_Clean "Dogfood ........: ${_dfd}"
	else
		fEcho_Clean "Dogfood ........: (off)"
	fi
	fEcho_Clean "Demo gif .......: $(fOnOff "${GIF_ENABLE}" "$( ((gif_to_tmp)) && echo 'drawn into the temp dir only' || echo "${GIF_OUT:-on}")")"
	if ((${#GIT_PUBLISH[@]})); then
		fEcho_Clean "Publish (last) .: ${GIT_PUBLISH[*]}$( [[ -n "${publish_msg}" ]] && echo " (\"${publish_msg}\")" || echo ' (asks for the message now)')"
	else
		fEcho_Clean "Publish (last) .: (skipped)"
	fi
	fEcho_Clean "Frozen copy ....: $( ((freeze)) && echo 'stages 2-7 run from a copy taken after the format stage' || echo '(off)')"
	fEcho_Clean "Containers .....: $( ((no_container)) && echo '(off, --no-container; the steps that use one run on the host)' || echo 'where docker answers, else the host; the build and tests in the release image')"
	_rh=""; for _h in "${REMOTE_HOSTS[@]}"; do _t="${_h#*|}"; _rh+="${_h%%|*} (${_t%%|*}), "; done
	if [[ -n "${step_no[remote]:-}" ]]; then _rh="${_rh%, }: the unit and integration tests, under the host lock"
	elif ((${#REMOTE_HOSTS[@]} == 0)); then _rh="(none in config.bash)"
	else _rh="(off, ${off_why[remote]:-the release builds are off})"; fi
	fEcho_Clean "Other hosts ....: ${_rh}"
	fEcho_Clean "Temp files .....: $( ((keep_temp)) && echo 'kept, --keep-temp' || echo 'removed at the end')"
	_on="$(printf '%s, ' "${steps_on[@]}")"
	fEcho_Clean "Steps ..........: ${step_total}$( ((step_total)) && echo ": ${_on%, }")"
	if ((${#steps_off[@]})); then
		fEcho_Clean "Steps off ......: ${steps_off[0]}"
		for _o in "${steps_off[@]:1}"; do fEcho_Clean "                  ${_o}"; done
	fi
	fEcho_Clean
elif ((! inner_run)) && ((${#steps_off[@]})); then
	## -q has no plan, so the count in the step lines would go unexplained.
	_off="$(printf '%s; ' "${steps_off[@]}")"
	fEcho_Clean "steps off: ${_off%; }"
fi
## A run with nothing in its plan would pass having checked nothing. The plan
## above says why each step is off.
if ((step_total == 0 && ! inner_run)); then
	keep_temp=0
	fDie "every step is off, so there's nothing to run (try --help)"
fi
## fListIds SUITE WHAT WHERE...: the IDs a suite prints its status lines with,
## and the steps that run it.
fListIds(){
	local ids where
	local -a lines=()
	ids="$("${TEST_ID_LIST_CMD[@]}" "$1")" || fDie "could not list the test IDs: ${TEST_ID_LIST_CMD[*]} $1"
	[[ -z "${ids}" ]] || mapfile -t lines <<< "${ids}"
	where="$(printf '%s; ' "${@:3}")"
	fEcho_Clean "   ${2}, ${#lines[@]} IDs, in ${where%; }:"
	((${#lines[@]} == 0)) || printf '      %s\n' "${lines[@]}"
}
if ((list_only)) && ((${#TEST_ID_LIST_CMD[@]})); then
	declare -a _unitIn=() _itIn=()
	if [[ -n "${step_no[tests]:-}" ]] && ((! unit_off)); then _unitIn+=("step ${step_no[tests]}, ${step_title[tests]}"); fi
	if [[ -n "${step_no[tests]:-}" ]] && ((! it_off)) && ((${#IT_ROOTS[@]})); then
		_its=""; for _r in "${IT_ROOTS[@]}"; do _its+="${_r%%|*}$([[ -d "${_r#*|}" ]] || echo ' (not there, so it skips)'), "; done
		_itIn+=("step ${step_no[tests]}, ${step_title[tests]}, once on each of ${_its%, }")
	fi
	if [[ -n "${step_no[release]:-}" ]]; then
		## A release check that runs IT_CMD prints the same lines again.
		for _c in "${RELEASE_CHECKS[@]}"; do
			if [[ "${_c#*|}" == *'${IT_CMD[@]}'* ]]; then _itIn+=("step ${step_no[release]}, ${step_title[release]}: ${_c%%|*}"); fi
		done
	fi
	if [[ -n "${step_no[remote]:-}" ]]; then
		for _h in "${REMOTE_HOSTS[@]}"; do
			_unitIn+=("step ${step_no[remote]}, ${step_title[remote]}, on ${_h%%|*}")
			_itIn+=("step ${step_no[remote]}, ${step_title[remote]}, on ${_h%%|*}")
		done
	fi
	if ((${#_unitIn[@]} || ${#_itIn[@]})); then
		fEcho_Clean "Test IDs, as each status line shows them:"
		if ((${#_unitIn[@]})); then fListIds unit "unit tests" "${_unitIn[@]}"; fi
		if ((${#_itIn[@]})); then fListIds it "integration test" "${_itIn[@]}"; fi
	else
		fEcho_Clean "Test IDs .......: (none in this run)"
	fi
	fEcho_Clean
fi
if ((list_only)); then
	fEcho_Clean "--list: nothing was run"
	## Nothing in it to keep.
	keep_temp=0
	run_said=1; exit 0
fi
if ((! assume_yes && ! inner_run)) && ((${#GIT_PUBLISH[@]})) && [[ -z "${publish_msg}" ]]; then
	read -r -p "Publish commit message (blank = git's editor; Ctrl+C stops the run): " m || true
	fEcho_ResetBlankCounter
	if [[ -n "${m:-}" ]]; then publish_msg="${m}"; fi
fi

## The whole run into a rotated log, for lint-report.bash. Not under
## --backlog-run-quick, which writes nothing, and not in the run on the
## frozen copy, whose output already goes through this one.
if [[ "${mode}" != bq ]] && ((! inner_run)) && [[ -n "${LINT_LOG_DIR:-}" ]] && mkdir -p "${root}/${LINT_LOG_DIR}" 2>/dev/null; then
	gfs_rotate "${root}/${LINT_LOG_DIR}" run log >/dev/null 2>&1 || true
	## It has to outlive the stop, or the cleanup lines are lost. A Ctrl+C
	## reaches the whole process group, so it ignores that too, and ends when
	## the run closes its end. -p keeps it writing the log after a reader such
	## as grep is gone, since the same stop takes that down too.
	exec > >(trap '' INT TERM; exec tee -p "${root}/${LINT_LOG_DIR}/run_${stamp}.log") 2>&1
	stop_keep+=("$!")
fi

## A pinned tool that drifted is a warning, so a box update can't change a
## result without saying so.
if ((! inner_run)); then
	for pin in "${TOOL_PINS[@]}"; do
		pin_name="${pin%%|*}"; rest="${pin#*|}"; pin_ver="${rest%%|*}"; pin_cmd="${rest#*|}"
		have="$(bash -c "${pin_cmd}" 2>/dev/null || true)"
		have="${have//$'\n'/ }"
		if [[ -z "${pin_ver}" ]]; then
			fEcho "WARNING: no pinned version for ${pin_name}"
		elif [[ -z "${have}" ]]; then
			fEcho "WARNING: pinned tool missing: ${pin_name} (want ${pin_ver})"
		elif [[ "${have}" != *"${pin_ver}"* ]]; then
			fEcho "WARNING: ${pin_name} drifted from pin ${pin_ver}: ${have:0:120}"
		fi
	done
fi


#•••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••
## Stages

## A stash the sync stage or the publisher left, when a run stopped between
## its stash and its pop, or the pop conflicted. It holds uncommitted work.
## Syncing or publishing past it leaves that work stashed, and the next stash
## buries it deeper. The publisher looks only for its own. Prints the entry.
fLeftStash(){
	local line=""
	while IFS= read -r line; do
		if [[ "${line}" =~ :\ (cicd\ sync\ [0-9]{8}-[0-9]{6}|auto-stash)$ ]]; then printf '%s\n' "${line}"; return 0; fi
	done < <(git -C "${root}" stash list 2>/dev/null)
	return 1
}

## Stage 0: take the remote's work before anything is built, so the run tests
## the tree that gets pushed. The publish stage refuses if there's more by then.
fStageSync(){
	local branch="" upstream="" out="" ahead=0 behind=0 dirty=0 ff=0
	fStep sync || return 0
	if out="$(fLeftStash)"; then fDie "an earlier run's stash is still in 'git stash list': ${out}. Pop or drop it, then run again"; fi
	branch="$(git -C "${root}" symbolic-ref --quiet --short HEAD || true)"
	upstream="$(git -C "${root}" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)"
	if [[ -z "${branch}" ]]; then
		fEcho "WARNING: detached HEAD; nothing to sync"
	elif [[ -z "${upstream}" ]]; then
		fEcho "WARNING: ${branch} tracks no upstream; nothing to sync"
	elif ! out="$(fGitRemote -C "${root}" fetch --quiet 2>&1)"; then
		fEcho_Clean "${out}"
		fEcho "WARNING: fetch failed (offline?); going on with the local tree"
	else
		## Counts either side of the merge base, so diverged reads apart from
		## behind. Only behind can fast-forward.
		read -r ahead behind < <(git -C "${root}" rev-list --left-right --count "HEAD...${upstream}")
		if   ((ahead && behind)); then fDie "${branch} and ${upstream} have diverged (${ahead} local, ${behind} remote); reconcile by hand"
		elif ((behind)); then
			## Stash-wrapped, since the tree is often dirty and a fast-forward
			## refuses to touch a modified file. An untracked file counts.
			if ! git -C "${root}" diff --quiet || ! git -C "${root}" diff --cached --quiet; then dirty=1; fi
			if [[ -n "$(git -C "${root}" ls-files --others --exclude-standard || true)" ]]; then dirty=1; fi
			if ((dirty)); then git -C "${root}" stash push --quiet --include-untracked --message "cicd sync ${stamp}"; fi
			if git -C "${root}" merge --ff-only --quiet "${upstream}"; then ff=1; fi
			## A pop that conflicts leaves markers in the tree, and building those
			## proves nothing. git keeps the entry on a failed pop.
			if ((dirty)) && ! git -C "${root}" stash pop --quiet; then
				fDie "the local changes conflict with ${upstream}; they're safe in the stash. Resolve, then 'git stash drop'"
			fi
			((ff)) || fDie "fast-forward from ${upstream} failed"
			fEcho "OK: fast-forwarded ${behind} commit(s) from ${upstream}"
		elif ((ahead)); then fEcho "OK: ${ahead} commit(s) ahead of ${upstream}, nothing to take"
		else                 fEcho "OK: level with ${upstream}"
		fi
	fi
	fStepPass
}

## Stage 1: format. In place; check-only in the check-only modes.
fStageFormat(){
	fStep format || return 0
	if ((gate_mode)) && ((${#FMT_CHECK_CMD[@]})); then
		fEcho_Clean "${FMT_CHECK_CMD[*]}"
		"${FMT_CHECK_CMD[@]}" || fDie "format check failed; run ${FMT_CMD[*]:-cargo fmt} and commit"
		fEcho "OK: format clean"
	elif ((${#FMT_CMD[@]})); then
		fEcho_Clean "${FMT_CMD[*]}"
		"${FMT_CMD[@]}" || fDie "formatter failed"
		fEcho "OK: formatted"
	else
		fDie "the plan has the format step on, but there's no format command"
	fi
	fStepPass
}

## Where stages 2-4 build and test, worked out once, at the first step that
## needs it. The image, or the host with one line saying why.
tests_ctr=""; tests_ctr_work=""; tests_ctr_why=""
fTestsWhere(){
	local why=""
	[[ -z "${tests_ctr}" ]] || return 0
	fCtrUseRelease
	ctr_step=tests
	why="$(fCtrWhyNot)"
	if [[ -z "${why}" ]]; then
		tests_ctr_work="${run_tmp}/ctr"
		if fCtrReady "${tests_ctr_work}"; then
			fCtrFetch "${tests_ctr_work}"
			tests_ctr=1
			RELEASE_NATIVE_BIN="${TESTS_CTR_NATIVE_BIN}"
			fEcho_Clean "build and tests: in ${ctr_tag}"
			return 0
		fi
		why="its image couldn't be set up"
	fi
	tests_ctr=0; tests_ctr_why="${why}"
	fEcho "NOTE: build and tests on the host, since ${why}"
}
## A cargo step, where fTestsWhere said. Run fTestsWhere first, in this shell.
fInTests(){   ## fInTests COMMAND [ARG...]
	if [[ "${tests_ctr}" == 1 ]]; then
		fCtrRunSelf "${tests_ctr_work}" "${TESTS_CTR_TARGET_DIR}" "${here}/utility/in-image.bash" "$@"
	else
		"$@"
	fi
}

## Stage 2: debug build.
fStageBuild(){
	fStep build || return 0
	fTestsWhere
	fEcho_Clean "${BUILD_CMD[*]}"
	fBg fInTests "${BUILD_CMD[@]}" || fDie "debug build failed"
	fEcho "OK: debug build"
	fStepPass
}

## One lint tool, its output also into the lint log.
lint_log="/dev/null"
## In the background, as each long step is, so a stop doesn't wait for it.
fLintTee(){ "$@" 2>&1 | tee -a "${lint_log}"; }
fLintRun(){ local rc=0; fBg fLintTee "$@" || rc=$?; return "${rc}"; }
## An eval'd one. Without its own ERR trap, since a finding isn't the run
## aborting.
fLintEval(){ trap - ERR; eval "$1"; }
## A missing tool fails in the check-only modes and is a noted skip otherwise.
fLintTool(){   ## fLintTool NAME -> 0 when it's here
	command -v "$1" >/dev/null 2>&1 && return 0
	((gate_strict)) && fDie "$1 is needed in a check-only run but isn't installed"
	fEcho "WARNING: $1 isn't installed; skipped"
	echo "$1" >> "${gate_skips}"
	return 1
}

## Stage 3: lint. Every tool runs, so the log has all of it, and then the stage
## fails if any of them did.
fStageLint(){
	local -a failed=() files=() shFiles=() mdFiles=() psFiles=() pyFiles=()
	local f skip s c
	fStep lint || return 0
	if [[ "${mode}" != bq ]] && [[ -n "${LINT_LOG_DIR:-}" ]] && mkdir -p "${root}/${LINT_LOG_DIR}" 2>/dev/null; then
		lint_log="${root}/${LINT_LOG_DIR}/lint_${stamp}.log"
	fi
	## Untracked files too, since they go out with the next publish.
	mapfile -t files < <(git -C "${root}" ls-files --cached --others --exclude-standard)
	for f in "${files[@]}"; do
		[[ -f "${root}/${f}" ]] || continue
		case "${f}" in
			*.bash) shFiles+=("${f}") ;;
			*.ps1)  psFiles+=("${f}") ;;
			*.py)   pyFiles+=("${f}") ;;
			*.md)
				skip=0
				for s in "${MARKDOWN_SKIP[@]}"; do if [[ "${f}" == "${s}" ]]; then skip=1; fi; done
				((skip)) || mdFiles+=("${f}") ;;
		esac
	done
	for f in "${SHELLCHECK_EXTRA[@]}"; do [[ -f "${root}/${f}" ]] && shFiles+=("${f}"); done

	fTestsWhere
	fEcho_Clean "clippy: ${LINT_CMD[*]}"
	if fLintRun fInTests "${LINT_CMD[@]}"; then fEcho "OK: clippy clean"; else failed+=(clippy); fi
	if ((! ${#shFiles[@]})); then
		fEcho_Clean "shellcheck: no bash files"
	elif fLintTool shellcheck; then
		fEcho_Clean "shellcheck: ${#shFiles[@]} file(s)"
		if fLintRun shellcheck "${shFiles[@]}"; then fEcho "OK: shellcheck clean"; else failed+=(shellcheck); fi
	fi
	if ((! ${#mdFiles[@]})); then
		fEcho_Clean "markdownlint: no markdown files"
	elif fLintTool markdownlint; then
		fEcho_Clean "markdownlint: ${#mdFiles[@]} file(s), ${MARKDOWNLINT_CMD[*]}"
		if fLintRun "${MARKDOWNLINT_CMD[@]}" "${mdFiles[@]}"; then fEcho "OK: markdownlint clean"; else failed+=(markdownlint); fi
	fi
	if ((${#psFiles[@]})) && ((${#PS_LINT_CMD[@]})) && fLintTool "${PS_LINT_CMD[0]}"; then
		fEcho_Clean "PSScriptAnalyzer: ${#psFiles[@]} file(s)"
		if fLintRun "${PS_LINT_CMD[@]}" "${psFiles[@]}"; then fEcho "OK: PSScriptAnalyzer clean"; else failed+=(PSScriptAnalyzer); fi
	fi
	## Not through fLintTool: a box without ruff or mypy skips it even in the
	## merge gate.
	if ((${#pyFiles[@]})) && ((${#PY_LINT_CMD[@]})); then
		if ! command -v "${PY_LINT_CMD[0]}" >/dev/null 2>&1; then
			fEcho "NOTE: ${PY_LINT_CMD[0]} isn't installed; ${#pyFiles[@]} Python file(s) not linted"
			echo "${PY_LINT_CMD[0]}" >> "${gate_skips}"
		else
			fEcho_Clean "ruff: ${#pyFiles[@]} file(s)"
			if fLintRun "${PY_LINT_CMD[@]}" "${pyFiles[@]}" && fLintRun "${PY_FMT_CHECK_CMD[@]}" "${pyFiles[@]}"; then
				fEcho "OK: ruff clean"
			else
				failed+=(ruff)
			fi
		fi
	fi
	if ((${#pyFiles[@]})) && ((${#PY_TYPE_CMD[@]})); then
		if ! command -v "${PY_TYPE_CMD[0]}" >/dev/null 2>&1; then
			fEcho "NOTE: ${PY_TYPE_CMD[0]} isn't installed; ${#pyFiles[@]} Python file(s) not type-checked"
			echo "${PY_TYPE_CMD[0]}" >> "${gate_skips}"
		else
			fEcho_Clean "mypy: ${#pyFiles[@]} file(s)"
			if fLintRun "${PY_TYPE_CMD[@]}" "${pyFiles[@]}"; then fEcho "OK: mypy clean"; else failed+=(mypy); fi
		fi
	fi
	for c in "${LINT_EXTRA[@]}"; do
		fEcho_Clean "${c%%|*}: ${c#*|}"
		if fLintRun fLintEval "${c#*|}"; then fEcho "OK: ${c%%|*}"; else failed+=("${c%%|*}"); fi
	done
	if [[ "${lint_log}" != /dev/null ]]; then gfs_rotate "${root}/${LINT_LOG_DIR}" lint log >/dev/null 2>&1 || true; fi
	lint_log="/dev/null"
	((${#failed[@]} == 0)) || fDie "lint: ${failed[*]} found something; the output is above"
	fStepPass
}

## The integration test once on ROOT, which makes its own dir under it, and
## sweeps its own stale ones.
fRunIt(){   ## fRunIt LABEL ROOT
	local label="$1" itRoot="$2" real="" fsType="" want="" rc=0
	if [[ ! -d "${itRoot}" ]]; then
		fEcho "NOTE: integration test on ${label} skipped, since ${itRoot} isn't there"
		echo "it-${label}" >> "${gate_skips}"
		return 0
	fi
	real="$(realpath -e -- "${itRoot}")"
	fsType="$(stat -f -c %T -- "${real}" 2>/dev/null || true)"
	case "${label}" in ext4) want="ext2/ext3" ;; *) want="${label}" ;; esac
	if [[ "${fsType}" != "${want}" ]]; then fEcho "WARNING: ${itRoot} is ${fsType:-unknown}, not ${label}"; echo "it-${label}" >> "${gate_skips}"; fi
	fEcho_Clean "integration test on ${label}: HOST_TEMP=${real} ${RELEASE_NATIVE_BIN}"
	HOST_TEMP="${real}" fBg "${IT_CMD[@]}" "${root}/${RELEASE_NATIVE_BIN}" || rc=$?
	((rc == 0)) || fDie "integration test failed on ${label} (exit ${rc})"
	fEcho "OK: integration test on ${label}"
}

## Stage 4: tests, then the slow leak checks.
fStageTests(){
	local r step t0
	fStep tests || return 0
	if ((! unit_off || ! it_off)); then fTestsWhere; fi
	if ((! unit_off)); then
		fEcho_Clean "${TEST_CMD[*]}  (TMPDIR=$( [[ "${tests_ctr}" == 1 ]] && echo "${tests_ctr_work}/tmp" || echo "${TMPDIR}"))"
		fBg fInTests "${TEST_CMD[@]}" || fDie "unit tests failed"
		fEcho "OK: unit tests"
	fi
	if ((! it_off)); then
		## The integration test runs the release build.
		fEcho_Clean "${RELEASE_NATIVE_CMD[*]}"
		fBg fInTests "${RELEASE_NATIVE_CMD[@]}" || fDie "release build failed"
		[[ -x "${root}/${RELEASE_NATIVE_BIN}" ]] || fDie "no release binary at ${RELEASE_NATIVE_BIN}"
		for r in "${IT_ROOTS[@]}"; do fRunIt "${r%%|*}" "${r#*|}"; done
	fi
	## Last, since the slow ones take a long time and the rest should report first.
	for step in "${LEAKCHECK_STEPS[@]}"; do
		fEcho_Clean "leak check: ${step}"
		fCpuCap heavy; fCpuShow
		t0="${SECONDS}"
		fBg eval "${step}" || fDie "leak check failed: ${step}"
		fEcho_Clean "leak check took $(fMinSec $((SECONDS - t0))): ${step}"
	done
	if ((${#LEAKCHECK_STEPS[@]})); then fEcho "OK: leak checks"; fi
	fStepPass
}

## The tree this run tested, for the pre-push hook, once the release checks
## and the gif are through too, since the merge gate has them. Taken after the
## format stage, since that rewrites what gets tested. Only the run that
## started records, so a gif that fails leaves nothing recorded
## (2026102814341404).
green_tree=""
fRecordGreen(){
	[[ -n "${green_tree}" ]] || return 0
	if [[ -s "${gate_skips}" ]]; then
		fEcho_Clean "tree not recorded for the pre-push hook, since this run skipped: $(sort -u "${gate_skips}" | paste -sd ' ')"
	elif "${here}/utility/green-tree.bash" record "${root}" "${green_tree}"; then
		fEcho "OK: tree ${green_tree:0:12} recorded; a push of it skips the pre-push gate"
	fi
	return 0
}

## Seconds since an EPOCHREALTIME, to 2 places, with no fork. Its point
## follows the locale, so a comma goes too.
fSecsSince(){ local us=$(( ${EPOCHREALTIME/[.,]/} - ${1/[.,]/} )); printf '%d.%02d s' $((us / 1000000)) $((us % 1000000 / 10000)); }

## Stage 5: profiler. The attribution check comes before any graph is drawn,
## since a graph that names the wrong code is worse than none. A failed build,
## check or step fails the run. The report never does, and never touches the
## --check marker, which is the session start's.
fStageProfile(){
	local base="" fsType="" work="" step="" name="" cmd="" t0="" svg="" profDir="" latest=""
	fStep profile || return 0
	fEcho_Clean "${PROFILE_BUILD_CMD[*]}"
	fBg "${PROFILE_BUILD_CMD[@]}" || fDie "profiling build failed"
	export PROFILE_BIN="${root}/${PROFILE_BIN}"
	[[ -x "${PROFILE_BIN}" ]] || fDie "no profiling binary at ${PROFILE_BIN}"
	if [[ -n "${PROFILE_CHECK}" ]]; then
		fEcho_Clean "attribution check: ${PROFILE_CHECK}"
		fBg eval "${PROFILE_CHECK}" || fDie "profiler attribution check failed; its graph would name the wrong code"
	fi

	base="${PROFILE_ROOT}"
	if [[ -z "${base}" || ! -d "${base}" ]]; then
		fEcho "NOTE: the profiler root ${base:-(none)} isn't there; the workload goes in the run's temp dir"
		base="${run_tmp_root}"
	fi
	fRunDirMake "${base}"
	work="${made_dir}"
	fsType="$(stat -f -c %T -- "${work}" 2>/dev/null || true)"
	if [[ "${fsType}" != ext2/ext3 ]]; then fEcho "WARNING: the profiler workload is on ${fsType:-unknown}, not ext4"; fi
	export PROFILE_WORKLOAD="${work}" TUKFS_PROFILE_DIR="${work}/samples"
	mkdir -- "${TUKFS_PROFILE_DIR}" || fDie "could not make ${TUKFS_PROFILE_DIR}"
	fEcho_Clean "workload: ${PROFILE_WORKLOAD_GEN}  (in ${work})"
	fBg eval "${PROFILE_WORKLOAD_GEN}" || fDie "the profiler workload failed"
	for step in "${PROFILE_TIMED[@]}"; do
		name="${step%%|*}"; cmd="${step#*|}"
		fEcho_Clean "profile step: ${name}"
		t0="${EPOCHREALTIME}"
		## In an if, so a step can test its own exit, as the rescan's 4.
		if ! fBg eval "${cmd}"; then fDie "profiler step failed: ${name}"; fi
		fEcho_Clean "profile timing: ${name} $(fSecsSince "${t0}")"
	done
	svg="${TUKFS_PROFILE_DIR}/flame.svg"
	[[ -s "${svg}" ]] || fDie "the profiler drew no flamegraph"

	## Born "frequent". The rotation gives it another role, by the stamp.
	profDir="${root}/${PROFILE_OUT_DIR}"
	mkdir -p -- "${profDir}" || fDie "could not make ${PROFILE_OUT_DIR}"
	mv -f -- "${svg}" "${profDir}/flame_${stamp}_frequent.svg" || fDie "could not move the flamegraph into ${PROFILE_OUT_DIR}"
	gfs_rotate "${profDir}" flame svg >/dev/null 2>&1 || true
	latest="$(compgen -G "${profDir}/flame_${stamp}_*.svg" || true)"
	latest="${latest%%$'\n'*}"
	[[ -n "${latest}" ]] || fDie "the flamegraph went missing from ${PROFILE_OUT_DIR} in the rotation"
	unset PROFILE_WORKLOAD TUKFS_PROFILE_DIR
	if fRunDirGone "${work}"; then freed_kb=$((freed_kb + gone_kb)); fi
	fEcho "OK: flamegraph: ${latest#"${root}/"}"
	if command -v python3 >/dev/null 2>&1; then
		fEcho_Clean
		fBg python3 "${here}/utility/flame-report.py" --dir "${profDir}" || fEcho_Clean "hot spots: no report; the reason is above"
	else
		fEcho "WARNING: python3 isn't installed; no hot spot report"
	fi
	fStepPass
}

## The release set's file names, which download links depend on:
## <exe>-<version>-<os-arch>, the same plus .deb or .rpm, and
## <exe>-<version>-sha256sums.txt. Anything else in the dir is left alone.
fReleaseName(){ [[ "$1" =~ ^${EXE_NAME}-[0-9][0-9A-Za-z.+~-]*-(linux-[a-z0-9_]+(\.deb|\.rpm)?|sha256sums\.txt)$ ]]; }

## Stage 6: the native release build and the cross targets, copied under their
## release names into a stage dir in the run's temp dir. Then the packages and
## the release checks over that, and only when all of them pass does the set
## replace the one in release_dir, with its sums file.
## For the eval'd config strings: release_stage, release_work, ver,
## staged_osarchs, the os-arch of each build, native first, and
## release_glibc, the floor check's mode.
release_stage=""; release_work=""; ver=""; release_glibc="glibc"
declare -a staged_osarchs=()
fStageRelease(){
	local t label osarch art cmd c f n artDir artShown sums relBin="${RELEASE_BUILD_BIN}"
	local -a built=() names=() relCmd=("${RELEASE_BUILD_CMD[@]}")
	fStep release || return 0
	ver="$(fVersion)"
	[[ -n "${ver}" ]] || fDie "no version in ${VERSION_MANIFEST}"
	## Without the image it still builds, but not a set that can go out, so
	## the tree isn't recorded either (2026102509342993).
	fTestsWhere
	if [[ "${tests_ctr}" != 1 ]]; then
		relCmd=("${RELEASE_HOST_BUILD_CMD[@]}"); relBin="${RELEASE_HOST_BUILD_BIN}"
		release_glibc="glibc-note"; CROSS_TARGETS=()
		echo "release-image" >> "${gate_skips}"
		fEcho "NOTE: release build on the host, ${RELEASE_NATIVE_OSARCH} only and with its glibc, since ${tests_ctr_why}"
	fi
	fEcho_Clean "${relCmd[*]}"
	fBg "${relCmd[@]}" || fDie "release build failed"
	[[ -x "${root}/${relBin}" ]] || fDie "no release binary at ${relBin}"
	## Bytes, since du gives what a compressed filesystem stores.
	fEcho "OK: ${RELEASE_NATIVE_OSARCH}: ${relBin} ($(stat -c %s -- "${root}/${relBin}") bytes)"
	built=("${RELEASE_NATIVE_OSARCH}|${relBin}")
	for t in "${CROSS_TARGETS[@]}"; do
		label="${t%%|*}"; t="${t#*|}"; osarch="${t%%|*}"; t="${t#*|}"; art="${t%%|*}"; cmd="${t#*|}"
		fEcho_Clean "cross: ${label}: ${cmd}"
		fBg eval "${cmd}" || fDie "cross build failed: ${label}"
		[[ -f "${root}/${art}" ]] || fDie "no binary for ${label} at ${art}"
		fEcho "OK: ${osarch}: ${art} ($(stat -c %s -- "${root}/${art}") bytes)"
		built+=("${osarch}|${art}")
	done
	[[ -n "${release_dir}" ]] || { fStepPass; return 0; }

	release_stage="${TMPDIR}/release"; release_work="${TMPDIR}/release-work"
	mkdir -- "${release_stage}" "${release_work}" || fDie "could not make the release stage dir"
	staged_osarchs=()
	for t in "${built[@]}"; do
		osarch="${t%%|*}"; n="${EXE_NAME}-${ver}-${osarch}"
		fReleaseName "${n}" || fDie "${n}: not a release name; check the os-arch in config.bash"
		cp -- "${root}/${t#*|}" "${release_stage}/${n}" || fDie "could not stage ${n}"
		chmod 0755 -- "${release_stage}/${n}"
		if [[ -n "${SOURCE_DATE_EPOCH:-}" ]]; then touch -d "@${SOURCE_DATE_EPOCH}" -- "${release_stage}/${n}"; fi
		staged_osarchs+=("${osarch}")
	done
	if ((PACKAGE_ENABLE)) && [[ -n "${PACKAGE_CMD}" ]]; then
		fEcho_Clean "packages"
		fBg eval "${PACKAGE_CMD}" || fDie "packages failed"
	fi
	for c in "${RELEASE_CHECKS[@]}"; do
		fEcho_Clean "release check: ${c%%|*}"
		fBg eval "${c#*|}" || fDie "release check failed: ${c%%|*}"
	done
	if ((${#RELEASE_CHECKS[@]})); then fEcho "OK: ${#RELEASE_CHECKS[@]} release check(s)"; fi

	## The sums file goes first and comes back last, so a run stopped part way
	## leaves no sums for a mixed set. Old files go by name, one at a time, so
	## a dir that isn't the release set can't lose more than its release files.
	artDir="${release_dir}"; artShown="${artDir#"${root}/"}"
	sums="${EXE_NAME}-${ver}-sha256sums.txt"
	mkdir -p -- "${artDir}" || fDie "could not make ${artShown}"
	rm -f -- "${artDir}/.${sums}.tmp"
	for f in "${artDir}/${EXE_NAME}-"*sha256sums.txt; do
		if [[ -f "${f}" && ! -L "${f}" ]] && fReleaseName "${f##*/}"; then rm -f -- "${f}"; fi
	done
	for f in "${release_stage}"/*; do
		n="${f##*/}"
		fReleaseName "${n}" || fDie "the stage dir has ${n}, which isn't a release name"
		mv -f -- "${f}" "${artDir}/${n}" || fDie "could not move ${n} into ${artShown}"
		names+=("${n}")
	done
	for f in "${artDir}/${EXE_NAME}-"*; do
		if [[ -f "${f}" && ! -L "${f}" && " ${names[*]} " != *" ${f##*/} "* ]] && fReleaseName "${f##*/}"; then rm -f -- "${f}"; fi
	done
	( cd "${artDir}" && sha256sum -- "${names[@]}" > ".${sums}.tmp" && mv -f -- ".${sums}.tmp" "${sums}" ) || fDie "could not write ${sums}"
	fEcho_Clean "$(cd "${artDir}" && stat -c '%10s  %n' -- "${names[@]}" "${sums}")"
	fEcho "OK: ${#names[@]} release file(s) and ${sums} in ${artShown}/"
	if ((${#CROSS_TARGETS[@]} == 0)); then fEcho_Clean "note: no cross targets in this run, so the set is the native build alone"; fi
	fStepPass
}

## Stage 7: the unit tests and the integration test on a box of each arch in
## REMOTE_HOSTS, on stage 6's build of it, through remote-tests.bash. A box
## that isn't there, or no build of its arch in this run, is a SKIP, and the
## run goes on. It keeps the tree from being recorded, as a missing test root
## does.
fStageRemote(){
	local h host osarch target bin rc why ran=0
	local whyFile="${run_tmp}/remote-why"
	fStep remote || return 0
	for h in "${REMOTE_HOSTS[@]}"; do
		host="${h%%|*}"; h="${h#*|}"; osarch="${h%%|*}"; target="${h#*|}"
		bin="${release_dir}/${EXE_NAME}-${ver}-${osarch}"
		why=""
		if [[ " ${staged_osarchs[*]} " != *" ${osarch} "* || -z "${release_dir}" || ! -f "${bin}" ]]; then
			why="no ${osarch} build in this run"
		else
			fEcho_Clean "${host}: cicd/utility/remote-tests.bash ${host} ${target} ${bin#"${root}/"}"
			rc=0; rm -f -- "${whyFile}"
			TUKFS_SKIP_WHY="${whyFile}" fBg "${here}/utility/remote-tests.bash" "${host}" "${target}" "${bin}" || rc=$?
			if ((rc > 128)); then exit "${rc}"; fi
			if ((rc == 3)); then
				why="$(cat -- "${whyFile}" 2>/dev/null || true)"; why="${why#"${host}: "}"; why="${why:-no reason given}"
			else
				((rc == 0)) || fDie "the tests failed on ${host} (exit ${rc})"
				fEcho "OK: unit and integration tests on ${host}"
				ran=$((ran + 1))
				continue
			fi
		fi
		fEcho "SKIP ${host}: ${why}"
		echo "${step_title[remote]}: ${host}, ${why}" >> "${skip_log}"
		echo "remote-${host}" >> "${gate_skips}"
	done
	if ((ran)); then fStepPass; else fStepSkip; fi
}

## Stage 8: the native release build into the first writable dest, unless
## that copy is running or already has these bytes. Then the dogfood runner and
## its launcher, where they changed.
fStageDogfood(){
	local src="" dest="" runner rSrc rDir sorry=0
	local -a parts=()
	fStep dogfood || return 0
	src="${release_dir}/${EXE_NAME}-$(fVersion)-${RELEASE_NATIVE_OSARCH}"
	[[ -n "${release_dir}" && -f "${src}" ]] || fDie "no native release build at ${src}"
	dest="$(fFirstWritableDir "${DOGFOOD_DESTS[@]}")"
	if [[ -z "${dest}" ]]; then
		fEcho "WARNING: no dogfood dest is there and writable (${DOGFOOD_DESTS[*]}); skipped"
	elif cmp -s -- "${src}" "${dest}/${EXE_NAME}"; then
		fEcho "OK: ${dest}/${EXE_NAME} is already this build"
	elif fInUse "${dest}/${EXE_NAME}"; then
		fEcho "WARNING: ${dest}/${EXE_NAME} is running; dogfood copy skipped"
	else
		fInstallAtomic "${src}" "${dest}" "${EXE_NAME}" 0755 || sorry=1
	fi
	## "source|dir|dir...". Into each dir that's there.
	for runner in "${DOGFOOD_RUNNERS[@]}"; do
		IFS='|' read -r -a parts <<< "${runner}"
		rSrc="${root}/${parts[0]}"
		[[ -f "${rSrc}" ]] || fDie "no dogfood runner at ${parts[0]}"
		for rDir in "${parts[@]:1}"; do
			if [[ ! -d "${rDir}" || ! -w "${rDir}" ]]; then fEcho "WARNING: ${rDir} isn't there or writable; ${rSrc##*/} not copied"; continue; fi
			if cmp -s -- "${rSrc}" "${rDir}/${rSrc##*/}"; then fEcho_Clean "${rDir}/${rSrc##*/} is current"; continue; fi
			fInstallAtomic "${rSrc}" "${rDir}" "${rSrc##*/}" 0755 || sorry=1
		done
	done
	((sorry == 0)) || fDie "dogfood: an install failed; see above"
	fStepPass
}

## Stage 9: demo gif. A check-only run draws it from the tree it tested, into
## its temp dir.
fGifIn(){ cd "$1" && root="$1" && eval "${GIF_CMD}"; }
fStageGif(){
	local gifRoot="${root}"
	fStep gif || return 0
	if ((gif_to_tmp)); then
		GIF_OUT="${run_tmp}/demo.gif"; GIF_ROTATE_DIR="${run_tmp}/no-private/demo/gif"
		if [[ -n "${gate_rev}" && -n "${frozen_root}" ]]; then gifRoot="${frozen_root}"; fi
	fi
	fBg fGifIn "${gifRoot}" || fDie "demo gif failed"
	if ((! gif_to_tmp)); then gif_wrote="${GIF_OUT#"${root}"/}"; fi
	fStepPass
}

## Stage 10: backup + publish through the copied publisher. It commits and
## pushes the checkout as it is, after its own pull, so first make sure that's
## what was tested. The gif this run drew is the one change it makes itself.
tested_tree=""; gif_wrote=""
fStagePublish(){
	local flag="--no-prompt" now="" out="" upstream="" behind="" i=0
	local -a changed=()
	fStep publish || return 0
	local -r nothing="Nothing was committed or pushed."
	## Again here, since --no-sync skips the check at the start.
	if out="$(fLeftStash)"; then fDie "publish refused: an earlier run's stash is still in 'git stash list': ${out}. Pop or drop it, then run again. ${nothing}"; fi
	[[ -n "${tested_tree}" ]] || fDie "publish refused: no record of the tree this run tested. ${nothing}"
	now="$("${here}/utility/green-tree.bash" tree "${root}")" || fDie "publish refused: could not read the checkout's tree. ${nothing}"
	out="$(git -C "${root}" diff --name-only --no-renames "${tested_tree}" "${now}")" || fDie "publish refused: could not compare the checkout with the tree tested. ${nothing}"
	if [[ -n "${out}" ]]; then mapfile -t changed < <(grep -vxF -- "${gif_wrote:-/}" <<< "${out}" || true); fi
	if ((${#changed[@]})); then
		fEcho_Clean "Changed in the checkout since the run took the tree it tested:"
		for ((i = 0; i < ${#changed[@]} && i < 20; i++)); do fEcho_Clean "	${changed[i]}"; done
		if ((${#changed[@]} > 20)); then fEcho_Clean "	and $((${#changed[@]} - 20)) more"; fi
		fDie "publish refused: the checkout isn't the tree this run tested. ${nothing}"
	fi
	if upstream="$(git -C "${root}" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)"; then
		out="$(fGitRemote -C "${root}" fetch --quiet 2>&1)" || { fEcho_Clean "${out}"; fDie "publish refused: fetch from ${upstream} failed. ${nothing}"; }
		behind="$(git -C "${root}" rev-list --count "HEAD..${upstream}")" || fDie "publish refused: could not compare with ${upstream}. ${nothing}"
		((behind == 0)) || fDie "publish refused: ${upstream} has ${behind} commit(s) this run didn't test. Run again to take them. ${nothing}"
	fi
	command -v rar >/dev/null 2>&1 || export GIT_BACKUP_AND_PUBLISH_NOBACKUP=1
	## This run already asked, so the publisher doesn't. -q also quiets it.
	((quiet)) && flag="--quiet"
	if [[ -n "${publish_msg}" ]]; then
		## The GIT_EDITOR helper fills the message, so no editor opens.
		GIT_AUTO_MESSAGE="${publish_msg}" GIT_EDITOR="${here}/utility/git-auto-msg.bash" "${GIT_PUBLISH[@]}" "${flag}"
	else
		"${GIT_PUBLISH[@]}" "${flag}"
	fi
	fEcho "OK: published"
	fStepPass
}

## A detached, locked worktree of what the format stage left, HEAD plus what
## isn't committed, for stages 2-7. Any trouble making it runs them in the
## checkout, with a warning.
fFreeze(){
	local head="" tree="" link="" i=0
	local -a changed=()
	if [[ -n "${gate_rev}" ]]; then
		## The pushed commit, as it is. Its builds go to their own target dir, so
		## they don't replace the checkout's.
		tree="$(git -C "${root}" rev-parse -q --verify "${gate_rev}^{tree}" 2>/dev/null)" || fDie "no such commit: ${gate_rev}"
		frozen_root="${run_tmp}/tree"
		fFrozenAdd "${root}" "${frozen_root}" "${gate_rev}" || { frozen_root=""; fDie "could not check ${gate_rev:0:12} out to gate it"; }
		fFrozenLink "${root}" "${frozen_root}" target "${root}/${GATE_TARGET_DIR:-target-gate}" || fDie "could not link the gate's target dir"
		frozen_tree="${tree}"
		fSection "Frozen copy"
		fEcho_Clean "stages 2-7 run from ${frozen_root}, holding ${gate_rev:0:12}, the commit being pushed"
		return 0
	fi
	if ! head="$(git -C "${root}" rev-parse -q --verify HEAD 2>/dev/null)" || ! tree="$("${here}/utility/green-tree.bash" tree "${root}" 2>/dev/null)"; then
		fEcho "WARNING: no commit to copy; stages 2-7 run in the checkout"
		return 0
	fi
	frozen_root="${run_tmp}/tree"
	if ! fFrozenAdd "${root}" "${frozen_root}" "${head}" "${tree}"; then
		frozen_root=""
		fEcho "WARNING: could not make a frozen copy; stages 2-7 run in the checkout"
		return 0
	fi
	for link in "${FROZEN_LINKS[@]}"; do
		fFrozenLink "${root}" "${frozen_root}" "${link}" || fDie "could not link ${link} into the frozen copy"
	done
	frozen_tree="${tree}"
	mapfile -t changed < <(git -C "${root}" diff --name-status --no-renames "${head}" "${tree}")
	fSection "Frozen copy"
	fEcho_Clean "stages 2-7 run from ${frozen_root}"
	if ((${#changed[@]} == 0)); then
		fEcho_Clean "copied ${head:0:12}, with nothing uncommitted"
	else
		fEcho_Clean "copied ${head:0:12} plus ${#changed[@]} uncommitted file(s):"
		for ((i = 0; i < ${#changed[@]} && i < 20; i++)); do fEcho_Clean "	${changed[i]}"; done
		if ((${#changed[@]} > 20)); then fEcho_Clean "	and $((${#changed[@]} - 20)) more"; fi
	fi
	return 0
}

## Stages 2-7 in the frozen copy, by the copy's own engine.
fRunFrozen(){
	local -a inner=("$( ((quiet)) && echo -q || echo -y )" --no-sync --no-dogfood --no-gif --no-publish "${inner_pass[@]}")
	local rc=0
	tested_tree="${frozen_tree}"
	((record_green)) && green_tree="${frozen_tree}"
	TUKFS_RUN_PART=build TUKFS_STEP_PLAN="${step_plan}" fBg bash "${frozen_root}/cicd/cicd.bash" "${inner[@]}" || rc=$?
	## It ended on a blank line of its own.
	_wasLastEchoBlank=1
	## A stopped run stays a stopped run, and the EXIT trap says so.
	if ((rc > 128)); then exit "${rc}"; fi
	((rc == 0)) || fDie "the run in the frozen copy failed; its output is above"
}


#•••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••
## Cleanup

## rm -rf for build cache entries in one area: TARGET/<profile>/<area>/<name>,
## or the same under a target triple, no links, and ours. The profiles are
## debug, release and profiling. The area is resolved once, so a name in it
## that isn't a link can't lead anywhere else. One rm for the lot, since after
## a toolchain update every entry is stale. A name that fails a check is left.
fSafeRmCache(){   ## fSafeRmCache CACHE_REAL AREA NAME...
	local cache="$1" area="$2" real="" name="" p=""
	local -a ok=()
	shift 2
	[[ "${cache}" == /* && "${cache}" != *//* && "${cache}" != *..* ]] || return 1
	[[ "${area}" == "${cache}/"* && "${area}" != *..* && "${area}" != *$'\n'* ]] || return 1
	[[ "${area#"${cache}/"}" =~ ^([a-z0-9_-]+/)?(debug|release|profiling)/(deps|build|\.fingerprint|incremental)$ ]] || return 1
	real="$(realpath -e -- "${area}" 2>/dev/null || true)"
	[[ "${real}" == "${area}" && ! -L "${area}" ]] || return 1
	for name in "$@"; do
		p="${area}/${name}"
		if [[ "${name}" =~ ^[A-Za-z0-9_.+-]+$ && "${name}" != *..* && ! -L "${p}" && -O "${p}" ]]; then ok+=("${p}"); fi
	done
	((${#ok[@]})) || return 0
	printf '%s\0' "${ok[@]}" | xargs -0 rm -rf --one-file-system --
}

## Build cache entries that are dead for sure: made before rust-toolchain.toml
## last changed, so by the toolchain it pinned before, or named for a crate
## that's gone from Cargo.lock. A warm cache for the current toolchain and
## lockfile stays. The host and the release image both take their toolchain
## from that pin, so it dates target/ctr too, where the host's own install
## time didn't (2026102814341438). Prints "COUNT KB".
fPruneCache(){   ## fPruneCache DIR
	local dir="${root}/$1" cache="" toolTime=0 mt=0 kb=0 n=0 name="" crate="" e="" area="" size="" stale=0
	local -a names=()
	local -A crates=() sizes=()
	[[ -d "${dir}" ]] || { echo "0 0"; return 0; }
	cache="$(realpath -e -- "${dir}")" || { echo "0 0"; return 0; }
	toolTime="$(stat -c %Y -- "${root}/rust-toolchain.toml" 2>/dev/null || echo 0)"
	while read -r name; do crates["${name//-/_}"]=1; done < <(sed -n 's/^name = "\([^"]*\)"$/\1/p' "${root}/Cargo.lock")
	## Names of what cargo makes for a unit: lib<crate>-<hash>.<ext>, <crate>-<hash>[.<ext>],
	## and build_script_build-<hash> beside its package's dir.
	for area in "${cache}"/{,*/}{debug,release,profiling}/{deps,build,.fingerprint,incremental}; do
		[[ -d "${area}" && ! -L "${area}" ]] || continue
		names=()
		while IFS=$'\t' read -r -d '' mt e; do
			[[ "${mt}" =~ ^[0-9]{1,15}$ ]] || continue
			name="${e##*/}"
			stale=0
			if ((toolTime > 0 && mt < toolTime)); then stale=1
			elif ((${#crates[@]})) && [[ "${name}" == *-* ]]; then
				## libc's rlib is liblibc-<hash>, and its dep-info libc-<hash>.d.
				crate="${name%-*}"; crate="${crate//-/_}"
				if [[ -z "${crates[${crate}]:-}" && -z "${crates[${crate#lib}]:-}" && "${crate}" != build_script_* ]]; then stale=1; fi
			fi
			if ((stale)); then names+=("${name}"); fi
		done < <(find "${area}" -mindepth 1 -maxdepth 1 -printf '%Ts\t%p\0' 2>/dev/null)
		((${#names[@]})) || continue
		## Sizes first, all in one du, a hard link counted in each name as
		## before. A name is counted once it's gone.
		sizes=()
		while IFS=$'\t' read -r -d '' size e; do
			if [[ "${size}" =~ ^[0-9]{1,15}$ ]]; then sizes["${e##*/}"]="${size}"; fi
		done < <(printf '%s\0' "${names[@]/#/"${area}/"}" | du -skl -0 --files0-from=- 2>/dev/null)
		fSafeRmCache "${cache}" "${area}" "${names[@]}" || true
		for name in "${names[@]}"; do
			[[ -e "${area}/${name}" || -L "${area}/${name}" ]] && continue
			n=$((n + 1)); kb=$((kb + ${sizes["${name}"]:-0}))
		done
	done
	echo "${n} ${kb}"
}

## A cache dir that another live run's frozen copy links to as its target,
## such as the pre-push gate building in target-gate. Its lock file can differ
## from the checkout's, and its build is mid-write. A run in the checkout
## itself, with no frozen copy, isn't seen.
fCacheInUse(){   ## fCacheInUse DIR
	local dir="${root}/$1" d="" pid=""
	[[ -n "${run_tmp_root}" && -d "${dir}" ]] || return 1
	for d in "${run_tmp_root}/tukfs-hash/"[0-9]*_[0-9][0-9][0-9]; do
		[[ -L "${d}/tree/target" && "${d}/tree/target" -ef "${dir}" ]] || continue
		pid=""; { read -r pid < "${d}/run.pid"; } 2>/dev/null || continue
		[[ "${pid}" =~ ^[0-9]{1,10}$ && "${pid}" != "$$" && -d "/proc/${pid}" ]] && return 0
	done
	return 1
}

## Run dirs whose run is gone: killed outright, so their trap never ran, or
## kept by --keep-temp over 2 days ago (2026102518150001). A strict name, a
## run.pid that's gone, and a mark that names the same PID. A frozen copy in
## one goes through git first, so its locked record goes too.
fSweepStale(){   ## fSweepStale BASE -> prints "COUNT KB"
	local base="" d="" got="" pid="" kb=0 n=0 size=0 repo=""
	base="$(realpath -e -- "$1" 2>/dev/null || true)"
	[[ -n "${base}" && -d "${base}/tukfs-hash" ]] || { echo "0 0"; return 0; }
	while IFS= read -r -d '' d; do
		[[ -d "${d}" && ! -L "${d}" ]] || continue
		fSafePath "${d}" 2>/dev/null || continue
		pid=""; { read -r pid < "${d}/run.pid"; } 2>/dev/null || continue
		[[ "${pid}" =~ ^[0-9]{1,10}$ && "${pid}" != "$$" ]] || continue
		## Not kill -0, which fails on another user's process too.
		[[ -d "/proc/${pid}" ]] && continue
		got=""; { read -r got < "${d}/${run_mark}"; } 2>/dev/null || continue
		[[ "${got}" == "${pid}-"* ]] || continue
		if [[ -e "${d}/${kept_mark}" && -n "$(find "${d}/${kept_mark}" -maxdepth 0 -mmin -2880 2>/dev/null)" ]]; then continue; fi
		size="$(du -sk -- "${d}" 2>/dev/null | cut -f1 || true)"
		[[ "${size}" =~ ^[0-9]{1,15}$ ]] || size=0
		repo=""
		## fSafeRm checks this too, but only after git has been in it.
		[[ -O "${d}" ]] || continue
		if [[ -d "${d}/tree" && ! -L "${d}/tree" ]]; then
			## The checkout it came from, which may not be this one.
			repo="$(git -C "${d}/tree" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
			[[ "${repo}" == /* ]] || repo="${root}"
			fFrozenRemove "${repo}" "${d}/tree" || true
		fi
		if fSafeRm "${d}" "${got}"; then n=$((n + 1)); kb=$((kb + size)); fi
		if [[ -n "${repo}" ]]; then fFrozenRemove "${repo}" "${d}/tree" || true; fi
	done < <(find "${base}/tukfs-hash" -mindepth 1 -maxdepth 1 -type d -name '[0-9]*_[0-9][0-9][0-9]' -print0 2>/dev/null)
	echo "${n} ${kb}"
}

## Every root a run makes dirs under, into swept, with their size in swept_kb.
declare -a swept=(); swept_kb=0
fSweepKilled(){
	local r out n=0 kb=0
	swept=(); swept_kb=0
	for r in "${run_tmp_root}" ${PROFILE_ROOT:+"${PROFILE_ROOT}"}; do
		out="$(fSweepStale "${r}")"; read -r n kb <<< "${out}"
		if ((n)); then swept+=("${n} stale run dir(s) under ${r}"); swept_kb=$((swept_kb + kb)); fi
	done
	return 0
}

## What's gone stale that the pipeline made, then this run's temp files, in one
## line. The run on the frozen copy only removes its own.
fCleanup(){
	local -a gone=()
	local d kb=0 total=0 n=0 c out
	if ((inner_run)); then
		fFrozenGone || true
		for d in "${run_dirs[@]}"; do fRunDirGone "${d}" || true; done
		return 0
	fi
	fSection "$(fNow): Cleanup"
	## Measured first, while the frozen copy is still in it.
	kb="$(du -sk -- "${run_tmp}" 2>/dev/null | cut -f1 || true)"
	[[ "${kb}" =~ ^[0-9]{1,15}$ ]] || kb=0
	total=$((freed_kb + kb))
	fFrozenGone || true
	if ((! gate_mode)); then
		for c in "${CACHE_DIRS[@]}"; do
			if fCacheInUse "${c}"; then fEcho_Clean "cleanup: left ${c} as it is, since another run is building in it"; continue; fi
			out="$(fPruneCache "${c}")"; read -r n kb <<< "${out}"
			if ((n)); then gone+=("${n} stale build cache entries in ${c}"); total=$((total + kb)); fi
		done
	fi
	fSweepKilled
	gone+=("${swept[@]}"); total=$((total + swept_kb))
	fCtrsGone
	if [[ "${ctrs_said}" == kept* ]]; then fEcho_Clean "${ctrs_said}"
	elif [[ -n "${ctrs_said}" ]]; then gone+=("${ctrs_said}"); total=$((total + ctrs_kb)); fi
	ctrs_said=""
	for d in "${run_dirs[@]}"; do fRunDirGone "${d}" || true; done
	if ((keep_temp)); then
		kept_shown=1
		for d in "${kept_dirs[@]}"; do fEcho_Clean "kept (--keep-temp): ${d}"; done
		total=$((total - kb))
		if ((${#gone[@]})); then fEcho_Clean "cleanup: removed $(printf '%s, ' "${gone[@]}" | sed 's/, $//'), about $(fSize "${total}")"; fi
		return 0
	fi
	gone+=("this run's temp files")
	fEcho_Clean "cleanup: removed $(printf '%s, ' "${gone[@]}" | sed 's/, $//'), about $(fSize "${total}")"
	return 0
}


#•••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••
## Run

fmt_done=0
## Here too, and not only at the end, so a run that's stopped as well still
## takes down what the last one left.
if ((! inner_run)); then
	fSweepKilled
	if ((${#swept[@]})); then fEcho_Clean "cleanup: removed $(printf '%s, ' "${swept[@]}" | sed 's/, $//'), about $(fSize "${swept_kb}")"; fi
	fStageSync
fi
if ((freeze)); then
	## Rewrites the checkout, before the copy is taken. A check runs in the copy.
	if ((${#FMT_CMD[@]})); then fStageFormat; fmt_done=1; fi
	fFreeze
fi
if [[ -n "${frozen_root}" ]]; then
	fRunFrozen
else
	## The run on the frozen copy only checks, and only in the check-only modes.
	if ((! fmt_done)) && { ((gate_mode)) || [[ "${run_part}" != build ]]; }; then fStageFormat; fi
	if ((! inner_run)) && { ((record_green)) || ((${#GIT_PUBLISH[@]})); }; then tested_tree="$("${here}/utility/green-tree.bash" tree "${root}" || true)"; fi
	if ((record_green && ! inner_run)); then green_tree="${tested_tree}"; fi
	fStageBuild
	fStageLint
	fStageTests
	fStageProfile
	fStageRelease
	fStageRemote
fi
if ((! inner_run)); then
	fStageDogfood
	fStageGif
	fRecordGreen
	fStagePublish
fi
## Before the cleanup takes the file away.
declare -a skipped=()
if ((! inner_run)) && [[ -s "${skip_log}" ]]; then mapfile -t skipped < "${skip_log}"; fi
fCleanup
if ((inner_run)); then run_said=1; exit 0; fi

run_said=1
if ((${#skipped[@]})); then
	fEcho_Clean
	fEcho_Clean "Skipped:"
	for _s in "${skipped[@]}"; do fEcho_Clean "   SKIP ${_s}"; done
fi
fSection "${APP_NAME} CI/CD: done. ($(fMinSec $((SECONDS - started))))"
fEcho_Clean
exit 0
}


##	History:
##		- 2026-10-23: Created from shcl's engine, trimmed to one crate on Linux: no
##		  crosscheck, large-document gate, drop-ins tarball, installer drift
##		  check, bindings or container. Stages print start and PASS lines with
##		  times. The integration test runs once per test root in config.bash. Run
##		  dirs, the frozen copy in them, and stale build cache entries are
##		  removed only behind guards. --slow, and a build number for --version.
##		- 2026-10-23: --gate always leaves the leak checks out, and each one's
##		  time is shown.
##		- 2026-10-23: The profiler stage, from shcl's: its attribution check, a
##		  generated workload in a run dir of its own, a timed line per step, a
##		  rotated flamegraph and flame-report.py's summary. ruff in the lint
##		  stage, and the profiling build in the cache prune.
##		- 2026-10-23: The demo gif's settings in the plan.
##		- 2026-10-23: LINT_EXTRA, for the test ID check. A cid dir in the run's
##		  temp dir, so a stop kills every container the run started.
##		- 2026-10-23: A build that isn't a tagged release shows its date.
##		- 2026-10-24: --no-debug, and --no-codeql for CodeQL on its own.
##		- 2026-10-24: A stop's cleanup ignores further signals and a gone
##		  reader, and the run log outlives the reader.
##		- 2026-10-24: INT, TERM and HUP trapped, and the long steps waited on
##		  in the background, so a second TERM can't skip the cleanup. A killed
##		  run's dirs and frozen copy go at the next run's start and end, as
##		  soon as its PID is gone, rather than a day later.
##		- 2026-10-24: With no TMPDIR, a run works under RUN_TMP_ROOT, not /tmp.
##		- 2026-10-25: A quarter of the cores when busy or for a leak check,
##		  rechecked at each step, and nice 19 with idle I/O.
##		- 2026-10-25: The shared flags: --long, --backlog-run-quick with its
##		  areas, --backlog-run-full, --merge-gate, --no-container, --no-remote,
##		  --keep-temp and --list. --gate and --ci are other names. The tree is
##		  recorded after the release checks.
##		- 2026-10-25: Step lines in the shared form, timed to the hundredth and
##		  closed by PASS or FAIL. Only the steps that run are counted, the
##		  frozen copy's included, and the plan lists the rest with the reason.
##		  A 79 character rule.
##		- 2026-10-25: --list prints the test IDs too, from TEST_ID_LIST_CMD.
##		- 2026-10-25: The debug build, clippy, unit tests and the integration
##		  test's release build in the release image, or on the host with a note.
##		- 2026-10-25: Without the image, the x86_64 release build on the host,
##		  with a note, and no arm64.
##		- 2026-10-25: Stage 7, other hosts: the arm64 unit and integration
##		  tests on vmDebARM64. A box that isn't there is a SKIP, listed again
##		  at the end. --no-remote skips it.
##		- 2026-10-25: Run dirs named <stamp>_<NNN> under HOST_TEMP, with
##		  run.pid, and swept after 2 days. TEMP and TMP too. The integration
##		  test makes its own dir. The run's containers are removed by label
##		  at the end.
##		- 2026-10-25: Leak checks in 3 lengths. The fast ones run in --quick
##		  too, and long ones only in --long, which the frozen copy now gets.
##		- 2026-10-25: A killed run's dir and frozen copy go at the next run
##		  again. Only a kept dir waits 2 days.
##		- 2026-10-28: mypy in the lint stage. shellcheck follows sources, per
##		  .shellcheckrc, so the disables that only covered for that are gone.
##		- 2026-10-29: Publish refuses a checkout that changed since the run took
##		  its tree, other than the gif, and an upstream with commits to take.
##		- 2026-10-28: The backlog runs and the merge gate build the release set
##		  in the run's temp dir, and leave the checkout's alone.
##		- 2026-10-29: An area named with the --no- option that takes it out is
##		  refused, and so is a plan with no steps.
##		- 2026-10-29: The profiler, lint, cross builds, packages and release
##		  checks in the background too, so a stop doesn't wait for them.
##		- 2026-10-29: Sync and publish refuse while an earlier run's stash is
##		  left. The cache prune dates entries by rust-toolchain.toml, and leaves
##		  a cache dir alone while another run builds in it.
