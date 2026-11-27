#!/usr/bin/env bash

##	Purpose:
##		- One-line installer for tukfs-hash on Linux. Finds the newest stable
##		  or dev release on GitHub, checks the binary for this CPU against
##		  the release's sums file, and puts it in ~/.local/bin, or in
##		  /usr/local/bin for the whole system.
##		- Says what it'll do and asks first, unless given --yes. When the same
##		  bytes are already in place it changes nothing, so it's safe to run
##		  again.
##		- Runs on Bash 3.2 and up, so no namerefs, mapfile, or associative arrays.
##	Syntax:
##		bash <(curl -fsSL https://raw.githubusercontent.com/tukzedo/tukfs-hash/main/install.bash) [--help]
##	Exit: 0 = installed or already in place, 1 = refused, failed, or declined.
##	History: At bottom of script.

##	Copyright © 2026 t00mietum (CryptogID: ปʬϝღถɔ4რఠΔթะ9ƾǝu)
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


set -Eeuo pipefail

INSTALLER_VERSION="1.0.3"
PROG="tukfs-hash"
REPO="tukzedo/tukfs-hash"
API="https://api.github.com/repos/${REPO}/releases?per_page=100"
DOWNLOADS="https://github.com/${REPO}/releases/download"
GLIBC_MAJOR=2; GLIBC_MINOR=28

release="stable"
target="user"
assumeYes=0
useSudo=0
work=""
asset=""
staged=""

fEcho(){ printf '[ %s ]\n' "$*"; }
fEcho_Clean(){ printf '%s\n' "$*"; }
fDie(){ printf '[ ERROR: %s ]\n' "$*" >&2; echo >&2; exit 1; }

## Spelled out rather than read from the header. Run as `bash <(curl ...)`, the script is a pipe the shell has already read, so there's nothing to read back.
fUsage(){ cat <<'EOF'
Installs the newest tukfs-hash release from GitHub, after checking its sha256.

Usage:
	bash <(curl -fsSL https://raw.githubusercontent.com/tukzedo/tukfs-hash/main/install.bash) [options]

Options:
	--release stable|dev ... stable = newest release (default), dev = newest including pre-releases
	--target user|system ... user = ~/.local/bin (default), system = /usr/local/bin, through sudo when not root
	-y, --yes .............. don't ask before installing
	--version .............. print this installer's version
	-h, --help ............. this help

Notes:
	- Options take "--name value" or "--name=value".
	- The CPU is detected, x86_64 or arm64. Builds need glibc 2.28 or newer.
	- With no stable release yet, stable takes the newest pre-release.
	- Running it again is safe. When the same build is already there, nothing changes.
	- The .deb and .rpm packages on the releases page install to /usr/bin instead.
EOF
}

## Each release's tag, then 1 for a pre-release. Drafts aren't public, but are skipped all the same. Commas and braces to newlines, so compact JSON reads like the pretty kind, one field per line.
fListReleases(){
	tr ',{' '\n' <<<"${releaseJson}" | awk '
		/^[[:space:]]*"tag_name":[[:space:]]*"/ { tag = $0; sub(/^[[:space:]]*"tag_name":[[:space:]]*"/, "", tag); sub(/".*/, "", tag) }
		/^[[:space:]]*"draft":[[:space:]]*true/ { tag = "" }
		/^[[:space:]]*"prerelease":[[:space:]]*(true|false)/ { if (tag != "") print tag " " ($0 ~ /true/ ? 1 : 0); tag = "" }
	'
}

## Newest by version, never by the list's order. A pre-release sorts below its release (1.0.0-beta.2 < 1.0.0), and runs of digits compare as numbers (beta.2 < beta.10).
fNewest(){
	awk '{
		ver = $1; sub(/^v/, "", ver); pre = ""
		if (index(ver, "-")) { pre = substr(ver, index(ver, "-") + 1); ver = substr(ver, 1, index(ver, "-") - 1) }
		n = split(ver, part, ".")
		key = sprintf("%08d%08d%08d", part[1], (n > 1 ? part[2] : 0), (n > 2 ? part[3] : 0))
		if (pre == "") { key = key "1" } else {
			key = key "0"
			while (match(pre, /[0-9]+/)) { key = key substr(pre, 1, RSTART - 1) sprintf("%08d", substr(pre, RSTART, RLENGTH)); pre = substr(pre, RSTART + RLENGTH) }
			key = key pre
		}
		print key " " $1
	}' | LC_ALL=C sort -r | awk 'NR == 1 { print $2 }'
}

fAsTarget(){ if ((useSudo)); then sudo "$@"; else "$@"; fi; }

## Only the one download is ever in the work folder, so it goes by name, then rmdir. The new copy goes too if a stop came before its rename, such as a Ctrl+C at a sudo prompt.
fWorkGone(){
	rm -f -- "${work}/${asset}"; rmdir -- "${work}" 2>/dev/null || true
	if [[ -n "${staged}" ]] && [[ -e "${staged}" || -L "${staged}" ]]; then
		fAsTarget rm -f -- "${staged}" || true
		if [[ -e "${staged}" || -L "${staged}" ]]; then
			local how="rm"; ((useSudo)) && how="sudo rm"
			printf '[ Note: %s is left over from this install. Remove it with: %s %s ]\n' "${staged}" "${how}" "${staged}" >&2
		fi
	fi
}

## Some folder on PATH is the install folder, by what it points to rather than its text, so a trailing slash or a link to it still counts.
fOnPath(){
	local rest="${PATH:-}:" dir=""
	while [[ -n "${rest}" ]]; do
		dir="${rest%%:*}"; rest="${rest#*:}"
		if [[ -n "${dir}" && "${dir}" -ef "${destDir}" ]]; then return 0; fi
	done
	return 1
}

fMain(){
	echo
	while (($#)); do
		case "$1" in
			--release|--target) [[ $# -ge 2 ]] || fDie "$1 needs a value (try --help)" ;;
		esac
		case "$1" in
			--release)   release="$2"; shift 2 ;;
			--release=*) release="${1#*=}"; shift ;;
			--target)    target="$2"; shift 2 ;;
			--target=*)  target="${1#*=}"; shift ;;
			-y|--yes)    assumeYes=1; shift ;;
			--version)   echo "${PROG} installer v${INSTALLER_VERSION}"; echo; exit 0 ;;
			-h|--help)   fUsage; echo; exit 0 ;;
			*)           fDie "unknown option: $1 (try --help)" ;;
		esac
	done
	[[ "${release}" == "stable" || "${release}" == "dev"    ]] || fDie "--release takes stable or dev, not '${release}'"
	[[ "${target}"  == "user"   || "${target}"  == "system" ]] || fDie "--target takes user or system, not '${target}'"


	##	What to fetch, and where it goes.

	[[ "$(uname -s)" == "Linux" ]] || fDie "${PROG} runs only on Linux, but this is $(uname -s)"
	cpu="$(uname -m)"
	case "${cpu}" in
		x86_64|amd64)  arch="x86_64" ;;
		aarch64|arm64) arch="arm64" ;;
		*) fDie "there's no build for a ${cpu} CPU, only x86_64 and arm64" ;;
	esac

	## The builds link against glibc 2.28. Without getconf there's nothing to ask, and the trial run of the download below still catches a box that's too old.
	glibc=""
	if command -v getconf >/dev/null 2>&1; then
		glibc="$(getconf GNU_LIBC_VERSION 2>/dev/null || true)"
		[[ "${glibc}" == "glibc "* ]] || fDie "the builds need glibc ${GLIBC_MAJOR}.${GLIBC_MINOR} or newer, but this system doesn't use glibc"
		glibc="${glibc#glibc }"
		## Checked as text first, since bash arithmetic runs a $(...) hidden in a value.
		[[ "${glibc}" =~ ^([0-9]+)\.([0-9]+) ]] || fDie "can't read the glibc version '${glibc}'"
		major="${BASH_REMATCH[1]}"; minor="${BASH_REMATCH[2]}"
		if ((10#${major} < GLIBC_MAJOR || (10#${major} == GLIBC_MAJOR && 10#${minor} < GLIBC_MINOR))); then
			fDie "the builds need glibc ${GLIBC_MAJOR}.${GLIBC_MINOR} or newer, but this system has ${glibc}"
		fi
	fi

	uid="$(id -u)"
	if [[ "${target}" == "user" ]]; then
		[[ -n "${HOME:-}" ]] || fDie "HOME isn't set, so there's no ~/.local/bin"
		home="${HOME}"; while [[ "${home}" == */ && "${home}" != "/" ]]; do home="${home%/}"; done
		## A sudo that keeps HOME, or su -m, would leave a root-owned copy in someone else's folder.
		if [[ "${uid}" == "0" && -e "${home}" && ! -O "${home}" ]]; then
			fDie "this is running as root, but HOME is ${home}, which isn't root's. Run it without sudo to install for that user, or use --target system for /usr/local/bin"
		fi
		destDir="${home%/}/.local/bin"
	else
		destDir="/usr/local/bin"
	fi
	destPath="${destDir}/${PROG}"
	if [[ -d "${destPath}" ]]; then
		[[ ! -L "${destPath}" ]] || fDie "${destPath} is a link to a folder, so nothing was changed"
		fDie "there's a folder at ${destPath}, so nothing was changed"
	fi
	if [[ "${target}" == "system" && "${uid}" != "0" ]]; then
		command -v sudo >/dev/null 2>&1 || fDie "--target system needs root, or sudo"
		useSudo=1
	fi

	command -v curl      >/dev/null 2>&1 || fDie "curl is needed"
	command -v sha256sum >/dev/null 2>&1 || fDie "sha256sum is needed"

	fEcho "Looking up the newest ${release} release"
	## The list rather than releases/latest, which skips pre-releases and has nothing while every release is one.
	releaseJson="$(curl -fsSL "${API}")" || fDie "couldn't list the releases on GitHub (offline, or rate-limited?)"

	releases="$(fListReleases || true)"
	kind="stable release"
	if [[ "${release}" == "stable" ]]; then
		tag="$(awk '$2 == 0' <<<"${releases}" | fNewest || true)"
		if [[ -z "${tag}" ]]; then
			tag="$(fNewest <<<"${releases}" || true)"
			[[ -z "${tag}" ]] || fEcho "There's no stable release yet, so this takes the newest pre-release"
		fi
	else
		tag="$(fNewest <<<"${releases}" || true)"
	fi
	[[ -n "${tag}" ]] || fDie "GitHub lists no releases of ${REPO}"
	[[ "${tag}" =~ ^v[0-9A-Za-z.+-]+$ ]] || fDie "the newest release has a tag this installer doesn't expect: ${tag}"
	awk -v t="${tag}" '$1 == t && $2 == 1 { found = 1 } END { exit !found }' <<<"${releases}" && kind="pre-release"

	version="${tag#v}"
	asset="${PROG}-${version}-linux-${arch}"
	sums="${PROG}-${version}-sha256sums.txt"
	url="${DOWNLOADS}/${tag}/${asset}"

	## The sums file is small, so it's read before asking, and the check for an install that's already this build goes by bytes rather than by --version.
	sumsText="$(curl -fsSL "${DOWNLOADS}/${tag}/${sums}")" || fDie "couldn't download ${sums} from release ${tag}"
	want="$(awk -v a="${asset}" '$2 == a || $2 == "*" a { print $1; exit }' <<<"${sumsText}")"
	[[ "${want}" =~ ^[0-9a-f]{64}$ ]] || fDie "${sums} has no sha256 for ${asset}"

	haveVer=""
	if [[ -f "${destPath}" ]]; then
		have="$(sha256sum "${destPath}" 2>/dev/null || true)"
		if [[ "${have%% *}" == "${want}" ]]; then
			if [[ -x "${destPath}" ]]; then
				fEcho "${destPath} is already ${PROG} ${tag}, so there's nothing to do"
				echo
				exit 0
			fi
			haveVer="the same build, but it isn't executable"
		elif [[ -x "${destPath}" ]]; then
			haveVer="$("${destPath}" --version 2>/dev/null || true)"; haveVer="${haveVer%%$'\n'*}"
		fi
	fi


	##	Say the plan, get a yes, then do it.

	echo
	fEcho "Plan"
	fEcho_Clean "    Release:   ${tag}, a ${kind}"
	fEcho_Clean "    System:    Linux ${cpu}${glibc:+, glibc ${glibc}}"
	fEcho_Clean "    Download:  ${url}"
	fEcho_Clean "    Check:     sha256 from ${sums}"
	fEcho_Clean "    Install:   ${destPath}"
	if [[ -L "${destPath}" ]]; then
		fEcho_Clean "    Replaces:  a link to $(readlink -- "${destPath}" || true), with the file itself"
	elif [[ -e "${destPath}" ]]; then
		[[ -n "${haveVer}" ]] || haveVer="a file that doesn't give its version"
		fEcho_Clean "    Replaces:  ${haveVer}"
	fi
	((useSudo)) && fEcho_Clean "    Uses sudo to write to ${destDir}."
	echo

	if ((! assumeYes)); then
		## From the terminal, not stdin, which is the script itself under curl | bash.
		{ : </dev/tty; } 2>/dev/null || fDie "there's no terminal to ask on, so nothing was changed. Run it again with --yes to go ahead."
		answer=""; read -r -p "Go ahead? [y/N] " answer </dev/tty || true
		case "${answer}" in
			y|Y|yes|Yes|YES) : ;;
			*) echo; fEcho "Stopped, and nothing was changed"; echo; exit 1 ;;
		esac
		echo
	fi

	## CDPATH is cleared, since with it set cd prints the folder, and a relative TMPDIR could resolve against it.
	tmpRoot="$(CDPATH='' cd -- "${TMPDIR:-/tmp}" && pwd -P)" || fDie "there's no temp folder at ${TMPDIR:-/tmp}"
	work="$(mktemp -d "${tmpRoot}/${PROG}-install.XXXXXX")" || fDie "couldn't make a work folder in ${tmpRoot}"
	trap fWorkGone EXIT

	fEcho "Downloading ${asset}"
	progress="-sS"; [[ -t 2 ]] && progress="--progress-bar"
	curl -fL "${progress}" -o "${work}/${asset}" "${url}" || fDie "the download failed: ${url}"

	fEcho "Checking its sha256"
	got="$(sha256sum "${work}/${asset}")"; got="${got%% *}"
	[[ "${got}" == "${want}" ]] || fDie "the download doesn't match ${sums}, so nothing was installed. Wanted ${want}, got ${got}."

	fEcho "Installing to ${destPath}"
	## Through a new name in the same folder, then a rename over the old one, so a running copy keeps going and a stop partway leaves the old one whole.
	staged="${destDir}/.${PROG}.new.$$"
	fAsTarget mkdir -p -- "${destDir}"                          || fDie "couldn't make ${destDir}"
	fAsTarget install -m 0755 -- "${work}/${asset}" "${staged}" || fDie "couldn't write to ${destDir}"

	## A trial run, so a build that can't start here never replaces one that can. It runs from the install folder, since a temp folder is often mounted noexec.
	[[ -x "${staged}" ]] || fDie "${destDir} won't run programs, as on a noexec mount, so nothing was installed"
	newVer="$("${staged}" --version 2>&1)" || fDie "the download doesn't run on this system, so nothing was installed: ${newVer%%$'\n'*}"
	newVer="${newVer%%$'\n'*}"

	## -T so a link to a folder that turned up since the check gets replaced rather than moved into.
	fAsTarget mv -fT -- "${staged}" "${destPath}"               || fDie "couldn't put ${PROG} in place at ${destPath}"

	echo
	fEcho "Installed ${newVer}"
	found="$(command -v "${PROG}" 2>/dev/null || true)"
	if ! fOnPath; then
		fEcho "Note: ${destDir} isn't on PATH"
	elif [[ -n "${found}" && ! "${found}" -ef "${destPath}" ]]; then
		fEcho "Note: ${found} comes first on PATH, so it's the one that runs"
	fi
	echo
}

## Nothing runs until the last line is read, so a download cut off partway does nothing.
fMain "$@"


##	History:
##		- 2026-11-17: Created from convert-base-v2's install.bash.
##		- 2026-11-19: Blank line around --help, --version and option errors too.
##		- 2026-11-20: Refuses a link to a folder at the name, and root with
##		  someone else's HOME. Same bytes without the execute bit get put in again.
##		- 2026-11-20: All in one function, called at the end. The trial run is
##		  from the install folder, and a stop before the rename removes the new
##		  copy. HOME with a trailing slash, and CDPATH.
