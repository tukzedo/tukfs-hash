#!/usr/bin/env bash

##	Purpose:
##		Run by ctr-image.bash's fCtrFetch in an image, with network: the
##		crates Cargo.lock names, then with NIGHTLY the ones -Zbuild-std takes
##		for its std, into CARGO_HOME, so the checks can run offline.
##	Syntax:
##		ctr-fetch.bash [NIGHTLY]
##	History: At bottom of script.

##	Copyright © 2026 t00mietum (CryptogID: ปʬϝღถɔ4რఠΔթะ9ƾǝu)
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


set -Eeuo pipefail

nightly="${1:-}"
cargo fetch --locked --quiet
[[ -n "${nightly}" ]] || exit 0
lib="$(rustc "+${nightly}" --print sysroot)/lib/rustlib/src/rust/library/Cargo.toml"
cargo "+${nightly}" fetch --locked --quiet --manifest-path "${lib}"


##	History:
##		- 2026-10-23: Created.
##		- 2026-10-23: NIGHTLY is optional, for the release image.
