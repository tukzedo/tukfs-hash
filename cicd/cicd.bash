#!/usr/bin/env bash

#  shellcheck disable=1091  ## 'source is valid here, but shellcheck doesn't know the path to it.'
#  shellcheck disable=2016  ## 'Expressions don't expand in single quotes, use double quotes for that.' I know, and I often want an explicit '$'.
#  shellcheck disable=2034  ## 'variable appears unused.' Complains about valid use of variable indirection.
#  shellcheck disable=2153  ## 'Possible misspelling.' False hit on vars assigned in the sourced config.bash.
#  shellcheck disable=2154  ## 'referenced but not assigned.' False hit on trap strings that assign the var they use (rc=$?).
#  shellcheck disable=2155  ## 'Declare and assign separately to avoid masking return values.' Cumbersome and unnecessary.
#  shellcheck disable=2317  ## 'Can't reach.' False hits on functions that only run from a trap.
#  shellcheck disable=2329  ## 'This function is never invoked.' The same, for the EXIT trap's function.

##	- Purpose: Local CI/CD pipeline. Generic engine; the project's settings
##	  are in config.bash.
##	- Stages, fail-fast (an error stops the run before the next stage):
##	   0. remote sync (fast-forward from upstream before anything is built)
##	   1. format (in place; check-only under --gate)
##	   2. build (debug)
##	   3. lint (clippy, shellcheck over every tracked *.bash, markdownlint over
##	      every tracked .md, PSScriptAnalyzer over every tracked .ps1, ruff
##	      over every tracked .py, then LINT_EXTRA, such as the test ID check)
##	   4. tests (cargo test, then the integration test once per test root),
##	      then the slow leak checks
##	   5. profiler (a flamegraph of a scan, from an in-process sampler, into
##	      PROFILE_OUT_DIR, and flame-report.py's summary of it)
##	   6. release builds (native, cross targets, packages, release checks),
##	      into RELEASE_ARTIFACT_DIR with a sha256 sums file
##	   7. dogfood (the native release build, and the dogfood runner)
##	   8. demo gif (a scenario run against the release build, drawn as a
##	      fake terminal, GFS-rotated, and copied to GIF_OUT when it changed)
##	   9. backup + publish to git
##	   A stage config.bash has off prints one skip line. Cleanup comes last.
##	- Syntax:
##	  cicd/cicd.bash [options]
##	  Options:
##	   With no options a run does every stage config.bash has on.
##	   --gate              the merge gate the pre-push hook runs: format check
##	                       (no rewrite), build, lint and tests. Strict: a
##	                       missing tool fails it. Unattended, and no release,
##	                       dogfood, gif or publish
##	   --quick             leave out the steps config.bash lists in QUICK_SKIP,
##	                       the leak checks, profiler and demo gif
##	   --slow              everything, the same as no options. Not with --quick
##	   --leakcheck         add the slow leak checks to --quick. --gate never
##	                       runs them
##	   --no-leakcheck      leave the leak checks out of any run. Not with
##	                       --leakcheck
##	   -q, --quiet         unattended and quiet: no preflight block, and cargo
##	                       and the publisher get their own quiet flags. Stage
##	                       lines, results and warnings still print
##	   -y, --yes           unattended, not quiet
##	   -m, --message MSG   publish with this commit message. Also --msg MSG,
##	                       and -m=MSG
##	   --no-sync           skip the remote sync
##	   --no-fmt            skip the format stage
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
##	   --no-freeze         run stages 2-6 in the checkout, not in a copy
##	   -h, --help          show this help
##	- With none of -q, -y, -m or --no-publish, the run asks once at the start
##	  for the commit message. Blank opens git's editor at publish, and Ctrl+C
##	  stops the whole run.
##	- The job count is half of nproc, at least 1, worked out once and given to
##	  every tool that runs in parallel, cargo's test threads included. A
##	  CPU_CAP set by the caller wins.
##	- A run that passes the tests records the tree it tested
##	  (utility/green-tree.bash), and the pre-push hook lets a push of that tree
##	  through without running the gate again. --quick, --no-fmt, --no-lint,
##	  --no-tests, a missing tool and a missing test root each keep a run from
##	  recording.
##	- Each run works in <TMPDIR>/tukfs-hash/<prefix>_run_<stamp>_<pid>, with
##	  TMPDIR pointed into it, so what a failed test leaves goes with it. It and
##	  the integration test's dirs are removed at the end, even when the run
##	  fails or is stopped, and only by fSafeRm. A stop kills the containers
##	  the run started first.
##	- Stages 2-6 run from a copy of the tree taken after the format stage,
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

## Half the cores, since the box usually has something else running. Anything
## but a plain count is ignored, since it goes into arithmetic.
_cores="$(nproc 2>/dev/null || echo 2)"
if [[ ! "${CPU_CAP:-}" =~ ^[1-9][0-9]{0,3}$ ]]; then
	CPU_CAP=$(( _cores / 2 ))
	if (( CPU_CAP < 1 )); then CPU_CAP=1; fi
fi
## cargo and libtest take these where a command has no -j or --test-threads.
export CPU_CAP CARGO_BUILD_JOBS="${CPU_CAP}" RUST_TEST_THREADS="${CPU_CAP}"

## Settings config.bash may leave out.
LEAKCHECK_STEPS=(); CROSS_TARGETS=(); QUICK_SKIP=(); FROZEN_LINKS=(); CACHE_DIRS=(); SHELLCHECK_EXTRA=(); MARKDOWN_SKIP=()
RELEASE_CHECKS=(); DOGFOOD_DESTS=(); DOGFOOD_RUNNERS=(); PS_LINT_CMD=(); PY_LINT_CMD=(); PY_FMT_CHECK_CMD=(); LINT_EXTRA=()
PROFILE_ENABLE=0; PACKAGE_ENABLE=0; DOGFOOD_ENABLE=0; GIF_ENABLE=0
PROFILE_BUILD_CMD=(); PROFILE_TIMED=(); PROFILE_BIN=''; PROFILE_OUT_DIR=''; PROFILE_ROOT=''; PROFILE_CHECK=''; PROFILE_WORKLOAD_GEN=''
PACKAGE_CMD=''; GIF_CMD=''; GIF_OUT=''; RELEASE_ARTIFACT_DIR=''; RELEASE_NATIVE_OSARCH='native'
## -q for eval'd config strings that pass it on to a tool. Empty otherwise.
QUIET_FLAG=""

## shellcheck source=config.bash
source "${here}/config.bash"
[[ "${RUN_TMP_PREFIX:-}" =~ ^[a-z0-9_-]{8,}$ ]] || { echo "config.bash: RUN_TMP_PREFIX has to be 8 or more of a-z, 0-9, _ and -" >&2; exit 2; }

## Set for the run a run starts on its frozen copy: TUKFS_RUN_PART=build runs
## stages 2-6 only, and TUKFS_GREEN_TREE is the tree the copy holds. The
## pre-push hook sets TUKFS_GATE_REV to the commit being pushed, which is then
## what gets copied, with nothing uncommitted.
run_part="${TUKFS_RUN_PART:-}"; green_given="${TUKFS_GREEN_TREE:-}"; gate_rev="${TUKFS_GATE_REV:-}"
unset TUKFS_RUN_PART TUKFS_GREEN_TREE TUKFS_GATE_REV
case "${run_part}" in ''|build) ;; *) echo "TUKFS_RUN_PART=${run_part}: not build" >&2; exit 2 ;; esac
if [[ -n "${gate_rev}" && ! "${gate_rev}" =~ ^[0-9a-f]{40}$ ]]; then echo "TUKFS_GATE_REV=${gate_rev}: not a full commit hash" >&2; exit 2; fi
inner_run=0
if [[ -n "${run_part}" ]]; then inner_run=1; fi

source "${here}/utility/include/frozen-tree.bash"
source "${here}/utility/include/stop-descendants.bash"
source "${here}/utility/include/gfs-rotate.bash"
cd "${root}"
stamp="$(date +%Y%m%d-%H%M%S)"
started=${SECONDS}


#•••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••
## Options

assume_yes=0; quiet=0; gate_mode=0; quick=0; slow=0; cli_message=""; sync_enable=1; gate_partial=0
leakcheck_flag=0; no_leakcheck=0; no_freeze=0; fmt_off=0; lint_off=0; tests_off=0; release_off=0
## The options the run on the frozen copy takes over.
inner_pass=()
while (($#)); do case "$1" in
	--gate)                   gate_mode=1; assume_yes=1; inner_pass+=("$1"); shift ;;
	--quick)                  quick=1; inner_pass+=("$1"); shift ;;
	--slow)                   slow=1; shift ;;
	--leakcheck)              leakcheck_flag=1; inner_pass+=("$1"); shift ;;
	--no-leakcheck)           no_leakcheck=1; inner_pass+=("$1"); shift ;;
	-q|--quiet)               quiet=1; assume_yes=1; QUIET_FLAG="-q"; export CARGO_TERM_QUIET=true; shift ;;
	-y|--yes)                 assume_yes=1; shift ;;
	--no-sync)                sync_enable=0; shift ;;
	--no-fmt)                 fmt_off=1; gate_partial=1; inner_pass+=("$1"); shift ;;
	--no-lint)                lint_off=1; gate_partial=1; inner_pass+=("$1"); shift ;;
	--no-tests)               tests_off=1; LEAKCHECK_STEPS=(); gate_partial=1; inner_pass+=("$1"); shift ;;
	--no-cross)               CROSS_TARGETS=(); inner_pass+=("$1"); shift ;;
	--no-package)             PACKAGE_ENABLE=0; inner_pass+=("$1"); shift ;;
	--no-profile)             PROFILE_ENABLE=0; inner_pass+=("$1"); shift ;;
	## Dogfood and the gif take the release binary, so a stale one would go out.
	--no-release)             release_off=1; PACKAGE_ENABLE=0; DOGFOOD_ENABLE=0; GIF_ENABLE=0; inner_pass+=("$1"); shift ;;
	--no-dogfood)             DOGFOOD_ENABLE=0; shift ;;
	--no-gif)                 GIF_ENABLE=0; shift ;;
	--no-publish)             GIT_PUBLISH=(); shift ;;
	--no-freeze)              no_freeze=1; shift ;;
	--message=*|--msg=*|-m=*) cli_message="${1#*=}"; shift ;;
	-m|--message|--msg)       (($# >= 2)) || { echo "$1 needs a message (try --help)" >&2; exit 2; }; cli_message="$2"; shift 2 ;;
	-h|--help)                sed -n '/^##	- Purpose:/,/^##	History:/p' "${BASH_SOURCE[0]}" | sed '$d; s/^##	\{0,1\}//'; exit 0 ;;
	*) echo "unknown option: $1 (try --help)" >&2; exit 2 ;;
esac; done
## Two options that say opposite things are refused, rather than the last winning.
if ((leakcheck_flag && no_leakcheck)); then echo "--leakcheck and --no-leakcheck can't go together (try --help)" >&2; exit 2; fi
if ((quick && slow)); then echo "--quick and --slow can't go together (try --help)" >&2; exit 2; fi
if [[ -n "${gate_rev}" ]] && ((! gate_mode)); then echo "TUKFS_GATE_REV is only for --gate" >&2; exit 2; fi

## --gate: correctness only, unattended and side-effect free.
if ((gate_mode)); then
	## A gate that skips what it can't run stops checking the day a box loses
	## a tool, so here a missing tool fails. A test root that isn't there is
	## still a skip with a note, since not every box has one.
	gate_strict=1
	sync_enable=0
	FMT_CMD=()
	release_off=1; CROSS_TARGETS=(); PACKAGE_ENABLE=0; PROFILE_ENABLE=0; DOGFOOD_ENABLE=0; GIF_ENABLE=0
	GIT_PUBLISH=()
else
	gate_strict=0
	FMT_CHECK_CMD=()
fi
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
	PROFILE_ENABLE=0; GIF_ENABLE=0
	for list in LEAKCHECK_STEPS CROSS_TARGETS RELEASE_CHECKS IT_ROOTS; do fQuickDrop "${list}"; done
fi
## A run with no options does everything, the leak checks included. The gate
## is the pre-push hook, and stays fast.
if ((no_leakcheck || gate_mode)) || { ((quick)) && ((! leakcheck_flag)); }; then LEAKCHECK_STEPS=(); fi

## A run at least as thorough as the gate records the tree it tested.
record_green=1
if ((quick || gate_partial)); then record_green=0; fi


#•••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••
## Output

declare -i _wasLastEchoBlank=0
fEcho_ResetBlankCounter(){ _wasLastEchoBlank=0; }
fEcho_Clean(){ if [[ -n "${1:-}" ]]; then echo -e "$*"; _wasLastEchoBlank=0; elif [[ "${_wasLastEchoBlank}" == 0 ]] && echo; then _wasLastEchoBlank=1; fi; }
fEcho(){       if [[ -n "$*"     ]]; then fEcho_Clean "[ $* ]"; else fEcho_Clean ""; fi; }
fEcho_Force(){ fEcho_ResetBlankCounter; fEcho "$*"; }
_letterbox="••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••"
fSection(){ fEcho_Clean; fEcho_Clean "${_letterbox}"; fEcho "$*"; }
## Set once the run has said how it ended, so the EXIT trap knows a stop by
## its silence. $? there is 0 after a TERM.
run_said=0
fDie(){ run_said=1; { fEcho_Force "FAILED: $*"; echo; } >&2; exit 1; }
fNow(){ printf '%(%Y%m%d-%H%M%S)T' -1; }
## A stage opens with its start line and closes with a PASS or SKIP line.
step_n=0; step_name=""
fStep(){     step_n="$1"; step_name="$2"; fSection "$(fNow); Step ${step_n} of 9; ${step_name} ..."; }
fStepPass(){ fEcho "$(fNow); PASS: Step ${step_n} of 9; ${step_name}."; fEcho_Clean; }
fStepSkip(){ fEcho_Clean "${1:-skipped}"; fEcho "$(fNow); SKIP: Step ${step_n} of 9; ${step_name}."; fEcho_Clean; }
fMinSec(){ printf '%dm %02ds' $(($1 / 60)) $(($1 % 60)); }
## KB to a size a person reads.
fSize(){ if (($1 >= 1048576)); then printf '%d.%d GB' $(($1 / 1048576)) $(($1 % 1048576 * 10 / 1048576)); else printf '%d MB' $((($1 + 512) / 1024)); fi; }
trap 'rc=$?; run_said=1; printf "\n[ CICD ABORTED (exit %s) at line %s: %s ]\n\n" "$rc" "$LINENO" "$BASH_COMMAND" >&2; exit $rc' ERR

## Git that talks to the remote goes through gitsby where it's installed, so it
## uses the account the repo belongs to. Plain git on a box without it.
fGitRemote(){ if command -v gitsby >/dev/null 2>&1; then gitsby raw git "$@"; else git "$@"; fi; }

## Dogfood helpers, from shcl's engine.
## First existing and writable dir from the list; nothing when there's none.
fFirstWritableDir(){ local d; for d in "$@"; do if [[ -d "${d}" && -w "${d}" ]]; then echo "${d}"; break; fi; done; return 0; }
## 0 when a running process was started from this file.
fInUse(){   ## fInUse PATH
	local path exe
	path="$(readlink -f -- "$1" 2>/dev/null)" || return 1
	for exe in /proc/[0-9]*/exe; do
		if [[ "$(readlink -- "${exe}" 2>/dev/null || true)" == "${path}" ]]; then return 0; fi
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
## Temp dirs, and the only rm -rf this script does

## Every dir the run makes is <root>/tukfs-hash/<prefix>_<kind>_<stamp>_<pid>[_<label>],
## with this run's token in its mark file. The kinds are run, it for the
## integration test, and prof for the profiler's workload.
run_mark=".cicd-run"
run_token="$$-${RANDOM}${RANDOM}-${EPOCHREALTIME}"
declare -a run_dirs=()   ## made by this run, removed at the end

## The checks fSafeRm makes before it removes anything, minus the mark. 0 when
## PATH could be one of this run's dirs.
fSafePath(){
	local p="${1:-}" fhs=""
	if [[ -z "${p}" || "${p}" != /* || "${p}" == *..* || "${p}" == *//* || "${p}" == *$'\n'* ]]; then
		printf 'cleanup: refused, bad path: "%s"\n' "${p}" >&2; return 1
	fi
	if ! [[ "${p}" =~ ^(/[A-Za-z0-9._+-]+)+/tukfs-hash/${RUN_TMP_PREFIX}_(run|it|prof)_[0-9]{8}-[0-9]{6}_[0-9]+(_[a-z0-9]+)?$ ]]; then
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
made_dir=""
fRunDirMake(){   ## fRunDirMake BASE KIND [LABEL]
	local base="" d=""
	base="$(realpath -e -- "$1")" || fDie "temp root isn't there: $1"
	d="${base}/tukfs-hash/${RUN_TMP_PREFIX}_$2_${stamp}_$$${3:+_$3}"
	fSafePath "${d}" || fDie "can't make a temp dir under ${base} that the cleanup could remove"
	mkdir -p -- "${base}/tukfs-hash" || fDie "could not make ${base}/tukfs-hash"
	mkdir -- "${d}" || fDie "could not make ${d}"
	run_dirs+=("${d}")
	printf '%s\n' "${run_token}" > "${d}/${run_mark}" || fDie "could not mark ${d}"
	made_dir="${d}"
}

## Remove one of this run's dirs, drop it from the list, and set gone_kb to its
## size. Not through $( ), or the list would change in a subshell only.
gone_kb=0; freed_kb=0
fRunDirGone(){   ## fRunDirGone DIR
	local d="$1" kb="" i
	gone_kb=0
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
	frozen_root=""
	[[ -n "${d}" ]] || return 0
	fFrozenRemove "${root}" "${d}" && return 0
	echo "cleanup: git could not remove the frozen copy at ${d}; it goes with the temp dir" >&2
	return 0
}

run_tmp_root="$(realpath -e -- "${TMPDIR:-/tmp}" 2>/dev/null || true)"
[[ "${run_tmp_root}" == /* ]] || run_tmp_root="$(realpath -e /tmp)"
fRunDirMake "${run_tmp_root}" run
run_tmp="${made_dir}"
export TMPDIR="${run_tmp}"
## Every container a step starts leaves its ID here, so a stop of the run
## kills each one, however far down its client is.
if ((! inner_run)); then
	mkdir -- "${run_tmp}/cid" || fDie "could not make ${run_tmp}/cid"
	export TUKFS_CID_DIR="${run_tmp}/cid"
	stop_cid_dir="${TUKFS_CID_DIR}"
fi
gate_skips="${run_tmp}/gate-skips"
: > "${gate_skips}"

## A run that stops early: whatever it started, then its dirs. fCleanup has
## done this already on a whole run. A stop says so in the form lint-report.bash
## takes for a finished run.
fRunTmpGone(){
	local d kb="" total=0 left_frozen=""
	if ((! run_said && ! inner_run)); then printf '\n[ CICD ABORTED (stopped) ]\n' >&2; fi
	## First, or what's still running reads a copy and a temp dir already gone.
	fStopDescendants || true
	((${#run_dirs[@]})) || { fFrozenGone || true; return 0; }
	## Measured first, while the frozen copy is still in it.
	for d in "${run_dirs[@]}"; do
		kb="$(du -sk -- "${d}" 2>/dev/null | cut -f1 || true)"
		if [[ "${kb}" =~ ^[0-9]{1,15}$ ]]; then total=$((total + kb)); fi
	done
	left_frozen="${frozen_root}"
	fFrozenGone || true
	for d in "${run_dirs[@]}"; do fRunDirGone "${d}" || true; done
	## git's record of a copy it couldn't take down, now that the dir is gone.
	if [[ -n "${left_frozen}" ]]; then fFrozenRemove "${root}" "${left_frozen}" || true; fi
	if ((! inner_run)); then printf '[ cleanup: removed this run'\''s temp files, about %s ]\n' "$(fSize "${total}")" >&2; fi
	return 0
}
trap 'fRunTmpGone || true' EXIT


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
build_number=""
commit_time="$(git -C "${root}" log -1 --format=%ct "${gate_rev:-HEAD}" 2>/dev/null || true)"
if [[ -n "${commit_time}" ]]; then
	build_number="$(fBuildNumber "${commit_time}")" || fDie "no build number from the commit time"
	export "${BUILD_ENV_NAME}=${build_number}"
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
if ((! quiet && ! inner_run)); then
	fEcho_Clean
	fEcho_Clean "${APP_NAME} $( ((gate_mode)) && echo 'gate' || echo 'local CI/CD')$( ((quick)) && echo ', quick' )"
	fEcho_Clean
	fEcho_Clean "Repo root ......: ${root}"
	fEcho_Clean "Version ........: v$(fVersion)${build_number:+ build ${build_number}}"
	fEcho_Clean "Jobs ...........: ${CPU_CAP} (of ${_cores} cores)"
	fEcho_Clean "Temp dir .......: ${run_tmp}"
	fEcho_Clean "Remote sync ....: $(fOnOff "${sync_enable}" 'fast-forward when behind; stop when diverged')"
	fEcho_Clean "Format .........: $( ((gate_mode)) && echo "${FMT_CHECK_CMD[*]:-(skipped)}" || echo "${FMT_CMD[*]:-(skipped)}")"
	fEcho_Clean "Build (debug) ..: ${BUILD_CMD[*]}"
	fEcho_Clean "Lint ...........: $( ((lint_off)) && echo '(skipped)' || echo "${LINT_CMD[*]}, shellcheck, markdownlint, PSScriptAnalyzer, ruff$( ((${#LINT_EXTRA[@]})) && echo ", ${#LINT_EXTRA[@]} more")")"
	if ((tests_off)); then
		fEcho_Clean "Tests ..........: (skipped)"
	else
		_its=""; for _r in "${IT_ROOTS[@]}"; do _its+="${_r%%|*} (${_r#*|}), "; done
		fEcho_Clean "Tests ..........: ${TEST_CMD[*]}"
		fEcho_Clean "Integration ....: ${_its%, }"
	fi
	fEcho_Clean "Leak checks ....: $( ((${#LEAKCHECK_STEPS[@]})) && echo "${#LEAKCHECK_STEPS[@]}, at the end of the tests" || echo '(none in this run)')"
	fEcho_Clean "Profiler .......: $(fOnOff "${PROFILE_ENABLE}" "${#PROFILE_TIMED[@]} step(s) on a tree under ${PROFILE_ROOT:-the temp dir} -> ${PROFILE_OUT_DIR:-(nowhere)}/")"
	if ((release_off)); then
		fEcho_Clean "Release ........: (skipped)"
	else
		_rel="${RELEASE_NATIVE_OSARCH}"; for _t in "${CROSS_TARGETS[@]}"; do _t="${_t#*|}"; _rel+=", ${_t%%|*}"; done
		fEcho_Clean "Release ........: ${_rel}, into ${RELEASE_ARTIFACT_DIR:-(nowhere)}"
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
	fEcho_Clean "Demo gif .......: $(fOnOff "${GIF_ENABLE}" "${GIF_OUT:-on}")"
	if ((${#GIT_PUBLISH[@]})); then
		fEcho_Clean "Publish (last) .: ${GIT_PUBLISH[*]}$( [[ -n "${publish_msg}" ]] && echo " (\"${publish_msg}\")" || echo ' (asks for the message now)')"
	else
		fEcho_Clean "Publish (last) .: (skipped)"
	fi
	fEcho_Clean "Frozen copy ....: $( ((freeze)) && echo 'stages 2-6 run from a copy taken after the format stage' || echo '(off)')"
	fEcho_Clean
fi
if ((! assume_yes && ! inner_run)) && ((${#GIT_PUBLISH[@]})) && [[ -z "${publish_msg}" ]]; then
	read -r -p "Publish commit message (blank = git's editor; Ctrl+C stops the run): " m || true
	fEcho_ResetBlankCounter
	if [[ -n "${m:-}" ]]; then publish_msg="${m}"; fi
fi

## The whole run into a rotated log, for lint-report.bash. Not under --gate,
## which writes nothing, and not in the run on the frozen copy, whose output
## already goes through this one.
if ((! gate_mode && ! inner_run)) && [[ -n "${LINT_LOG_DIR:-}" ]] && mkdir -p "${root}/${LINT_LOG_DIR}" 2>/dev/null; then
	gfs_rotate "${root}/${LINT_LOG_DIR}" run log >/dev/null 2>&1 || true
	## It has to outlive the stop, or the cleanup lines are lost. A Ctrl+C
	## reaches the whole process group, so it ignores that too, and ends when
	## the run closes its end.
	exec > >(trap '' INT TERM; exec tee "${root}/${LINT_LOG_DIR}/run_${stamp}.log") 2>&1
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

## Stage 0: take the remote's work before anything is built, so the run tests
## the tree that gets pushed. The publish stage pulls too, but after the tests.
fStageSync(){
	local branch="" upstream="" out="" ahead=0 behind=0 dirty=0 ff=0
	fStep 0 "Remote sync"
	if ((! sync_enable)); then fStepSkip "remote sync skipped"; return 0; fi
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

## Stage 1: format. In place; check-only under --gate.
fStageFormat(){
	fStep 1 "Format"
	if ((gate_mode)) && ((${#FMT_CHECK_CMD[@]})); then
		fEcho_Clean "${FMT_CHECK_CMD[*]}"
		"${FMT_CHECK_CMD[@]}" || fDie "format check failed; run ${FMT_CMD[*]:-cargo fmt} and commit"
		fEcho "OK: format clean"
	elif ((${#FMT_CMD[@]})); then
		fEcho_Clean "${FMT_CMD[*]}"
		"${FMT_CMD[@]}" || fDie "formatter failed"
		fEcho "OK: formatted"
	else
		fStepSkip "format skipped"; return 0
	fi
	fStepPass
}

## Stage 2: debug build.
fStageBuild(){
	fStep 2 "Build (debug)"
	fEcho_Clean "${BUILD_CMD[*]}"
	"${BUILD_CMD[@]}" || fDie "debug build failed"
	fEcho "OK: debug build"
	fStepPass
}

## One lint tool, its output also into the lint log.
lint_log="/dev/null"
fLintRun(){ local rc=0; "$@" 2>&1 | tee -a "${lint_log}" || rc=$?; return "${rc}"; }
## An eval'd one. Without its own ERR trap, since a finding isn't the run
## aborting.
fLintEval(){ trap - ERR; eval "$1"; }
## A missing tool fails under --gate and is a noted skip otherwise.
fLintTool(){   ## fLintTool NAME -> 0 when it's here
	command -v "$1" >/dev/null 2>&1 && return 0
	((gate_strict)) && fDie "$1 is needed under --gate but isn't installed"
	fEcho "WARNING: $1 isn't installed; skipped"
	echo "$1" >> "${gate_skips}"
	return 1
}

## Stage 3: lint. Every tool runs, so the log has all of it, and then the stage
## fails if any of them did.
fStageLint(){
	local -a failed=() files=() shFiles=() mdFiles=() psFiles=() pyFiles=()
	local f skip s c
	fStep 3 "Lint"
	if ((lint_off)); then fStepSkip "lint skipped"; return 0; fi
	if ((! gate_mode)) && [[ -n "${LINT_LOG_DIR:-}" ]] && mkdir -p "${root}/${LINT_LOG_DIR}" 2>/dev/null; then
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

	fEcho_Clean "clippy: ${LINT_CMD[*]}"
	if fLintRun "${LINT_CMD[@]}"; then fEcho "OK: clippy clean"; else failed+=(clippy); fi
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
	## Not through fLintTool: a box without ruff skips it even under --gate.
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
	for c in "${LINT_EXTRA[@]}"; do
		fEcho_Clean "${c%%|*}: ${c#*|}"
		if fLintRun fLintEval "${c#*|}"; then fEcho "OK: ${c%%|*}"; else failed+=("${c%%|*}"); fi
	done
	if [[ "${lint_log}" != /dev/null ]]; then gfs_rotate "${root}/${LINT_LOG_DIR}" lint log >/dev/null 2>&1 || true; fi
	lint_log="/dev/null"
	((${#failed[@]} == 0)) || fDie "lint: ${failed[*]} found something; the output is above"
	fStepPass
}

## The integration test once on ROOT, in a dir of this run's under it.
fRunIt(){   ## fRunIt LABEL ROOT
	local label="$1" itRoot="$2" real="" fsType="" want="" d="" rc=0
	if [[ ! -d "${itRoot}" ]]; then
		fEcho "NOTE: integration test on ${label} skipped, since ${itRoot} isn't there"
		echo "it-${label}" >> "${gate_skips}"
		return 0
	fi
	real="$(realpath -e -- "${itRoot}")"
	fsType="$(stat -f -c %T -- "${real}" 2>/dev/null || true)"
	case "${label}" in ext4) want="ext2/ext3" ;; *) want="${label}" ;; esac
	if [[ "${fsType}" != "${want}" ]]; then fEcho "WARNING: ${itRoot} is ${fsType:-unknown}, not ${label}"; fi
	fRunDirMake "${real}" it "${label}"
	d="${made_dir}"
	fEcho_Clean "integration test on ${label}: TMPDIR=${d}"
	TMPDIR="${d}" "${IT_CMD[@]}" "${root}/${RELEASE_NATIVE_BIN}" || rc=$?
	((rc == 0)) || fDie "integration test failed on ${label} (exit ${rc})"
	if fRunDirGone "${d}"; then freed_kb=$((freed_kb + gone_kb)); fi
	fEcho "OK: integration test on ${label}"
}

## Stage 4: tests, then the slow leak checks.
fStageTests(){
	local r step t0
	fStep 4 "Tests"
	if ((tests_off)); then fStepSkip "tests skipped"; return 0; fi
	fEcho_Clean "${TEST_CMD[*]}  (TMPDIR=${TMPDIR})"
	"${TEST_CMD[@]}" || fDie "unit tests failed"
	fEcho "OK: unit tests"
	## The integration test runs the release build.
	fEcho_Clean "${RELEASE_NATIVE_CMD[*]}"
	"${RELEASE_NATIVE_CMD[@]}" || fDie "release build failed"
	[[ -x "${root}/${RELEASE_NATIVE_BIN}" ]] || fDie "no release binary at ${RELEASE_NATIVE_BIN}"
	for r in "${IT_ROOTS[@]}"; do fRunIt "${r%%|*}" "${r#*|}"; done
	## Last, since the slow ones take a long time and the rest should report first.
	for step in "${LEAKCHECK_STEPS[@]}"; do
		fEcho_Clean "leak check: ${step}"
		t0="${SECONDS}"
		eval "${step}" || fDie "leak check failed: ${step}"
		fEcho_Clean "leak check took $(fMinSec $((SECONDS - t0))): ${step}"
	done
	if ((${#LEAKCHECK_STEPS[@]})); then fEcho "OK: leak checks"; fi
	fRecordGreen
	fStepPass
}

## The tree this run tested, for the pre-push hook. Taken after the format
## stage, since that rewrites what gets tested.
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

## Seconds since an EPOCHREALTIME, to 2 places, with no fork.
fSecsSince(){ local us=$(( ${EPOCHREALTIME/./} - ${1/./} )); printf '%d.%02d s' $((us / 1000000)) $((us % 1000000 / 10000)); }

## Stage 5: profiler. The attribution check comes before any graph is drawn,
## since a graph that names the wrong code is worse than none. A failed build,
## check or step fails the run. The report never does, and never touches the
## --check marker, which is the session start's.
fStageProfile(){
	local base="" fsType="" work="" step="" name="" cmd="" t0="" svg="" profDir="" latest=""
	fStep 5 "Profiler"
	if ((! PROFILE_ENABLE)) || ((! ${#PROFILE_BUILD_CMD[@]})); then fStepSkip "profiler off in config.bash, or skipped"; return 0; fi
	fEcho_Clean "${PROFILE_BUILD_CMD[*]}"
	"${PROFILE_BUILD_CMD[@]}" || fDie "profiling build failed"
	export PROFILE_BIN="${root}/${PROFILE_BIN}"
	[[ -x "${PROFILE_BIN}" ]] || fDie "no profiling binary at ${PROFILE_BIN}"
	if [[ -n "${PROFILE_CHECK}" ]]; then
		fEcho_Clean "attribution check: ${PROFILE_CHECK}"
		eval "${PROFILE_CHECK}" || fDie "profiler attribution check failed; its graph would name the wrong code"
	fi

	base="${PROFILE_ROOT}"
	if [[ -z "${base}" || ! -d "${base}" ]]; then
		fEcho "NOTE: the profiler root ${base:-(none)} isn't there; the workload goes in the run's temp dir"
		base="${run_tmp_root}"
	fi
	fRunDirMake "${base}" prof
	work="${made_dir}"
	fsType="$(stat -f -c %T -- "${work}" 2>/dev/null || true)"
	if [[ "${fsType}" != ext2/ext3 ]]; then fEcho "WARNING: the profiler workload is on ${fsType:-unknown}, not ext4"; fi
	export PROFILE_WORKLOAD="${work}" TUKFS_PROFILE_DIR="${work}/samples"
	mkdir -- "${TUKFS_PROFILE_DIR}" || fDie "could not make ${TUKFS_PROFILE_DIR}"
	fEcho_Clean "workload: ${PROFILE_WORKLOAD_GEN}  (in ${work})"
	eval "${PROFILE_WORKLOAD_GEN}" || fDie "the profiler workload failed"
	for step in "${PROFILE_TIMED[@]}"; do
		name="${step%%|*}"; cmd="${step#*|}"
		fEcho_Clean "profile step: ${name}"
		t0="${EPOCHREALTIME}"
		## In an if, so a step can test its own exit, as the rescan's 4.
		if ! eval "${cmd}"; then fDie "profiler step failed: ${name}"; fi
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
		python3 "${here}/utility/flame-report.py" --dir "${profDir}" || fEcho_Clean "hot spots: no report; the reason is above"
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
## replace the one in RELEASE_ARTIFACT_DIR, with its sums file.
## For the eval'd config strings: release_stage, release_work, ver and
## staged_osarchs, the os-arch of each build, native first.
release_stage=""; release_work=""; ver=""
declare -a staged_osarchs=()
fStageRelease(){
	local t label osarch art cmd c f n artDir sums
	local -a built=() names=()
	fStep 6 "Release builds"
	if ((release_off)); then fStepSkip "release builds skipped"; return 0; fi
	ver="$(fVersion)"
	[[ -n "${ver}" ]] || fDie "no version in ${VERSION_MANIFEST}"
	fEcho_Clean "${RELEASE_NATIVE_CMD[*]}"
	"${RELEASE_NATIVE_CMD[@]}" || fDie "release build failed"
	[[ -x "${root}/${RELEASE_NATIVE_BIN}" ]] || fDie "no release binary at ${RELEASE_NATIVE_BIN}"
	## Bytes, since du gives what a compressed filesystem stores.
	fEcho "OK: ${RELEASE_NATIVE_OSARCH}: ${RELEASE_NATIVE_BIN} ($(stat -c %s -- "${root}/${RELEASE_NATIVE_BIN}") bytes)"
	built=("${RELEASE_NATIVE_OSARCH}|${RELEASE_NATIVE_BIN}")
	for t in "${CROSS_TARGETS[@]}"; do
		label="${t%%|*}"; t="${t#*|}"; osarch="${t%%|*}"; t="${t#*|}"; art="${t%%|*}"; cmd="${t#*|}"
		fEcho_Clean "cross: ${label}: ${cmd}"
		eval "${cmd}" || fDie "cross build failed: ${label}"
		[[ -f "${root}/${art}" ]] || fDie "no binary for ${label} at ${art}"
		fEcho "OK: ${osarch}: ${art} ($(stat -c %s -- "${root}/${art}") bytes)"
		built+=("${osarch}|${art}")
	done
	[[ -n "${RELEASE_ARTIFACT_DIR}" ]] || { fStepPass; return 0; }

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
		eval "${PACKAGE_CMD}" || fDie "packages failed"
	fi
	for c in "${RELEASE_CHECKS[@]}"; do
		fEcho_Clean "release check: ${c%%|*}"
		eval "${c#*|}" || fDie "release check failed: ${c%%|*}"
	done
	if ((${#RELEASE_CHECKS[@]})); then fEcho "OK: ${#RELEASE_CHECKS[@]} release check(s)"; fi

	## The sums file goes first and comes back last, so a run stopped part way
	## leaves no sums for a mixed set. Old files go by name, one at a time, so
	## a dir that isn't the release set can't lose more than its release files.
	artDir="${root}/${RELEASE_ARTIFACT_DIR}"
	sums="${EXE_NAME}-${ver}-sha256sums.txt"
	mkdir -p -- "${artDir}" || fDie "could not make ${RELEASE_ARTIFACT_DIR}"
	rm -f -- "${artDir}/.${sums}.tmp"
	for f in "${artDir}/${EXE_NAME}-"*sha256sums.txt; do
		if [[ -f "${f}" && ! -L "${f}" ]] && fReleaseName "${f##*/}"; then rm -f -- "${f}"; fi
	done
	for f in "${release_stage}"/*; do
		n="${f##*/}"
		fReleaseName "${n}" || fDie "the stage dir has ${n}, which isn't a release name"
		mv -f -- "${f}" "${artDir}/${n}" || fDie "could not move ${n} into ${RELEASE_ARTIFACT_DIR}"
		names+=("${n}")
	done
	for f in "${artDir}/${EXE_NAME}-"*; do
		if [[ -f "${f}" && ! -L "${f}" && " ${names[*]} " != *" ${f##*/} "* ]] && fReleaseName "${f##*/}"; then rm -f -- "${f}"; fi
	done
	( cd "${artDir}" && sha256sum -- "${names[@]}" > ".${sums}.tmp" && mv -f -- ".${sums}.tmp" "${sums}" ) || fDie "could not write ${sums}"
	fEcho_Clean "$(cd "${artDir}" && stat -c '%10s  %n' -- "${names[@]}" "${sums}")"
	fEcho "OK: ${#names[@]} release file(s) and ${sums} in ${RELEASE_ARTIFACT_DIR}/"
	if ((${#CROSS_TARGETS[@]} == 0)); then fEcho_Clean "note: no cross targets in this run, so the set is the native build alone"; fi
	fStepPass
}

## Stage 7: the native release build into the first writable dest, unless
## that copy is running or already has these bytes. Then the dogfood runner and
## its launcher, where they changed.
fStageDogfood(){
	local src="" dest="" runner rSrc rDir sorry=0
	local -a parts=()
	fStep 7 "Dogfood"
	if ((! DOGFOOD_ENABLE)) || ((! ${#DOGFOOD_DESTS[@]})); then fStepSkip "dogfood off in config.bash, or skipped"; return 0; fi
	src="${root}/${RELEASE_ARTIFACT_DIR}/${EXE_NAME}-$(fVersion)-${RELEASE_NATIVE_OSARCH}"
	[[ -n "${RELEASE_ARTIFACT_DIR}" && -f "${src}" ]] || fDie "no native release build at ${src}"
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

## Stage 8: demo gif.
fStageGif(){
	fStep 8 "Demo gif"
	if ((! GIF_ENABLE)) || [[ -z "${GIF_CMD}" ]]; then fStepSkip "demo gif off in config.bash, or skipped"; return 0; fi
	eval "${GIF_CMD}" || fDie "demo gif failed"
	fStepPass
}

## Stage 9: backup + publish through the copied publisher.
fStagePublish(){
	local flag="--no-prompt"
	fStep 9 "Backup + publish"
	if ((! ${#GIT_PUBLISH[@]})); then fStepSkip "publish skipped"; return 0; fi
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
## isn't committed, for stages 2-6. Any trouble making it runs them in the
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
		fEcho_Clean "stages 2-6 run from ${frozen_root}, holding ${gate_rev:0:12}, the commit being pushed"
		return 0
	fi
	if ! head="$(git -C "${root}" rev-parse -q --verify HEAD 2>/dev/null)" || ! tree="$("${here}/utility/green-tree.bash" tree "${root}" 2>/dev/null)"; then
		fEcho "WARNING: no commit to copy; stages 2-6 run in the checkout"
		return 0
	fi
	frozen_root="${run_tmp}/tree"
	if ! fFrozenAdd "${root}" "${frozen_root}" "${head}" "${tree}"; then
		frozen_root=""
		fEcho "WARNING: could not make a frozen copy; stages 2-6 run in the checkout"
		return 0
	fi
	for link in "${FROZEN_LINKS[@]}"; do
		fFrozenLink "${root}" "${frozen_root}" "${link}" || fDie "could not link ${link} into the frozen copy"
	done
	frozen_tree="${tree}"
	mapfile -t changed < <(git -C "${root}" diff --name-status --no-renames "${head}" "${tree}")
	fSection "Frozen copy"
	fEcho_Clean "stages 2-6 run from ${frozen_root}"
	if ((${#changed[@]} == 0)); then
		fEcho_Clean "copied ${head:0:12}, with nothing uncommitted"
	else
		fEcho_Clean "copied ${head:0:12} plus ${#changed[@]} uncommitted file(s):"
		for ((i = 0; i < ${#changed[@]} && i < 20; i++)); do fEcho_Clean "	${changed[i]}"; done
		if ((${#changed[@]} > 20)); then fEcho_Clean "	and $((${#changed[@]} - 20)) more"; fi
	fi
	return 0
}

## Stages 2-6 in the frozen copy, by the copy's own engine.
fRunFrozen(){
	local -a inner=("$( ((quiet)) && echo -q || echo -y )" --no-sync --no-dogfood --no-gif --no-publish "${inner_pass[@]}")
	local rc=0 green=""
	((record_green)) && green="${frozen_tree}"
	TUKFS_RUN_PART=build TUKFS_GREEN_TREE="${green}" bash "${frozen_root}/cicd/cicd.bash" "${inner[@]}" || rc=$?
	## It ended on a blank line of its own.
	_wasLastEchoBlank=1
	## A stopped run stays a stopped run, and the EXIT trap says so.
	if ((rc > 128)); then exit "${rc}"; fi
	((rc == 0)) || fDie "the run in the frozen copy failed; its output is above"
}


#•••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••
## Cleanup

## rm -rf for a build cache entry: TARGET/<profile>/<area>/<name>, or the same
## under a target triple, no links, and ours. The profiles are debug, release
## and profiling.
fSafeRmCache(){   ## fSafeRmCache CACHE_REAL PATH
	local cache="$1" p="$2" real=""
	[[ "${cache}" == /* && "${cache}" != *//* && "${cache}" != *..* ]] || return 1
	[[ "${p}" == "${cache}/"* && "${p}" != *..* && "${p}" != *$'\n'* ]] || return 1
	[[ "${p#"${cache}/"}" =~ ^([a-z0-9_-]+/)?(debug|release|profiling)/(deps|build|\.fingerprint|incremental)/[A-Za-z0-9_.+-]+$ ]] || return 1
	real="$(realpath -e -- "${p}" 2>/dev/null || true)"
	[[ "${real}" == "${p}" && ! -L "${p}" && -O "${p}" ]] || return 1
	rm -rf --one-file-system -- "${p}"
}

## Build cache entries that are dead for sure: made before the pinned
## toolchain was installed, so by an older one, or named for a crate that's
## gone from Cargo.lock. A warm cache for the current toolchain and lockfile
## stays. Prints "COUNT KB".
fPruneCache(){   ## fPruneCache DIR
	local dir="${root}/$1" cache="" sysroot="" toolTime=0 mt=0 kb=0 n=0 name="" crate="" e="" area="" size="" stale=0
	local -A crates=()
	[[ -d "${dir}" ]] || { echo "0 0"; return 0; }
	cache="$(realpath -e -- "${dir}")" || { echo "0 0"; return 0; }
	sysroot="$(rustc --print sysroot 2>/dev/null || true)"
	toolTime="$(stat -c %Y -- "${sysroot}/lib/rustlib/multirust-channel-manifest.toml" 2>/dev/null || echo 0)"
	while read -r name; do crates["${name//-/_}"]=1; done < <(sed -n 's/^name = "\([^"]*\)"$/\1/p' "${root}/Cargo.lock")
	## Names of what cargo makes for a unit: lib<crate>-<hash>.<ext>, <crate>-<hash>[.<ext>],
	## and build_script_build-<hash> beside its package's dir.
	for area in "${cache}"/{,*/}{debug,release,profiling}/{deps,build,.fingerprint,incremental}; do
		[[ -d "${area}" && ! -L "${area}" ]] || continue
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
			((stale)) || continue
			size="$(du -sk -- "${e}" 2>/dev/null | cut -f1 || true)"
			if fSafeRmCache "${cache}" "${e}"; then
				n=$((n + 1))
				if [[ "${size}" =~ ^[0-9]{1,15}$ ]]; then kb=$((kb + size)); fi
			fi
		done < <(find "${area}" -mindepth 1 -maxdepth 1 -printf '%Ts\t%p\0' 2>/dev/null)
	done
	echo "${n} ${kb}"
}

## Run dirs left by runs that were killed outright, so their trap never ran:
## a strict name, a mark whose PID matches the name and is gone, and a day old.
fSweepStale(){   ## fSweepStale BASE -> prints "COUNT KB"
	local base="" d="" got="" pid="" kb=0 n=0 size=0
	base="$(realpath -e -- "$1" 2>/dev/null || true)"
	[[ -n "${base}" && -d "${base}/tukfs-hash" ]] || { echo "0 0"; return 0; }
	for d in "${base}/tukfs-hash/${RUN_TMP_PREFIX}"_{run,it,prof}_*; do
		[[ -d "${d}" && ! -L "${d}" ]] || continue
		fSafePath "${d}" 2>/dev/null || continue
		[[ "${d}" =~ _[0-9]{8}-[0-9]{6}_([0-9]+)(_[a-z0-9]+)?$ ]] || continue
		pid="${BASH_REMATCH[1]}"
		[[ "${pid}" != "$$" ]] || continue
		got=""; { read -r got < "${d}/${run_mark}"; } 2>/dev/null || continue
		[[ "${got}" == "${pid}-"* ]] || continue
		kill -0 "${pid}" 2>/dev/null && continue
		[[ -n "$(find "${d}" -maxdepth 0 -mmin +1440 2>/dev/null || true)" ]] || continue
		size="$(du -sk -- "${d}" 2>/dev/null | cut -f1 || true)"
		[[ "${size}" =~ ^[0-9]{1,15}$ ]] || size=0
		if fSafeRm "${d}" "${got}"; then n=$((n + 1)); kb=$((kb + size)); fi
	done
	echo "${n} ${kb}"
}

## What's gone stale that the pipeline made, then this run's temp files, in one
## line. The run on the frozen copy only removes its own.
fCleanup(){
	local -a gone=()
	local d kb=0 total=0 n=0 c r out
	if ((inner_run)); then
		fFrozenGone || true
		for d in "${run_dirs[@]}"; do fRunDirGone "${d}" || true; done
		return 0
	fi
	fSection "$(fNow); Cleanup"
	## Measured first, while the frozen copy is still in it.
	kb="$(du -sk -- "${run_tmp}" 2>/dev/null | cut -f1 || true)"
	[[ "${kb}" =~ ^[0-9]{1,15}$ ]] || kb=0
	total=$((freed_kb + kb))
	fFrozenGone || true
	if ((! gate_mode)); then
		for c in "${CACHE_DIRS[@]}"; do
			out="$(fPruneCache "${c}")"; read -r n kb <<< "${out}"
			if ((n)); then gone+=("${n} stale build cache entries in ${c}"); total=$((total + kb)); fi
		done
	fi
	for r in "${run_tmp_root}" "${IT_ROOTS[@]#*|}" ${PROFILE_ROOT:+"${PROFILE_ROOT}"}; do
		out="$(fSweepStale "${r}")"; read -r n kb <<< "${out}"
		if ((n)); then gone+=("${n} dir(s) of killed runs under ${r}"); total=$((total + kb)); fi
	done
	for d in "${run_dirs[@]}"; do fRunDirGone "${d}" || true; done
	gone+=("this run's temp files")
	fEcho_Clean "cleanup: removed $(printf '%s, ' "${gone[@]}" | sed 's/, $//'), about $(fSize "${total}")"
	return 0
}


#•••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••
## Run

fmt_done=0
if ((! inner_run)); then fStageSync; fi
if ((freeze)); then
	## Rewrites the checkout, before the copy is taken. A check runs in the copy.
	if ((${#FMT_CMD[@]})); then fStageFormat; fmt_done=1; fi
	fFreeze
fi
if [[ -n "${frozen_root}" ]]; then
	fRunFrozen
else
	## The run on the frozen copy only checks, and only under --gate.
	if ((! fmt_done)) && { ((gate_mode)) || [[ "${run_part}" != build ]]; }; then fStageFormat; fi
	if [[ -n "${green_given}" ]]; then green_tree="${green_given}"
	elif ((record_green && ! inner_run)); then green_tree="$("${here}/utility/green-tree.bash" tree "${root}" || true)"; fi
	fStageBuild
	fStageLint
	fStageTests
	fStageProfile
	fStageRelease
fi
if ((! inner_run)); then
	fStageDogfood
	fStageGif
	fStagePublish
fi
fCleanup
if ((inner_run)); then run_said=1; exit 0; fi

run_said=1
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
