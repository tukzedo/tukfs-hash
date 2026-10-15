<!-- markdownlint-disable MD007 -- Unordered list indentation -->
<!-- markdownlint-disable MD010 -- No hard tabs -->
<!-- markdownlint-disable MD041 -- First line in a file should be a top-level heading -->

# tukfs-hash design

## Summary

Started in October 2026 after bad RAM was found on a workstation. The question was which files on disk it had changed. Files that went bad in memory before being written have valid filesystem checksums, so a scrub can't see them. What gives them away is content that changed while the size and time didn't.

## Database

- `files` is one row per distinct content: blake3, size, and blake2b when rmlint had one. `paths` is one row per name, pointing at a `files` row, with the size, time, inode and when it was read. The split is the same one nemo-anywhere's cache uses, without thumbnails.

- `runs` has one row per scan, with its skip date and a summary. `events` has every mismatch, read error, unstable file and failed attribute write, by run.

- Names go in as text when they're UTF-8 and as blobs when they aren't, so the sqlite3 shell can match most of them with a plain string.

- Unlike nemo-anywhere's cache, this one is never thrown away and rebuilt. A damaged file, or one with another table version, is refused and left alone, since it's the only record of what files used to read as.

- One writer thread commits at most a second apart. Events go in first, in their own transaction, so a row the database refuses can't take a mismatch with it.

- WAL while running, rollback mode after, so a user without write access to the folder can still open it read-only. Leaving WAL mode needs the file to itself. When something else has it open, the run warns and keeps its result, and the next run tries again.

- Pages are 16 KiB, to match the dataset's recordsize.

- Every edit leaves a `files` row no path points at. `prune` deletes those and nothing else. They're never looked up, since a lookup goes from the path. A content that comes back after a prune gets a new row. It takes the lock like a scan, and isn't a run.

## Reading files

- Each root is walked on its own and the walk stops at every mount point, so bind mounts, snapshots and other filesystems are only read when they are listed.
	- It also stops at any folder on another device than the root. That covers a btrfs subvolume that isn't mounted, and anything mounted after the mount table was read.

- Every file and folder is opened from the root's own folder, and no symlink is followed and no mount crossed anywhere on the way. A folder swapped for a symlink after it was listed counts as gone, rather than sending the scan, which runs as root, somewhere else. Kernels before 5.6 have no `openat2`, so there it goes one folder at a time.

- Roots on the same disks share one group of workers. One worker for any group with a hard drive, 2 on SATA flash and 4 on NVMe. Two readers on one hard drive make it seek between them.

- Folders go in name order and files in inode order, which on most filesystems is close to the order on disk.
	- A folder with over a million files is queued a million at a time, each part in inode order, so its list stays bounded.
	- The names of a folder's subfolders are all held until it's done, for the name order. Only names are kept, not whole paths.

- A file is checked with fstat before and after reading. If the size, time or ctime moved, it's recorded as unstable and not stored. Running VM images and live databases land there.

- The first worker to reach a hard-linked inode claims it. Other names wait for that result rather than reading the file again, and the entry is dropped once every name has been seen. Each name still gets compared with its own database row.
	- A name skipped by its row or attributes counts as seen too. Names outside the roots never come, so a group keeps only its newest 262,144 results, and a later name of an older one is read again.

- A file's cached pages are dropped before it's read, so a scribble in the page cache isn't hashed as if it were on disk. ZFS ignores that advice and answers from the ARC, so there a second read can't tell memory from disk.

- An EIO on ZFS means a block failed its checksum with no good copy left. It's reported the same as a mismatch.

## Mismatches

- A file that reads differently from a stored checksum, at the same size and time, is read once more before it's believed. When the second read matches everything stored, the event is `cache-mismatch` and the file is recorded as usual.

- Otherwise the attribute and the database row are left as they were and nothing new is written. The next run reads the file again and reports it again. Writing the new checksum would make the next run call the damaged file clean, and a crash before the event was saved would leave no trace at all.

- `accept` is the one way to replace a stored checksum with a different one. It reads the file twice and wants both reads to agree, so a fault during that read isn't what gets kept. It logs an `accepted` event under its own run, with status `accept`, which `scan --resume` never picks up.

- A database lookup that fails for any reason but a missing row is a `db-error` event, and the file isn't recorded. Taking it for "no record" would overwrite the row unseen.

## Skipping

- A file is skipped when the database or its attributes say it was read on or after the skip date with the same size, time and inode. The default skip date is the start of today, so a rerun the same day is cheap and a run on a later day reads everything again and compares.

- The attributes only skip a file when `user.blake3.inode` names the file's own device and inode, and the checksum beside it, and the file's database row doesn't disagree. Another name of a hard-linked file can leave a fresh set without ever seeing this name's row. `cp -a` and `rsync -aX` copy the attributes, but the copy gets another inode. The checksum in it means a later one written by nemo-anywhere, which writes no date, doesn't get to use ours.

- A date later than now never skips. Otherwise a wrong clock or a flipped bit would skip the file forever.

- Device numbers can change at a reboot or remount, as `sdX` names do. That only costs a second read.

- A resumed run keeps its original skip date. Anything it already read counts as fresh even when `--since` is later than when it began.

## Runs and exit codes

- `--resume` only continues the newest scan, and only when it didn't finish and has the same roots. An older stopped run would bring back its old skip date, and 2 wrappers share one database, so one could finish the other's run over the wrong roots. Roots are compared as `plan` keeps them, so the order they're given in doesn't matter. Runs from before the root list was kept can't be resumed.

- A run still marked `running` when the next one starts was killed, since the lock is held. It's marked `killed`. If it's the newest, `--resume` takes it like a stopped one.

- A run that can't go on is marked `failed` and exits 1. That's a write the database refused, a worker that couldn't open the database, or a panic. The other workers stop, the events so far are kept, and the summary is still written. `--resume` takes it like a stopped one once the cause is fixed.

- `scan --verify` reads every file that has a blake3 stored at its current size and time, in the database or on the file, and compares it the same way a scan does. Its skip date is its own start, so only what it already read in an earlier part is skipped. New and edited files aren't read. A clean read updates the database row, so a scan later that day skips it, but no attributes are written, so ctimes don't move.
	- It's a scan flag rather than its own command, since it needs everything a scan has: the walk and its mount rules, workers per disk, the claim on hard links, stop and resume, events and exit codes. A command that went through the database's rows instead would read in name order, not disk order, and couldn't open files safely from their root.
	- `runs.verify` marks these runs. `--resume` only continues one with `--verify`, and a full scan only without it. Otherwise one would finish the other with the wrong skip date and the wrong rules for attributes.

- A resumed run doesn't read again what an earlier part already judged at the same size and time, mismatches included, so it doesn't report them twice.

- The exit code comes from the run's events in the database, not from the counters of the process that ends it. A file reported by 2 parts counts once, so a resume doesn't double it.

- Each event kind sets one exit code bit, and the bits add up with 2 for a stop. This table is the rule:

	| Event                                                                                       | Bit
	| :---                                                                                        | :---
	| `b3-xattr-mismatch`, `b2-rmlint-mismatch`, `b3-db-mismatch`, `cache-mismatch`, `read-error` | 4
	| `read-unsupported`, `dir-error`, `stat-error`, `open-error`, `db-error`                     | 8
	| `unstable`, `xattr-error`                                                                   | none
	| a kind this version doesn't know                                                            | 8

- `unstable` files are live ones, like a running VM's disk or a database in use. They'd set 8 on every run of the main scan and make it mean nothing. An attribute that can't be written comes after the file was checked.

- A folder that can't be listed, or stops listing part way, is a `dir-error`. The files in it aren't seen at all, so there's nothing else to count them by.

- A file the filesystem driver says it can't read is a `read-unsupported`. Debian's ntfs3 says that for every file Windows compresses or encrypts, which is most of a Windows system drive. Nothing was read, so it counts as unchecked.

## Gone

- A path's `seen_run` is the last run that reached it, by reading it, skipping it as fresh, or flagging it. Every part of a resumed run has the same id. `gone` lists the paths a finished run, status `done`, didn't reach. A stopped or failed run never walked everything, so it isn't asked.

- Only paths the run would have reached count:
	- Under one of its roots.
	- No event of their own in that run. A file that couldn't be opened or read was still there and also seen.
	- Not under a folder with a `dir-error` in that run, since nothing below it was listed.
	- Last seen from the same root or a shallower one. A scan stops at every mount, so a path another run reached from a deeper root may be on a filesystem this run didn't walk. A run with no root list, like `accept`'s, can't say, so it doesn't hold a path back.

- `--exclude` isn't kept with the run, so a folder left out counts as not seen.

## Attributes

- The names and formats match nemo-anywhere, so either program can use what the other left. The date and inode are new; nemo-anywhere ignores them.

- None are written in git work trees. Files come and go with each checkout, git checksums what it keeps, and a ctime change makes git look at each file again.

- Dropbox folders get them like any other. Dropbox already keeps its own attribute on each file, and rmlint's attributes have sat on most of them without trouble. Other attributes on a file are left as they are.

- Nothing is written to NTFS, APFS or HFS+, not attributes and not the database. Linux's drivers for them aren't reliable enough to trust with writes, and this tool only runs on Linux. They're still read and recorded.
	- A FUSE mount of a disk or image with no type of its own, `fuseblk` or a user's plain `fuse`, counts too. That's ntfs-3g or exfat-fuse in practice, and exfat has no attributes anyway.
	- The walk stays on its root's device, so a root's filesystem decides for every file under it.

- Writing changes ctime, and Linux has no call to set it back. Only changing the system clock or editing the inode on an unmounted ext4 could, and neither is safe to do per file.

- On ZFS with `xattr=on`, each file's attributes are a hidden folder plus a file per name. `xattr=sa` keeps them in the inode and is much faster.

## Snapshot diffs

- `snapdiff` counts every line it can't use and every file it couldn't stat or open, and exits 8 for them. A run that skipped input quietly would read as clean.

- A path with both a `-` and a `+` line in `zfs diff` is a file replaced by a new one. rsync without `--inplace`, tar and atomic saves do that, and they keep the time, so these get compared too.

- btrfs `find-new` names a file by its current name only. When that name isn't in the old snapshot, the old snapshot is walked once for the inode numbers it still needs, since snapshots of one subvolume keep them. A matching birth time rules out a number used again after a delete. A walk is only paid for when a listed file is missing from the old side, which new files also cause.

## Rejected

- PostgreSQL. Hashing runs at disk speed and one SQLite writer keeps up easily. A server adds a daemon and a data folder, and a single file is easier to snapshot and copy.

- Hashing from snapshots instead of live files. It would avoid unstable files but can't leave attributes on the live ones.

## Copyright and license

> Copyright © 2026 t00mietum (CryptogID: ปʬϝღถɔ4რఠΔթะ9ƾǝu)<br>
> Licensed under [GPL-2.0](../license.md). No warranty.
