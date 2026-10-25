#!/usr/bin/env bash
#  shellcheck disable=1091  ## 'Not following.' The stop include is checked on its own.

##	Purpose: End to end, as a normal user, on a filesystem with user xattrs. No
##		root and no mounts, so mount boundaries are left to `plan` on a real box.
##	Usage: tests/integration.bash [BINARY]
##	History: At bottom of script.

# Copyright © 2026 t00mietum (CryptogID: ปʬϝღถɔ4რఠΔթะ9ƾǝu)
# Licensed under GPL-2.0-only. No warranty.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bin="${1:-${here}/target/release/tukfs-hash}"
# Resolved, so fSafeRm can insist the path has no links in it.
work="$(realpath -e -- "${TMPDIR:-/tmp}")/tukfs-hash/test_tukfs-hash_itzq_$(date +%Y%m%d-%H%M%S)_$$"
# The exit trap removes it only while the marker holds this run's token, so
# a folder this run didn't make is never touched.
token="$$-${RANDOM}${RANDOM}-${EPOCHREALTIME}"
# A TERM to this shell alone leaves its children writing into the folder.
source "${here}/cicd/utility/include/stop-descendants.bash"
mkdir -p -- "${work%/*}"
mkdir -- "${work}"
printf '%s\n' "${token}" > "${work}/.test-run"

# rm -rf, but only on what can only be one of this script's work folders:
# .../tmp/<something>/test_tukfs-hash_itzq_<stamp>_<pid>, no links, no dots.
fSafeRm() {
	local p="${1:-}" real='' fhs=''
	if [[ -z "${p}" || "${p}" != /* || "${p}" == *..* || "${p}" == *//* || "${p}" == *$'\n'* ]]; then
		printf 'fSafeRm: refused, bad path: "%s"\n' "${p}" >&2; return 1
	fi
	if ! [[ "${p}" =~ ^(/.+)?/tmp/[^/]+(/[^/]+)*/test_tukfs-hash_itzq_[0-9]{8}-[0-9]{6}_[0-9]+$ ]]; then
		printf 'fSafeRm: refused, not a test folder: %s\n' "${p}" >&2; return 1
	fi
	for fhs in / /bin /boot /dev /etc /home /lib /lib64 /media /mnt /opt /proc /root /run /sbin /srv /sys /tmp /usr /var "${HOME:-/}"; do
		if [[ "${p%/}" == "${fhs%/}" ]]; then printf 'fSafeRm: refused, system folder: %s\n' "${p}" >&2; return 1; fi
	done
	real="$(realpath -e -- "${p}")" || { printf 'fSafeRm: refused, not there: %s\n' "${p}" >&2; return 1; }
	if [[ "${real}" != "${p}" || ! -d "${p}" || -L "${p}" ]]; then
		printf 'fSafeRm: refused, a link or not a folder: %s\n' "${p}" >&2; return 1
	fi
	rm -rf --one-file-system -- "${p}"
}
fCleanup() {
	local got=''
	fStopDescendants
	read -r got 2> /dev/null < "${work}/.test-run" || true
	if [[ "${got}" != "${token}" ]]; then printf 'not removed, no marker for this run: %s\n' "${work}" >&2; return 0; fi
	fSafeRm "${work}" || true
}
trap fCleanup EXIT
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
fFlipByte() { python3 -I -c 'import os,sys; p,off,mask=sys.argv[1],int(sys.argv[2]),int(sys.argv[3],0); n=int(sys.argv[4]); st=os.stat(p); f=open(p,"r+b"); f.seek(off); b=f.read(n); f.seek(off); f.write(bytes(x^mask for x in b)); f.close(); os.utime(p, ns=(st.st_atime_ns, st.st_mtime_ns))' "${1}" "${2}" "${3}" "${4:-1}"; }
check() { if [[ "${3}" == "${4}" ]]; then ok "${1}" "${2}"; else bad "${1}" "${2}: got [${3}], want [${4}]"; fi; }
q() { sqlite3 "${db}" "${1}"; }
scan() { local rc=0; "${bin}" scan --db "${db}" --root "${tree}" --progress 3600 "${@}" > "${work}/out.txt" 2>&1 || rc=$?; echo "${rc}"; }
xget() { getfattr --only-values -n "${2}" "${1}" 2>/dev/null || true; }
tomorrow="$(date -d tomorrow +%Y-%m-%d)"
# Waits up to 10 s for a scan to say it has started, rather than guessing.
# Up to 60 s, since a loaded box has taken more than 10 to get going.
wait_started() { for _ in $(seq 1 1200); do grep -q '^group ' "${1}" 2> /dev/null && return 0; sleep 0.05; done; return 1; }
# wait_reached PID DIR: up to 60 s for a scan to have a file under DIR open.
# Fails at once if it has ended, since a zombie has no fds.
wait_reached() { for _ in $(seq 1 1200); do [[ -e "/proc/${1}/fd/1" ]] || return 1; [[ -n "$(find "/proc/${1}/fd" -lname "${2}/*" -print -quit 2> /dev/null)" ]] && return 0; sleep 0.05; done; return 1; }

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
check ddx0s "file handed back readable" "$(stat -c %U "${db}")" "$(id -un)"
st=0; [[ ! -e "${db}-wal" ]] || st=1; expect ddx0t "database left in rollback mode" "WAL file left behind" "${st}"

# 2. Same day: nothing read again.
rc="$(scan)"
check ddx0v "second scan exit" "${rc}" 0
check ddx0w "second scan hashed nothing" "$(grep -o 'hashed [0-9]*' "${work}/out.txt" | head -1)" "hashed 0"

# 3. Change bytes, put the time back. All three references must notice.
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
skipped="$(grep -o 'skipped [0-9]*' "${work}/out.txt" | head -1 | cut -d' ' -f2)"
st=0; [[ "${skipped}" =~ ^[0-9]+$ && "${part}" =~ ^[0-9]+$ && "${skipped}" -ge "${part}" ]] || st=1; expect ddx1e "resume skipped what was done (${skipped})" "resume skipped ${skipped}, want at least ${part}" "${st}"
check ddx1f "every path seen by the run" "$(q 'SELECT count(*) FROM paths WHERE seen_run != (SELECT max(id) FROM runs)')" 0

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
# Put back on any exit, or the cleanup can't remove them.
trap 'chmod 755 "${ud}/locked" 2> /dev/null || true; chmod 644 "${ud}/open/c" 2> /dev/null || true; fCleanup' EXIT
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
for _ in $(seq 1 200); do grep -q open "${work}/holder.txt" && break; sleep 0.05; done
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
fscan > /dev/null
fFlipByte "${wf}/a" 0 1
sleep 0.01; printf 'two, edited\n' > "${wf}/b"
fq "CREATE TRIGGER refuse BEFORE INSERT ON files BEGIN SELECT RAISE(ABORT, 'refused by the test'); END;"
check ddy8p "a refused row fails the run" "$(fscan --since "${tomorrow}") $(fq 'SELECT status FROM runs ORDER BY id DESC LIMIT 1')" "1 failed"
check ddy8q "its events kept" "$(fq "SELECT group_concat(kind || ' ' || path) FROM events WHERE run_id = (SELECT max(id) FROM runs)")" "b3-db-mismatch ${wf}/a"
expect ddy8r "summary kept" "summary: $(fq 'SELECT summary FROM runs ORDER BY id DESC LIMIT 1')" grep -q 'events in the whole run: b3-db-mismatch 1$' <<< "$(fq 'SELECT summary FROM runs ORDER BY id DESC LIMIT 1')"
expect ddy8s "says why" "output: $(cat "${work}/wf.txt")" grep -q 'refused by the test' "${work}/wf.txt"
check ddy8t "failed run left in rollback mode" "$(fq 'PRAGMA journal_mode')" delete
fq "DROP TRIGGER refuse"
check ddy8v "a failed run resumed" "$(fscan --resume) $(fq 'SELECT status FROM runs ORDER BY id DESC LIMIT 1') $(fq 'SELECT count(*) FROM runs')" "4 done 2"
check ddy8w "and the refused row taken" "$(fq "SELECT count(*) FROM paths p JOIN files f ON f.id = p.file_id WHERE p.path = '${wf}/b' AND f.bytes = 12")" 1

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
trap 'chmod 755 "${gd}/a/dlock" 2> /dev/null || true; chmod 644 "${gd}/a/locked" 2> /dev/null || true; fCleanup' EXIT
check ddya0 "gone: scan with an unreadable file and folder" "$(gscan --root "${gd}/a" --exclude "${gd}/a/sub" --since "${tomorrow}")" 8
chmod 755 "${gd}/a/dlock"; chmod 644 "${gd}/a/locked"
check ddya1 "gone: exit" "$(gone)" 0
check ddya2 "gone: only the deleted name" "$(grep -c '^gone' "${work}/gone.txt") $(grep '^gone' "${work}/gone.txt" | cut -f2)" "1 ${gd}/a/del"
expect ddya3 "gone: says what it didn't count" "output: $(cat "${work}/gone.txt")" grep -q 'not counted: names under 1 folder' "${work}/gone.txt"
last="$(gq 'SELECT max(id) FROM runs')"
gq "UPDATE runs SET status = 'stopped' WHERE id = ${last}"
check ddya4 "gone: a stopped run refused" "$(gone --run "${last}")" 1
check ddya5 "gone: the newest finished run by default" "$(gone) $(head -1 "${work}/gone.txt") $(grep -c '^gone' "${work}/gone.txt")" "0 run $((last - 1)) 0"

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
rscan() { local rc=0; "${bin}" scan --db "${rdb}" --root "${rd}" --progress 3600 --since "${tomorrow}" "${@}" > "${work}/rd.txt" 2>&1 || rc=$?; echo "${rc}"; }
xhex() { getfattr --only-values -n "${2}" "${1}" 2>/dev/null | od -An -tx1 | tr -d ' \n'; }
b2bhex() { printf '%s' "$(b2sum "${1}" | cut -d' ' -f1)" | od -An -tx1 | tr -d ' \n'; echo 00; }
check de5g2 "rmlint: plain scan" "$(rscan)" 0
check de5g3 "rmlint: none written without the flag" "$(xget "${rd}/one" user.rmlint.blake2b.mtime)" ""
check de5g4 "rmlint: none in the database either" "$(sqlite3 "${rdb}" 'SELECT count(*) FROM files WHERE b2b IS NOT NULL')" 0
check de5g5 "rmlint: flagged scan" "$(rscan --rmlint)" 0
check de5g6 "rmlint: checksum with its NUL" "$(xhex "${rd}/one" user.rmlint.blake2b.cksum)" "$(b2bhex "${rd}/one")"
check de5g7 "rmlint: time as rmlint writes it" "$(xget "${rd}/one" user.rmlint.blake2b.mtime)" "1620310089.1234567"
check de5g8 "rmlint: stale set replaced" "$(xhex "${rd}/two" user.rmlint.blake2b.cksum) $(xget "${rd}/two" user.rmlint.blake2b.mtime)" "$(b2bhex "${rd}/two") 915177600"
check de5g9 "rmlint: none in a git work tree" "$(xget "${rd}/repo/g" user.rmlint.blake2b.mtime)" ""
check de5ga "rmlint: every file's blake2b stored" "$(sqlite3 "${rdb}" 'SELECT count(*) FROM files WHERE b2b IS NOT NULL')" 3
check de5gb "rmlint: counted" "$(grep -o 'rmlint [0-9]*' "${work}/rd.txt" | head -1)" "rmlint 2"
check de5gc "rmlint: next scan verifies them" "$(rscan --rmlint) $(grep -o 'b2b [0-9]*' "${work}/rd.txt" | head -1) $(grep -o 'rmlint [0-9]*' "${work}/rd.txt" | head -1)" "0 b2b 2 rmlint 0"
if command -v rmlint > /dev/null; then
	# rmlint hashes only files that share a size, so a pair.
	rp="${work}/rp"; mkdir -p "${rp}"
	printf 'pair\n' > "${rp}/a"; cp "${rp}/a" "${rp}/b"
	touch -d '2024-01-01 00:00:00.351000100' "${rp}/a" "${rp}/b"
	(cd "${rp}" && env -u DISPLAY rmlint -a blake2b --xattr -o summary:/dev/null "${rp}" > /dev/null 2>&1) || true
	theirs="$(xhex "${rp}/a" user.rmlint.blake2b.cksum) $(xhex "${rp}/a" user.rmlint.blake2b.mtime)"
	setfattr -x user.rmlint.blake2b.cksum "${rp}/a"; setfattr -x user.rmlint.blake2b.mtime "${rp}/a"
	"${bin}" scan --db "${rdb}" --root "${rp}" --rmlint --progress 3600 > /dev/null 2>&1 || true
	st=0; [[ "${#theirs}" -gt 100 ]] || st=1; expect de5gd "rmlint: rmlint wrote a set" "rmlint left nothing" "${st}"
	check de5ge "rmlint: same bytes as rmlint's" "$(xhex "${rp}/a" user.rmlint.blake2b.cksum) $(xhex "${rp}/a" user.rmlint.blake2b.mtime)" "${theirs}"
else
	skip de5gd "rmlint: rmlint wrote a set (rmlint isn't installed)"
	skip de5ge "rmlint: same bytes as rmlint's (rmlint isn't installed)"
fi

# 21. --version gives the version, and the build number when the pipeline
# stamped one, with its date unless it's a release, then the copyright line
# from the source.
ver="$("${bin}" --version)"
st=0; [[ "${ver%%$'\n'*}" =~ ^tukfs-hash\ v[0-9]+\.[0-9]+\.[0-9]+(\ build\ [0-9a-hjkmnp-tv-z]+(\ \([0-9]{4}-[0-9]{2}-[0-9]{2}\))?)?$ ]] || st=1
expect deb0d "version line" "version line is [${ver%%$'\n'*}]" "${st}"
check deb0e "copyright line" "${ver#*$'\n'}" "$(sed -n '1s|^// ||p' "${here}/src/main.rs")"

if [[ "${fails}" -eq 0 ]]; then
	echo "all passed"
else
	echo "${fails} failed"
	exit 1
fi


##	Script history:
##		- 20261013: Created, with scan, report and snapdiff.
##		- 20261014: accept, stored sums kept on a mismatch, exit codes, resume
##		  checks, snapdiff input checks and odd names, writer faults, --verify,
##		  gone and prune.
##		- 20261019: --rmlint and rmlint's blake2b xattrs, b2b names.
##		- 20261023: Header and history. Old commented-out checks dropped, every
##		  expansion braced, adn the work folder is removed only when its marker
##		  holds the run's token.
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
