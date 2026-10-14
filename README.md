<!-- markdownlint-disable MD007 -- Unordered list indentation -->
<!-- markdownlint-disable MD010 -- No hard tabs -->
<!-- markdownlint-disable MD041 -- First line in a file should be a top-level heading -->

# tukfs-hash

Checksums every file on a Linux box, remembers what each one read as, and says when a file's contents changed while its size and modified time didn't. That is what bad RAM, a bad cable or a filesystem bug leaves behind. A normal edit always moves the time.

It's a utility under tukfs, part of tukzedo.

## What it does

- Reads each regular file once with blake3. Files that already have a current rmlint blake2b checksum get blake2b too, from the same read.
- Compares the result with three earlier records, when they're there and the size and time still match:
	- The blake3 left on the file in extended attributes, by this program or by nemo-anywhere.
	- rmlint's blake2b, in `user.rmlint.blake2b.*`.
	- Its own database from earlier runs.
- Writes the blake3 back onto the file, in the attributes nemo-anywhere reads, plus the date it was taken and the inode it came from. Files in git work trees get none, since git already checksums what it keeps.
- Keeps everything in one SQLite file, which can be copied or archived as is.
- Runs one worker per set of disks, so no disk is read by two at once, and more on flash. It never crosses into another mount.
- Stops cleanly on Ctrl+C and picks up where it left off with `--resume`. A file read since the start of the day, or since `--since`, isn't read again.
- `snapdiff` takes the change list from `zfs diff` or `btrfs subvolume find-new` and flags files that changed between 2 snapshots with the same size and time.

## Attributes

| Name                  | Value
| :---                  | :---
| `user.blake3.b64u`    | blake3-256, base64url with no padding
| `user.blake3.bytes`   | size when it was taken
| `user.blake3.date`    | when it was taken, microseconds since 1970
| `user.blake3.mtime`   | modified time when it was taken, microseconds since 1970
| `user.blake3.inode`   | `device:inode:checksum` of the file it was taken from

A reader trusts the checksum only when both the size and time match the file. The time is written after the checksum and the inode last, so a write that stops part way is thrown away.

A file is skipped without reading only when `user.blake3.inode` matches the file's own device and inode and the checksum next to it. A copy made with `cp -a` or `rsync -aX` brings the attributes along, so it gets read and compared. Attributes from before `user.blake3.inode` existed never skip.

Writing an attribute changes the file's ctime, and Linux has no way to set it back.

## Usage

~~~text
tukfs-hash scan --db FILE --root DIR [--root DIR ...] [options]
tukfs-hash plan --root DIR [--root DIR ...]
tukfs-hash runs --db FILE
tukfs-hash report --db FILE [--run N] [--kind KIND]
tukfs-hash snapdiff --old DIR --new DIR (--zfs-diff FILE --mount DIR | --find-new FILE | --list FILE)
~~~

`tukfs-hash --help` has the options. Run `scan` as root to reach every file. The database is handed back to the user who ran sudo when the run ends.

Exit codes: 0 fine, 1 error, 2 stopped, 4 mismatches or read errors found.

## Building

~~~bash
cargo build --release
tests/integration.bash
~~~

The integration test needs `sqlite3`, `getfattr`, `setfattr` and `b2sum`, and a `TMPDIR` on a filesystem with user xattrs.

## Copyright and license

> Copyright © 2026 t00mietum (CryptogID: ปʬϝღถɔ4რఠΔթะ9ƾǝu)<br>
> Licensed under [GPL-2.0](license.md). No warranty.
