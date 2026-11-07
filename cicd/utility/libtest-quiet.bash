#!/usr/bin/env bash

##	Purpose:
##		Run a `cargo test` command with libtest's own per-test lines left out of
##		its stdout. Every test prints its status line with its test ID on
##		stderr, so libtest's would be the same test twice. Its summary, failure
##		detail and everything cargo prints still go through.
##		From shcl's cicd/utility/libtest-quiet.bash.
##	Syntax:
##		libtest-quiet.bash COMMAND [ARG ...]
##	Exit: the command's.
##	History: At bottom of script.

##	Copyright © 2026 t00mietum (CryptogID: ปʬϝღถɔ4რఠΔթะ9ƾǝu)
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


set -Eeuo pipefail

(($#)) || { echo "usage: libtest-quiet.bash COMMAND [ARG ...]" >&2; exit 2; }
"$@" | sed -u -E '/^test .+ \.\.\. (ok|FAILED|ignored)(, .*)?$/d'


##	History:
##		- 2026-10-23: Copied from shcl's.
