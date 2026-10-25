#!/usr/bin/env bash

#  shellcheck disable=1091  ## 'Not following.' The includes are checked on their own.
#  shellcheck disable=2154  ## 'referenced but not assigned.' TESTS_CTR_TARGET_DIR comes from config.bash.

##	Purpose:
##		Run by cicd.bash in the release image, through ctr-image.bash's
##		fCtrRunSelf: COMMAND from the repo root, with the image's own target
##		dir, so its builds don't replace the host's, and the job count the
##		run passed in. config.bash maps the image's cargo home in panic
##		messages, as it does the host's.
##	Syntax:
##		in-image.bash COMMAND [ARG...]
##	Exit: the command's, or 2.
##	History: At bottom of script.

##	Copyright © 2026 t00mietum (CryptogID: ปʬϝღถɔ4რఠΔթะ9ƾǝu)
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


set -Eeuo pipefail

[[ -n "${TUKFS_IN_IMAGE:-}" ]] || { echo "in-image.bash: only runs in the image" >&2; exit 2; }
(($#)) || { echo "usage: in-image.bash COMMAND [ARG...]" >&2; exit 2; }
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
here="${root}/cicd"
cd "${root}"
source "${here}/utility/include/cpu-cap.bash"
fCpuCap
## shellcheck source=../config.bash
source "${here}/config.bash"
export CARGO_TARGET_DIR="${TESTS_CTR_TARGET_DIR}"
exec "$@"


##	History:
##		- 2026-10-25: Created, for the build and tests in the image.
