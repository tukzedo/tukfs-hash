#!/usr/bin/env bash
# Copyright © 2026 t00mietum (CryptogID: ปʬϝღถɔ4რఠΔթะ9ƾǝu)
# Licensed under GPL-2.0-only. No warranty.
#
# End to end, as a normal user, on a filesystem with user xattrs. No root and
# no mounts, so mount boundaries are left to `plan` on a real box.
#
# Usage: tests/integration.bash [BINARY]
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bin="${1:-$here/target/release/tukfs-hash}"
work="${TMPDIR:-/tmp}/test_tukfs-hash_$(date +%Y%m%d-%H%M%S)$$"
mkdir -p "$work"
trap 'rm -rf -- "$work"' EXIT
tree="$work/tree"
db="$work/db/t.sqlite"
mkdir -p "$tree" "$work/db"

fails=0
ok()   { printf 'ok   %s\n' "$1"; }
bad()  { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }
expect() { if "${@:3}"; then ok "$1"; else bad "$2"; fi; }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1: got [$2], want [$3]"; fi; }
q() { sqlite3 "$db" "$1"; }
scan() { local rc=0; "$bin" scan --db "$db" --root "$tree" --progress 3600 "$@" > "$work/out.txt" 2>&1 || rc=$?; echo "$rc"; }
xget() { getfattr --only-values -n "$2" "$1" 2>/dev/null || true; }
tomorrow="$(date -d tomorrow +%Y-%m-%d)"
# Waits up to 10 s for a scan to say it has started, rather than guessing.
wait_started() { local i; for i in $(seq 1 200); do grep -q '^group ' "$1" 2> /dev/null && return 0; sleep 0.05; done; return 1; }

# Varied names, sizes and dates.
: > "$tree/empty"
printf 'hello\n' > "$tree/small.txt"
head -c 3000000 /dev/urandom > "$tree/big.bin"
mkdir -p "$tree/sub dir" "$tree/repo/.git/objects" "$tree/repo/src"
printf 'x' > "$tree/sub dir/one byte"
printf 'tracked\n' > "$tree/repo/src/main.c"
printf 'blob\n' > "$tree/repo/.git/objects/ab"
ln "$tree/big.bin" "$tree/sub dir/big-link.bin"
# ZFS with utf8only refuses a name that isn't UTF-8.
odd=0
if printf 'odd\n' 2> /dev/null > "$tree/$(printf 'caf\xe9')"; then odd=1; fi
touch -d '2020-02-03 04:05:06.123456789' "$tree/small.txt"
touch -d '2011-01-01 00:00:00' "$tree/big.bin"

# rmlint-style blake2b on one file, current, and on another, stale.
printf 'rmlint was here\n' > "$tree/rm.txt"
printf 'rmlint stale\n' > "$tree/rm-stale.txt"
for f in rm.txt rm-stale.txt; do
	sum="$(b2sum "$tree/$f" | cut -d' ' -f1)"
	mt="$(stat -c %.9Y "$tree/$f")"
	setfattr -n user.rmlint.blake2b.cksum -v "$sum" "$tree/$f"
	setfattr -n user.rmlint.blake2b.mtime -v "$mt" "$tree/$f"
done
setfattr -n user.rmlint.blake2b.mtime -v "1000.5" "$tree/rm-stale.txt"

# 1. First pass hashes everything and leaves attributes.
rc="$(scan)"
check "first scan exit" "$rc" 0
check "paths recorded" "$(q 'SELECT count(*) FROM paths')" $((9 + odd))
check "hard link read once" "$(grep -o 'links [0-9]*' "$work/out.txt" | head -1)" "links 1"
check "empty file digest" "$(xget "$tree/empty" user.blake3.b64u)" "rxNJufX5oaagQE3qNtzJSZvLJcmtwRK3zJqTyuQfMmI"
check "size attribute" "$(xget "$tree/small.txt" user.blake3.bytes)" 6
check "mtime attribute in microseconds" "$(xget "$tree/small.txt" user.blake3.mtime)" "$(date -d '2020-02-03 04:05:06.123456' +%s)123456"
expect "date attribute" "date attribute missing" [ -n "$(xget "$tree/small.txt" user.blake3.date)" ]
check "no attributes in a git work tree" "$(xget "$tree/repo/src/main.c" user.blake3.b64u)" ""
check "no attributes inside .git" "$(xget "$tree/repo/.git/objects/ab" user.blake3.b64u)" ""
check "git files still recorded" "$(q "SELECT count(*) FROM paths WHERE path LIKE '%/repo/%'")" 2
check "non-UTF-8 name stored as blob" "$(q "SELECT count(*) FROM paths WHERE typeof(path) = 'blob'")" "$odd"
check "current rmlint blake2b verified" "$(grep -o 'b2 [0-9]*' "$work/out.txt" | head -1)" "b2 1"
check "blake2b stored for it" "$(q "SELECT count(*) FROM files WHERE b2 IS NOT NULL")" 1
check "nothing outside the root" "$(q "SELECT count(*) FROM paths WHERE CAST(path AS TEXT) NOT LIKE '$tree/%'")" 0
check "no events" "$(q 'SELECT count(*) FROM events')" 0
check "file handed back readable" "$(stat -c %U "$db")" "$(id -un)"
expect "database left in rollback mode" "WAL file left behind" [ ! -e "$db-wal" ]

# 2. Same day: nothing read again.
rc="$(scan)"
check "second scan exit" "$rc" 0
check "second scan hashed nothing" "$(grep -o 'hashed [0-9]*' "$work/out.txt" | head -1)" "hashed 0"

# 3. Change bytes, put the time back. All three references must notice.
python3 -I - "$tree/big.bin" "$tree/rm.txt" <<'EOF'
import os, sys
for p in sys.argv[1:]:
	st = os.stat(p)
	with open(p, "r+b") as f:
		off = min(1048592, st.st_size // 2)
		f.seek(off)
		data = f.read(16)
		f.seek(off)
		f.write(bytes(b ^ 0x5A for b in data))
	os.utime(p, ns=(st.st_atime_ns, st.st_mtime_ns))
EOF
rc="$(scan --since "$tomorrow")"
check "corruption exit code" "$rc" 4
check "xattr mismatch found" "$(q "SELECT count(*) FROM events WHERE kind = 'b3-xattr-mismatch'")" 2
check "database mismatch found" "$(q "SELECT count(*) FROM events WHERE kind = 'b3-db-mismatch'")" 2
check "rmlint mismatch found" "$(q "SELECT group_concat(path) FROM events WHERE kind = 'b2-rmlint-mismatch'")" "$tree/rm.txt"
"$bin" report --db "$db" > "$work/report.txt"
expect "report lists it" "report misses big.bin" grep -q $'^b3-xattr-mismatch\t'"$tree/big.bin" "$work/report.txt"
check "unchanged attributes keep their digest" "$(xget "$tree/empty" user.blake3.b64u)" "rxNJufX5oaagQE3qNtzJSZvLJcmtwRK3zJqTyuQfMmI"

# 4. A real edit moves the time and is not a mismatch.
sleep 0.01
printf 'edited\n' >> "$tree/small.txt"
rc="$(scan --since "$tomorrow")"
check "edit is not corruption" "$(q "SELECT count(*) FROM events WHERE run_id = (SELECT max(id) FROM runs) AND path = '$tree/small.txt'")" 0
check "edit updates the size attribute" "$(xget "$tree/small.txt" user.blake3.bytes)" 13

# 5. Stop part way, then resume.
mkdir -p "$tree/many"
for i in $(seq 1 400); do head -c $((i * 16384)) /dev/urandom > "$tree/many/f$i"; done
runs_before="$(q 'SELECT count(*) FROM runs')"
"$bin" scan --db "$db" --root "$tree" --since "$tomorrow" --threads "$tree=1" --progress 3600 > "$work/stop.txt" 2>&1 &
pid=$!
wait_started "$work/stop.txt" || bad "scan never started"
sleep 0.1
kill -INT "$pid"
rc=0; wait "$pid" || rc=$?
check "stopped exit code" "$rc" 2
check "run marked stopped" "$(q 'SELECT status FROM runs ORDER BY id DESC LIMIT 1')" stopped
part="$(q "SELECT count(*) FROM paths WHERE path LIKE '%/many/%'")"
expect "stopped before the end ($part of 400)" "did not stop early ($part)" [ "$part" -lt 400 ]
rc="$(scan --resume)"
check "resume exit" "$rc" 0
check "resume finished the rest" "$(q "SELECT count(*) FROM paths WHERE path LIKE '%/many/%'")" 400
check "resume reused the run" "$(q 'SELECT count(*) FROM runs')" "$((runs_before + 1))"
skipped="$(grep -o 'skipped [0-9]*' "$work/out.txt" | head -1 | cut -d' ' -f2)"
expect "resume skipped what was done ($skipped)" "resume skipped $skipped, want at least $part" [ "$skipped" -ge "$part" ]
check "every path seen by the run" "$(q 'SELECT count(*) FROM paths WHERE seen_run != (SELECT max(id) FROM runs)')" 0

# 6. snapdiff: same size and time, different bytes.
mkdir -p "$work/old" "$work/new"
head -c 100000 /dev/urandom > "$work/old/a"
cp -p "$work/old/a" "$work/new/a"
printf 'same\n' > "$work/old/b"; cp -p "$work/old/b" "$work/new/b"
printf 'v1\n' > "$work/old/c"; printf 'v2 longer\n' > "$work/new/c"
touch -d '2001-01-01' "$work/old/c"
python3 -I -c 'import os,sys; p=sys.argv[1]; st=os.stat(p); f=open(p,"r+b"); f.seek(4096); f.write(b"\0"*16); f.close(); os.utime(p, ns=(st.st_atime_ns, st.st_mtime_ns))' "$work/new/a"
printf 'a\nb\nc\nmissing\n' > "$work/list"
rc=0; "$bin" snapdiff --old "$work/old" --new "$work/new" --list "$work/list" > "$work/sd.txt" 2> /dev/null || rc=$?
check "snapdiff exit" "$rc" 4
check "snapdiff flags only a" "$(cut -f1,2 "$work/sd.txt")" $'content-changed-same-mtime\ta'
expect "snapdiff run detail" "snapdiff detail: $(cat "$work/sd.txt")" grep -q '16 bytes differ in 1 run(s), 1 starting on a 16-byte boundary: 4096+16' "$work/sd.txt"

# 7. A second scan of the same database is refused while one runs.
"$bin" scan --db "$db" --root "$tree" --since "$tomorrow" --threads "$tree=1" --progress 3600 > "$work/first.txt" 2>&1 &
pid=$!
wait_started "$work/first.txt" || bad "scan never started"
rc=0; "$bin" scan --db "$db" --root "$tree" > "$work/lock.txt" 2>&1 || rc=$?
kill -INT "$pid" 2> /dev/null || true
wait "$pid" || true
check "second scan refused" "$rc" 1
expect "says why" "lock message: $(cat "$work/lock.txt")" grep -q 'locked' "$work/lock.txt"

# 8. Attributes vouch only for the inode that was read. A fresh database each
# time, so only the attributes can skip a file.
xt="$work/xa"
mkdir -p "$xt"
for f in a b c d; do head -c $((20000 + ${#f} * 777)) /dev/urandom > "$xt/$f"; done
touch -d '2015-05-05 05:05:05.5' "$xt/a"; touch -d '2019-09-09' "$xt/c"
xscan() { local rc=0; "$bin" scan --db "$work/db/$1.sqlite" --root "$xt" --progress 3600 > "$work/x.txt" 2>&1 || rc=$?; echo "$rc"; }
flip() { python3 -I -c 'import os,sys; p=sys.argv[1]; st=os.stat(p); f=open(p,"r+b"); f.seek(100); b=f.read(1); f.seek(100); f.write(bytes([b[0]^1])); f.close(); os.utime(p, ns=(st.st_atime_ns, st.st_mtime_ns))' "$1"; }
check "attribute scan exit" "$(xscan x1)" 0
check "inode attribute" "$(xget "$xt/a" user.blake3.inode)" "$(stat -c '%d:%i' "$xt/a"):$(xget "$xt/a" user.blake3.b64u)"
check "fresh attributes skip" "$(xscan x2) $(grep -o 'hashed [0-9]*' "$work/x.txt" | head -1)" "0 hashed 0"
# A copy with a flipped byte, a set from before the inode attribute, and a
# date in the future.
cp -a "$xt/a" "$xt/a-copy"; flip "$xt/a-copy"
setfattr -x user.blake3.inode "$xt/b" 2> /dev/null || true; flip "$xt/b"
setfattr -n user.blake3.date -v "$(( ($(date +%s) + 86400 * 365) * 1000000 ))" "$xt/c"; flip "$xt/c"
check "untrusted attributes read again" "$(xscan x3)" 4
check "each one is a mismatch" "$(sqlite3 "$work/db/x3.sqlite" "SELECT group_concat(path, ' ') FROM (SELECT path FROM events WHERE kind = 'b3-xattr-mismatch' ORDER BY path)")" "$xt/a-copy $xt/b $xt/c"
check "the rest still skip" "$(grep -o 'hashed [0-9]*' "$work/x.txt" | head -1)" "hashed 3"

if [[ "$fails" -eq 0 ]]; then
	echo "all passed"
else
	echo "$fails failed"
	exit 1
fi
