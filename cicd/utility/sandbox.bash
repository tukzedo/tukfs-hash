#!/usr/bin/env bash

##	Purpose:
##		Runs a test step on the host in a bubblewrap sandbox, so a bug in what
##		it runs can only write to the folders named. Everything else is
##		read-only. Home, /tmp and /run are empty, so the sockets in them, such
##		as docker's, ssh-agent's, tmux's and the session bus, aren't there to
##		reach. No network, no other processes, and no sudo. The toolchain
##		folders in home are shown read-only, so cargo runs offline from what
##		an earlier step fetched. See design.md, Test sandbox.
##		TUKFS_NO_SANDBOX=1, from cicd.bash's --no-sandbox, runs the command
##		as is, with a warning. Inside the build image it always runs as is,
##		since the image is the sandbox there.
##	Syntax:
##		sandbox.bash RW_DIR... -- COMMAND [ARG...]
##		Each RW_DIR has to be there already, and can't be /, a folder right
##		under it such as /tmp, home itself or a folder home is in.
##	Exit: the command's, or 2 when it can't run.
##	History: At bottom of script.

##	Copyright © 2026 t00mietum (CryptogID: ปʬϝღถɔ4რఠΔթะ9ƾǝu)
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


set -Eeuo pipefail

fDie(){ echo "sandbox: $*" >&2; exit 2; }

rw=()
while (($#)) && [[ "$1" != -- ]]; do rw+=("$1"); shift; done
(($# >= 2)) || fDie "usage: sandbox.bash RW_DIR... -- COMMAND [ARG...]"
shift

if [[ -n "${TUKFS_IN_IMAGE:-}" ]]; then exec "$@"; fi
if [[ -n "${TUKFS_NO_SANDBOX:-}" ]]; then
	echo "[ WARNING: no sandbox (--no-sandbox): this step can write anywhere this user can ]" >&2
	exec "$@"
fi

command -v bwrap >/dev/null 2>&1 || fDie "bubblewrap (bwrap) isn't installed; install it, or pass --no-sandbox to run the tests unguarded"
homeReal="$(realpath -e -- "${HOME:?}")" || fDie "no home folder"

args=(
	--die-with-parent --unshare-all
	--ro-bind / / --dev-bind /dev /dev --proc /proc
	--tmpfs /dev/shm --tmpfs /tmp --tmpfs /run --tmpfs "${homeReal}"
	--unsetenv SSH_AUTH_SOCK --unsetenv DBUS_SESSION_BUS_ADDRESS --unsetenv XDG_RUNTIME_DIR
	--unsetenv DISPLAY --unsetenv WAYLAND_DISPLAY --unsetenv TMUX
	--setenv CARGO_NET_OFFLINE true --setenv TUKFS_SANDBOX 1
)
## Toolchains only. ~/.cargo's credentials stay hidden.
for d in .rustup .cargo/bin .cargo/registry .cargo/git; do
	if [[ -d "${homeReal}/${d}" ]]; then args+=(--ro-bind "${homeReal}/${d}" "${homeReal}/${d}"); fi
done
pools=()
for d in "${rw[@]}"; do
	real="$(realpath -e -- "${d}" 2>/dev/null)" || fDie "not there: ${d}"
	[[ -d "${real}" ]] || fDie "not a folder: ${d}"
	if [[ "${real}" =~ ^/[^/]*$ || "${homeReal}/" == "${real}/"* ]]; then fDie "too wide to leave writable: ${d}"; fi
	args+=(--bind "${real}" "${real}")
	read -r fsType src < <(findmnt -no FSTYPE,SOURCE -T "${real}" 2>/dev/null || true) || true
	if [[ "${fsType:-}" == zfs && -n "${src:-}" ]]; then pools+=("${src%%/*}"); fi
done

## ZFS shows no pool to a user namespace it isn't delegated to, so `zpool
## list` fails in here. A scan needs it for the pool's disks, so this stand-in
## gives back what the real one said out here, for the pools above only.
if ((${#pools[@]})) && zpoolReal="$(command -v zpool 2>/dev/null)"; then
	shim=$'#!/usr/bin/env bash\n## The test sandbox\'s stand-in, from sandbox.bash.\n'
	shim+=$'if [[ "${#}" -eq 5 && "${1} ${2} ${3} ${4}" == "list -v -H -P" ]]; then case "${5}" in\n'
	for p in $(printf '%s\n' "${pools[@]}" | sort -u); do
		out="$("${zpoolReal}" list -v -H -P "${p}" 2>/dev/null | base64 -w 0)" || continue
		shim+="	${p@Q}) base64 -d <<< ${out@Q}; exit 0 ;;"$'\n'
	done
	shim+=$'esac; fi\n'
	shim+="exec ${zpoolReal@Q} \"\${@}\""$'\n'
	exec {shimFd}< <(printf '%s' "${shim}")
	args+=(--perms 0555 --ro-bind-data "${shimFd}" /run/tukfs-sandbox/zpool --setenv PATH "/run/tukfs-sandbox:${PATH}")
fi

## A box with user namespaces off can't run bwrap at all.
bwrap --unshare-all --ro-bind / / true 2>/dev/null || fDie "bwrap can't start here (are user namespaces off?); pass --no-sandbox to run the tests unguarded"
exec bwrap "${args[@]}" -- "$@"


##	History:
##		- 2026-11-02: Created.
