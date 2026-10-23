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
##		- A hook stage that's off here (profiler, packages, dogfood, demo gif)
##		  prints a skip line and nothing else. The backlog items that fill them
##		  are named beside each.
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
RUST_PIN="$(sed -n '/^channel *= *"/{ s/^channel *= *"\([^"]*\)".*/\1/p; q; }' "${root}/rust-toolchain.toml" 2>/dev/null || true)"
TOOL_PINS=(
	"rustc|${RUST_PIN}|rustc --version"
	"shellcheck|${PIN_SHELLCHECK}|shellcheck --version"
	"markdownlint|${PIN_MARKDOWNLINT}|markdownlint --version"
	"nightly|${PIN_NIGHTLY}|rustup toolchain list"
)

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
LINT_CMD=(cargo clippy -j "${CPU_CAP}" --locked --all-targets -- -D warnings)
SHELLCHECK_EXTRA=(cicd/hooks/pre-push cicd/utility/n8git_backup-and-publish cicd/tool-pins.env)
MARKDOWNLINT_CMD=(markdownlint --disable MD013 --)
MARKDOWN_SKIP=(license.md)

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

## Stage 4, last: the slow leak and memory checks, eval'd in order. A run with
## no flags runs them; --gate and --quick only with --leakcheck.
## Filled by 2026102309501602.
LEAKCHECK_STEPS=()

## Stage 5: profiler, eval'd. Filled by 2026102309501604.
PROFILE_ENABLE=0
PROFILE_CMD=''

## Stage 6: release builds. The native one is also what the integration test
## runs, so it's usually already built by then. Cross targets are
## "label|command", eval'd. Packages are one eval'd string.
## Both filled by 2026102309501603.
RELEASE_NATIVE_CMD=(cargo build --release -j "${CPU_CAP}" --locked)
RELEASE_NATIVE_BIN="target/release/${EXE_NAME}"
CROSS_TARGETS=()
PACKAGE_ENABLE=0
PACKAGE_CMD=''

## Stage 7: dogfood, eval'd. Filled by 2026102309501603.
DOGFOOD_ENABLE=0
DOGFOOD_CMD=''

## Stage 8: demo gif, eval'd. Filled by 2026102309501605.
GIF_ENABLE=0
GIF_CMD=''

## What --quick leaves out, each matched as plain text against one step of
## LEAKCHECK_STEPS, CROSS_TARGETS or IT_ROOTS. Nothing yet takes long enough.
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
