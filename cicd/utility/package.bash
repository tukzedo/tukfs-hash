#!/usr/bin/env bash

#  shellcheck disable=2016  ## 'Expressions don't expand in single quotes.' The ${TUKFS_*} names are nfpm.yaml's, filled by sed.

##	Purpose:
##		- A .deb and an .rpm through nfpm for each Linux binary in the stage
##		  dir, named into the same tukfs-hash-<version>-<os-arch> family, beside
##		  it. The binary is all they hold.
##		- Two builds of one commit give the same bytes: the mtimes inside are
##		  SOURCE_DATE_EPOCH, which the engine sets from the commit.
##		- Writes only into STAGE_DIR and WORK_DIR, and removes nothing. Both are
##		  in the run's temp dir, which cicd.bash removes.
##	Syntax:
##		package.bash STAGE_DIR VERSION WORK_DIR
##		NFPM names the nfpm to run, if it isn't on PATH.
##	History: At bottom of script.

##	Copyright © 2026 t00mietum (CryptogID: ปʬϝღถɔ4რఠΔթะ9ƾǝu)
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


set -Eeuo pipefail

stageDir="${1:?usage: package.bash STAGE_DIR VERSION WORK_DIR}"
ver="${2:?usage: package.bash STAGE_DIR VERSION WORK_DIR}"
workDir="${3:?usage: package.bash STAGE_DIR VERSION WORK_DIR}"
meDir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
nfpm="${NFPM:-nfpm}"

fEcho(){ echo "[ $* ]"; }
fDie(){ echo "package: $*" >&2; exit 1; }

[[ -d "${stageDir}" && -d "${workDir}" ]] || fDie "no such dir: ${stageDir} or ${workDir}"
command -v "${nfpm}" >/dev/null 2>&1 || fDie "nfpm isn't installed (or set NFPM); --no-package skips the packages"
## Not a default from the clock, which would make every build differ.
[[ "${SOURCE_DATE_EPOCH:-}" =~ ^[0-9]{1,15}$ ]] || fDie "SOURCE_DATE_EPOCH isn't set to the commit time"
mtime="$(date -u -d "@${SOURCE_DATE_EPOCH}" +%Y-%m-%dT%H:%M:%SZ)"

## rpm names the soname rather than a package, since distros name the package
## differently.
debGccDep='libgcc-s1'
rpmGccDep='libgcc_s.so.1()(64bit)'

built=0
## "os-arch|nfpm arch". nfpm turns amd64 into x86_64 for the rpm.
for pair in "x86_64|amd64" "arm64|arm64"; do
	osarch="${pair%%|*}"; goarch="${pair#*|}"
	bin="${stageDir}/tukfs-hash-${ver}-linux-${osarch}"
	[[ -f "${bin}" ]] || continue
	glibc="$(objdump -T "${bin}" | { grep -o 'GLIBC_[0-9.]*' || true; } | sed 's/GLIBC_//' | sort -uV | tail -1)"
	[[ -n "${glibc}" ]] || fDie "no GLIBC_ symbol version in ${bin}"
	debGcc=""; rpmGcc=""
	## Into a variable first: a grep -q that quits early kills readelf with
	## SIGPIPE under pipefail.
	needed="$(readelf -d "${bin}" || true)"
	if grep -q 'NEEDED.*libgcc_s' <<<"${needed}"; then debGcc=$'\n      - '"${debGccDep}"; rpmGcc=$'\n      - '"${rpmGccDep}"; fi
	yaml="${workDir}/nfpm-linux-${osarch}.yaml"
	sed -e "s|\${TUKFS_VERSION}|${ver}|g" -e "s|\${TUKFS_ARCH}|${goarch}|g" \
	    -e "s|\${TUKFS_BIN}|${bin}|g" -e "s|\${TUKFS_MTIME}|${mtime}|g" \
	    -e "s|\${TUKFS_GLIBC}|${glibc}|g" -e "s|\${TUKFS_DEB_LIBGCC}|${debGcc//$'\n'/\\n}|g" -e "s|\${TUKFS_RPM_LIBGCC}|${rpmGcc//$'\n'/\\n}|g" \
	    "${meDir}/../packaging/nfpm.yaml" > "${yaml}"
	if grep -q '^[^#]*\${TUKFS_' "${yaml}"; then fDie "nfpm.yaml has a name package.bash doesn't fill"; fi
	for fmt in deb rpm; do
		out="${stageDir}/tukfs-hash-${ver}-linux-${osarch}.${fmt}"
		"${nfpm}" package -f "${yaml}" -p "${fmt}" -t "${out}" >/dev/null || fDie "nfpm failed on ${out##*/}"
		fEcho "OK: package: ${out##*/} ($(stat -c %s -- "${out}") bytes)"
		built=$((built + 1))
	done
done

((built)) || fDie "no Linux binaries in ${stageDir}"


##	History:
##		- 2026-10-23: Created from shcl's package.bash: nfpm only, binary only.
