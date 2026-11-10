#!/usr/bin/env bash

##	Purpose: End to end, as a normal user, on a filesystem with user xattrs. No
##		root, and no mounts but step 23's in a user namespace, so mount
##		boundaries are left to `plan` on a real box.
##	Usage: tests/integration.bash [--keep-temp] [BINARY]
##		Works in <HOST_TEMP>/tukfs-hash/<YYYYmmDD-HHMMSS>_<NNN>, or under
##		TMPDIR when HOST_TEMP isn't set, so HOST_TEMP picks the filesystem.
##		It's removed at the end unless --keep-temp, or TUKFS_KEEP_TEMP, says
##		to keep it. Its own folders there whose run is gone are removed
##		first, but a kept one only once it's 2 days old.
##		TUKFS_IT_BTRFS names a folder on btrfs for step 27's subvolume, which
##		then gets a second work folder of the same kind under
##		<TUKFS_IT_BTRFS>/tukfs-hash/. Without it, step 27 runs only when the
##		work folder is on btrfs.
##	History: At bottom of script.

##	Copyright © 2026 t00mietum (CryptogID: ปʬϝღถɔ4რఠΔթะ9ƾǝu)
##	Licensed under GPL-2.0-only. No warranty.
##	SPDX-License-Identifier: GPL-2.0-only

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
keep="${TUKFS_KEEP_TEMP:-}"
if [[ "${1:-}" == --keep-temp ]]; then keep=1; shift; fi
bin="${1:-${here}/target/release/tukfs-hash}"
# Resolved, so fSafeRm can insist the path has no links in it.
base="$(realpath -e -- "${HOST_TEMP:-${TMPDIR:-/tmp}}")/tukfs-hash"
btBase=''
if [[ -n "${TUKFS_IT_BTRFS:-}" ]]; then
	# The folder below it is the one to check, since a sandbox can leave only
	# that one on the disk, over a tmpfs /tmp.
	if btReal="$(realpath -e -- "${TUKFS_IT_BTRFS}" 2> /dev/null)" && mkdir -p -- "${btReal}/tukfs-hash" 2> /dev/null &&
		[[ "$(stat -f -c %T -- "${btReal}/tukfs-hash")" == btrfs ]]; then
		btBase="${btReal}/tukfs-hash"
	else
		echo "TUKFS_IT_BTRFS isn't a folder on btrfs, so step 27 uses the work folder: ${TUKFS_IT_BTRFS}" >&2
	fi
fi
# The exit trap removes it only while the marker has this run's token, so
# a folder this run didn't make is never touched.
token="$$-${RANDOM}${RANDOM}-${EPOCHREALTIME}"
# A TERM to this shell alone leaves its children writing into the folder.
source "${here}/cicd/utility/include/stop-descendants.bash"
# A Ctrl+C reaches a running scan too, which stops and exits on its own, and
# with no trap bash would go on to the next step. A stop that comes between 2
# command substitutions in one word makes bash 5.2 fail to parse the trap,
# and set -e then exits 2, which still cleans up.
fStopOnSignals

# Gives back what a step made unreadable and a stop or kill kept it from
# putting back, so the folder can be removed or looked at. find doesn't follow
# links.
fUnlock() {
	find "${1}" -xdev \( -type d ! -perm -u=rwx -exec chmod u+rwx {} + \) -o \( -type f ! -perm -u=r -exec chmod u+r {} + \) 2> /dev/null || true
}

# rm --one-file-system skips a btrfs subvolume, which has its own device, so
# one left by a stop in step 27 is emptied and removed first. Its own folder
# is always inode 256.
fDropSubvols() {
	local sv=''
	[[ "$(stat -f -c %T -- "${1}" 2> /dev/null)" == btrfs ]] || return 0
	while IFS= read -r -d '' sv; do
		find "${sv}" -xdev -mindepth 1 -delete 2> /dev/null || true
		rmdir -- "${sv}" 2> /dev/null || true
	done < <(find "${1}" -xdev -mindepth 1 -type d -inum 256 -print0 2> /dev/null)
}

# rm -rf, but only on what can only be one of this script's work folders:
# <base>/<stamp>_<NNN>, or the same under btBase, no links, no dots.
fSafeRm() {
	local p="${1:-}" real='' fhs=''
	if [[ -z "${p}" || "${p}" != /* || "${p}" == *..* || "${p}" == *//* || "${p}" == *$'\n'* ]]; then
		printf 'fSafeRm: refused, bad path: "%s"\n' "${p}" >&2; return 1
	fi
	if [[ ( "${p%/*}" != "${base}" && ( -z "${btBase}" || "${p%/*}" != "${btBase}" ) ) || ! "${p##*/}" =~ ^[0-9]{8}-[0-9]{6}_[0-9]{3}$ ]]; then
		printf 'fSafeRm: refused, not a test folder: %s\n' "${p}" >&2; return 1
	fi
	for fhs in / /bin /boot /dev /etc /home /lib /lib64 /media /mnt /opt /proc /root /run /sbin /srv /sys /tmp /usr /var "${HOME:-/}"; do
		if [[ "${p%/}" == "${fhs%/}" ]]; then printf 'fSafeRm: refused, system folder: %s\n' "${p}" >&2; return 1; fi
	done
	real="$(realpath -e -- "${p}")" || { printf 'fSafeRm: refused, not there: %s\n' "${p}" >&2; return 1; }
	if [[ "${real}" != "${p}" || ! -d "${p}" || -L "${p}" ]]; then
		printf 'fSafeRm: refused, a link or not a folder: %s\n' "${p}" >&2; return 1
	fi
	fUnlock "${p}"
	fDropSubvols "${p}"
	# The marks go last, so a removal that fails partway leaves a folder the
	# next run's sweep still knows (2026110210514819).
	find "${p}" -mindepth 1 -maxdepth 1 ! -name run.pid ! -name .test-run ! -name .test-kept -exec rm -rf --one-file-system -- {} + &&
		rm -f -- "${p}/.test-kept" "${p}/run.pid" "${p}/.test-run" && rmdir -- "${p}"
}

# Ours, and its run gone, such as a killed one's. A kept one waits 2 days
# (2026102518150001). A folder with no marker of this script's, such as a
# cicd run's, or another user's, isn't ours.
fSweep() {   ## fSweep BASE
	local old='' pid='' got=''
	mkdir -p -- "${1}"
	while IFS= read -r -d '' old; do
		pid=''; got=''
		read -r pid 2> /dev/null < "${old}/run.pid" || continue
		read -r got 2> /dev/null < "${old}/.test-run" || continue
		[[ "${pid}" =~ ^[0-9]{1,10}$ && "${got}" == "${pid}-"* && ! -d "/proc/${pid}" && -O "${old}" && ! -L "${old}" ]] || continue
		if [[ -e "${old}/.test-kept" && -n "$(find "${old}/.test-kept" -maxdepth 0 -mmin -2880 2> /dev/null)" ]]; then continue; fi
		fSafeRm "${old}" && printf 'removed a stale test folder: %s\n' "${old}"
	done < <(find "${1}" -mindepth 1 -maxdepth 1 -type d -name '[0-9]*_[0-9][0-9][0-9]' -print0 2> /dev/null)
}

# A work folder under BASE, with this run's marks, named in OUT.
fNewWork() {   ## fNewWork BASE OUT
	local -n out_nw="${2}"
	local n=1 stamp=''
	printf -v stamp '%(%Y%m%d-%H%M%S)T' -1
	printf -v out_nw '%s/%s_%03d' "${1}" "${stamp}" "${n}"
	until mkdir -- "${out_nw}" 2> /dev/null; do
		[[ -e "${out_nw}" ]] || { echo "could not make a work folder in ${1}" >&2; exit 2; }
		n=$((n + 1)); [[ "${n}" -lt 1000 ]] || { echo "no free work folder name in ${1}" >&2; exit 2; }
		printf -v out_nw '%s/%s_%03d' "${1}" "${stamp}" "${n}"
	done
	printf '%s\n' "${token}" > "${out_nw}/.test-run"
	printf '%s\n' "$$" > "${out_nw}/run.pid"
	if [[ -n "${keep}" ]]; then : > "${out_nw}/.test-kept"; fi
}

work=''; btWork=''
fSweep "${base}"
if [[ -n "${btBase}" ]]; then fSweep "${btBase}"; fi
fNewWork "${base}" work
export TMPDIR="${work}" TEMP="${work}" TMP="${work}"

fCleanupOne() {
	local w="${1}" got=''
	if [[ -n "${keep}" ]]; then fUnlock "${w}"; : > "${w}/.test-kept" || true; printf 'kept (--keep-temp): %s\n' "${w}"; return 0; fi
	read -r got 2> /dev/null < "${w}/.test-run" || true
	if [[ "${got}" != "${token}" ]]; then printf 'not removed, no marker for this run: %s\n' "${w}" >&2; return 0; fi
	fSafeRm "${w}" || true
}
fCleanup() {
	fStopDescendants
	fCleanupOne "${work}"
	if [[ -n "${btWork}" ]]; then fCleanupOne "${btWork}"; fi
}
trap fCleanup EXIT
if [[ -n "${btBase}" ]]; then fNewWork "${btBase}" btWork; fi
tree="${work}/tree"
db="${work}/db/t.sqlite"
mkdir -p "${tree}" "${work}/db"

# Every check starts with its test ID, and its status line shows it. A new
# one takes its ID from `cicd/utility/test-ids.py new`.
fails=0
fLine() { printf '%s %s %s\n' "${1}" "${2}" "${3}"; }
ok()   { fLine PASS "${1}" "${2}"; }
bad()  { fLine FAIL "${1}" "${2}"; fails=$((fails + 1)); }
skip() { fLine SKIP "${1}" "${2}"; }
# expect ID OK FAIL STATUS, or expect ID OK FAIL COMMAND... A bare false [[ ]]
# trips set -e, so its status is caught first: st=0; [[ ... ]] || st=1
expect() {
	if [[ "${#}" -eq 4 && "${4}" =~ ^[0-9]+$ ]]; then
		if [[ "${4}" == 0 ]]; then ok "${1}" "${2}"; else bad "${1}" "${3}"; fi
	elif "${@:4}"; then ok "${1}" "${2}"; else bad "${1}" "${3}"; fi
}
# fFlipByte FILE OFFSET MASK [COUNT]: xor COUNT bytes (default 1) at OFFSET
# with MASK, then put the times back.
fFlipByte() {
	python3 -I -c '
import os, sys
p, off, mask, n = sys.argv[1], int(sys.argv[2]), int(sys.argv[3], 0), int(sys.argv[4])
st = os.stat(p)
with open(p, "r+b") as f:
	f.seek(off); b = f.read(n)
	f.seek(off); f.write(bytes(x ^ mask for x in b))
os.utime(p, ns=(st.st_atime_ns, st.st_mtime_ns))
' "${1}" "${2}" "${3}" "${4:-1}"
}
check() { if [[ "${3}" == "${4}" ]]; then ok "${1}" "${2}"; else bad "${1}" "${2}: got [${3}], want [${4}]"; fi; }
q() { sqlite3 "${db}" "${1}"; }
scan() { local rc=0; "${bin}" scan --db "${db}" --root "${tree}" --progress 3600 "${@}" > "${work}/out.txt" 2>&1 || rc=$?; echo "${rc}"; }
xget() { getfattr --only-values -n "${2}" "${1}" 2>/dev/null || true; }
tomorrow="$(date -d tomorrow +%Y-%m-%d)"
# Waits up to 10 s for a scan to say it has started, rather than guessing.
# Up to 60 s, since a loaded box has taken more than 10 to get going.
wait_started() {
	local i
	for ((i = 0; i < 1200; i++)); do
		grep -q '^group ' "${1}" 2> /dev/null && return 0
		sleep 0.05
	done
	return 1
}
# wait_reached PID DIR: up to 60 s for a scan to have a file under DIR open.
# Fails at once if it has ended, since a zombie has no fds.
wait_reached() {
	local i
	for ((i = 0; i < 1200; i++)); do
		[[ -e "/proc/${1}/fd/1" ]] || return 1
		[[ -n "$(find "/proc/${1}/fd" -lname "${2}/*" -print -quit 2> /dev/null)" ]] && return 0
		sleep 0.05
	done
	return 1
}

# Varied names, sizes and dates.
: > "${tree}/empty"
printf 'hello\n' > "${tree}/small.txt"
head -c 3000000 /dev/urandom > "${tree}/big.bin"
mkdir -p "${tree}/sub dir" "${tree}/repo/.git/objects" "${tree}/repo/src"
printf 'x' > "${tree}/sub dir/one byte"
printf 'tracked\n' > "${tree}/repo/src/main.c"
printf 'blob\n' > "${tree}/repo/.git/objects/ab"
ln "${tree}/big.bin" "${tree}/sub dir/big-link.bin"
# ZFS with utf8only refuses a name that isn't UTF-8.
odd=0
if printf 'odd\n' 2> /dev/null > "${tree}/$(printf 'caf\xe9')"; then odd=1; fi
touch -d '2020-02-03 04:05:06.123456789' "${tree}/small.txt"
touch -d '2011-01-01 00:00:00' "${tree}/big.bin"

# rmlint-style blake2b on one file, current, and on another, stale.
printf 'rmlint was here\n' > "${tree}/rm.txt"
printf 'rmlint stale\n' > "${tree}/rm-stale.txt"
for f in rm.txt rm-stale.txt; do
	sum="$(b2sum "${tree}/${f}" | cut -d' ' -f1)"
	mt="$(stat -c %.9Y "${tree}/${f}")"
	setfattr -n user.rmlint.blake2b.cksum -v "${sum}" "${tree}/${f}"
	setfattr -n user.rmlint.blake2b.mtime -v "${mt}" "${tree}/${f}"
done
setfattr -n user.rmlint.blake2b.mtime -v "1000.5" "${tree}/rm-stale.txt"

# 1. First pass hashes everything and leaves attributes.
rc="$(scan)"
check ddx0a "first scan exit" "${rc}" 0
check ddx0b "paths recorded" "$(q 'SELECT count(*) FROM paths')" $((9 + odd))
# Counts reads, since a second name can skip through the first's fresh attribute.
check ddx0c "hard link read once" "$(grep -o 'hashed [0-9]*' "${work}/out.txt" | head -1)" "hashed $((8 + odd))"
check ddx0d "empty file digest" "$(xget "${tree}/empty" user.blake3.b64u)" "rxNJufX5oaagQE3qNtzJSZvLJcmtwRK3zJqTyuQfMmI"
check ddx0e "size attribute" "$(xget "${tree}/small.txt" user.blake3.bytes)" 6
check ddx0f "mtime attribute in microseconds" "$(xget "${tree}/small.txt" user.blake3.mtime)" "$(date -d '2020-02-03 04:05:06.123456' +%s)123456"
st=0; [[ -n "$(xget "${tree}/small.txt" user.blake3.date)" ]] || st=1; expect ddx0g "date attribute" "date attribute missing" "${st}"
check ddx0h "no attributes in a git work tree" "$(xget "${tree}/repo/src/main.c" user.blake3.b64u)" ""
check ddx0j "no attributes inside .git" "$(xget "${tree}/repo/.git/objects/ab" user.blake3.b64u)" ""
check ddx0k "git files still recorded" "$(q "SELECT count(*) FROM paths WHERE path LIKE '%/repo/%'")" 2
check ddx0m "non-UTF-8 name stored as blob" "$(q "SELECT count(*) FROM paths WHERE typeof(path) = 'blob'")" "${odd}"
check ddx0n "current rmlint blake2b verified" "$(grep -o 'b2b [0-9]*' "${work}/out.txt" | head -1)" "b2b 1"
check ddx0p "blake2b stored for it" "$(q "SELECT count(*) FROM files WHERE b2b IS NOT NULL")" 1
check ddx0q "nothing outside the root" "$(q "SELECT count(*) FROM paths WHERE CAST(path AS TEXT) NOT LIKE '${tree}/%'")" 0
check ddx0r "no events" "$(q 'SELECT count(*) FROM events')" 0
# Only sudo hands the file to someone else. Without it the owner is always us.
if [[ "$(id -u)" == 0 && "${SUDO_UID:-}" =~ ^[0-9]+$ ]]; then
	check ddx0s "file handed back readable" "$(stat -c %u "${db}")" "${SUDO_UID}"
else
	skip ddx0s "file handed back readable (not run through sudo)"
fi
# A database still in WAL mode has no -wal file after a clean close either.
check ddx0t "database left in rollback mode" "$(q 'PRAGMA journal_mode')" delete

# 2. Same day: nothing read again.
rc="$(scan)"
check ddx0v "second scan exit" "${rc}" 0
check ddx0w "second scan hashed nothing" "$(grep -o 'hashed [0-9]*' "${work}/out.txt" | head -1)" "hashed 0"

# 3. Change bytes, put the time back. All 3 references must notice.
digest_of() { q "SELECT hex(f.b3) FROM paths p JOIN files f ON f.id = p.file_id WHERE p.path = '${1}'"; }
x_before="$(xget "${tree}/big.bin" user.blake3.b64u)"
db_before="$(digest_of "${tree}/big.bin")"
# rm.txt is 16 bytes, so its flip starts half way and runs off the end.
fFlipByte "${tree}/big.bin" 1048592 0x5A 16; fFlipByte "${tree}/rm.txt" 8 0x5A 16
rc="$(scan --since "${tomorrow}")"
check ddx0x "corruption exit code" "${rc}" 4
# big.bin's hard link is held to its own records too.
check ddx0y "xattr mismatch found" "$(q "SELECT group_concat(path, ' ') FROM (SELECT path FROM events WHERE kind = 'b3-xattr-mismatch' ORDER BY path)")" "${tree}/big.bin ${tree}/rm.txt ${tree}/sub dir/big-link.bin"
check ddx0z "database mismatch found" "$(q "SELECT count(*) FROM events WHERE kind = 'b3-db-mismatch'")" 3
check ddx10 "rmlint mismatch found" "$(q "SELECT group_concat(path) FROM events WHERE kind = 'b2b-rmlint-mismatch'")" "${tree}/rm.txt"
"${bin}" report --db "${db}" > "${work}/report.txt"
expect ddx11 "report lists it" "report misses big.bin" grep -q $'^b3-xattr-mismatch\t'"${tree}/big.bin" "${work}/report.txt"
check ddx12 "unchanged attributes keep their digest" "$(xget "${tree}/empty" user.blake3.b64u)" "rxNJufX5oaagQE3qNtzJSZvLJcmtwRK3zJqTyuQfMmI"
# The stored checksums stay, so the next run reports the same again, until
# the files are accepted.
check ddy6p "damaged attribute kept" "$(xget "${tree}/big.bin" user.blake3.b64u)" "${x_before}"
check ddy6q "damaged database row kept" "$(digest_of "${tree}/big.bin")" "${db_before}"
last_run() { q "SELECT count(*) FROM events WHERE run_id = (SELECT max(id) FROM runs) ${1}"; }
rc="$(scan --since "${tomorrow}")"
check ddy6r "reported again on the next run" "${rc} $(last_run "AND kind LIKE '%-mismatch'")" "4 7"
check ddy6s "attribute still kept" "$(xget "${tree}/big.bin" user.blake3.b64u)" "${x_before}"
# The row still has the earlier good read's date, so a plain run would skip.
rc="$(scan)"
check dejdg "reported again on a plain run the same day" "${rc} $(last_run "AND kind LIKE '%-mismatch'")" "4 7"
rc=0; (cd "${tree}" && "${bin}" accept --db "${db}" ./big.bin "sub dir/big-link.bin" rm.txt) > "${work}/accept.txt" 2>&1 || rc=$?
check ddy6t "accept exit" "${rc}" 0
check ddy6v "accept logged" "$(last_run "AND kind = 'accepted'")" 3
expect ddy6w "accept names the other link" "accept output: $(cat "${work}/accept.txt")" grep -q '1 other name' "${work}/accept.txt"
st=0; [[ "$(xget "${tree}/big.bin" user.blake3.b64u)" != "${x_before}" ]] || st=1; expect ddy6x "accept replaced the attribute" "attribute unchanged" "${st}"
check ddy6y "accept dropped rmlint's old checksum" "$(xget "${tree}/rm.txt" user.rmlint.blake2b.cksum)" ""
rc=0; "${bin}" accept --db "${db}" "${tree}/sub dir" "${tree}/small.txt" > /dev/null 2>&1 || rc=$?
check ddy6z "accept of a folder fails" "${rc}" 1
rc="$(scan --since "${tomorrow}")"
check ddy70 "clean after accept" "${rc} $(last_run "")" "0 0"
# A read date later than now never skips, or a wrong clock would hide damage.
ob="${tree}/sub dir/one byte"
q "UPDATE paths SET hashed_us = hashed_us + 31536000000000 WHERE path = '${ob}'"
fFlipByte "${ob}" 0 1
rc="$(scan --since "${tomorrow}")"
check dejdh "future read date: read and reported" "${rc} $(last_run "AND kind = 'b3-db-mismatch'")" "4 1"
rc=0; "${bin}" accept --db "${db}" "${ob}" > /dev/null 2>&1 || rc=$?
check dejdj "future read date: accepted" "${rc} $(scan --since "${tomorrow}")" "0 0"

# 4. A real edit moves the time and is not a mismatch.
sleep 0.01
printf 'edited\n' >> "${tree}/small.txt"
rc="$(scan --since "${tomorrow}")"
check ddx13 "edit is not corruption" "$(q "SELECT count(*) FROM events WHERE run_id = (SELECT max(id) FROM runs) AND path = '${tree}/small.txt'")" 0
check ddx14 "edit updates the size attribute" "$(xget "${tree}/small.txt" user.blake3.bytes)" 13

# 5. Stop part way, then resume. A damaged file in the top folder is read
# before the stop, and the stop and the resumed part both have to say so.
mkdir -p "${tree}/many"
python3 -I -c 'import os,sys; d=sys.argv[1]; [open(os.path.join(d, f"f{i}"), "wb").write(os.urandom(i * 16384)) for i in range(1, 401)]' "${tree}/many"
# Or the scan's first fsync waits for these 1.3 GB to be written out, which
# on btrfs at load 40 took longer than wait_started allows.
sync -f "${tree}/many"
runs_before="$(q 'SELECT count(*) FROM runs')"
fFlipByte "${tree}/rm-stale.txt" 0 1
"${bin}" scan --db "${db}" --root "${tree}" --since "${tomorrow}" --threads "${tree}=1" --progress 3600 > "${work}/stop.txt" 2>&1 &
pid=$!
expect ddx15 "scan started" "scan never started" wait_started "${work}/stop.txt"
# A fixed 0.1 s was sometimes too soon at load 30. The one worker takes files
# before folders, so once it's in many/ it has judged rm-stale.txt.
expect dednm "scan got past the top folder" "scan never opened a file in many/" wait_reached "${pid}" "${tree}/many"
kill -INT "${pid}"
rc=0; wait "${pid}" || rc=$?
# A stop adds 2 to what was found before it.
check ddx16 "stopped exit code, with the damage found" "${rc}" 6
check ddx17 "run marked stopped" "$(q 'SELECT status FROM runs ORDER BY id DESC LIMIT 1')" stopped
part="$(q "SELECT count(*) FROM paths WHERE path LIKE '%/many/%'")"
st=0; [[ "${part}" =~ ^[0-9]+$ && "${part}" -lt 400 ]] || st=1; expect ddx18 "stopped before the end (${part} of 400)" "did not stop early (${part})" "${st}"
rc="$(scan --resume)"
# The damage found before the stop still counts.
check ddx19 "resume exit" "${rc}" 4
check ddx1a "resume didn't report it twice" "$(q "SELECT count(*) FROM events WHERE run_id = (SELECT max(id) FROM runs) AND path = '${tree}/rm-stale.txt'")" 2
expect ddx1b "summary counts the whole run" "summary: $(q 'SELECT summary FROM runs ORDER BY id DESC LIMIT 1')" grep -q 'events in the whole run: b3-db-mismatch 1, b3-xattr-mismatch 1$' <<< "$(q 'SELECT summary FROM runs ORDER BY id DESC LIMIT 1')"
check ddx1c "resume finished the rest" "$(q "SELECT count(*) FROM paths WHERE path LIKE '%/many/%'")" 400
check ddx1d "resume reused the run" "$(q 'SELECT count(*) FROM runs')" "$((runs_before + 1))"
# No match fails the pipeline, which would end the script with no FAIL line.
skipped="$(grep -o 'skipped [0-9]*' "${work}/out.txt" | head -1 | cut -d' ' -f2 || true)"
st=0; [[ "${skipped}" =~ ^[0-9]+$ && "${part}" =~ ^[0-9]+$ && "${skipped}" -ge "${part}" ]] || st=1; expect ddx1e "resume skipped what was done (${skipped})" "resume skipped ${skipped}, want at least ${part}" "${st}"
check ddx1f "every path seen by the run" "$(q 'SELECT count(*) FROM paths WHERE seen_run != (SELECT max(id) FROM runs)')" 0
# The same in a new database, where only the attributes know the damaged file
# and no row says the stopped part reached it (2026102814341415).
"${bin}" scan --db "${work}/db/r5.sqlite" --root "${tree}" --since "${tomorrow}" --threads "${tree}=1" --progress 3600 > "${work}/stop.txt" 2>&1 &
pid=$!
st=0; { wait_started "${work}/stop.txt" && wait_reached "${pid}" "${tree}/many"; } || st=1
expect des7k "new database: scan got past the top folder" "scan never opened a file in many/" "${st}"
kill -INT "${pid}"
rc=0; wait "${pid}" || rc=$?
rc2=0; "${bin}" scan --db "${work}/db/r5.sqlite" --root "${tree}" --resume --progress 3600 > "${work}/out.txt" 2>&1 || rc2=$?
check des7m "new database: resume didn't report it twice" "${rc} ${rc2} $(sqlite3 "${work}/db/r5.sqlite" "SELECT count(*) FROM events WHERE path = '${tree}/rm-stale.txt'")" "6 4 1"

# 6. snapdiff: same size and time, different bytes.
mkdir -p "${work}/old" "${work}/new"
head -c 100000 /dev/urandom > "${work}/old/a"
cp -p "${work}/old/a" "${work}/new/a"
printf 'same\n' > "${work}/old/b"; cp -p "${work}/old/b" "${work}/new/b"
printf 'v1\n' > "${work}/old/c"; printf 'v2 longer\n' > "${work}/new/c"
touch -d '2001-01-01' "${work}/old/c"
fFlipByte "${work}/new/a" 4096 255 16
printf 'a\nb\nc\nmissing\n' > "${work}/list"
rc=0; "${bin}" snapdiff --old "${work}/old" --new "${work}/new" --list "${work}/list" > "${work}/sd.txt" 2> /dev/null || rc=$?
check ddx1g "snapdiff exit" "${rc}" 4
check ddx1h "snapdiff flags only a" "$(cut -f1,2 "${work}/sd.txt")" $'content-changed-same-mtime\ta'
expect ddx1j "snapdiff run detail" "snapdiff detail: $(cat "${work}/sd.txt")" grep -q '16 bytes differ in 1 run(s), 1 starting on a 16-byte boundary: 4096+16' "${work}/sd.txt"

# 7. A second scan of the same database is refused while one runs.
"${bin}" scan --db "${db}" --root "${tree}" --since "${tomorrow}" --threads "${tree}=1" --progress 3600 > "${work}/first.txt" 2>&1 &
pid=$!
expect ddx1k "scan started" "scan never started" wait_started "${work}/first.txt"
rc=0; "${bin}" scan --db "${db}" --root "${tree}" > "${work}/lock.txt" 2>&1 || rc=$?
kill -INT "${pid}" 2> /dev/null || true
wait "${pid}" || true
check ddx1m "second scan refused" "${rc}" 1
expect ddx1n "says why" "lock message: $(cat "${work}/lock.txt")" grep -q 'locked' "${work}/lock.txt"

# 8. Attributes vouch only for the inode that was read. A fresh database each
# time, so only the attributes can skip a file.
xt="${work}/xa"
mkdir -p "${xt}"
for f in a b c d; do head -c $((20000 + ${#f} * 777)) /dev/urandom > "${xt}/${f}"; done
touch -d '2015-05-05 05:05:05.5' "${xt}/a"; touch -d '2019-09-09' "${xt}/c"
xscan() { local rc=0; "${bin}" scan --db "${work}/db/${1}.sqlite" --root "${xt}" --progress 3600 > "${work}/x.txt" 2>&1 || rc=$?; echo "${rc}"; }
check ddy5b "attribute scan exit" "$(xscan x1)" 0
check ddy5c "inode attribute" "$(xget "${xt}/a" user.blake3.inode)" "$(stat -c '%d:%i' "${xt}/a"):$(xget "${xt}/a" user.blake3.b64u)"
check ddy5d "fresh attributes skip" "$(xscan x2) $(grep -o 'hashed [0-9]*' "${work}/x.txt" | head -1)" "0 hashed 0"
# A copy with a flipped byte, a set from before the inode attribute, and a
# date in the future.
cp -a "${xt}/a" "${xt}/a-copy"; fFlipByte "${xt}/a-copy" 100 1
setfattr -x user.blake3.inode "${xt}/b" 2> /dev/null || true; fFlipByte "${xt}/b" 100 1
setfattr -n user.blake3.date -v "$(( ($(date +%s) + 86400 * 365) * 1000000 ))" "${xt}/c"; fFlipByte "${xt}/c" 100 1
check ddy5e "untrusted attributes read again" "$(xscan x3)" 4
check ddy5f "each one is a mismatch" "$(sqlite3 "${work}/db/x3.sqlite" "SELECT group_concat(path, ' ') FROM (SELECT path FROM events WHERE kind = 'b3-xattr-mismatch' ORDER BY path)")" "${xt}/a-copy ${xt}/b ${xt}/c"
check ddy5g "the rest still skip" "$(grep -o 'hashed [0-9]*' "${work}/x.txt" | head -1)" "hashed 3"

# 9. snapdiff refuses or reports input it can't use, rather than checking
# nothing and exiting 0. Each case has a damaged file it should reach.
sd="${work}/sd"
mkdir -p "${sd}/old" "${sd}/new" "${sd}/live"
ln -s "${sd}/live" "${sd}/live-link"
live="$(realpath "${sd}/live")"
head -c 5000 /dev/urandom > "${sd}/old/d"; cp -p "${sd}/old/d" "${sd}/new/d"; fFlipByte "${sd}/new/d" 100 1
sdiff() { local rc=0; "${bin}" snapdiff --old "${sd}/old" --new "${sd}/new" "${@}" > "${sd}/out.txt" 2> "${sd}/err.txt" || rc=$?; echo "${rc}"; }
printf 'M\tF\t%s/d\n' "${live}" > "${sd}/typed"
check ddy61 "zfs diff -F read" "$(sdiff --zfs-diff "${sd}/typed" --mount "${live}") $(cut -f1,2 "${sd}/out.txt")" $'4 content-changed-same-mtime\td'
printf 'M\t%s/d\n' "${live}" > "${sd}/plain"
check ddy62 "--mount through a symlink" "$(sdiff --zfs-diff "${sd}/plain" --mount "${sd}/live-link") $(cut -f2 "${sd}/out.txt")" "4 d"
check ddy63 "lines outside --mount refused" "$(sdiff --zfs-diff "${sd}/plain" --mount "${sd}/old")" 1
expect ddy64 "says which line" "outside message: $(cat "${sd}/err.txt")" grep -q "1 line(s) aren't under --mount.* the first at line 1" "${sd}/err.txt"
printf -- '-\t%s/d\n+\t%s/d\n' "${live}" "${live}" > "${sd}/replaced"
check ddy65 "a replaced file is compared" "$(sdiff --zfs-diff "${sd}/replaced" --mount "${live}") $(cut -f2 "${sd}/out.txt")" "4 d"
printf 'M\t%s/d\nM\t%s/not-there\n' "${live}" "${live}" > "${sd}/gone"
check ddy66 "a file zfs diff names but the snapshot lacks" "$(sdiff --zfs-diff "${sd}/gone" --mount "${live}") $(grep -c '^missing' "${sd}/out.txt")" "12 1"
printf 'what\nM\t%s/d\n' "${live}" > "${sd}/junk"
check ddy67 "a line not understood" "$(sdiff --zfs-diff "${sd}/junk" --mount "${live}")" 12
expect ddy68 "says which line" "junk message: $(cat "${sd}/err.txt")" grep -q '^line 1 not understood: what$' "${sd}/err.txt"
printf '%s/d\n' "${sd}/new" > "${sd}/abs"
check ddy69 "absolute list names refused" "$(sdiff --list "${sd}/abs")" 1
printf 'd\r\n' > "${sd}/crlf"
check ddy6a "nothing compared" "$(sdiff --list "${sd}/crlf")" 8
mkdir -p "${sd}/old/locked" "${sd}/new/locked"
printf 'x\n' > "${sd}/old/locked/f"; cp -p "${sd}/old/locked/f" "${sd}/new/locked/f"
chmod 000 "${sd}/old/locked"
printf 'locked/f\nd\n' > "${sd}/locked"
check ddy6b "a stat error is counted" "$(sdiff --list "${sd}/locked") $(cut -f1,2 "${sd}/out.txt" | sort | tr '\n' ' ')" $'12 content-changed-same-mtime\td stat-error\tlocked/f '
chmod 755 "${sd}/old/locked"
# btrfs find-new names a renamed file by its new name only. The same inode
# under 2 names stands in for 2 snapshots.
ln "${sd}/old/d" "${sd}/old/before"
ln "${sd}/old/d" "${sd}/new/after"
printf 'inode %s file offset 0 len 4096 disk start 0 offset 0 gen 9 flags NONE after\ntransid marker was 12\n' "$(stat -c %i "${sd}/new/after")" > "${sd}/renamed"
check ddy6c "a renamed file found by inode" "$(sdiff --find-new "${sd}/renamed" --all) $(cut -f1,2 "${sd}/out.txt")" $'0 same\tafter'
# A long list takes no more memory than a short one, since each file is
# compared as it's read. Peak RSS from GNU time, since a child forked from
# python3 keeps python's high-water mark of about 12 MB through the exec, and
# snapdiff takes about 2.5. 100,000 names, all different, every 10th a file
# on both sides, against 1 line. 10 bytes kept per line fails it.
mem="${sd}/mem"; mkdir -p "${mem}/old" "${mem}/new"
head -c 3000 /dev/urandom > "${mem}/old/kept"; cp -p "${mem}/old/kept" "${mem}/new/kept"
printf 'kept\n' > "${mem}/short"
python3 -I -c '
import os, sys
d = sys.argv[1]
os.mkdir(d + "/old/many"); os.mkdir(d + "/new/many")
with open(d + "/long", "w") as f:
	for i in range(100000):
		name = "many/%d" % i
		if i % 10 == 0:
			open(d + "/old/" + name, "w").close()
			os.link(d + "/old/" + name, d + "/new/" + name)
		f.write(name + "\n")
' "${mem}"
# Exit status and peak KB. GNU time puts a line before them on a non-zero exit.
peak() { /usr/bin/time -o "${mem}/peak" -f '%x %M' "${bin}" snapdiff --old "${mem}/old" --new "${mem}/new" --list "${1}" > /dev/null 2>&1 || true; tail -n 1 "${mem}/peak" 2> /dev/null; }
if [[ -x /usr/bin/time ]] && /usr/bin/time -o "${mem}/peak" -f '%M' true 2> /dev/null && [[ "$(cat "${mem}/peak")" =~ ^[0-9]+$ ]]; then
	rcShort='' kbShort='' rcLong='' kbLong=''
	read -r rcShort kbShort < <(peak "${mem}/short") || true
	read -r rcLong kbLong < <(peak "${mem}/long") || true
	st=1; [[ "${rcShort} ${rcLong}" == "0 0" && "${kbShort}" =~ ^[0-9]+$ && "${kbLong}" =~ ^[0-9]+$ ]] && (( kbLong - kbShort < 1024 )) && st=0
	expect df0pq "a long list costs no more memory" "100,000 lines: exit ${rcLong}, ${kbLong} KB, against ${kbShort} KB for 1, want under 1 MB more" "${st}"
else
	skip df0pq "a long list costs no more memory (no GNU time at /usr/bin/time)"
fi

# 10. Names that aren't plain text: arguments are taken, and output escapes
# them so 2 names never print the same.
rc=0; "${bin}" snapdiff --old "${sd}/$(printf 'x\xff')" --new "${sd}/new" --list "${sd}/abs" > /dev/null 2> "${sd}/err.txt" || rc=$?
# ZFS with utf8only says EILSEQ rather than ENOENT.
check ddy6d "non-UTF-8 argument" "${rc} $(sed 's/: [^:]*$//' "${sd}/err.txt")" "1 tukfs-hash: ${sd}/x\\xff"
tab="$(printf 't\tab')"
head -c 3000 /dev/urandom > "${sd}/old/${tab}"; cp -p "${sd}/old/${tab}" "${sd}/new/${tab}"; fFlipByte "${sd}/new/${tab}" 100 1
names="${tab}"
if [[ "${odd}" == 1 ]]; then
	head -c 3000 /dev/urandom > "${sd}/old/$(printf 'caf\xe9')"; cp -p "${sd}/old/$(printf 'caf\xe9')" "${sd}/new/"; fFlipByte "${sd}/new/$(printf 'caf\xe9')" 100 1
	names+=$'\n'"$(printf 'caf\xe9')"
fi
printf '%s\n' "${names}" > "${sd}/names"
want='t\x09ab'; [[ "${odd}" == 1 ]] && want+=$'\ncaf\\xe9'
check ddy6e "snapdiff escapes names" "$(sdiff --list "${sd}/names") $(cut -f2 "${sd}/out.txt")" "4 ${want}"
rt="${work}/rt"; mkdir -p "${rt}"
head -c 3000 /dev/urandom > "${rt}/${tab}"
"${bin}" scan --db "${work}/db/rt.sqlite" --root "${rt}" --no-xattrs --progress 3600 > /dev/null 2>&1 || true
fFlipByte "${rt}/${tab}" 100 1
"${bin}" scan --db "${work}/db/rt.sqlite" --root "${rt}" --no-xattrs --since "${tomorrow}" --progress 3600 > /dev/null 2>&1 || true
"${bin}" report --db "${work}/db/rt.sqlite" > "${work}/report2.txt"
check ddy6f "report escapes names" "$(grep -c "^b3-db-mismatch"$'\t'"${rt}/t\\\\x09ab"$'\t' "${work}/report2.txt")" 1

# 11. Each name of a hard-linked file is held to its own row, with no
# attributes to fall back on.
hl="${work}/hl"; mkdir -p "${hl}"
head -c 50000 /dev/urandom > "${hl}/b_old"
hscan() { local rc=0; "${bin}" scan --db "${work}/db/${1}.sqlite" --root "${hl}" --threads "${hl}=1" --progress 3600 "${@:2}" > "${work}/hl.txt" 2>&1 || rc=$?; echo "${rc}"; }
hq() { sqlite3 "${work}/db/${1}.sqlite" "${2}"; }
check ddy71 "linked file first scan" "$(hscan hl --no-xattrs)" 0
ln "${hl}/b_old" "${hl}/a_new"
fFlipByte "${hl}/b_old" 100 1
check ddy72 "other name compared with its own row" "$(hscan hl --no-xattrs --since "${tomorrow}") $(hq hl "SELECT group_concat(kind || ' ' || path) FROM events")" "4 b3-db-mismatch ${hl}/b_old"
# A fresh set left through one name doesn't vouch for the other. The set's
# digest is the damaged one, as nemo-anywhere would write after the damage,
# and the row is from an earlier day.
rm -f "${hl}/a_new"
head -c 50000 /dev/urandom > "${hl}/b_old"
check ddy73 "linked file first scan, again" "$(hscan hl2 --no-xattrs)" 0
hq hl2 "UPDATE paths SET hashed_us = hashed_us - 172800000000"
fFlipByte "${hl}/b_old" 100 1
mkdir -p "${work}/hlc"; cp -p "${hl}/b_old" "${work}/hlc/x"
"${bin}" scan --db "${work}/db/hlc.sqlite" --root "${work}/hlc" --progress 3600 > /dev/null 2>&1 || true
# Quoted, or a digest starting 0s or 0x is decoded by setfattr.
setfattr -n user.blake3.b64u -v "\"$(xget "${work}/hlc/x" user.blake3.b64u)\"" "${hl}/b_old"
setfattr -n user.blake3.bytes -v 50000 "${hl}/b_old"
setfattr -n user.blake3.mtime -v "$(stat -c %.6Y "${hl}/b_old" | tr -d .)" "${hl}/b_old"
ln "${hl}/b_old" "${hl}/a_new"
check ddy74 "a fresh set from the other name" "$(hscan hl2) $(hq hl2 "SELECT group_concat(kind || ' ' || path) FROM events")" "4 b3-db-mismatch ${hl}/b_old"

# 12. A row the database can't read is an error, not "no record", and is
# left as it was.
lk="${work}/lk"; mkdir -p "${lk}"
printf 'one\n' > "${lk}/f"; printf 'two two\n' > "${lk}/g"
"${bin}" scan --db "${work}/db/lk.sqlite" --root "${lk}" --no-xattrs --progress 3600 > /dev/null 2>&1 || true
sqlite3 "${work}/db/lk.sqlite" "UPDATE paths SET bytes = 'junk' WHERE path = '${lk}/f'"
"${bin}" scan --db "${work}/db/lk.sqlite" --root "${lk}" --no-xattrs --since "${tomorrow}" --progress 3600 > /dev/null 2>&1 || true
check ddy75 "unreadable row reported" "$(sqlite3 "${work}/db/lk.sqlite" "SELECT group_concat(kind || ' ' || path) FROM events")" "db-error ${lk}/f"
check ddy76 "unreadable row left alone" "$(sqlite3 "${work}/db/lk.sqlite" "SELECT bytes FROM paths WHERE path = '${lk}/f'")" junk
rc=0; "${bin}" scan --db "${work}/db/lk.sqlite" --root "${lk}" --no-xattrs --since "${tomorrow}" --progress 3600 > /dev/null 2>&1 || rc=$?
check ddy77 "unreadable row exits 8" "${rc}" 8

# 13. A folder or file that can't be read is reported and exits 8, or 12
# with a mismatch too.
ud="${work}/ud"; mkdir -p "${ud}/locked" "${ud}/open"
printf 'a\n' > "${ud}/open/a"; printf 'b\n' > "${ud}/locked/b"; printf 'c\n' > "${ud}/open/c"
uscan() { local rc=0; "${bin}" scan --db "${work}/db/ud.sqlite" --root "${ud}" --no-xattrs --progress 3600 "${@}" > "${work}/ud.txt" 2>&1 || rc=$?; echo "${rc}"; }
uq() { sqlite3 "${work}/db/ud.sqlite" "${1}"; }
check ddy7a "readable tree" "$(uscan)" 0
chmod 000 "${ud}/locked" "${ud}/open/c"
check ddy7b "unreadable folder and file" "$(uscan --since "${tomorrow}") $(uq "SELECT group_concat(kind || ' ' || path, ', ') FROM (SELECT kind, path FROM events WHERE run_id = (SELECT max(id) FROM runs) ORDER BY path)")" "8 dir-error ${ud}/locked, open-error ${ud}/open/c"
fFlipByte "${ud}/open/a" 0 1
rc="$(uscan --since "${tomorrow}")"
chmod 755 "${ud}/locked"; chmod 644 "${ud}/open/c"
check ddy7c "and a mismatch" "${rc}" 12

# 14. --resume takes only the newest scan, only if it didn't finish, and only
# over the same roots.
rs="${work}/rs"; mkdir -p "${rs}/x" "${rs}/y"
printf 'x\n' > "${rs}/x/f"; printf 'y\n' > "${rs}/y/f"
rscan() { local rc=0; "${bin}" scan --db "${work}/db/rs.sqlite" --no-xattrs --progress 3600 "${@}" > "${work}/rs.txt" 2>&1 || rc=$?; echo "${rc}"; }
rq() { sqlite3 "${work}/db/rs.sqlite" "${1}"; }
newest="(SELECT max(id) FROM runs WHERE status != 'accept')"
rscan --root "${rs}/x" > /dev/null
rq "UPDATE runs SET status = 'stopped'"
rscan --root "${rs}/x" > /dev/null
check ddy7d "an older stopped run isn't resumed" "$(rscan --root "${rs}/x" --resume) $(rq "SELECT count(*) FROM runs WHERE status = 'stopped'")" "1 1"
expect ddy7e "says why" "message: $(cat "${work}/rs.txt")" grep -q 'finished' "${work}/rs.txt"
rq "UPDATE runs SET status = 'stopped' WHERE id = ${newest}"
check ddy7f "other roots refused" "$(rscan --root "${rs}/y" --resume)" 1
expect ddy7g "says which" "message: $(cat "${work}/rs.txt")" grep -q "other roots (not given now: ${rs}/x; not in that run: ${rs}/y)" "${work}/rs.txt"
n="$(rq 'SELECT count(*) FROM runs')"
check ddy7h "same roots resumed" "$(rscan --root "${rs}/x" --resume) $(rq "SELECT status FROM runs WHERE id = ${newest}") $(rq 'SELECT count(*) FROM runs')" "0 done ${n}"
# A run killed hard is still marked running. Resume takes it; a new run
# marks it killed.
rq "UPDATE runs SET status = 'running' WHERE id = ${newest}"
check ddy7j "a killed run resumed" "$(rscan --root "${rs}/x" --resume) $(rq "SELECT status FROM runs WHERE id = ${newest}")" "0 done"
rq "UPDATE runs SET status = 'running' WHERE id = ${newest}"
killed="$(rq "SELECT max(id) FROM runs")"
check ddy7k "a new run marks it killed" "$(rscan --root "${rs}/x") $(rq "SELECT status FROM runs WHERE id = ${killed}")" "0 killed"
# accept's own runs don't hide a stopped scan.
rq "UPDATE runs SET status = 'stopped' WHERE id = ${newest}"
rc=0; "${bin}" accept --db "${work}/db/rs.sqlite" "${rs}/x/f" > /dev/null 2>&1 || rc=$?
expect ddy7m "accept after a stopped scan" "accept failed" "${rc}"
check ddy7n "resumed past an accept" "$(rscan --root "${rs}/x" --resume) $(rq "SELECT status FROM runs WHERE id = ${newest}")" "0 done"

# 15. Something else with the database open doesn't cost the result. It stays
# in WAL mode until a run finds it free.
wl="${work}/wl"; mkdir -p "${wl}"; printf 'w\n' > "${wl}/f"
wdb="${work}/db/wl.sqlite"
wscan() { local rc=0; "${bin}" scan --db "${wdb}" --root "${wl}" --no-xattrs --progress 3600 "${@}" > "${work}/wl.txt" 2>&1 || rc=$?; echo "${rc}"; }
wscan > /dev/null
sqlite3 "${wdb}" 'PRAGMA journal_mode=WAL' > /dev/null
python3 -I -c 'import sqlite3,sys,time; c=sqlite3.connect(sys.argv[1]); c.execute("SELECT count(*) FROM runs").fetchall(); print("open", flush=True); time.sleep(120)' "${wdb}" > "${work}/holder.txt" &
holder=$!
for ((i = 0; i < 200; i++)); do grep -q open "${work}/holder.txt" && break; sleep 0.05; done
fFlipByte "${wl}/f" 0 1
rc="$(wscan --since "${tomorrow}")"
kill "${holder}"; wait "${holder}" 2> /dev/null || true
check ddy8h "held open: exit" "${rc}" 4
expect ddy8j "held open: summary" "output: $(cat "${work}/wl.txt")" grep -q '^events in the whole run: b3-db-mismatch 1$' "${work}/wl.txt"
expect ddy8k "held open: warns" "output: $(cat "${work}/wl.txt")" grep -q 'left in WAL mode' "${work}/wl.txt"
check ddy8m "held open: run recorded" "$(sqlite3 "${wdb}" 'SELECT status FROM runs ORDER BY id DESC LIMIT 1')" "done"
check ddy8n "free again: back in rollback mode" "$(wscan --since "${tomorrow}") $(sqlite3 "${wdb}" 'PRAGMA journal_mode')" "4 delete"

# 16. A row the database refuses doesn't take the events with it. The run
# stops, is marked failed, and can be resumed.
wf="${work}/wf"; mkdir -p "${wf}"
printf 'one\n' > "${wf}/a"; printf 'two\n' > "${wf}/b"
fdb="${work}/db/wf.sqlite"
fscan() { local rc=0; "${bin}" scan --db "${fdb}" --root "${wf}" --no-xattrs --progress 3600 "${@}" > "${work}/wf.txt" 2>&1 || rc=$?; echo "${rc}"; }
fq() { sqlite3 "${fdb}" "${1}"; }
fqSchema() { sqlite3 -cmd '.dbconfig defensive off' "${fdb}" "PRAGMA writable_schema = ON; ${1}" > /dev/null; }
fscan > /dev/null
fFlipByte "${wf}/a" 0 1
sleep 0.01; printf 'two, edited\n' > "${wf}/b"
# A trigger would be refused when the database opens, so it's a CHECK the
# rows already there pass. b's new content is 12 bytes.
fqSchema "UPDATE sqlite_schema SET sql = substr(sql, 1, length(sql) - 1) || ', CONSTRAINT refused_by_the_test CHECK (bytes < 10))' WHERE name = 'files';"
check ddy8p "a refused row fails the run" "$(fscan --since "${tomorrow}") $(fq 'SELECT status FROM runs ORDER BY id DESC LIMIT 1')" "1 failed"
check ddy8q "its events kept" "$(fq "SELECT group_concat(kind || ' ' || path) FROM events WHERE run_id = (SELECT max(id) FROM runs)")" "b3-db-mismatch ${wf}/a"
expect ddy8r "summary kept" "summary: $(fq 'SELECT summary FROM runs ORDER BY id DESC LIMIT 1')" grep -q 'events in the whole run: b3-db-mismatch 1$' <<< "$(fq 'SELECT summary FROM runs ORDER BY id DESC LIMIT 1')"
expect ddy8s "says why" "output: $(cat "${work}/wf.txt")" grep -q 'refused_by_the_test' "${work}/wf.txt"
check ddy8t "failed run left in rollback mode" "$(fq 'PRAGMA journal_mode')" delete
fqSchema "UPDATE sqlite_schema SET sql = replace(sql, ', CONSTRAINT refused_by_the_test CHECK (bytes < 10))', ')') WHERE name = 'files';"
check ddy8v "a failed run resumed" "$(fscan --resume) $(fq 'SELECT status FROM runs ORDER BY id DESC LIMIT 1') $(fq 'SELECT count(*) FROM runs')" "4 done 2"
check ddy8w "and the refused row taken" "$(fq "SELECT count(*) FROM paths p JOIN files f ON f.id = p.file_id WHERE p.path = '${wf}/b' AND f.bytes = 12")" 1
fq "CREATE TRIGGER planted AFTER INSERT ON runs BEGIN SELECT 1; END;"
check des6w "a planted trigger refused" "$(fscan) $(grep -c 'has trigger "planted"' "${work}/wf.txt")" "1 1"
fq "DROP TRIGGER planted"

# 17. --verify reads every file with a stored checksum again, even the same
# day, and nothing else. It leaves no attributes and records no new files.
vt="${work}/vt"; mkdir -p "${vt}"
head -c 40000 /dev/urandom > "${vt}/k1"; head -c 70000 /dev/urandom > "${vt}/k2"; printf 'edit me\n' > "${vt}/k3"
touch -d '2018-08-08 08:08:08.25' "${vt}/k1"
vdb="${work}/db/vt.sqlite"
vscan() { local rc=0; "${bin}" scan --db "${vdb}" --root "${vt}" --progress 3600 "${@}" > "${work}/vt.txt" 2>&1 || rc=$?; echo "${rc}"; }
vq() { sqlite3 "${vdb}" "${1}"; }
check ddy9g "verify: first scan" "$(vscan)" 0
check ddy9h "verify: known files read the same day" "$(vscan --verify) $(grep -o 'hashed [0-9]*' "${work}/vt.txt" | head -1)" "0 hashed 3"
printf 'new\n' > "${vt}/n1"
sleep 0.01; printf 'edited\n' >> "${vt}/k3"
fFlipByte "${vt}/k2" 0 1
k1c="$(stat -c %z "${vt}/k1")"
check ddy9j "verify: exit and reads" "$(vscan --verify) $(grep -o 'hashed [0-9]*' "${work}/vt.txt" | head -1)" "4 hashed 2"
check ddy9k "verify: only the damaged file flagged" "$(vq "SELECT group_concat(kind || ' ' || path, ', ') FROM (SELECT kind, path FROM events WHERE run_id = (SELECT max(id) FROM runs) ORDER BY kind)")" "b3-db-mismatch ${vt}/k2, b3-xattr-mismatch ${vt}/k2"
check ddy9m "verify: new file not recorded" "$(vq "SELECT count(*) FROM paths WHERE path = '${vt}/n1'")" 0
check df1rm "verify: no attributes on a new file" "$(getfattr -d -m '^user\.(blake3|rmlint)\.' --absolute-names "${vt}/n1" 2> /dev/null || true)" ""
check ddy9n "verify: no attribute written" "$(stat -c %z "${vt}/k1")" "${k1c}"
check ddy9p "verify: edited file's row left for the next scan" "$(vq "SELECT bytes FROM paths WHERE path = '${vt}/k3'")" 8
check ddy9q "verify: every known name seen" "$(vq 'SELECT count(*) FROM paths WHERE seen_run != (SELECT max(id) FROM runs)')" 0
check ddy9r "verify: --since refused" "$(vscan --verify --since "${tomorrow}")" 1
# --resume keeps the run's mode.
vq "UPDATE runs SET status = 'stopped' WHERE id = (SELECT max(id) FROM runs)"
check ddy9s "verify: resumed as a full scan refused" "$(vscan --resume)" 1
expect ddy9t "says why" "message: $(cat "${work}/vt.txt")" grep -q 'was a --verify run' "${work}/vt.txt"
check ddy9v "verify: resumed" "$(vscan --verify --resume) $(grep -o 'hashed [0-9]*' "${work}/vt.txt" | head -1) $(vq 'SELECT status FROM runs ORDER BY id DESC LIMIT 1')" "4 hashed 0 done"
check ddy9w "verify: then a full scan" "$(vscan --since "${tomorrow}") $(vq "SELECT count(*) FROM paths WHERE path = '${vt}/n1'")" "4 1"
vq "UPDATE runs SET status = 'stopped' WHERE id = (SELECT max(id) FROM runs)"
check ddy9x "verify: a full scan resumed as a verify refused" "$(vscan --verify --resume)" 1
expect ddy9y "says why" "message: $(cat "${work}/vt.txt")" grep -q 'was a full scan' "${work}/vt.txt"
check ddy9z "verify: runs says which" "$("${bin}" runs --db "${vdb}" | grep -c ', verify$')" 2

# 18. gone lists names a finished scan didn't see, and only those it would
# have reached.
gd="${work}/gd"; mkdir -p "${gd}/a/sub" "${gd}/a/dlock" "${gd}/b"
for f in a/keep a/del a/locked a/sub/deep a/dlock/f b/other; do printf '%s\n' "${f}" > "${gd}/${f}"; done
gdb="${work}/db/gd.sqlite"
gscan() { local rc=0; "${bin}" scan --db "${gdb}" --no-xattrs --progress 3600 "${@}" > "${work}/gd.txt" 2>&1 || rc=$?; echo "${rc}"; }
gone() { local rc=0; "${bin}" gone --db "${gdb}" "${@}" > "${work}/gone.txt" 2>&1 || rc=$?; echo "${rc}"; }
gq() { sqlite3 "${gdb}" "${1}"; }
gscan --root "${gd}/a" > /dev/null
gscan --root "${gd}/b" > /dev/null
# A deeper root, standing in for a mount that the walk from a/ stops at.
gscan --root "${gd}/a/sub" > /dev/null
rm -f -- "${gd}/a/del"
chmod 000 "${gd}/a/locked" "${gd}/a/dlock"
check ddya0 "gone: scan with an unreadable file and folder" "$(gscan --root "${gd}/a" --exclude "${gd}/a/sub" --since "${tomorrow}")" 8
chmod 755 "${gd}/a/dlock"; chmod 644 "${gd}/a/locked"
check ddya1 "gone: exit" "$(gone)" 0
check ddya2 "gone: only the deleted name" "$(grep -c '^gone' "${work}/gone.txt") $(grep '^gone' "${work}/gone.txt" | cut -f2)" "1 ${gd}/a/del"
expect ddya3 "gone: says what it didn't count" "output: $(cat "${work}/gone.txt")" grep -q 'not counted: names under 1 folder' "${work}/gone.txt"
last="$(gq 'SELECT max(id) FROM runs')"
gq "UPDATE runs SET status = 'stopped' WHERE id = ${last}"
check ddya4 "gone: a stopped run refused" "$(gone --run "${last}")" 1
check ddya5 "gone: the newest finished run by default" "$(gone) $(head -1 "${work}/gone.txt") $(grep -c '^gone' "${work}/gone.txt")" "0 run $((last - 1)) 0"
# A typo or a run that isn't there is an error rather than an empty list.
rep() { local rc=0; "${bin}" report --db "${gdb}" "${@}" > "${work}/rep.txt" 2>&1 || rc=$?; echo "${rc}"; }
check dehzs "report: an unknown kind refused" "$(rep --kind read-eror) $(grep -c 'unknown kind read-eror; kinds are b3-xattr-mismatch' "${work}/rep.txt") $(rep --kind dir-error)" "1 1 0"
check dehzt "report and gone: an unknown run refused" "$(rep --run 999) $(grep -c '^tukfs-hash: no run 999$' "${work}/rep.txt") $(gone --run 999)" "1 1 1"
check dehzv "report and gone: a negative limit refused" "$(rep --limit -1) $(gone --limit -1) $(rep --limit 0) $(grep -c $'^dir-error\t' "${work}/rep.txt")" "1 1 0 0"
# Lines cut at the limit are counted (2026102814341433).
nEv="$(gq "SELECT count(*) FROM events WHERE run_id = ${last}")"
check desgc "report: says how many the limit left off" "$(rep --run "${last}" --limit 1) $(grep -c "^$((nEv - 1)) more not shown, raise --limit to see them$" "${work}/rep.txt" || true)" "0 1"

# 19. prune removes only contents no name points at.
orphans="$(q 'SELECT count(*) FROM files WHERE id NOT IN (SELECT file_id FROM paths)')"
paths_before="$(q 'SELECT count(*) FROM paths')"
st=0; [[ "${orphans}" =~ ^[0-9]+$ && "${orphans}" -gt 0 ]] || st=1; expect ddya6 "prune: edits left contents behind (${orphans})" "nothing to prune" "${st}"
rc=0; "${bin}" prune --db "${db}" > "${work}/prune.txt" 2>&1 || rc=$?
check ddya7 "prune: exit and count" "${rc} $(cat "${work}/prune.txt")" "0 removed ${orphans} content(s) no name points at"
check ddya8 "prune: none left, every name kept" "$(q 'SELECT count(*) FROM files WHERE id NOT IN (SELECT file_id FROM paths)') $(q 'SELECT count(*) FROM paths p JOIN files f ON f.id = p.file_id')" "0 ${paths_before}"

# 20. --rmlint takes blake2b from the same read for every file, and writes
# rmlint's set where it's missing or stale, the same bytes rmlint would.
rd="${work}/rd"; mkdir -p "${rd}/repo/.git"
printf 'one\n' > "${rd}/one"; printf 'two\n' > "${rd}/two"; printf 'git\n' > "${rd}/repo/g"
touch -d '2021-05-06 07:08:09.123456789' "${rd}/one"
touch -d '1999-01-01 00:00:00' "${rd}/two"
setfattr -n user.rmlint.blake2b.cksum -v "$(b2sum "${rd}/one" | cut -d' ' -f1)" "${rd}/two"
setfattr -n user.rmlint.blake2b.mtime -v 1000.5 "${rd}/two"
rdb="${work}/db/rd.sqlite"
rdscan() { local rc=0; "${bin}" scan --db "${rdb}" --root "${rd}" --progress 3600 --since "${tomorrow}" "${@}" > "${work}/rd.txt" 2>&1 || rc=$?; echo "${rc}"; }
# Empty for a missing attribute, as xget is, so a check fails rather than the script.
xhex() { { getfattr --only-values -n "${2}" "${1}" 2>/dev/null || true; } | od -An -tx1 | tr -d ' \n'; }
b2bhex() { printf '%s' "$(b2sum "${1}" | cut -d' ' -f1)" | od -An -tx1 | tr -d ' \n'; echo 00; }
check de5g2 "rmlint: plain scan" "$(rdscan)" 0
check de5g3 "rmlint: none written without the flag" "$(xget "${rd}/one" user.rmlint.blake2b.mtime)" ""
check de5g4 "rmlint: none in the database either" "$(sqlite3 "${rdb}" 'SELECT count(*) FROM files WHERE b2b IS NOT NULL')" 0
check de5g5 "rmlint: flagged scan" "$(rdscan --rmlint)" 0
check de5g6 "rmlint: checksum with its NUL" "$(xhex "${rd}/one" user.rmlint.blake2b.cksum)" "$(b2bhex "${rd}/one")"
check de5g7 "rmlint: time as rmlint writes it" "$(xget "${rd}/one" user.rmlint.blake2b.mtime)" "1620310089.1234567"
check de5g8 "rmlint: stale set replaced" "$(xhex "${rd}/two" user.rmlint.blake2b.cksum) $(xget "${rd}/two" user.rmlint.blake2b.mtime)" "$(b2bhex "${rd}/two") 915177600"
check de5g9 "rmlint: none in a git work tree" "$(xget "${rd}/repo/g" user.rmlint.blake2b.mtime)" ""
check de5ga "rmlint: every file's blake2b stored" "$(sqlite3 "${rdb}" 'SELECT count(*) FROM files WHERE b2b IS NOT NULL')" 3
check de5gb "rmlint: counted" "$(grep -o 'rmlint [0-9]*' "${work}/rd.txt" | head -1)" "rmlint 2"
check de5gc "rmlint: next scan verifies them" "$(rdscan --rmlint) $(grep -o 'b2b [0-9]*' "${work}/rd.txt" | head -1) $(grep -o 'rmlint [0-9]*' "${work}/rd.txt" | head -1)" "0 b2b 2 rmlint 0"
if command -v rmlint > /dev/null; then
	# rmlint hashes only files that share a size, so a pair.
	rp="${work}/rp"; mkdir -p "${rp}"
	printf 'pair\n' > "${rp}/a"; cp "${rp}/a" "${rp}/b"
	touch -d '2024-01-01 00:00:00.351000100' "${rp}/a" "${rp}/b"
	(cd "${rp}" && env -u DISPLAY rmlint -a blake2b --xattr -o summary:/dev/null "${rp}" > /dev/null 2>&1) || true
	theirs="$(xhex "${rp}/a" user.rmlint.blake2b.cksum) $(xhex "${rp}/a" user.rmlint.blake2b.mtime)"
	setfattr -x user.rmlint.blake2b.cksum "${rp}/a" 2> /dev/null || true
	setfattr -x user.rmlint.blake2b.mtime "${rp}/a" 2> /dev/null || true
	"${bin}" scan --db "${rdb}" --root "${rp}" --rmlint --progress 3600 > /dev/null 2>&1 || true
	st=0; [[ "${#theirs}" -gt 100 ]] || st=1; expect de5gd "rmlint: rmlint wrote a set" "rmlint left nothing" "${st}"
	check de5ge "rmlint: same bytes as rmlint's" "$(xhex "${rp}/a" user.rmlint.blake2b.cksum) $(xhex "${rp}/a" user.rmlint.blake2b.mtime)" "${theirs}"
else
	skip de5gd "rmlint: rmlint wrote a set (rmlint isn't installed)"
	skip de5ge "rmlint: same bytes as rmlint's (rmlint isn't installed)"
fi

# 21. --version gives the version, and the build number when the pipeline
# stamped one, with its date unless it's a release. A tree that isn't the
# commit's marks the number -dirty, and is never a release. That one line and
# nothing else, so the x keeps a trailing blank line from being stripped.
ver="$("${bin}" --version; echo x)"; ver="${ver%x}"
st=0; [[ "${ver%%$'\n'*}" =~ ^tukfs-hash\ v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?(\ build\ [0-9a-hjkmnp-tv-z]+((-dirty)?\ \([0-9]{4}-[0-9]{2}-[0-9]{2}\))?)?$ ]] || st=1
expect deb0d "version line" "version line is [${ver%%$'\n'*}]" "${st}"
check deb0e "version line alone" "${ver}" "${ver%%$'\n'*}"$'\n'

# 22. Help ends with one blank line before the prompt, however it's asked
# for. The bare command shows it too, with exit 1. The x and exit code after
# the output keep its trailing blank line from being stripped.
helpBad=""; helpRcs=""
for helpArg in -h --help help ''; do
	helpOut="$("${bin}" ${helpArg:+"${helpArg}"} && echo "x0" || echo "x$?")"
	helpRcs+=" [${helpArg}] ${helpOut##*x}"
	[[ "${helpOut%x*}" == *[![:space:]]$'\n\n' ]] || helpBad+=" [${helpArg}]"
done
check dee8e "help ends with a blank line" "${helpBad}" ""
check des4v "help exit codes" "${helpRcs}" " [-h] 0 [--help] 0 [help] 0 [] 1"

# After a command too. And a command refuses another's option by name, rather
# than leave out the filter it asked for (2026102814341425).
helpWant="$("${bin}" --help && echo x0)"
check df1q4 "help after a command" "$("${bin}" scan --root "${tree}" --help && echo x0 || echo "x$?")|$("${bin}" accept --db "${db}" -h && echo x0 || echo "x$?")" "${helpWant}|${helpWant}"
refused() { local rc=0 msg=''; msg="$("${bin}" "${@}" 2>&1 > /dev/null)" || rc=$?; echo "${rc} ${msg}"; }
check df1q5 "gone refuses --root" "$(refused gone --db "${db}" --root "${tree}")" "1 tukfs-hash: gone doesn't take --root; see --help"
check df1q6 "report refuses --since" "$(refused report --db "${db}" --since "${tomorrow}")" "1 tukfs-hash: report doesn't take --since; see --help"
check df1q7 "accept refuses --rmlint" "$(refused accept --db "${db}" --rmlint "${tree}/small.txt")" "1 tukfs-hash: accept doesn't take --rmlint; see --help"

# 23. A mount point whose name isn't UTF-8 doesn't stop a scan of some other
# root (2026102519331112). The mounts are in a user namespace, so no root is
# needed, and they go when it ends. A box that won't make one skips, and so
# does ZFS, whose pools can't be seen from one.
ns="${work}/ns"
mkdir -p "${ns}/mnt" "${ns}/root"
printf 'x\n' > "${ns}/root/f"
cat > "${ns}/in.bash" << 'EOF'
odd="${1}/mnt/$(printf 'caf\xe9')"
mount -t tmpfs none "${1}/mnt" && mkdir "${odd}" && mount -t tmpfs none "${odd}" || exit 1
: > "${1}/mounted"
"${2}" scan --db "${1}/t.sqlite" --root "${1}/root" --progress 3600 > "${1}/out.txt" 2>&1
EOF
rc=0; nsfs="$(stat -f -c %T "${ns}/root")"
if [[ "${nsfs}" != zfs ]]; then
	unshare --user --map-root-user --mount bash "${ns}/in.bash" "${ns}" "${bin}" 2> /dev/null || rc=$?
fi
if [[ "${nsfs}" == zfs ]]; then
	skip deeby "scan with a mount point that isn't UTF-8 (ZFS pools aren't seen from a user namespace)"
elif [[ -e "${ns}/mounted" ]]; then
	check deeby "scan with a mount point that isn't UTF-8" "${rc} $(head -1 "${ns}/out.txt" | grep mountinfo || true)" "0 "
else
	skip deeby "scan with a mount point that isn't UTF-8 (no user namespace here)"
fi

# 24. Run through sudo, a link at the database or one of its 3 other names
# would be followed as root and the target made or chowned (2026102814341403).
# The own ids stand in for sudo's, so no root is needed.
ln_case() {
	local d="${work}/ln${1:-db}" rc=0
	mkdir -p "${d}"
	cp "${db}" "${d}/real.sqlite"
	if [[ "${2}" == db ]]; then
		ln -s "${d}/real.sqlite" "${d}/t.sqlite"
	else
		cp "${db}" "${d}/t.sqlite"
		[[ "${2}" == none ]] || ln -s "${d}/target" "${d}/t.sqlite${1}"
	fi
	SUDO_UID="$(id -u)" SUDO_GID="$(id -g)" "${bin}" prune --db "${d}/t.sqlite" > "${d}/out.txt" 2>&1 || rc=$?
	echo "${rc} $([[ -e "${d}/target" ]] && echo made || echo none)"
}
check dejdp "sudo prune, no links" "$(ln_case .none none)" "0 none"
check dejdq "sudo prune, database name a link" "$(ln_case "" db)" "1 none"
check dejdr "sudo prune, lock a link" "$(ln_case .lock link)" "1 none"
check dejds "sudo prune, -wal a link" "$(ln_case -wal link)" "1 none"
check dejdt "sudo prune, -shm a link" "$(ln_case -shm link)" "1 none"
# Each refusal names the link, where SQLite said only "unable to open database file"
# (2026102822062342).
lnSaid=''
for sfx in '' .lock -wal -shm; do
	lnSaid+="$(grep -cF "${work}/ln${sfx:-db}/t.sqlite${sfx}: is a symbolic link; refused" "${work}/ln${sfx:-db}/out.txt" || true)"
done
check df1qe "sudo prune, each link named" "${lnSaid}" 1111

# 25. A mount that's been mounted over is gone from the walk's view, and so is
# what's mounted on it (2026102814341407). In a user namespace, as step 23.
# Under a whole mnt, sub is a folder like any other. A root under a tmpfs
# that covers ext4 takes the tmpfs's type, so it's refused as no disk.
cat > "${ns}/over.bash" << 'EOF2'
cd "${1}" && mkdir -p a/base/sub a/hid a/vis/sub a/mnt b/base/sub b/hid b/mnt || exit 1
printf 'x\n' > a/vis/top; printf 'y\n' > a/vis/sub/f1; printf 'z\n' > a/hid/f0
mount --bind a/base a/mnt && mount --bind a/hid a/mnt/sub && mount --bind a/vis a/mnt || exit 1
mount --bind b/base b/mnt && mount --bind b/hid b/mnt/sub && mount -t tmpfs none b/mnt || exit 1
mkdir b/mnt/sub && printf 'w\n' > b/mnt/sub/f || exit 1
: > over.mounted
rc=0; "${2}" scan --db a.sqlite --root a/mnt --progress 3600 > a.out 2>&1 || rc=$?
echo "${rc} $(grep -o 'hashed [0-9]*' a.out | head -1)" > a.got
rc=0; "${2}" scan --db b.sqlite --root b/mnt/sub --progress 3600 > b.out 2>&1 || rc=$?
echo "${rc} $(grep -c 'is tmpfs from none' b.out)" > b.got
EOF2
if [[ "${nsfs}" != zfs ]]; then
	unshare --user --map-root-user --mount bash "${ns}/over.bash" "${ns}" "${bin}" 2> /dev/null || true
fi
if [[ "${nsfs}" == zfs ]]; then
	skip des5j "walk under a mount that's been mounted over (ZFS pools aren't seen from a user namespace)"
	skip des5k "root's type from the mount on top (ZFS pools aren't seen from a user namespace)"
elif [[ -e "${ns}/over.mounted" ]]; then
	check des5j "walk under a mount that's been mounted over" "$(cat "${ns}/a.got")" "0 hashed 2"
	check des5k "root's type from the mount on top" "$(cat "${ns}/b.got")" "1 1"
else
	skip des5j "walk under a mount that's been mounted over (no user namespace here)"
	skip des5k "root's type from the mount on top (no user namespace here)"
fi
# A bind mount of a folder inside another root is that root's folder, wherever
# it's mounted, so it isn't read twice (2026102814341414). One of a folder
# outside the roots is read. A database reached through such a mount still
# leaves out only its own names in the root's walk (2026110719570617), adn
# --no-xattr and --exclude given by the mount's name still apply, also to a
# root under it (2026110720070507). A root that's the bind mount is still
# under the folders above its source, a git work tree too (2026111011092307).
cat > "${ns}/bind.bash" << 'EOF2'
cd "${1}" && mkdir -p c/tree/sub c/tree/s2 c/tree/b c/bind c/out c/ob || exit 1
for f in 1 2 3 4; do printf '%s\n' "${f}" > "c/tree/sub/f${f}"; done
printf 't\n' > c/tree/top; printf 'g\n' > c/tree/s2/g; printf 'o\n' > c/out/f
mount --bind c/tree/sub c/bind && mount --bind c/tree/s2 c/tree/b && mount --bind c/out c/ob || exit 1
: > bind.mounted
rc=0; "${2}" scan --db c.sqlite --root c/tree --root c/bind --root c/tree/b --root c/ob --progress 3600 > c.out 2>&1 || rc=$?
echo "${rc} $(grep -o 'files [0-9]* hashed [0-9]*' c.out | head -1)" > c.got
grep -c '^skipping root .*: inside .*/c/tree, as .*/c/tree/s' c.out > c.skips
rc=0; "${2}" scan --db c/bind/d.sqlite --root c/tree --progress 3600 > d.out 2>&1 || rc=$?
echo "${rc}" > d.got
mkdir -p e/tree/sub/deep e/bind || exit 1
printf 't\n' > e/tree/top; printf 'f\n' > e/tree/sub/f; printf 'g\n' > e/tree/sub/deep/g
mount --bind e/tree/sub e/bind || exit 1
escan() { local rc=0; "${2}" scan --db "${1}.sqlite" --progress 3600 "${@:3}" > "${1}.out" 2>&1 || rc=$?; echo "${rc} $(grep -oE 'files [0-9]+' "${1}.out" | head -1)"; }
escan e1 "${2}" --root e/tree --no-xattr e/bind > e1.got
echo "$(escan e2 "${2}" --root e/tree --exclude e/bind --no-xattrs) $(escan e3 "${2}" --root e/bind/deep --exclude e/tree/sub --no-xattrs)" > e2.got
mkdir -p g/repo/.git g/mnt || exit 1
for t in ex nx repo plain; do mkdir -p "g/${t}/src" "g/mnt/${t}" && printf '%s\n' "${t}" > "g/${t}/src/f" && mount --bind "g/${t}/src" "g/mnt/${t}" || exit 1; done
escan g1 "${2}" --root g/mnt/ex --exclude g/ex --no-xattrs > g1.got
escan g2 "${2}" --root g/mnt/nx --no-xattr g/nx > g2.got
escan g3 "${2}" --root g/mnt/repo --root g/mnt/plain > g3.got
EOF2
if [[ "${nsfs}" != zfs ]]; then
	unshare --user --map-root-user --mount bash "${ns}/bind.bash" "${ns}" "${bin}" 2> /dev/null || true
fi
if [[ "${nsfs}" == zfs ]]; then
	skip df0qc "bind mount of a folder inside another root read once (ZFS pools aren't seen from a user namespace)"
	skip df0qd "bind mounts inside another root named as skipped (ZFS pools aren't seen from a user namespace)"
	skip df0qh "database through a bind mount: own names left out, no attributes (ZFS pools aren't seen from a user namespace)"
	skip df1nj "--no-xattr by a bind mount's name (ZFS pools aren't seen from a user namespace)"
	skip df1nk "--exclude by a bind mount's name (ZFS pools aren't seen from a user namespace)"
	skip df4j8 "root that's a bind of a folder in an --exclude folder (ZFS pools aren't seen from a user namespace)"
	skip df4j9 "root that's a bind of a folder in a --no-xattr folder (ZFS pools aren't seen from a user namespace)"
	skip df4ja "root that's a bind of a folder in a git work tree (ZFS pools aren't seen from a user namespace)"
elif [[ -e "${ns}/bind.mounted" ]]; then
	check df0qc "bind mount of a folder inside another root read once" "$(cat "${ns}/c.got")" "0 files 7 hashed 7"
	check df0qd "bind mounts inside another root named as skipped" "$(cat "${ns}/c.skips")" 2
	dd="${ns}/c/tree/sub/d.sqlite"
	check df0qh "database through a bind mount: own names left out, no attributes" "$(cat "${ns}/d.got") $(sqlite3 "${dd}" 'SELECT count(*) FROM paths') $(sqlite3 "${dd}" "SELECT count(*) FROM paths WHERE path LIKE '%/d.sqlite%'") $(xget "${dd}" user.blake3.b64u)" "0 6 0 "
	et="${ns}/e/tree"
	check df1nj "--no-xattr by a bind mount's name" "$(cat "${ns}/e1.got") $(xget "${et}/top" user.blake3.b64u | wc -c) $(xget "${et}/sub/f" user.blake3.b64u)$(xget "${et}/sub/deep/g" user.blake3.b64u)" "0 files 3 43 "
	check df1nk "--exclude by a bind mount's name" "$(cat "${ns}/e2.got")" "0 files 1 0 files 0"
	gt="${ns}/g"
	check df4j8 "root that's a bind of a folder in an --exclude folder" "$(cat "${ns}/g1.got")" "0 files 0"
	check df4j9 "root that's a bind of a folder in a --no-xattr folder" "$(cat "${ns}/g2.got") $(xget "${gt}/nx/src/f" user.blake3.b64u | wc -c)" "0 files 1 0"
	check df4ja "root that's a bind of a folder in a git work tree" "$(cat "${ns}/g3.got") $(xget "${gt}/repo/src/f" user.blake3.b64u | wc -c) $(xget "${gt}/plain/src/f" user.blake3.b64u | wc -c)" "0 files 2 0 43"
else
	skip df0qc "bind mount of a folder inside another root read once (no user namespace here)"
	skip df0qd "bind mounts inside another root named as skipped (no user namespace here)"
	skip df0qh "database through a bind mount: own names left out, no attributes (no user namespace here)"
	skip df1nj "--no-xattr by a bind mount's name (no user namespace here)"
	skip df1nk "--exclude by a bind mount's name (no user namespace here)"
	skip df4j8 "root that's a bind of a folder in an --exclude folder (no user namespace here)"
	skip df4j9 "root that's a bind of a folder in a --no-xattr folder (no user namespace here)"
	skip df4ja "root that's a bind of a folder in a git work tree (no user namespace here)"
fi

# 26. A root that can't be resolved stops the scan before it starts, with the
# real error, and leaves no database behind (2026102814341406).
mr="${work}/mr"
mkdir -p "${mr}/t"
printf 'x\n' > "${mr}/t/f"
rc=0; "${bin}" scan --db "${mr}/t.sqlite" --root "${mr}/t" --root "${mr}/t/nonexist" --progress 3600 > "${mr}/out.txt" 2>&1 || rc=$?
check des5v "scan with a missing root" "${rc}" 1
mrDb=none; [[ -e "${mr}/t.sqlite" ]] && mrDb=made
check des5w "missing root named, nothing scanned" "$(grep -cF "can't resolve root ${mr}/t/nonexist: No such file or directory (os error 2)" "${mr}/out.txt" || true) ${mrDb}" "1 none"

# 27. An unmounted btrfs subvolume given as a root is read on its own, though
# it sits inside another root whose walk stops at it (2026102814341412). Only
# on btrfs, so TUKFS_IT_BTRFS or HOST_TEMP picks it (2026110211132205).
bt="${btWork:-${work}}/bt"
mkdir -p "${bt}/p"
printf 'a\n' > "${bt}/p/f1"
if [[ "$(stat -f -c %T "${bt}")" == btrfs ]] && btrfs subvolume create "${bt}/p/sv" > /dev/null 2>&1; then
	printf 'b\n' > "${bt}/p/sv/f2"; printf 'c\n' > "${bt}/p/sv/f3"
	rc=0; "${bin}" scan --db "${bt}/t.sqlite" --root "${bt}/p" --root "${bt}/p/sv" --progress 3600 > "${bt}/out.txt" 2>&1 || rc=$?
	check des5x "btrfs subvolume inside another root" "${rc} $(grep -o 'hashed [0-9]*' "${bt}/out.txt" | head -1 || true)" "0 hashed 3"
	# rm --one-file-system leaves a subvolume behind, so it goes first.
	rm -f -- "${bt}/p/sv/f2" "${bt}/p/sv/f3"; rmdir -- "${bt}/p/sv" || true
else
	skip des5x "btrfs subvolume inside another root (not on btrfs, or no btrfs tool)"
fi

# 28. Beside a database inside the root, only its own 5 names are left out,
# not every name that starts with it (2026102814341408). A root below a
# folder with .git is in a git work tree, as the folder with .git is
# (2026102814341413).
dn="${work}/dn"; mkdir -p "${dn}/tree/tukdir" "${dn}/repo/.git" "${dn}/repo/src"
printf 'n\n' > "${dn}/tree/tuk-notes.txt"; printf 'd\n' > "${dn}/tree/tuk.d"; printf 'i\n' > "${dn}/tree/tukdir/f"
printf 'c\n' > "${dn}/repo/src/a.c"
rc=0; "${bin}" scan --db "${dn}/tree/tuk" --root "${dn}/tree" --no-xattrs --progress 3600 > "${dn}/out.txt" 2>&1 || rc=$?
check des65 "names that start with the database's" "${rc} $(sqlite3 "${dn}/tree/tuk" 'SELECT count(*) FROM paths')" "0 3"
check des66 "the database's own names left out" "$(sqlite3 "${dn}/tree/tuk" "SELECT count(*) FROM paths WHERE path LIKE '%/tuk' OR path LIKE '%/tuk.lock' OR path LIKE '%/tuk-%al'")" 0
rc=0; "${bin}" scan --db "${dn}/g.sqlite" --root "${dn}/repo/src" --progress 3600 > "${dn}/g.txt" 2>&1 || rc=$?
check des67 "root below a git folder: no attributes" "${rc} $(sqlite3 "${dn}/g.sqlite" 'SELECT count(*) FROM paths') $(xget "${dn}/repo/src/a.c" user.blake3.b64u)" "0 1 "

# 29. The pipeline runs this in its sandbox, where only the folder that has
# the work folders can be written, and docker's socket isn't there. Run by the
# pipeline outside it, without --no-sandbox, is a failure. Home is an empty
# tmpfs in there, which is fine to write, and a scan refuses tmpfs, so a test
# root is never on one.
if [[ -n "${TUKFS_SANDBOX:-}" || ( -n "${TUKFS_RUN_NAME:-}" && -z "${TUKFS_NO_SANDBOX:-}" ) ]]; then
	probe="${base%/*}/.tukfs-hash-sandbox-probe-$$"
	st=0; [[ -n "${TUKFS_SANDBOX:-}" ]] || st=1
	if [[ "$(stat -f -c %T -- "${base%/*}")" != tmpfs ]] && mkdir -- "${probe}" 2> /dev/null; then rmdir -- "${probe}"; st=1; fi
	[[ ! -e /run/docker.sock && ! -e /var/run/docker.sock ]] || st=1
	expect desk2 "sandbox: nothing outside the test folder written" "sandbox: not in it, could write ${probe%/*}, or docker's socket is there" "${st}"
else
	skip desk2 "sandbox: nothing outside the test folder written (not in the sandbox)"
fi

# 30. A first scan that fills the disk leaves a database the next run can
# still use (2026102814341430). The tmpfs that fills is in a user namespace,
# as step 23. 8k fails before a page is written, 96k partway through making
# the tables.
cat > "${ns}/full.bash" << 'EOF2'
cd "${1}" && mkdir -p full fr && printf 'x\n' > fr/f || exit 1
for sz in 8k 96k; do
	mount -t tmpfs -o "size=${sz}" none full || exit 1
	rc=0; "${2}" scan --db full/t.sqlite --root fr --progress 3600 > /dev/null 2>&1 || rc=$?
	echo "${rc}" > "full-${sz}.rc"
	cp full/t.sqlite "full-${sz}.sqlite" && umount full || exit 1
done
: > full.mounted
EOF2
if [[ "${nsfs}" != zfs ]]; then
	unshare --user --map-root-user --mount bash "${ns}/full.bash" "${ns}" "${bin}" 2> /dev/null || true
fi
if [[ "${nsfs}" == zfs ]]; then
	skip df1qb "database left by a full disk taken as new (ZFS pools aren't seen from a user namespace)"
elif [[ -e "${ns}/full.mounted" ]]; then
	fullGot=''
	for sz in 8k 96k; do
		rc=0; "${bin}" scan --db "${ns}/full-${sz}.sqlite" --root "${ns}/fr" --progress 3600 > /dev/null 2>&1 || rc=$?
		fullGot+="$(cat "${ns}/full-${sz}.rc") ${rc} "
	done
	check df1qb "database left by a full disk taken as new" "${fullGot}" "1 0 1 0 "
else
	skip df1qb "database left by a full disk taken as new (no user namespace here)"
fi

# 31. accept of a name no scan has a row for says so, since a scan may know
# the file by another name and go on reporting it (2026102814341431).
an="${work}/an"; mkdir -p "${an}"
cp "${db}" "${an}/t.sqlite"; printf 'n\n' > "${an}/new.txt"
rc=0; "${bin}" accept --db "${an}/t.sqlite" "${an}/new.txt" "${tree}/small.txt" > "${an}/out.txt" 2>&1 || rc=$?
check df1qc "accept of a name no scan knows says so" "${rc} $(grep -c 'no scan has a record under this name' "${an}/out.txt")" "0 1"

# 32. A file that changes while it's read, and an attribute that can't be
# written, are reported and set no exit bit (design.md, Runs and exit codes).
us="${work}/us"; mkdir -p "${us}"
head -c 16000000 /dev/urandom > "${us}/live"
# Appends a byte at a time, so the size moves under every read.
python3 -I -c '
import os, sys
fd = os.open(sys.argv[1], os.O_WRONLY | os.O_APPEND)
while True:
	os.write(fd, b"x")
' "${us}/live" &
appender=$!
for ((i = 0; i < 200; i++)); do [[ "$(stat -c %s "${us}/live")" -gt 16000000 ]] && break; sleep 0.05; done
# On a loaded box the appender can sit out a whole read, so a quiet scan gets
# another go. The first one that reports anything is what's checked.
for ((i = 1; i <= 5; i++)); do
	rc=0; "${bin}" scan --db "${work}/db/us${i}.sqlite" --root "${us}" --no-xattrs --progress 3600 > "${work}/us.txt" 2>&1 || rc=$?
	usGot="${rc} $(sqlite3 "${work}/db/us${i}.sqlite" "SELECT group_concat(kind || ' ' || path, ', ') FROM events")"
	[[ "${usGot}" == "0 " ]] || break
done
kill "${appender}"; wait "${appender}" 2> /dev/null || true
check df1rj "a file changing while read: reported, exit 0" "${usGot}" "0 unstable ${us}/live"
ro="${work}/ro"; mkdir -p "${ro}"
printf 'read only\n' > "${ro}/f"; chmod 444 "${ro}/f"
# Root, or a sandbox that kept its capabilities, can write it anyway.
if setfattr -n user.tukfs-probe -v 1 "${ro}/f" 2> /dev/null; then
	skip df1rk "an attribute that can't be written: reported, exit 0 (a 0444 file takes attributes here)"
else
	rc=0; "${bin}" scan --db "${work}/db/ro.sqlite" --root "${ro}" --progress 3600 > "${work}/ro.txt" 2>&1 || rc=$?
	check df1rk "an attribute that can't be written: reported, exit 0" "${rc} $(sqlite3 "${work}/db/ro.sqlite" "SELECT group_concat(kind || ' ' || path, ', ') FROM events")" "0 xattr-error ${ro}/f"
fi

# 33. A read error is news like a mismatch, so no skip passes the file until
# it reads clean (design.md, Skipping, row db-read-error). A preloaded shim
# fails the reads, since a real EIO needs a failing disk.
er="${work}/er"; mkdir -p "${er}/tree"
head -c 40000 /dev/urandom > "${er}/tree/bad"; printf 'fine\n' > "${er}/tree/good"
cat > "${er}/eio.c" << 'EOF'
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// Whether fd is open on a path that ends in EIO_NAME.
static int bad(int fd) {
	const char *want = getenv("EIO_NAME");
	char link[64], got[4096];
	if (!want) return 0;
	snprintf(link, sizeof link, "/proc/self/fd/%d", fd);
	ssize_t n = readlink(link, got, sizeof got - 1);
	if (n <= 0) return 0;
	got[n] = 0;
	size_t w = strlen(want);
	return (size_t)n >= w && strcmp(got + n - w, want) == 0;
}

ssize_t read(int fd, void *buf, size_t count) {
	static ssize_t (*real)(int, void *, size_t);
	if (!real) real = dlsym(RTLD_NEXT, "read");
	if (bad(fd)) { errno = EIO; return -1; }
	return real(fd, buf, count);
}

ssize_t pread64(int fd, void *buf, size_t count, off_t at) {
	static ssize_t (*real)(int, void *, size_t, off_t);
	if (!real) real = dlsym(RTLD_NEXT, "pread64");
	if (bad(fd)) { errno = EIO; return -1; }
	return real(fd, buf, count, at);
}
EOF
erdb="${work}/db/er.sqlite"
# erscan shim|plain [ARGS...]: the exit code, the run's read errors and how
# many files it read.
erscan() {
	local rc=0 pre=()
	if [[ "${1}" == shim ]]; then pre=(env "LD_PRELOAD=${er}/eio.so" "EIO_NAME=/er/tree/bad"); fi
	"${pre[@]}" "${bin}" scan --db "${erdb}" --root "${er}/tree" --progress 3600 "${@:2}" > "${work}/er.txt" 2>&1 || rc=$?
	echo "${rc} $(sqlite3 "${erdb}" "SELECT count(*) FROM events WHERE run_id = (SELECT max(id) FROM runs) AND kind = 'read-error'") $(grep -o 'hashed [0-9]*' "${work}/er.txt" | head -1)"
}
if ! command -v cc > /dev/null || ! cc -shared -fPIC -o "${er}/eio.so" "${er}/eio.c" -ldl > "${work}/er-cc.txt" 2>&1; then
	skip df4ep "read error: --verify reports it (no C compiler for the shim)"
	skip df4eq "read error: reported again on a plain run the same day (no C compiler for the shim)"
	skip df4er "read error: a clean read closes it (no C compiler for the shim)"
else
	erscan plain > /dev/null
	check df4ep "read error: --verify reports it" "$(erscan shim --verify)" "4 1 hashed 1"
	check df4eq "read error: reported again on a plain run the same day" "$(erscan shim)" "4 1 hashed 0"
	check df4er "read error: a clean read closes it" "$(erscan plain) $(erscan plain)" "0 0 hashed 1 0 0 hashed 0"
fi

if [[ "${fails}" -eq 0 ]]; then
	echo "all passed"
else
	echo "${fails} failed"
	exit 1
fi


##	History:
##		- 20261013: Created, with scan, report and snapdiff.
##		- 20261014: accept, stored sums kept on a mismatch, exit codes, resume
##		  checks, snapdiff input checks and odd names, writer faults, --verify,
##		  gone and prune.
##		- 20261019: --rmlint and rmlint's blake2b xattrs, b2b names.
##		- 20261023: Header and history. Old commented-out checks dropped, every
##		  expansion braced, and the work folder is removed only when its marker
##		  has the run's token.
##		- 20261023: expect takes a status for [[ ]] checks, one fFlipByte, and
##		  step 5's 400 files from one python3.
##		- 20261023: fSafeRm guards the work folder's rm -rf, and the folder moved
##		  under <TMPDIR>/tukfs-hash/.
##		- 20261023: --version lines.
##		- 20261023: The date after the build number. wait_started waits 60 s.
##		- 20261023: A test ID on every check, shown on its status line, and a
##		  skip line for each check left out.
##		- 20261024: A stop takes down what the test started before the work
##		  folder goes.
##		- 20261024: Step 5's files are synced before the scan.
##		- 20261025: Step 5 stops the scan once it's past the top folder, not
##		  after a fixed 0.1 s.
##		- 20261025: Test IDs in Crockford base 32 minutes, and PASS, FAIL and
##		  SKIP lines with no "integration" in them.
##		- 20261025: The work folder is <HOST_TEMP>/tukfs-hash/<stamp>_<NNN>,
##		  with run.pid, and old ones go after 2 days. --keep-temp.
##		- 20261025: --version is one line, with no copyright. Help ends with a
##		  blank line.
##		- 20261025: A killed run's folder goes at the next run. Only a kept
##		  one waits 2 days.
##		- 20261025: A scan with a mount point that isn't UTF-8, in a user
##		  namespace.
##		- 20261028: ddx1e and de5gd fail on their own line when they find
##		  nothing, rather than ending the script. Step 20's scan helper is
##		  rdscan, where it was a second rscan. SPDX line.
##		- 20261028: The stale folder sweep also needs the folder to be ours.
##		- 20261029: A build number marked -dirty.
##		- 20261102: A Ctrl+C stops the test as well as the running scan. A
##		  locked folder left by a stop or kill no longer blocks its removal.
##		- 20261102: Step 29, the pipeline's sandbox.
##		  ddx0t reads the journal mode, ddx0s runs only through sudo, and
##		  step 22 checks the exit codes.
##		- 20261102: Mounts that have been mounted over.
##		- 20261102: A root that can't be resolved, and a btrfs subvolume
##		  inside another root.
##		- 20261102: Names that start with the database's, and a root below a
##		  folder with .git.
##		- 20261102: A CHECK in place of the trigger that refuses a row, and a
##		  planted trigger refused.
##		- 20261102: Step 5 also stops and resumes over a new database.
##		- 20261107: The work folder's marks are removed last, so a removal
##		  that fails partway leaves it for the next run's sweep.
##		- 20261108: TUKFS_IT_BTRFS gives step 27 a work folder on btrfs, and a
##		  subvolume a stop left behind is removed with its folder.
##		- 20261108: A bind mount of a folder inside another root, and a
##		  database reached through one.
##		- 20261108: Help after a command, and an option another command takes
##		  refused.
##		- 20261108: A database left by a first scan that filled the disk.
##		- 20261108: accept of a name no scan knows.
##		- 20261108: A link at the database's names is named in the refusal.
##		- 20261108: A file that changes while read, an attribute that can't be
##		  written, and no attributes on a new file after --verify.
##		- 20261110: A read error, through a preloaded shim, is read and
##		  reported again until it reads clean.
