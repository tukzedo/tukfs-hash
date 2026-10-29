#!/usr/bin/env bash

##	Purpose:
##		Known advisories for the crates Cargo.lock names: vulnerable, unsound
##		and unmaintained ones, by RustSec's database, through cargo-deny and
##		deny.toml. Any of them fails. It covers third-party code only, which
##		is the point. On the host, since it fetches the database, and the leak
##		check image has no network.
##		The fetch and the check are apart, so a database that can't be had is
##		told from a finding. That's a noted skip, or a failure with
##		TUKFS_GATE_STRICT set, as the check-only modes do.
##	Syntax:
##		advisories.bash
##	Exit: 0 = clean or skipped, 1 = an advisory, or a failure under strict, 2 = can't run.
##	History: At bottom of script.

##	Copyright © 2026 t00mietum (CryptogID: ปʬϝღถɔ4რఠΔթะ9ƾǝu)
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


set -Eeuo pipefail

me="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${me}/include/leak-common.bash"

if (($#)); then echo "advisories: takes no arguments (see the header)" >&2; exit 2; fi
start="${SECONDS}"
strict="${TUKFS_GATE_STRICT:-}"

fSkip(){
	if [[ -n "${strict}" ]]; then echo "advisories: $1, and the gate needs it" >&2; exit 1; fi
	echo "note: advisories: skipped, since $1"
	exit 0
}

command -v cargo-deny >/dev/null 2>&1 || fSkip "cargo-deny isn't installed (want ${PIN_CARGO_DENY})"
out="$(cargo deny fetch db 2>&1)" || fSkip "the advisory database couldn't be fetched (offline?): $(tail -n 1 <<<"${out}" | cut -c1-160)"
rc=0
out="$(cargo deny check --disable-fetch advisories 2>&1)" || rc=$?
if ((rc != 0)); then
	printf '%s\n' "${out}"
	echo "advisories: cargo deny check advisories exited ${rc}" >&2
	exit 1
fi
echo "advisories: OK: none known for the $(grep -c "^name = " Cargo.lock) packages in Cargo.lock ($((SECONDS - start)) s)"


##	History:
##		- 2026-10-23: Created.
