#!/usr/bin/env bash

#  shellcheck disable=2016  ## 'Expressions don't expand in single quotes.' On purpose: the writer's script expands in its own bash.

##	Purpose:
##		The profiler stage's workload, in a dir cicd.bash made and removes:
##			gen DIR      a tree in DIR/tree of about TUKFS_PROFILE_MB (default
##			             1500) MB, in sizes from empty to 24 MB, with names and
##			             mtimes that vary, hard links, symlinks and a .git, then
##			             synced so a scan's dropped cache reads it from disk.
##			             DIR/db is left for the database.
##			change DIR   what the rescan should find: bytes changed with the
##			             mtime put back, as bad RAM leaves a file, plus files
##			             edited, added, removed and renamed.
##		It writes inside DIR/tree and nowhere else, and removes nothing it
##		didn't make in this run.
##	Syntax:
##		profile-workload.bash gen|change DIR
##		CPU_CAP caps the parallel writers (default half the cores, or a
##		quarter when the box is busy).
##	Exit: 0 = done, 1 = failed, 2 = bad arguments.
##	History: At bottom of script.

##	Copyright © 2026 t00mietum (CryptogID: ปʬϝღถɔ4რఠΔթะ9ƾǝu)
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


set -Eeuo pipefail

fDie(){ echo "profile-workload: $*" >&2; exit 1; }
(($# == 2)) || { echo "profile-workload: takes gen|change DIR (see the header)" >&2; exit 2; }
cmd="$1"; dir="$2"
[[ "${dir}" == /* && -d "${dir}" ]] || { echo "profile-workload: ${dir} isn't a dir" >&2; exit 2; }
tree="${dir}/tree"
source "$(dirname -- "${BASH_SOURCE[0]}")/include/cpu-cap.bash"
fCpuCap

## Same tree every run, so 2 graphs compare.
seed=20261023
fRand(){ seed=$(( (seed * 1103515245 + 12345) % 2147483648 )); }   ## into seed

## Random bytes once, and each file a slice of them behind a header with its
## own name, so no 2 files have the same content and the database keeps each.
fBlock(){
	head -c $((24 * 1048576)) /dev/urandom > "${dir}/block" || fDie "no random block"
}
## fFiles NAME:BYTES lines on stdin, written CPU_CAP at a time.
fFiles(){
	BLOCK="${dir}/block" xargs -d '\n' -P "${CPU_CAP}" -n 16 bash -c '
		for spec in "$@"; do
			f="${spec%:*}"; n="${spec##*:}"
			{ printf "tukfs-hash profile %s\n" "${f}"; head -c "${n}" "${BLOCK}"; } > "${f}" || exit 1
		done' files
}

fGen(){
	local i d n mb mm nn
	local -a specs=() names=()
	mb="${TUKFS_PROFILE_MB:-1500}"
	[[ "${mb}" =~ ^[1-9][0-9]{0,4}$ ]] || fDie "TUKFS_PROFILE_MB=${mb}: not a count of MB"
	[[ ! -e "${tree}" ]] || fDie "${tree} is already there"
	mkdir -p -- "${tree}" "${dir}/db"
	cd -- "${tree}"
	fBlock
	## Photos and music are most of the bytes, as on a real disk: about 55%
	## in 2 to 24 MB, 40% in 1 to 8 MB.
	for ((i = 0; i < mb * 55 / 1300; i++)); do
		fRand; printf -v mm '%02d' $((seed % 12 + 1)); d="photos/$((2014 + seed % 11))/${mm}"
		[[ -d "${d}" ]] || mkdir -p -- "${d}"
		fRand; printf -v nn '%04d' "${i}"; specs+=("${d}/IMG_${nn}.jpg:$(( 2097152 + seed % 23068672 ))")
	done
	for ((i = 0; i < mb * 40 / 450; i++)); do
		d="music/Artist $((i % 7))/Album ($((1990 + i % 30)))"
		[[ -d "${d}" ]] || mkdir -p -- "${d}"
		fRand; printf -v nn '%02d' $((i % 14 + 1)); specs+=("${d}/${nn} - Track number ${i}.flac:$(( 1048576 + seed % 7340032 ))")
	done
	## Documents: 1 KB to 256 KB, with the odd names a scan has to keep.
	names=("notes" "report final (2)" "a.b.c.d" ".hidden" "-starts-with-dash" "trailing space " $'caf\xc3\xa9' $'not utf-8 \xff\xfe' "$(printf 'long%.0s' {1..40})")
	for ((i = 0; i < 500; i++)); do
		d="docs/$((i % 9))/sub $((i % 4))"
		[[ -d "${d}" ]] || mkdir -p -- "${d}"
		fRand; specs+=("${d}/${names[i % ${#names[@]}]} ${i}.txt:$(( 1024 + seed % 261120 ))")
	done
	printf '%s\n' "${specs[@]}" | fFiles || fDie "could not write the big files"
	## Many small files, which is where the walk, the database and the
	## attributes cost the most per byte. Written here, since a process each
	## would take longer than the scan.
	for ((i = 0; i < 2000; i++)); do
		d="mail/$((i % 12))/cur"
		[[ -d "${d}" ]] || mkdir -p -- "${d}"
		printf 'Subject: %d\n\n%0*d\n' "${i}" $((i * 13 % 9000)) "${i}" > "${d}/${i}.b23,S=$((i * 13 % 9000)):2,S"
	done
	## A repo, whose files get no attributes.
	mkdir -p -- src/proj/.git/objects src/proj/lib
	for ((i = 0; i < 400; i++)); do
		printf -v d 'src/proj/.git/objects/%02x' $((i % 256))
		[[ -d "${d}" ]] || mkdir -- "${d}"
		printf 'blob %d\n%0*d\n' "${i}" $((i % 2000)) "${i}" > "${d}/obj${i}"
	done
	for ((i = 0; i < 200; i++)); do printf 'fn f%d() {}\n%0*d\n' "${i}" $((i * 7 % 6000)) "${i}" > "src/proj/lib/m${i}.rs"; done
	mkdir -p -- cache
	for ((i = 0; i < 200; i++)); do : > "cache/empty ${i}"; done
	for ((i = 0; i < 6; i++)); do ln -- "${specs[0]%:*}" "cache/link ${i}.jpg"; done
	ln -s -- ../docs cache/docs-link
	ln -s -- /nonexistent cache/dangling

	## mtimes from 2014 on, 64 of them, a few with nanoseconds.
	mapfile -d '' -t names < <(find . -type f -print0)
	for ((n = 0; n < 64; n++)); do
		local -a batch=()
		for ((i = n; i < ${#names[@]}; i += 64)); do batch+=("${names[i]}"); done
		((${#batch[@]})) || continue
		fRand
		touch -d "@$(( 1388534400 + seed % 370000000 )).$(( seed % 1000000000 ))" -- "${batch[@]}"
	done
	rm -f -- "${dir}/block"
	## Clean pages, so the scan's POSIX_FADV_DONTNEED drops them and it reads
	## the disk, as a real scan does.
	sync -f -- "${tree}"
	echo "profile workload: ${#names[@]} files, $(du -sm -- "${tree}" | cut -f1) MB in ${tree}"
}

## Bytes in the middle of F changed, with its mtime put back.
fFlip(){
	local f="$1" t="" size=0
	t="$(stat -c %y -- "${f}")"; size="$(stat -c %s -- "${f}")"
	printf 'BADRAM!!' | dd of="${f}" bs=1 seek=$((size / 2)) conv=notrunc status=none
	touch -d "${t}" -- "${f}"
}

fChange(){
	local f i
	local -a big=() small=()
	[[ -d "${tree}" ]] || fDie "no tree in ${dir}; run gen first"
	cd -- "${tree}"
	mapfile -t big < <(find photos -type f -name '*.jpg' | sort)
	mapfile -t small < <(find docs -type f -name '*.txt' | sort)
	big=("${big[@]:0:3}"); small=("${small[@]:0:5}")
	((${#big[@]} == 3 && ${#small[@]} == 5)) || fDie "the tree is short of files to change"
	for f in "${big[@]}" "${small[@]}"; do fFlip "${f}"; done
	## Edits and moves, which are no event.
	for f in src/proj/lib/m1{0..9}.rs; do echo "// edited" >> "${f}"; done
	for ((i = 0; i < 20; i++)); do printf 'new %d\n' "${i}" > "docs/0/new ${i}.txt"; done
	rm -f -- src/proj/lib/m2{0..9}.rs
	mv -- "music/Artist 0" "music/Artist zero"
	sync -f -- "${tree}"
	echo "profile workload: 8 files changed with their mtimes put back, and 10 edited, 20 added, 10 removed and 1 folder renamed"
}

case "${cmd}" in
	gen)    fGen ;;
	change) fChange ;;
	*) echo "profile-workload: ${cmd}: not gen or change" >&2; exit 2 ;;
esac


##	History:
##		- 2026-10-23: Created.
##		- 2026-10-25: The writer count from cpu-cap.bash.
