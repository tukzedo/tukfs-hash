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
##		- A hook stage that's off here (profiler, demo gif) prints a skip line
##		  and nothing else. The backlog items that fill them are named beside
##		  each.
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
## build.rs reads the build number from this at compile time.
BUILD_ENV_NAME="TUKFS_HASH_BUILD"

## Each run's temp dir and the integration test's dirs are named with this,
## under <root>/tukfs-hash/, and nothing else is ever removed by the guard.
RUN_TMP_PREFIX="cicd_tukfs-hash_qx7j"

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
	"cargo-zigbuild|${PIN_CARGO_ZIGBUILD}|cargo-zigbuild --version"
	"zig|${PIN_ZIG}|zig version"
	"nfpm|${PIN_NFPM}|go version -m \"${NFPM}\""
	"PSScriptAnalyzer|${PIN_PSSA}|pwsh -NoProfile -Command \"(Get-Module -ListAvailable PSScriptAnalyzer | Select-Object -First 1).Version.ToString()\""
)

## Paths into cargo's home end up in panic messages, so they're mapped to one
## name and the bytes don't depend on whose home it is. The checkout's own
## paths are already relative. Every cargo call gets it, or the release builds
## would rebuild what the tests built. Added once, since the run on the frozen
## copy reads this file again.
_remap="--remap-path-prefix=${CARGO_HOME:-${HOME}/.cargo}=/cargo"
if [[ " ${RUSTFLAGS:-} " != *" ${_remap} "* ]]; then export RUSTFLAGS="${RUSTFLAGS:+${RUSTFLAGS} }${_remap}"; fi

## Stage 1: format. FMT_CMD rewrites in place; FMT_CHECK_CMD fails on a diff
## and is what --gate runs. rustfmt.toml has the style. Bash is never formatted.
FMT_CMD=(cargo fmt)
FMT_CHECK_CMD=(cargo fmt --check)

## Stage 2: debug build. --locked everywhere, so a build never rewrites
## Cargo.lock behind the run's back.
BUILD_CMD=(cargo build -j "${CPU_CAP}" --locked)

## Stage 3: lint. The clippy lints are in Cargo.toml's [lints.clippy], so an
## editor's clippy sees the same ones: pedantic, mem_forget and
## undocumented_unsafe_blocks. shellcheck takes every tracked *.bash plus these.
## markdownlint takes every tracked .md but license.md, which is the GPL's own
## text and stays as published. MD013 is line length, and the docs never wrap.
## All features, or the soak test behind its feature goes unlinted.
LINT_CMD=(cargo clippy -j "${CPU_CAP}" --locked --all-targets --all-features -- -D warnings)
SHELLCHECK_EXTRA=(cicd/hooks/pre-push cicd/utility/n8git_backup-and-publish cicd/tool-pins.env utility/dogfood_tukfs-hash)
MARKDOWNLINT_CMD=(markdownlint --disable MD013 --)
MARKDOWN_SKIP=(license.md)
## Every tracked .ps1, with PSScriptAnalyzerSettings.psd1 at the repo root.
PS_LINT_CMD=(pwsh -NoProfile -File cicd/utility/lint-ps1.ps1)

## Stage 4: tests. Unit tests first, with TMPDIR in the run's temp dir. Then the
## integration test on a release build, once per root below, each in a dir of
## its own made under <root>/tukfs-hash/. "label|root". A root that isn't there
## skips with a note. TUKFS_CICD_IT_EXT4 and TUKFS_CICD_IT_ZFS override them.
TEST_CMD=(cargo test --release -j "${CPU_CAP}" --locked -- --test-threads "${CPU_CAP}")
IT_CMD=(tests/integration.bash)
IT_ROOTS=(
	"ext4|${TUKFS_CICD_IT_EXT4:-/mnt/ext/wip2/wip/tmp}"
	"zfs|${TUKFS_CICD_IT_ZFS:-${HOME}/tmp/tukfs-hash-zfs-it}"
)

## Stage 4, last: the slow leak and memory checks, eval'd in order, quick ones
## first. A run with no flags runs them, and --quick only with --leakcheck.
## --gate never does. Any report fails. The sanitizers, Miri and CodeQL run in
## the image below when docker answers, else on the host with a note.
LEAKCHECK_STEPS=(
	## Known advisories for every crate in Cargo.lock. On the host, since it
	## fetches RustSec's database. Offline is a noted skip.
	'cicd/utility/advisories.bash'
	## The main actions 20 times over in one process, with the heap at round
	## 20 held to round 10. The table goes in cicd/artifacts/soak/. On the
	## host, since a scan needs the real disks.
	'cicd/utility/soak.bash'
	## The unit tests under ASan and LSan, then TSan, then Miri, each in a
	## build dir of its own under target/leakcheck.
	'cicd/utility/sanitize-rust.bash --asan'
	'cicd/utility/sanitize-rust.bash --tsan'
	'cicd/utility/sanitize-rust.bash --miri'
	## Over the tree with every crate vendored. The SARIF and findings go in
	## cicd/artifacts/codeql/.
	'cicd/utility/codeql-scan.bash'
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

## Stage 5: profiler, eval'd. Filled by 2026102309501604.
PROFILE_ENABLE=0
PROFILE_CMD=''

## Stage 6: release builds, Linux only, since the tool reads Linux xattrs,
## mounts and snapshots. The native one is also what the integration test
## runs, so it's usually already built by then. Cross targets are
## "label|os-arch|binary|command", the command eval'd. arm64 goes through zig,
## which also builds the bundled SQLite, and takes about as long as x86_64.
## Each build is named <exe>-<version>-<os-arch> in RELEASE_ARTIFACT_DIR, with
## <exe>-<version>-sha256sums.txt beside them. Download links depend on these
## names, so they stay.
RELEASE_NATIVE_CMD=(cargo build --release -j "${CPU_CAP}" --locked)
RELEASE_NATIVE_BIN="target/release/${EXE_NAME}"
RELEASE_NATIVE_OSARCH="linux-x86_64"
CROSS_TARGETS=(
	"Linux arm64 (zig)|linux-arm64|target/aarch64-unknown-linux-gnu/release/${EXE_NAME}|cargo zigbuild --release -j \${CPU_CAP} --locked --target aarch64-unknown-linux-gnu"
)
RELEASE_ARTIFACT_DIR="cicd/artifacts/release"
## A .deb and an .rpm per build, from cicd/packaging/nfpm.yaml, into the stage
## dir before the checks run. The binary is all they hold.
PACKAGE_ENABLE=1
PACKAGE_CMD='cicd/utility/package.bash "${release_stage}" "${ver}" "${release_work}"'
## Over the stage dir, once everything's built and packaged; "label|command",
## eval'd. A failure keeps the whole set out of RELEASE_ARTIFACT_DIR.
RELEASE_CHECKS=(
	'native --version shows the stamped build|cicd/utility/check-release.bash version "${release_stage}/${EXE_NAME}-${ver}-${RELEASE_NATIVE_OSARCH}" "${EXE_NAME}" "${ver}" "${build_number}"'
	'file names the architecture of each build|cicd/utility/check-release.bash arch "${release_stage}" "${EXE_NAME}-${ver}" "${staged_osarchs[@]}"'
	'each package holds the binary and nothing else|if ((PACKAGE_ENABLE)); then cicd/utility/check-release.bash package "${release_stage}" "${EXE_NAME}" "${ver}" "${release_work}" "${staged_osarchs[@]}"; else echo "no packages in this run"; fi'
)

## Stage 7: dogfood. The native release build goes into the first of these
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

## Stage 8: demo gif, eval'd. Filled by 2026102309501605.
GIF_ENABLE=0
GIF_CMD=''

## What --quick leaves out, each matched as plain text against one step of
## LEAKCHECK_STEPS, CROSS_TARGETS, RELEASE_CHECKS or IT_ROOTS. Nothing yet
## takes long enough. The arm64 build and the packages each take less than
## the native build they come after.
QUICK_SKIP=()

## Stages 2-6 run from a frozen copy of the tree. These link back to the
## checkout's own, so builds start warm and the logs land where they're read.
FROZEN_LINKS=(target cicd/artifacts)
## The pre-push gate's builds go here instead of target, since the commit it
## builds may not be what's checked out.
GATE_TARGET_DIR="target-gate"

## Build caches the cleanup prunes: entries from an older toolchain, and those
## of crates gone from Cargo.lock. target-gate is the pre-push hook's.
CACHE_DIRS=(target target-gate)

## Run and lint logs, gitignored and GFS-rotated. lint-report.bash reads them.
LINT_LOG_DIR="cicd/artifacts/lint"

## Stage 9: backup and publish, through the copied publisher: a versioned rar of
## the project folder, then stash, pull --ff-only, pop, add, commit and push.
GIT_PUBLISH=(cicd/utility/n8git_backup-and-publish)
PUBLISH_AUTO_MESSAGE=""


##	History:
##		- 2026-10-23: Created from shcl's config.bash, trimmed to one crate.
##		- 2026-10-23: arm64 through zig, packages, release checks, the
##		  artifact names and dogfood. cargo's home is remapped in the builds.
##		- 2026-10-23: The leak checks, their image, and clippy over all features.
