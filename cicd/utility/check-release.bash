#!/usr/bin/env bash

##	Purpose:
##		- Checks over the release builds in the stage dir, before any of them
##		  reach the artifact dir. Each mode fails on the first thing wrong.
##		- version: the binary's --version first line is
##		  "NAME vVERSION build BUILD", and unless RELEASE is 1, then " (DATE)",
##		  the build's day where the binary runs. That's checked in 2 zones a
##		  day apart too. An empty BUILD fails, since a release with no build
##		  number can't be traced to its commit. BUILD may end in -dirty, for a
##		  tree that isn't its commit's, and then RELEASE can't be 1.
##		- arch: `file` names the architecture each os-arch says.
##		- package: each .deb and .rpm holds /usr/bin/NAME and nothing else,
##		  with the same bytes as the binary beside it, and its name, version,
##		  arch and glibc floor are right. WORK_DIR takes rpm's empty database.
##		- glibc: no build needs a glibc newer than FLOOR, so a build that
##		  picked up the box's glibc can't go out as a release.
##		- glibc-note: the same, but one over FLOOR is a NOTE, for a build
##		  made on the box since there was no docker.
##	Syntax:
##		check-release.bash version BIN NAME VERSION BUILD [RELEASE]
##		check-release.bash arch STAGE_DIR PREFIX OS-ARCH...
##		check-release.bash package STAGE_DIR NAME VERSION WORK_DIR OS-ARCH...
##		check-release.bash glibc|glibc-note STAGE_DIR PREFIX FLOOR OS-ARCH...
##		A binary is STAGE_DIR/PREFIX-OS-ARCH, and PREFIX is NAME-VERSION.
##	History: At bottom of script.

##	Copyright © 2026 t00mietum (CryptogID: ปʬϝღถɔ4რఠΔթะ9ƾǝu)
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


set -Eeuo pipefail

fDie(){ echo "check-release: $*" >&2; exit 1; }
fOk(){ echo "[ OK: $* ]"; }

fVersionCheck(){   ## fVersionCheck BIN NAME VERSION BUILD [RELEASE]
	local bin="$1" want="" got="" digits="0123456789abcdefghjkmnpqrstvwxyz" minutes=0 number="" c i zone
	local -a tzSet=()
	[[ -x "${bin}" ]] || fDie "not an executable: ${bin}"
	[[ -n "${4:-}" ]] || fDie "no build number to check ${bin##*/} against; is the commit time missing?"
	[[ "${4}" =~ ^([0-9a-hjkmnp-tv-z]{1,10})(-dirty)?$ ]] || fDie "not a build number: '${4}'"
	number="${BASH_REMATCH[1]}"
	[[ -z "${BASH_REMATCH[2]}" || "${5:-}" != 1 ]] || fDie "${4} is a dirty build, so it can't be a release"
	for ((i = 0; i < ${#number}; i++)); do
		c="${digits%%"${number:i:1}"*}"
		minutes=$((minutes * 32 + ${#c}))
	done
	## The box's own zone first, then UTC+14 and UTC-12, which never share a
	## date. An empty TZ would be UTC, so the first leaves it alone.
	for zone in '' Pacific/Kiritimati Etc/GMT+12; do
		tzSet=(); [[ -z "${zone}" ]] || tzSet=("TZ=${zone}")
		want="$2 v$3 build $4"
		[[ "${5:-}" == 1 ]] || want+=" ($(env "${tzSet[@]}" date -d "@$((946684800 + minutes * 60))" +%F))"
		got="$(env "${tzSet[@]}" "${bin}" --version 2>&1 || true)"
		got="${got%%$'\n'*}"
		[[ "${got}" == "${want}" ]] || fDie "${bin##*/} says '${got}', not '${want}'${zone:+, with TZ=${zone}}"
		fOk "${bin##*/}: ${got}${zone:+ (TZ=${zone})}"
	done
}

fArchCheck(){   ## fArchCheck STAGE_DIR PREFIX OS-ARCH...
	local dir="$1" prefix="$2" osarch bin desc want
	shift 2
	(($#)) || fDie "arch: no os-arch given"
	for osarch in "$@"; do
		bin="${dir}/${prefix}-${osarch}"
		[[ -f "${bin}" ]] || fDie "no build at ${bin}"
		case "${osarch}" in
			linux-x86_64) want='x86-64' ;;
			linux-arm64)  want='ARM aarch64' ;;
			*) fDie "arch: no rule for ${osarch}" ;;
		esac
		desc="$(file -b -- "${bin}")"
		[[ "${desc}" =~ ^ELF\ 64-bit\ LSB\ (pie\ )?executable,\ ${want}, ]] || fDie "${bin##*/} should be ${want}, but file says: ${desc}"
		fOk "${bin##*/}: ${desc%%, interpreter*}"
	done
}

## The glibc floor and libgcc need off the binary, the same way package.bash
## reads them.
fNeeds(){   ## fNeeds BIN -> "GLIBC LIBGCC(0|1)"
	local glibc="" needed="" gcc=0
	glibc="$(objdump -T "$1" | { grep -o 'GLIBC_[0-9.]*' || true; } | sed 's/GLIBC_//' | sort -uV | tail -1)"
	needed="$(readelf -d "$1" || true)"
	if grep -q 'NEEDED.*libgcc_s' <<<"${needed}"; then gcc=1; fi
	echo "${glibc} ${gcc}"
}

tilde="~"

fDebCheck(){   ## fDebCheck DEB BIN NAME VERSION ARCH GLIBC GCC
	local dver deb="$1" bin="$2" name="$3" ver="$4" arch="$5" glibc="$6" gcc="$7" f got="" list="" deps=""
	[[ -f "${deb}" ]] || fDie "no package at ${deb}"
	dver="${4/-/${tilde}}"   ## a pre-release dash is a tilde in a package version
	for f in "Package|${name}" "Version|${dver}" "Architecture|${arch}"; do
		got="$(dpkg-deb -f "${deb}" "${f%%|*}")"
		[[ "${got}" == "${f#*|}" ]] || fDie "${deb##*/}: ${f%%|*} is '${got}', not '${f#*|}'"
	done
	## Names only, then the binary's mode and owner.
	list="$(dpkg-deb -c "${deb}")"
	got="$(awk '{print $6}' <<<"${list}" | paste -sd ' ')"
	[[ "${got}" == "./usr/ ./usr/bin/ ./usr/bin/${name}" ]] || fDie "${deb##*/} holds '${got}', not ./usr/bin/${name} alone"
	grep -q "^-rwxr-xr-x root/root .* ./usr/bin/${name}\$" <<<"${list}" || fDie "${deb##*/}: /usr/bin/${name} isn't 0755 root:root"
	got="$(dpkg-deb --fsys-tarfile "${deb}" | tar -xOf - "./usr/bin/${name}" | sha256sum)"
	[[ "${got%% *}" == "$(sha256sum < "${bin}" | cut -d' ' -f1)" ]] || fDie "${deb##*/}: /usr/bin/${name} isn't ${bin##*/}"
	deps="$(dpkg-deb -f "${deb}" Depends)"
	[[ "${deps}" == *"libc6 (>= ${glibc})"* ]] || fDie "${deb##*/}: Depends '${deps}' lacks libc6 (>= ${glibc})"
	if ((gcc)) && [[ "${deps}" != *libgcc-s1* ]]; then fDie "${deb##*/}: Depends '${deps}' lacks libgcc-s1"; fi
	if ((! gcc)) && [[ "${deps}" == *libgcc* ]]; then fDie "${deb##*/}: Depends '${deps}' names libgcc, which the binary doesn't link"; fi
	fOk "${deb##*/}: /usr/bin/${name} alone, ${deps}"
}

fRpmCheck(){   ## fRpmCheck RPM BIN NAME VERSION ARCH GLIBC GCC DBDIR
	local dver rpmf="$1" bin="$2" name="$3" ver="$4" arch="$5" glibc="$6" gcc="$7" db="$8" got="" reqs=""
	local -a q=(rpm --dbpath "${db}" -qp)
	dver="${4/-/${tilde}}"
	[[ -f "${rpmf}" ]] || fDie "no package at ${rpmf}"
	got="$("${q[@]}" --qf '%{NAME} %{VERSION} %{ARCH}' "${rpmf}")"
	[[ "${got}" == "${name} ${dver} ${arch}" ]] || fDie "${rpmf##*/} is '${got}', not '${name} ${dver} ${arch}'"
	got="$("${q[@]}" --qf '[%{FILEMODES:perms} %{FILEUSERNAME}:%{FILEGROUPNAME} %{FILENAMES}\n]' "${rpmf}")"
	[[ "${got}" == "-rwxr-xr-x root:root /usr/bin/${name}" ]] || fDie "${rpmf##*/} holds '${got//$'\n'/; }', not /usr/bin/${name} alone at 0755 root:root"
	got="$(rpm2cpio "${rpmf}" | cpio -i --quiet --to-stdout "./usr/bin/${name}" | sha256sum)"
	[[ "${got%% *}" == "$(sha256sum < "${bin}" | cut -d' ' -f1)" ]] || fDie "${rpmf##*/}: /usr/bin/${name} isn't ${bin##*/}"
	reqs="$("${q[@]}" --requires "${rpmf}" | paste -sd ',')"
	[[ ",${reqs}," == *",glibc >= ${glibc},"* ]] || fDie "${rpmf##*/}: Requires '${reqs}' lacks glibc >= ${glibc}"
	if ((gcc)) && [[ ",${reqs}," != *",libgcc_s.so.1()(64bit),"* ]]; then fDie "${rpmf##*/}: Requires '${reqs}' lacks libgcc_s.so.1()(64bit)"; fi
	if ((! gcc)) && [[ "${reqs}" == *libgcc* ]]; then fDie "${rpmf##*/}: Requires '${reqs}' names libgcc, which the binary doesn't link"; fi
	fOk "${rpmf##*/}: /usr/bin/${name} alone, ${reqs}"
}

fPackageCheck(){   ## fPackageCheck STAGE_DIR NAME VERSION WORK_DIR OS-ARCH...
	local dir="$1" name="$2" ver="$3" work="$4" osarch bin debArch rpmArch glibc gcc db
	shift 4
	(($#)) || fDie "package: no os-arch given"
	[[ -d "${work}" ]] || fDie "no work dir: ${work}"
	## rpm wants a database even to read a package file, and the system's
	## isn't ours to open.
	db="${work}/rpmdb"
	mkdir -p -- "${db}"
	for osarch in "$@"; do
		bin="${dir}/${name}-${ver}-${osarch}"
		[[ -f "${bin}" ]] || fDie "no build at ${bin}"
		case "${osarch}" in
			linux-x86_64) debArch=amd64; rpmArch=x86_64 ;;
			linux-arm64)  debArch=arm64; rpmArch=aarch64 ;;
			*) fDie "package: no rule for ${osarch}" ;;
		esac
		read -r glibc gcc <<<"$(fNeeds "${bin}")"
		[[ -n "${glibc}" ]] || fDie "no GLIBC_ symbol version in ${bin}"
		fDebCheck "${bin}.deb" "${bin}" "${name}" "${ver}" "${debArch}" "${glibc}" "${gcc}"
		fRpmCheck "${bin}.rpm" "${bin}" "${name}" "${ver}" "${rpmArch}" "${glibc}" "${gcc}" "${db}"
	done
}

fGlibcCheck(){   ## fGlibcCheck NOTE(0|1) STAGE_DIR PREFIX FLOOR OS-ARCH...
	local noteOnly="$1" dir="$2" prefix="$3" floor="$4" osarch bin glibc gcc newer
	shift 4
	(($#)) || fDie "glibc: no os-arch given"
	[[ "${floor}" =~ ^[0-9]+\.[0-9]+$ ]] || fDie "glibc: '${floor}' isn't a version"
	for osarch in "$@"; do
		bin="${dir}/${prefix}-${osarch}"
		[[ -f "${bin}" ]] || fDie "no build at ${bin}"
		read -r glibc gcc <<<"$(fNeeds "${bin}")"
		[[ -n "${glibc}" ]] || fDie "no GLIBC_ symbol version in ${bin}"
		newer="$(printf '%s\n' "${floor}" "${glibc}" | sort -V | tail -n 1)"
		if [[ "${newer}" == "${floor}" ]]; then
			fOk "${bin##*/}: glibc ${glibc}"
		elif ((noteOnly)); then
			echo "[ NOTE: ${bin##*/} needs glibc ${glibc}, newer than ${floor}, since it was built on the box ]"
		else
			fDie "${bin##*/} needs glibc ${glibc}, newer than ${floor}"
		fi
	done
}

mode="${1:-}"
shift || true
case "${mode}" in
	version) (($# == 4 || $# == 5)) || fDie "usage: version BIN NAME VERSION BUILD [RELEASE]"; fVersionCheck "$@" ;;
	arch)    (($# >= 3)) || fDie "usage: arch STAGE_DIR PREFIX OS-ARCH..."; fArchCheck "$@" ;;
	package) (($# >= 5)) || fDie "usage: package STAGE_DIR NAME VERSION WORK_DIR OS-ARCH..."; fPackageCheck "$@" ;;
	glibc)   (($# >= 4)) || fDie "usage: glibc STAGE_DIR PREFIX FLOOR OS-ARCH..."; fGlibcCheck 0 "$@" ;;
	glibc-note) (($# >= 4)) || fDie "usage: glibc-note STAGE_DIR PREFIX FLOOR OS-ARCH..."; fGlibcCheck 1 "$@" ;;
	*) fDie "usage: check-release.bash version|arch|package|glibc|glibc-note ... (see the header)" ;;
esac


##	History:
##		- 2026-10-23: Created.
##		- 2026-10-23: glibc, for the release image's floor.
##		- 2026-10-23: version checks the date a build between releases shows.
##		- 2026-10-25: glibc-note, for a build on the box.
##		- 2026-10-29: version takes a build number marked -dirty.
