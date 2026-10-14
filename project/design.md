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

- One writer thread commits at most a second apart. WAL while running, rollback mode after, so a user without write access to the folder can still open it read-only.

- Pages are 16 KiB, to match the dataset's recordsize.

## Reading files

- Each root is walked on its own and the walk stops at every mount point, so bind mounts, snapshots and other filesystems are only read when they are listed.

- Roots on the same disks share one group of workers. One worker for any group with a hard drive, 2 on SATA flash and 4 on NVMe. Two readers on one hard drive make it seek between them.

- Folders go in name order and files in inode order, which on most filesystems is close to the order on disk.

- A file is checked with fstat before and after reading. If the size, time or ctime moved, it's recorded as unstable and not stored. Running VM images and live databases land there.

- The first worker to reach a hard-linked inode claims it. Other names wait for that result rather than reading the file again, and the entry is dropped once every name has been seen.

- An EIO on ZFS means a block failed its checksum with no good copy left. It's reported the same as a mismatch.

## Skipping

- A file is skipped when the database or its attributes say it was read on or after the skip date with the same size, time and inode. The default skip date is the start of today, so a rerun the same day is cheap and a run on a later day reads everything again and compares.

- The attributes only skip a file when `user.blake3.inode` names the file's own device and inode, and the checksum beside it. `cp -a` and `rsync -aX` copy the attributes, but the copy gets another inode. The checksum in it means a later one written by nemo-anywhere, which writes no date, doesn't get to use ours.

- A date later than now never skips. Otherwise a wrong clock or a flipped bit would skip the file forever.

- Device numbers can change at a reboot or remount, as `sdX` names do. That only costs a second read.

- A resumed run keeps its original skip date. Anything it already read counts as fresh even when `--since` is later than when it began.

## Attributes

- The names and formats match nemo-anywhere, so either program can use what the other left. The date and inode are new; nemo-anywhere ignores them.

- None are written in git work trees. Files come and go with each checkout, git checksums what it keeps, and a ctime change makes git look at each file again.

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
