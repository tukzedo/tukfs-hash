#!/usr/bin/env bash

#  shellcheck disable=2016  ## 'Expressions don't expand in single quotes.' On purpose: the eval'd strings expand in the engine.
#  shellcheck disable=2034  ## 'variable appears unused.' Everything here is read by cicd.bash.
#  shellcheck disable=1091  ## 'Not following.' The pins file is checked on its own.
#  shellcheck disable=2154  ## 'referenced but not assigned.' here, root and CPU_CAP come from cicd.bash.

##	Purpose:
##		- tukfs-hash's settings for the pipeline. cicd.bash is the engine and
##		  stays generic.
##		- Command arrays run from the repo root. Plain strings are eval'd by the
##		  engine, with CPU_CAP and the run's other variables in scope.
##		- A stage that's off here gets no step line, and the plan at the
##		  start lists it as off in config.bash.
##	History: At bottom of script.

##	Copyright © 2026 t00mietum (CryptogID: ปʬϝღถɔ4რఠΔթะ9ƾǝu)
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


## Only allow running sourced.
declare -i isSourced_k2vq9=0; [[ "${BASH_SOURCE[0]}" == "${0}" ]] || isSourced_k2vq9=1
((isSourced_k2vq9)) || { echo -e "\nError in $(basename "${BASH_SOURCE[0]}"): This script is meant to be 'sourced' from within another script.\n"; exit 1; }


## Identity. Cargo.toml is the only place the version is kept; the tag and the
## build stamp both read it.
APP_NAME="tukfs-hash"
EXE_NAME="tukfs-hash"
VERSION_MANIFEST="Cargo.toml"
## build.rs reads the build number from this at compile time, and from the
## second whether it's a release, which leaves the date off.
BUILD_ENV_NAME="TUKFS_HASH_BUILD"
BUILD_RELEASE_ENV_NAME="TUKFS_HASH_RELEASE"

## Each run's temp dir is <HOST_TEMP>/tukfs-hash/<YYYYmmDD-HHMMSS>_<NNN>.
## This is where it goes when HOST_TEMP isn't set, then TMPDIR, then /tmp.
## b23's /tmp is btrfs on LUKS, and slow to fsync under load
## (2026102409041302). TUKFS_CICD_RUN_TMP overrides it.
RUN_TMP_ROOT="${TUKFS_CICD_RUN_TMP:-/mnt/ext/wip2/wip/tmp}"

## Tool pins. The engine warns, without failing, when a tool has drifted.
## "name|version|command": the version has to show up in the command's output.
## shellcheck source=tool-pins.env
source "${here}/tool-pins.env"
## nfpm is go-installed, and ~/.go/bin isn't always on PATH. package.bash
## reads NFPM.
NFPM="$(command -v nfpm 2>/dev/null || echo "${HOME}/.go/bin/nfpm")"
export NFPM
RUST_PIN="$(sed -n '/^channel *= *"/{ s/^channel *= *"\([^"]*\)".*/\1/p; q; }' "${root}/rust-toolchain.toml" 2>/dev/null || true)"
TOOL_PINS=(
	"rustc|${RUST_PIN}|rustc --version"
	"shellcheck|${PIN_SHELLCHECK}|shellcheck --version"
	"markdownlint|${PIN_MARKDOWNLINT}|markdownlint --version"
	"nightly|${PIN_NIGHTLY}|rustup toolchain list"
	"cargo-deny|${PIN_CARGO_DENY}|cargo deny --version"
	"nfpm|${PIN_NFPM}|go version -m \"${NFPM}\""
	"PSScriptAnalyzer|${PIN_PSSA}|pwsh -NoProfile -Command \"(Get-Module -ListAvailable PSScriptAnalyzer | Select-Object -First 1).Version.ToString()\""
	"ruff|${PIN_RUFF}|ruff --version"
)

## Paths into cargo's home end up in panic messages, so they're mapped to one
## name and the bytes don't depend on whose home it is. The checkout's own
## paths are already relative. Every cargo call gets it, or the release builds
## would rebuild what the tests built. Added once, since the run on the frozen
## copy reads this file again.
_remap="--remap-path-prefix=${CARGO_HOME:-${HOME}/.cargo}=/cargo"
if [[ " ${RUSTFLAGS:-} " != *" ${_remap} "* ]]; then export RUSTFLAGS="${RUSTFLAGS:+${RUSTFLAGS} }${_remap}"; fi

## Stage 1: format. FMT_CMD rewrites in place; FMT_CHECK_CMD fails on a diff
## and is what the merge gate and backlog runs run. rustfmt.toml has the style. Bash is never formatted.
FMT_CMD=(cargo fmt)
FMT_CHECK_CMD=(cargo fmt --check)

## Stage 2: debug build. --locked everywhere, so a build never rewrites
## Cargo.lock behind the run's back. No -j or --test-threads in the arrays,
## since the job count can change between steps after this is read. cargo
## and libtest take it from CARGO_BUILD_JOBS and RUST_TEST_THREADS.
BUILD_CMD=(cargo build --locked)

## Stage 3: lint. The clippy lints are in Cargo.toml's [lints.clippy], so an
## editor's clippy sees the same ones: pedantic, mem_forget and
## undocumented_unsafe_blocks. shellcheck takes every tracked *.bash plus these.
## markdownlint takes every tracked .md but license.md, which is the GPL's own
## text and stays as published. MD013 is line length, and the docs never wrap.
## All features, or the soak test behind its feature goes unlinted.
LINT_CMD=(cargo clippy --locked --all-targets --all-features -- -D warnings)
SHELLCHECK_EXTRA=(cicd/hooks/pre-push cicd/utility/n8git_backup-and-publish cicd/tool-pins.env utility/dogfood_tukfs-hash)
MARKDOWNLINT_CMD=(markdownlint --disable MD013 --)
MARKDOWN_SKIP=(license.md)
## Every tracked .ps1, with PSScriptAnalyzerSettings.psd1 at the repo root.
PS_LINT_CMD=(pwsh -NoProfile -File cicd/utility/lint-ps1.ps1)
## Every tracked .py, by cicd/ruff.toml's rules, then its format. A box
## without ruff skips them with a note, even under the merge gate.
PY_LINT_CMD=(ruff check --config cicd/ruff.toml --)
PY_FMT_CHECK_CMD=(ruff format --check --config cicd/ruff.toml --)
## "label|command", eval'd after the rest. Every test prints its status line
## with its test ID, and a test with none, or 2 that share one, fails here
## rather than going by unseen.
LINT_EXTRA=(
	'test IDs|python3 cicd/utility/test-ids.py check'
)

## Stage 4: tests. Unit tests first, with TMPDIR in the run's temp dir. Then the
## integration test on a release build, once per root below, given as its
## HOST_TEMP, so it makes its own dir under <root>/tukfs-hash/. "label|root".
## A root that isn't there
## skips with a note. TUKFS_CICD_IT_EXT4 and TUKFS_CICD_IT_ZFS override them.
## libtest-quiet.bash drops libtest's per-test lines, since each test prints
## its own with its test ID.
TEST_CMD=(cicd/utility/libtest-quiet.bash cargo test --release --locked)
IT_CMD=(tests/integration.bash)
## For --list: the IDs and names TEST_CMD's tests print, given unit, and
## IT_CMD's, given it.
TEST_ID_LIST_CMD=(python3 cicd/utility/test-ids.py list)
IT_ROOTS=(
	"ext4|${TUKFS_CICD_IT_EXT4:-/mnt/ext/wip2/wip/tmp}"
	"zfs|${TUKFS_CICD_IT_ZFS:-${HOME}/tmp/tukfs-hash-zfs-it}"
)

## Stage 4, last: the leak and memory checks, eval'd in order, quick ones
## first, each "length|command". The lengths go by measured time on b23 with
## the image and build dirs warm. fast, under a minute: every run, --quick
## included. mid, minutes: a run with no options, --long, --backlog-run-full,
## the merge gate, and --quick --leakcheck. long, hours: --long only, which
## is the fuzz tests at an hour each. --backlog-run-quick runs none of them,
## but for a leak area or --leakcheck. Any report fails. The sanitizers, Miri
## and CodeQL run in the image below when docker answers, else on the host
## with a note.
LEAKCHECK_STEPS=(
	## Known advisories for every crate in Cargo.lock. On the host, since it
	## fetches RustSec's database. Offline is a noted skip. 1 to 3 s.
	'fast|cicd/utility/advisories.bash'
	## The main actions 20 times over in one process, with the heap at round
	## 20 held to round 10. The table goes in cicd/artifacts/soak/. On the
	## host, since a scan needs the real disks. 23 to 51 s.
	'fast|cicd/utility/soak.bash'
	## The unit tests under ASan and LSan, then TSan, then Miri, each in a
	## build dir of its own under target/leakcheck. ASan and TSan 10 to 59 s,
	## and 7.5 min for a cold build dir. Miri 42 s to 1.5 min.
	'fast|cicd/utility/sanitize-rust.bash --asan'
	'fast|cicd/utility/sanitize-rust.bash --tsan'
	'mid|cicd/utility/sanitize-rust.bash --miri'
	## The parser fuzz tests, SECS each, side by side on a quarter of the
	## cores. Their 1 s each in the unit tests is the floor.
	'fast|cicd/utility/fuzz.bash 20'
	'long|cicd/utility/fuzz.bash 3600'
	## Over the tree with every crate vendored. The SARIF and findings go in
	## cicd/artifacts/codeql/. 9 to 16.5 min.
	'mid|cicd/utility/codeql-scan.bash'
)

## The leak check image, from CTR_DIR, tagged by a hash of it and
## CTR_CONTEXT_EXTRA. The nightly and CodeQL come from tool-pins.env.
CTR_DIR="cicd/container"
CTR_IMAGE="${APP_NAME}-cicd"
CTR_CONTEXT_EXTRA=(rust-toolchain.toml cicd/tool-pins.env)
## The checks' own build dirs, and the image's cargo home, kept between runs
## so they start warm. Under target, which the frozen copy links back to.
LEAK_DIR="${root}/target/leakcheck"
CTR_CARGO_HOME="${LEAK_DIR}/cargo-home"

## Stage 5: profiler. A build like release with names kept and pprof's
## sampler in it, src/profiling.rs, since perf can't record on b23. First
## PROFILE_CHECK, the sampler's attribution against a workload whose answer
## is known, then PROFILE_WORKLOAD_GEN and each PROFILE_TIMED step in order,
## timed. All are eval'd from the repo root, with PROFILE_BIN, PROFILE_WORKLOAD
## and TUKFS_PROFILE_DIR exported. The scans add their samples to one
## flamegraph, which goes into PROFILE_OUT_DIR as flame_<stamp>_<role>.svg,
## GFS-rotated, and flame-report.py's summary of it goes in the log.
## The workload is a tree on ext4, with its database beside it, in a dir of
## this run's under PROFILE_ROOT, removed after. TUKFS_CICD_PROFILE_ROOT
## overrides it, and a root that isn't there falls back to the run's temp dir.
## --quick and --backlog-run-quick leave the stage out.
PROFILE_ENABLE=1
PROFILE_BUILD_CMD=(cargo build --profile profiling --features profiling --locked)
PROFILE_BIN="target/profiling/${EXE_NAME}"
PROFILE_OUT_DIR="cicd/artifacts/profiling"
PROFILE_ROOT="${TUKFS_CICD_PROFILE_ROOT:-${TUKFS_CICD_IT_EXT4:-/mnt/ext/wip2/wip/tmp}}"
PROFILE_CHECK='TUKFS_PROFILE_CHECK=1 "${PROFILE_BIN}"'
PROFILE_WORKLOAD_GEN='cicd/utility/profile-workload.bash gen "${PROFILE_WORKLOAD}"'
## "name|command". Any failure fails the stage. The rescan reads every file
## again, with blake2b, since its --since is after the first scan, and has to
## find the changed ones, which is exit 4.
PROFILE_TIMED=(
	'first scan|TUKFS_PROFILE_LABEL=first-scan "${PROFILE_BIN}" scan --db "${PROFILE_WORKLOAD}/db/profile.sqlite" --root "${PROFILE_WORKLOAD}/tree" --progress 3600'
	'change|cicd/utility/profile-workload.bash change "${PROFILE_WORKLOAD}"'
	'rescan --rmlint|TUKFS_PROFILE_LABEL=rescan "${PROFILE_BIN}" scan --db "${PROFILE_WORKLOAD}/db/profile.sqlite" --root "${PROFILE_WORKLOAD}/tree" --progress 3600 --rmlint --since "$(date -d tomorrow +%F)"; [[ $? -eq 4 ]]'
)

## Stage 4's release build, which the integration test runs. It's never a
## release, since it isn't from stage 6.
RELEASE_NATIVE_CMD=(cargo build --release --locked)
RELEASE_NATIVE_BIN="target/release/${EXE_NAME}"

## Stages 2 to 4 run BUILD_CMD, clippy, TEST_CMD and RELEASE_NATIVE_CMD in the
## release image below where docker answers, so they build with its pinned
## toolchain and glibc 2.28, and the integration test can run their build
## on any host. Into a target dir of their own, so a host build isn't
## replaced. With no docker, or --no-container, they run on the host, with
## a note. The integration test and the soak stay on the host, since they
## scan the real disks.
TESTS_CTR_TARGET_DIR="${root}/target/ctr"
TESTS_CTR_NATIVE_BIN="target/ctr/release/${EXE_NAME}"

## Stage 6: release builds, Linux only, since the tool reads Linux xattrs,
## mounts and snapshots. Both targets build in the release image, from
## REL_CTR_DIR, whose glibc is GLIBC_FLOOR, so that's all a build needs
## and the floor doesn't move with the box. arm64 is cross-built with
## Debian's cross gcc, which also builds the bundled SQLite, and takes about
## as long as x86_64. Cross targets are "label|os-arch|binary|command", the
## command eval'd. Each build is named <exe>-<version>-<os-arch> in
## RELEASE_ARTIFACT_DIR, with <exe>-<version>-sha256sums.txt beside them.
## Download links depend on these names, so they stay.
## Where the image can't be used, as for stages 2 to 4, RELEASE_HOST_BUILD_CMD
## builds x86_64 on the box with one note, into a dir of its own. It needs the
## box's glibc, so the floor check notes it rather than failing, and arm64 is
## left out, since the box has no cross gcc (2026102509342993).
GLIBC_FLOOR="2.28"
REL_CTR_DIR="cicd/container-release"
REL_CTR_IMAGE="${APP_NAME}-release"
REL_CTR_CONTEXT_EXTRA=(rust-toolchain.toml)
## Its build dir and cargo home, kept between runs so they start warm.
REL_TARGET_DIR="${root}/target/release-ctr"
REL_CTR_CARGO_HOME="${REL_TARGET_DIR}/cargo-home"
REL_TARGETS=(x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu)
RELEASE_BUILD_CMD=(cicd/utility/release-build.bash build x86_64-unknown-linux-gnu)
RELEASE_BUILD_BIN="target/release-ctr/x86_64-unknown-linux-gnu/release/${EXE_NAME}"
REL_HOST_TARGET_DIR="${root}/target/release-host"
RELEASE_HOST_BUILD_CMD=(cicd/utility/release-build.bash --host build x86_64-unknown-linux-gnu)
RELEASE_HOST_BUILD_BIN="target/release-host/x86_64-unknown-linux-gnu/release/${EXE_NAME}"
RELEASE_NATIVE_OSARCH="linux-x86_64"
CROSS_TARGETS=(
	"Linux arm64|linux-arm64|target/release-ctr/aarch64-unknown-linux-gnu/release/${EXE_NAME}|cicd/utility/release-build.bash build aarch64-unknown-linux-gnu"
)
RELEASE_ARTIFACT_DIR="cicd/artifacts/release"
## A .deb and an .rpm per build, from cicd/packaging/nfpm.yaml, into the stage
## dir before the checks run. The binary is all they hold.
PACKAGE_ENABLE=1
PACKAGE_CMD='cicd/utility/package.bash "${release_stage}" "${ver}" "${release_work}"'
## Over the stage dir, once everything's built and packaged; "label|command",
## eval'd. A failure keeps the whole set out of RELEASE_ARTIFACT_DIR.
## release_glibc is glibc, or glibc-note for a host build.
RELEASE_CHECKS=(
	'native --version shows the stamped build|cicd/utility/check-release.bash version "${release_stage}/${EXE_NAME}-${ver}-${RELEASE_NATIVE_OSARCH}" "${EXE_NAME}" "${ver}" "${build_number}" "${build_release}"'
	'file names the architecture of each build|cicd/utility/check-release.bash arch "${release_stage}" "${EXE_NAME}-${ver}" "${staged_osarchs[@]}"'
	'each package holds the binary and nothing else|if ((PACKAGE_ENABLE)); then cicd/utility/check-release.bash package "${release_stage}" "${EXE_NAME}" "${ver}" "${release_work}" "${staged_osarchs[@]}"; else echo "no packages in this run"; fi'
	'no build needs a glibc newer than GLIBC_FLOOR|cicd/utility/check-release.bash "${release_glibc}" "${release_stage}" "${EXE_NAME}-${ver}" "${GLIBC_FLOOR}" "${staged_osarchs[@]}"'
	## The release builds aren't the ones stage 4 tested, so the integration
	## test runs again on the x86_64 one, and the unit tests on arm64.
	'the integration test passes on the x86_64 release build|TMPDIR="${release_work}" "${IT_CMD[@]}" "${release_stage}/${EXE_NAME}-${ver}-${RELEASE_NATIVE_OSARCH}"'
	'the unit tests pass on arm64, under qemu|if [[ " ${staged_osarchs[*]} " == *" linux-arm64 "* ]]; then cicd/utility/release-build.bash test aarch64-unknown-linux-gnu; else echo "no arm64 build in this run"; fi'
)

## Stage 7: other hosts. The unit tests and the integration test on a box of
## each other arch, "host|os-arch|target", on stage 6's build of that os-arch,
## through cicd/utility/remote-tests.bash. The qemu run in the release image
## stays as the quick check. The box is held through the host lock for as
## long as it's used, and put back as it was found, by the VM state helper's
## wrap, which TUKFS_CICD_VM_WRAP overrides. A box that's held elsewhere is
## waited for up to REMOTE_LOCK_WAIT seconds, or TUKFS_CICD_LOCK_WAIT. A box
## that isn't there, no helper, or no build of its arch in the run, is a
## SKIP, and the run goes on. vmDebARM64 is emulated, so it takes about 3
## minutes, and --quick leaves the stage out.
REMOTE_HOSTS=("vmDebARM64|linux-arm64|aarch64-unknown-linux-gnu")
_vmWrap="$(compgen -G "${HOME}/synced/0-0/common/exec/util/linux/bash/*_vm-state.bash" || true)"
REMOTE_VM_WRAP="${TUKFS_CICD_VM_WRAP:-${_vmWrap%%$'\n'*}}"
REMOTE_LOCK_WAIT="${TUKFS_CICD_LOCK_WAIT:-900}"

## Stage 8: dogfood. The native release build goes into the first of these
## that's there and writable, under EXE_NAME, since the scan wrappers and root
## steps run it from there. Not when that copy is running. No arm64 dest,
## since the synced tree has no dir for one. TUKFS_CICD_DOGFOOD_UTIL moves
## the whole util tree, for a test.
DOGFOOD_ENABLE=1
_dfUtil="${TUKFS_CICD_DOGFOOD_UTIL:-${HOME}/synced/0-0/common/exec/util}"
DOGFOOD_DESTS=("${_dfUtil}/linux/bin")
## The dogfood runner and its launcher, into each dir that's there, when they
## changed. "source|dir|dir...".
DOGFOOD_RUNNERS=(
	"utility/dogfood_tukfs-hash.ps1|${_dfUtil}/0_crossplatform"
	"utility/dogfood_tukfs-hash|${_dfUtil}/linux/bash"
)

## Stage 9: demo gif, eval'd. cicd/demo/scenario.toml runs against the
## native release build from stage 6, in a home in the run's temp dir, and
## gen-demo-gif.py draws it. Each gif is GFS-rotated into GIF_ROTATE_DIR, in
## the private dir beside the checkout, unless it's the same as the newest
## there, and copied to GIF_OUT when it differs.
## No Pillow or font warns and passes. --quick and --backlog-run-quick leave
## it out, and the merge gate and --backlog-run-full draw it into the temp dir.
GIF_ENABLE=1
GIF_SCENARIO="cicd/demo/scenario.toml"
GIF_OUT="assets/demo.gif"
GIF_ROTATE_DIR="${root}/../private/demo/gif"
GIF_CMD='cicd/utility/demo-gif.bash "${root}/${RELEASE_ARTIFACT_DIR}/${EXE_NAME}-$(fVersion)-${RELEASE_NATIVE_OSARCH}" "${GIF_SCENARIO}" "${GIF_OUT}" "${GIF_ROTATE_DIR}" "${stamp}"'

## --backlog-run-quick AREA...: only the areas named run. "name|leak text|what".
## A leak area keeps each leak check its text is in. With no area named it's
## fmt, build, lint, unit and it.
BACKLOG_AREAS=(
	"fmt||the format check"
	"build||the debug build"
	"lint||clippy, shellcheck, markdownlint, PSScriptAnalyzer, ruff and the test IDs"
	"unit||the unit tests"
	"it||the integration test, on a release build, once per test root"
	"leak|cicd/utility/|every leak check but the long ones"
	"advisories|advisories.bash|known advisories in Cargo.lock"
	"soak|soak.bash|the soak test"
	"asan|--asan|the unit tests under ASan and LSan"
	"tsan|--tsan|the unit tests under TSan"
	"miri|--miri|the unit tests under Miri"
	"fuzz|fuzz.bash 20|the parser fuzz tests, 20 s each"
	"codeql|codeql|CodeQL, about 11 minutes"
	"profile||the profiler"
	"release||the release builds, packages and release checks"
	"remote||the arm64 tests on vmDebARM64, with the release builds they need"
)

## What --quick leaves out, each matched as plain text against one step of
## LEAKCHECK_STEPS, CROSS_TARGETS, RELEASE_CHECKS or IT_ROOTS. Nothing yet
## takes long enough. The arm64 build and the packages each take less than
## the native build they come after.
QUICK_SKIP=()

## Stages 2-7 run from a frozen copy of the tree. These link back to the
## checkout's own, so builds start warm and the logs land where they're read.
FROZEN_LINKS=(target cicd/artifacts)
## The pre-push gate's builds go here instead of target, since the commit it
## builds may not be what's checked out.
GATE_TARGET_DIR="target-gate"

## Build caches the cleanup prunes: entries from an older toolchain, and those
## of crates gone from Cargo.lock, under debug, release and profiling.
## target-gate is the pre-push hook's.
CACHE_DIRS=(target target-gate)

## Run and lint logs, gitignored and GFS-rotated. lint-report.bash reads them.
LINT_LOG_DIR="cicd/artifacts/lint"

## Stage 10: backup and publish, through the copied publisher: a versioned rar of
## the project folder, then stash, pull --ff-only, pop, add, commit and push.
GIT_PUBLISH=(cicd/utility/n8git_backup-and-publish)
PUBLISH_AUTO_MESSAGE=""


##	History:
##		- 2026-10-23: Created from shcl's config.bash, trimmed to one crate.
##		- 2026-10-23: arm64 through zig, packages, release checks, the
##		  artifact names and dogfood. cargo's home is remapped in the builds.
##		- 2026-10-23: The leak checks, their image, and clippy over all features.
##		- 2026-10-23: The profiler, and ruff over the pipeline's Python.
##		- 2026-10-23: Release builds in a glibc 2.28 image, not on the host
##		  and through zig.
##		- 2026-10-23: The demo gif.
##		- 2026-10-23: Test IDs: the check in the lint stage, and the unit
##		  tests' status lines.
##		- 2026-10-23: A gif the same as the newest rotated one isn't rotated in.
##		- 2026-10-23: The release flag for build.rs.
##		- 2026-10-24: RUN_TMP_ROOT.
##		- 2026-10-25: The job count from the environment, not -j.
##		- 2026-10-25: BACKLOG_AREAS.
##		- 2026-10-25: A stage off here is listed in the plan, not skipped in a line.
##		- 2026-10-25: TEST_ID_LIST_CMD.
##		- 2026-10-25: The build and tests in the release image.
##		- 2026-10-25: The x86_64 release build on the host without docker.
##		- 2026-10-25: REMOTE_HOSTS, the arm64 tests on vmDebARM64.
##		- 2026-10-25: No RUN_TMP_PREFIX, since run dirs are named by time and
##		  a counter.
##		- 2026-10-25: A length on each leak check.
##		- 2026-10-26: The parser fuzz tests, fast and long.
