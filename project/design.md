<!-- markdownlint-disable MD007 -- Unordered list indentation -->
<!-- markdownlint-disable MD010 -- No hard tabs -->
<!-- markdownlint-disable MD033 -- No inline html -->
<!-- markdownlint-disable MD041 -- First line in a file should be a top-level heading -->

<!-- TOC ignore:true -->
# tukfs-hash design

<!-- TOC ignore:true -->
## Table of contents

<!-- TOC -->

- [Summary](#summary)
- [Database](#database)
- [Reading files](#reading-files)
- [Mismatches](#mismatches)
- [Skipping](#skipping)
- [Runs and exit codes](#runs-and-exit-codes)
- [Gone](#gone)
- [Attributes](#attributes)
- [Snapshot diffs](#snapshot-diffs)
- [Build and release](#build-and-release)
- [Test sandbox](#test-sandbox)
- [Leak and memory checks](#leak-and-memory-checks)
- [Profiling](#profiling)
- [Demo gif](#demo-gif)
- [Rejected](#rejected)
- [Copyright and license](#copyright-and-license)

<!-- /TOC -->

## Summary

The project was started in October 2026, after bad RAM was found on a workstation. The question was which files on disk it had changed. Files that went bad in memory before being written have valid filesystem checksums, so a scrub can't see them. What gives them away is content that changed while the size and time didn't.

## Database

- `files` has one row per distinct content, with its blake3, its size, and its blake2b when rmlint had one or the scan had `--rmlint`. `paths` has one row per name, which points at a `files` row and has the size, time, and inode, and when the name was read. The tables are split the same way as nemo-anywhere's cache, without its thumbnails.

- `runs` has one row per scan, with its skip date and a summary. `events` has every mismatch, read error, unstable file, and failed attribute write, by run.

- Names are stored as text when they're UTF-8 and as blobs when they aren't, so most of them can be matched in the sqlite3 shell with a plain string. A name that's stored as anything else, such as a number from a hand edit in the sqlite3 shell, stops the command that reads it, with the column's name in the error. A wrong type in any other column does the same.

- Unlike nemo-anywhere's cache, this database is never thrown away and rebuilt. A damaged file, or one with another table version, is refused and left alone, since it's the only record of what files used to read as. An empty file is taken as new, such as the 0-byte file that a first scan leaves when the disk fills. The tables and their version are written in one transaction, so a failed first scan can't leave them half made.

- The database has a single writer thread, which commits at least once a second. Events are written first, in their own transaction, so a row that the database refuses can't take a mismatch with it.

- The folder walk looks up each file's row before it queues the file, 256 at a time in one read transaction. A transaction per lookup cost most of the lookup, about a sixth of the CPU on small files. Each batch's transaction ends before the walk waits on the queue, so it doesn't block the writer's checkpoint for long.

- Under sudo the database and its lock, `-wal`, and `-shm` files are handed back to the user who ran sudo. A symlink at any of the 4 names is refused rather than followed, since that user could point one at a system file before a root run. The error names the link. A command that only reads checks the database's own name, since it doesn't make either WAL file. The handover is done through an fd that was opened without following links, and only for regular files.
	- The database's folder has to be owned by that user or by root, or the command stops before it makes anything. A link at the folder would otherwise have root make the files wherever it points and hand them over, and the process that could plant a link at a name could plant one there too. The lock is made and the files are handed back through an fd of the folder that was checked (2026111011092301).
	- Only a run as root hands anything back. Another user, such as one `sudo -u` runs as, can't give files away, so it doesn't check the folder or try.

- The schema is checked first on every open, and anything the program doesn't make, such as a trigger, a view, or a virtual table, is refused without reading further. `trusted_schema` is off on every connection. Under sudo the user can write to the file, so it shouldn't be able to run any code that the program didn't put there (2026102814341423).

- When the database is inside a root, the scan leaves out only the database's own names. Those are the file and its `-wal`, `-shm`, `-journal`, and `.lock` files. Anything else beside it is read, whatever its name starts with. Its folder is known by device and inode, so a walk that gets to it under another name, such as through a bind mount, leaves them out there too.

- The database is in WAL mode while a run is going, and back in rollback mode after it, so a user without write access to the folder can still open it read-only. A connection can only leave WAL mode when it's the only one with the file open. When something else has it open, the run warns and its result stands, and the next run tries again.

- Pages are 16 KiB, to match the dataset's recordsize.

- The database is also the start of tukfs's own. There's one `files` row per distinct content, and tukfs will use those rows to find duplicate files. Every scan adds to the index that tukfs starts from.

- Every edit leaves behind a `files` row that doesn't have any path pointing at it. `prune` deletes only those rows. They're never looked up, since every lookup starts from the path. A content that comes back after a prune gets a new row. `prune` takes the lock like a scan does, but it isn't a run.

## Reading files

- Each root is walked on its own and the walk stops at every mount point, so bind mounts, snapshots, and other filesystems are only read when they're given as roots.
	- It also stops at any folder on another device than the root. That includes a btrfs subvolume that isn't mounted, and anything mounted after the mount table was read.
	- A mount that's been mounted over isn't a mount point any more, and the same goes for anything mounted on it, since there isn't a path to them. The parent IDs in the mount table show which mounts those are. The same rule is used to find which mount a root or the database is on.
	- Folders given to `--exclude` and `--no-xattr` are matched by device and inode as well as by path, so a walk that gets to one under another name, such as through a bind mount, still doesn't go into it or write attributes there. The same goes for a root inside one of those folders under another name. It also goes for a root that's a bind mount of a folder inside one. The mount table gives the folder that the bind mount shows, and the folders above it are checked where another mount of that filesystem shows them. A file that's given to `--no-xattr` doesn't get attributes under any name, including a hard link, since attributes belong to the inode. `--threads` still matches by path, since it only sets how many workers read.
	- A root that's the same folder as another, or a folder that another root's walk gets to, is dropped, so a file isn't read twice. A bind mount of a folder inside another root is one of those, wherever it's mounted. The mount table gives the folder each mount shows. The walk from the other root has to get to it on its own mount, without stopping at any mount that the bind mount doesn't have. A btrfs subvolume inside another root is kept, since that root's walk stops at it. When a root can't be resolved, such as after a typo, the scan stops before reading anything, with exit 1, so the rest isn't read under a run that looks fine. A root that's gone by the time its walk starts is a `dir-error`, so the run exits 8.
	- A path given to `--exclude` or `--no-xattr` that can't be resolved stops the scan the same way, with exit 1. A typo there would read a folder or write attributes where it was told not to, and nothing else would show it.
	- A root that's an `--exclude` folder, or inside one under any name, is dropped before the run begins, with a line on stderr naming the folder. Its walk wouldn't read anything, and every name under it would show in `gone`. When no root is left, it's "nothing to scan", with exit 1.

- Every file and folder is opened from the root's own folder, without following any symlink or crossing any mount on the way. A folder that's swapped for a symlink after it was listed counts as gone, rather than sending the scan somewhere else as root. Kernels before 5.6 don't have `openat2`, so on those the open goes one folder at a time.

- Roots on the same disks share one group of workers. A group with a hard drive gets 1 worker, a group on SATA flash gets 2, and a group on NVMe gets 4. A hard drive with 2 readers seeks back and forth between them.

- Folders go in name order and files in inode order, which on most filesystems is close to the order on disk.
	- A folder with over a million files is queued a million at a time, each part in inode order, so its list stays bounded.
	- The names of a folder's subfolders are all stored in memory until the folder is done, so they can go in name order. Only the names are stored, rather than whole paths.

- A file is checked with fstat before and after reading. If the size, time, or ctime moved, it's recorded as unstable and isn't stored. Running VM images and live databases end up as unstable.

- The first worker to get to a hard-linked inode claims it. Workers that get to its other names wait for that result rather than reading the file again, and the claim is dropped once every name has been seen. Each name still gets compared with its own database row.
	- A name that's skipped by its row or attributes counts as seen too. Names outside the roots never show up, so a group stores only its newest 262,144 results, and a later name of an older inode is read again.

- A file's cached pages are dropped before it's read, so a scribble in the page cache isn't hashed as if it were on disk. ZFS ignores that advice and returns the data from the ARC, so on ZFS a second read can't tell memory from disk.
	- The read itself is `O_DIRECT` where the filesystem accepts it, so the bytes go from the disk to the read buffer and aren't cached. Filling the page cache and then dropping it cost about as much CPU as blake3 did.
	- Files under 64 KiB are read plain. Going direct costs about 35 us of sys CPU per file, which is more than the drops cost on a file that small.
	- Where `O_DIRECT` is refused, at the start or partway through, the file is read plain, and the drops before and after the read still happen. ZFS 2.3 accepts it with `direct=standard`. It hasn't been checked whether a block that's already in the ARC is still read from there, so the line above is still right.

- An EIO on ZFS means a block failed its checksum and there wasn't a good copy left. It's reported the same as a mismatch.

## Mismatches

- A file that reads differently from a stored checksum, at the same size and time, is read once more before it's believed. When the second read matches everything stored, the event is `cache-mismatch` and the file is recorded as usual.

- Otherwise the attribute and the database row are left as they were, and the scan doesn't write anything new. The next run reads the file again and reports it again. Writing the new checksum would make the next run call the damaged file clean, and a crash before the event was saved wouldn't leave any trace at all.

- `accept` is the one way to replace a stored checksum with a different one. It reads the file twice and requires both reads to agree, so a fault during that read isn't what gets kept. It logs an `accepted` event under its own run, with status `accept`, which `scan --resume` never picks up. A name that doesn't have a row in the database gets one, with a note that it isn't known to any scan by that name. A scan may have recorded the file under another name, such as through a bind mount, and the row for that name is left as it was.

- A database lookup that fails for any reason but a missing row is a `db-error` event, and the file isn't recorded. Taking such a failure for "no record" would overwrite the row unseen.

- An attribute that can't be read, for any reason but a missing name or a filesystem that doesn't have them, is an `xattr-error` event, and the file doesn't get any attributes written. Taking it for "no set" would write over the set unseen, the same as with a row. The file is still read and recorded, and checked against its database row, and `accept` takes it in the database but leaves the attributes alone. Unlike write errors, every read error is an event, since each one is that file's own.

## Skipping

- A file is skipped when the database or its attributes show it was read on or after the skip date with the same size, time, and inode. The default skip date is the start of today, so a rerun the same day is cheap, and a run on a later day reads everything again and compares.

- A file is only skipped by its attributes when `user.blake3.inode` matches the file's own device and inode and the checksum beside it, and the file's database row doesn't disagree. A scan of another name of a hard-linked file can leave a fresh set without ever looking at this name's row. `cp -a` and `rsync -aX` copy the attributes, but the copy gets another inode. The checksum is in `user.blake3.inode` so that a later checksum from nemo-anywhere, which doesn't write a date, can't use ours.

- A file with a date later than now is never skipped. Otherwise a wrong clock or a flipped bit would skip the file forever.

- Device numbers can change at a reboot or remount, as `sdX` names do. That only costs a second read.

- The skip date is the start of today, or the `--since` date, but never later than the run's start. For `--verify` the skip date is the run's own start.

- Each case has one answer. This table is the rule, and any fix to how a file is skipped should give the row it changes. Rows whose item is still open aren't met by the code yet.

	| Row              | Case                                                                                                                                                                | Answer                                                        | Item
	| :---             | :---                                                                                                                                                                | :---                                                          | :---
	| `db-fresh`       | A row at the file's size, time and inode, read between the skip date and now                                                                                        | skip                                                          | -
	| `db-old`         | The same, read before the skip date                                                                                                                                 | read                                                          | -
	| `db-future`      | A row read later than now                                                                                                                                           | read                                                          | 2026102814341401
	| `db-changed`     | A row at another size, time or inode                                                                                                                                | read                                                          | -
	| `db-mismatch`    | The last read disagreed with what's stored, and nothing has accepted it since, whatever the dates                                                                   | read                                                          | 2026102814341402
	| `db-read-error`  | The last read failed with an I/O error, and nothing has read it clean or accepted it since                                                                          | read                                                          | 2026111011092300
	| `db-unchecked`   | The last try was a `stat-error`, `open-error`, `read-unsupported` or `unstable`, so no read finished                                                                | as the other rows say, by the last good read                  | 2026111011092300
	| `resume-seen`    | A resumed run, where an earlier part reached the path at its current size, time and inode, mismatch or not                                                          | skip, and not reported again                                  | 2026101406340909, 2026102814341415
	| `x-fresh`        | No row disagrees, the set is current at the size and time, `user.blake3.inode` names this device, inode and checksum, and its date is between the skip date and now | skip                                                          | 2026101406340902
	| `x-copy`         | The inode name is missing or names another inode, as after `cp -a`                                                                                                  | read                                                          | 2026101406340902
	| `x-future`       | The set's date is later than now                                                                                                                                    | read                                                          | 2026101406340902
	| `x-row-differs`  | The set is fresh, but the row at that size and time has another checksum                                                                                            | read                                                          | 2026101406340902
	| `x-mismatch`     | The set is fresh, but the path is a `db-mismatch` or `db-read-error`                                                                                                | read                                                          | 2026102814341402, 2026111011092300
	| `x-dev`          | The device number changed since, at a reboot or remount                                                                                                             | read                                                          | -
	| `link-done`      | Another name of the inode was read in this run at the same size and time                                                                                            | not read again, but compared with this name's own row and set | 2026101406340906
	| `link-dropped`   | That result was dropped as older than the newest 262,144                                                                                                            | read                                                          | 2026101406340921
	| `link-writing`   | The name that claimed the inode is still writing its set                                                                                                            | judged only after the claim is done                           | 2026102814341429
	| `verify-known`   | `--verify`, with a blake3 stored at the current size and time, not read in this run                                                                                 | read                                                          | -
	| `verify-unknown` | `--verify`, with nothing stored at the current size and time                                                                                                        | skip, with nothing written                                    | 2026101406340931

- A resumed run keeps its original skip date. Anything it already read counts as fresh, even when `--since` is later than when it began.

- A mismatch or a read error doesn't write a row, so a file without a row at its size and time doesn't have anything there to show that an earlier part got to it. For `resume-seen` the run's own mismatch and read error events are used instead. Such a path is skipped only when its ctime is from before the run began, since that means it wasn't touched after that part read it.

## Runs and exit codes

- `--resume` only continues the newest scan, and only when it didn't finish and has the same roots. An older stopped run would bring back its old skip date, and 2 wrappers share one database, so one wrapper could finish the other's run over the wrong roots. Roots are compared in the form `plan` stores them in, so the order they're given in doesn't matter. Runs from before the root list was stored can't be resumed.

- A run that's still marked `running` when the next one starts must have been killed, since the next one has the lock. It's marked `killed`. If it's the newest, `--resume` takes it like a stopped one.

- A run that can't go on is marked `failed` and exits 1. The causes are a write that the database refused, a folder walk that couldn't open the database, or a panic. The other workers stop, the events so far are kept, and the summary is still written. `--resume` takes it like a stopped one once the cause is fixed.

- `scan --verify` reads every file that has a blake3 stored at its current size and time, in the database or on the file, and compares it the same way a scan does. Its skip date is its own start, so only what it already read in an earlier part is skipped. New and edited files aren't read. A clean read updates the database row, so a scan later that day skips it, but it doesn't write any attributes, so ctimes don't move.
	- It's a scan flag rather than its own command, since it needs everything a scan has. That's the walk and its mount rules, workers per disk, the claim on hard links, stop and resume, and events and exit codes. A command that went through the database's rows instead would read in name order rather than disk order, and couldn't open files safely from their root.
	- `runs.verify` marks these runs. `--resume --verify` only continues a verify run, and a plain `--resume` only continues a full scan. Otherwise one would finish the other with the wrong skip date and the wrong rules for attributes.

- A resumed run doesn't read again what an earlier part already judged at the same size and time, mismatches included, so it doesn't report them twice.

- A group's progress lines and its summary line end with a percent done. It's measured against the used space of the filesystems its roots are on, which comes from `statvfs`. Counting the bytes first would take a second walk, and on hard drives that's a lot of seeks. The done part is the bytes read plus the sizes of files that were skipped without being read, so a resumed run starts near where the stopped one ended. A skipped name counts its share of a hard link's size. The percent is approximate. Compression and reflinks can make the bytes read go past the space used, so it stops at 100, and snapshots keep it low. A group with a root that's a folder inside its filesystem doesn't get a percent, since the rest of the filesystem would keep it near 0. That's judged by the mount table, so a bind mount of a folder doesn't get one either, even from another filesystem. The top of a btrfs subvolume gets one, since a subvolume's used space is the whole filesystem's anyway.

- The exit code comes from the run's events in the database, rather than from the counters of the process that ends it. A file that 2 parts reported counts once, so a resume doesn't double it.

- Each event kind sets one exit code bit, and the bits add up, with 2 for a stop. This table is the rule:

	| Event                                                                                        | Bit
	| :---                                                                                         | :---
	| `b3-xattr-mismatch`, `b2b-rmlint-mismatch`, `b3-db-mismatch`, `cache-mismatch`, `read-error` | 4
	| `read-unsupported`, `dir-error`, `stat-error`, `open-error`, `db-error`                      | 8
	| `unstable`, `xattr-error`                                                                    | none
	| a kind this version doesn't know                                                             | 8

- `unstable` files are live ones, like a running VM's disk or a database in use. They'd set 8 on every run of the main scan and make the bit meaningless. `xattr-error` doesn't set one either. An attribute write comes after the file was checked, and a file whose attributes can't be read is still checked against its database row.

- A folder that can't be listed, or stops listing part way, is a `dir-error`. The files in it aren't seen at all, so there isn't anything else to count them by.

- A file that the filesystem driver says it can't read is a `read-unsupported`. Debian's ntfs3 says that for every file that Windows compresses or encrypts, which is most of a Windows system drive. The file wasn't read, so it counts as unchecked.

## Gone

- A path's `seen_run` is the last run that got to it, by reading it, skipping it as fresh, or flagging it. Every part of a resumed run has the same id. `gone` lists the paths that a finished run didn't get to, and a finished run is one with status `done`. A stopped or failed run never walked everything, so `gone` doesn't use it.

- Only paths that the run would have gotten to count:
	- They're under one of its roots.
	- They don't have an event of their own in that run. A file that couldn't be opened or read was still there, so it was seen too.
	- They aren't under a folder with a `dir-error` in that run, since that folder's contents weren't listed.
	- They were last seen from the same root or a shallower one. A scan stops at every mount, so a path that another run got to from a deeper root may be on a filesystem this run didn't walk. A run without a root list, like `accept`'s, can't show that, so it doesn't leave a path out.

- `--exclude` isn't stored with the run, so a folder that was left out counts as not seen.

## Attributes

- The names and formats match nemo-anywhere's, so either program can use what the other left. The date and inode are new, and nemo-anywhere ignores them.

- Attributes aren't written in git work trees. Files come and go with each checkout, git checksums what it tracks, and a ctime change makes git look at each file again.
	- A root below a folder with `.git` is in one too. The search for `.git` stops where the filesystem changes, as git's does.
	- A root that's a bind mount of a folder in a work tree is in it too, even though git wouldn't find the `.git` if it ran there. The files belong to the work tree all the same. The folders above the mount's source are searched where another mount of that filesystem shows them.

- Dropbox folders get them like any other folder. Dropbox already puts its own attribute on each file, and rmlint's attributes have been on most of them without trouble. Other attributes on a file are left as they are.

- The scan doesn't write anything to NTFS, APFS, or HFS+, either attributes or the database. Linux's drivers for them aren't reliable enough to trust with writes, and this tool only runs on Linux. Files on them are still read and recorded.
	- A FUSE mount of a disk or image counts too when it doesn't have a type of its own, as with `fuseblk` or a user's plain `fuse`. In practice those are ntfs-3g or exfat-fuse, and exfat doesn't have attributes anyway. A `fuseblk` mount that's given a subtype shows as `fuseblk.<name>`, and counts the same.
	- The walk stays on its root's device, so the rule for a root's filesystem applies to every file under it.
	- A set that's already there, such as one that an older build wrote, can't be updated by `accept` either. So where the file's database row is at its size and time, the scan goes by the row alone and doesn't compare the attributes. Without such a row it still compares them.

- With `--rmlint`, rmlint's `user.rmlint.blake2b.*` are written too, where they're missing or their time is stale. The format is the one rmlint 2.10 writes. The checksum is hex ending in a NUL, and the time is C's `%.17g` of seconds plus nanoseconds. A current one that disagrees is a mismatch and is left in place, the same as ours.
	- They aren't written in the same cases as ours, which are git work trees, `--no-xattr`, `--verify`, and the filesystems above.
	- A file that's skipped as already read isn't read for them. The next run that reads the file writes them.

- Writing changes ctime, and Linux doesn't have a call to set it back. Only changing the system clock or editing the inode on an unmounted ext4 could, and both are unsafe to do per file.

- On ZFS with `xattr=dir`, each file's attributes are stored in a hidden folder, with a file per name. `xattr=sa` stores them in the inode and is much faster. On current OpenZFS, `xattr=on` means `sa` and is the default, but on older releases `on` meant `dir`.

## Snapshot diffs

- `snapdiff` counts every line it can't use and every file it couldn't stat or open, and exits 8 for them. A run that skipped input quietly would look clean.

- A path with both a `-` and a `+` line in `zfs diff` is a file that was replaced by a new one. rsync without `--inplace`, tar, and atomic saves do that, and they keep the time, so those files get compared too.

- `zfs diff` lists attributes that are stored as a folder, with `xattr=dir` or when a set is too big for `sa`, as `<xattrdir>` beneath their file, such as `a/<xattrdir>/user.blake3.date`. No path leads to them, and they aren't the file's bytes, so they're skipped like folders and links rather than counted as missing. A real folder named `<xattrdir>` is found by its path and compared, and a name whose owner isn't in `--new` is still missing.

- btrfs `find-new` names a file by its current name only. When that name isn't in the old snapshot, or names another inode there, as after `mv c a`, the old snapshot is walked once for the inode numbers that are still needed, since snapshots of one subvolume preserve them. A matching birth time rules out a number that was used again after a delete. A file that the walk doesn't find is compared with the one under its name, which is what an atomic save needs. The walk only runs when a listed file is missing from the old side or has another inode there.

- A file born after `--old` was taken can't be in it, so it skips the walk. A new one is counted as only in `--new` as it's read, and an atomic save is compared by its name right away. The time comes from btrfs's subvolume info, which needs no root. It's used only for a read-only snapshot that wasn't received, since files can be added to a writable one later, and a received one's files are all born after it. Otherwise new files wait for the walk like renamed ones. A clock that was set ahead when a file was made, and back by the snapshot, could make a renamed file look new, and then it's compared by name or counted as new.

- find-new and lists can name new files, so a file only in `--new` is counted apart from missing ones and isn't an error. zfs diff names files that are in both snapshots, so there it's missing.

- The change list is read a line at a time, and each file is compared as it's read, so that way memory doesn't grow with the list. Only zfs diff's `-` and `+` names, and the files that wait on the walk, are stored until the end. A file that waits keeps only its name and birth time, and the walk's list its inode, and both sides are stat'd again after the walk. A list of 100,000 lines took 66 MB before, and now takes the same as a list of 1 line. The integration test fails when 100,000 different names take 1 MB more than 1 line does, measured by peak RSS from GNU time, since a child of python3 starts at python's own peak. A line that's refused stops the run where it's read, with exit 1, after whatever was printed before it.

- A changed file keeps only the first 8 runs of bytes that differ, which its line names, and counts for the rest. 2 files of 64 MiB that differ in 1 byte of every 8 took 135 MB before, and now take what a 1-byte change does. The integration test fails when a 4 MiB file with 524,288 runs takes 1 MB more than one with a byte changed.

- Files are opened beneath `--old` and `--new` the same way scan opens them beneath a root, without following any symlink or crossing any mount on the way. A name that goes through a symlinked folder isn't in that snapshot, and counts as missing there. `--old` and `--new` themselves may be symlinks, since a person types them. Snapshots can't change, but a folder in one can still be a link to the live system, or a list can name one.

- Output is in the list's order. zfs diff's replaced files come last, sorted by name. find-new's files come in its own order, which is by inode, and the ones that waited on the walk come last. They used to be sorted by name, which needed the whole list in memory.

## Build and release

- `Cargo.toml` is the only place where the version is stored. The release tag and the build stamp are both made from it, so they can't disagree.

- The build number is the commit time in minutes since 2000-01-01 UTC, rounded, in lower-case Crockford base32. `cicd/cicd.bash` passes it in at compile time through `build.rs`, and `--version` prints it after the version. It comes from the commit rather than the clock, so 2 builds of one commit match. A plain `cargo build` doesn't have one.

- A build that isn't a release shows its date after the build number, such as `build debj2 (2026-10-23)`. The date is worked out from the build number when `--version` runs, in the local time zone of whoever runs it, so the same binary can show a different day in another zone. A release is a commit that's tagged `v<version>`, so the tag goes on before the release is built. A release build leaves the date off. The release check runs `--version` in the box's zone, UTC+14, and UTC-12, since the last 2 never share a date.

- A build of a tree that differs from its commit's, such as one with uncommitted work in the frozen copy, gets `-dirty` after the build number, such as `build debj2-dirty (2026-10-23)`, and is never a release, tag or not. The number still names the commit it was built on. Untracked files that aren't ignored count, the same as for the tree the gate records. The merge gate builds the pushed commit, so it's never marked (2026102814341434).

- Feature branches merge into `dev` with `--no-ff`. A `dev` to `main` merge is a release, and gets tagged. Pulls are `--ff-only`.

- The pipeline runs here, rather than on a hosted service. The pre-push hook runs `--merge-gate` on a push to `main`, and a push to `dev` or a feature branch isn't gated. The merge gate runs every check of a run with no options, so it takes most of an hour. It's skipped for a push to `main` that changes only the paths in `cicd/docs-paths`, which are `.md` files and `assets/`.
	- A backlog worker runs `--backlog-run-quick`, alone or with the areas `--help` lists, and a round runs `--backlog-run-full` at its end. `--gate` and `--ci` are other names for `--backlog-run-quick` and `--merge-gate`.
	- The 3 modes don't sync, dogfood, publish, install, rewrite a tracked file, or prompt. The demo gif they draw stays in the run's temp dir.
	- A run records the tree it tested only when it's at least as thorough as the merge gate, and the hook lets that tree through without running it again. It records the tree only once the demo gif has passed too, in the run that was started rather than the one on the frozen copy. `--no-gif` makes a run partial (2026102814341404). A run with no options records the tree with the gif it copied into the checkout, since the merge gate draws the same bytes from that tree and publish commits it. When anything else changed during the run, it doesn't record anything (2026102819580272).
	- A run with no options publishes last. It refuses when the checkout no longer has the tree the run tested, other than the demo gif it drew, or when the upstream has commits the run didn't take. On a box without rar it publishes without a backup (2026102814341411, 2026102814341426).
	- In the 3 check-only modes a missing tool fails the run. The check scripts get this setting as `TUKFS_GATE_STRICT`. A check that needs the leak check image, on a box without docker or the tool, is a skip instead, and the run doesn't record its tree (2026102814341405).

- `rust-toolchain.toml` pins the stable toolchain, so lint results don't move with the box. The dated nightly for sanitizer and Miri runs is in `cicd/tool-pins.env`.

- The bundled SQLite is built without FTS3, FTS5, R-Tree, and extension loading, since the program doesn't use any of them. `LIBSQLITE3_FLAGS` in `.cargo/config.toml` sets that. Every cargo build in the tree reads it, including the release image's and the leak checks', and a unit test fails when the flags are missing (2026102814341423).

- Release builds are Linux only, since the tool reads Linux xattrs, mounts, and snapshots. Both are built in a Debian 10 image from `cicd/container-release/`, so they need its glibc 2.28 rather than the box's. That means they run on RHEL 8, Debian 10, Ubuntu 18.10, and anything newer. arm64 is cross-built there with Debian's cross gcc, which also compiles the bundled SQLite. It takes about as long as x86_64, so every run builds both. The debug build, clippy, the unit tests, and the release build that the integration test runs are built in the same image, into `target/ctr`, so they use its pinned toolchain, the merge gate included, and the integration test can run that build on any box. Without docker, or when the image can't be set up, they build on the box with a one-line note, and `--no-container` does that on purpose. The integration test and the soak run on the box, since they scan its real disks, in the test sandbox below.
	- The release stage does the same, so a box without docker still gets a release build, and the run doesn't fail because of it, even in the merge gate. Only x86_64 is built then, into `target/release-host`, since the box doesn't have an arm64 cross gcc. It needs the box's glibc, so the floor check gives a note rather than failing. Such a run doesn't record its tree for the pre-push hook, the same as one with a missing tool (2026102509342993).

- The release set, in `cicd/artifacts/release/`, is named `tukfs-hash-<version>-linux-x86_64` and `tukfs-hash-<version>-linux-arm64`, the same names plus `.deb` and `.rpm`, and `tukfs-hash-<version>-sha256sums.txt`. Download links depend on these names, so they don't change. The x86_64 name is never amd64, though the `.deb` has to say amd64 inside.
	- Only a run that can make a release writes it there. The backlog runs and the merge gate build theirs in the run's temp dir, and the other hosts and the gif read it from there, so a check run leaves the set the way the last run that could make a release left it (2026102814341427).

- A run with no options on `main` uploads the release set to the git host as release `v<version>`, after publish, through `cicd/utility/release-upload.bash` (2026110218175401). It tags HEAD `v<version>` before the build when the tag isn't there yet, and takes it off again if the run stops before the upload. If a tag of that name is on another commit, here or on the git host, the run stops before the build, since the version wasn't bumped. It also stops when the checkout has uncommitted changes after the format stage, which is when the tree is checked and the tag goes on.
	- The upload pushes the tag, then makes the release with the files that the sums file lists, plus the sums file itself, under their own names. A version with a `-` in it, such as `1.0.0-beta.1`, is a pre-release. The git host marks the newest of the rest as the latest, by version, so an installer finds it as the latest release, or lists them all through the host's API. The notes are the build's version line and the version's section of `changelog.md`.
	- The upload runs only in a run that's as thorough as the merge gate and didn't skip anything, and never in the check-only modes, `--quick`, `--no-publish`, or `--no-upload`. If anything was skipped, or the release set isn't a release build, the run stops before publish, so it doesn't push anything, and the tag comes off. When the release image can't run, as with `--no-container` or without docker, the set would be a host build, so the plan leaves out the upload and the tag and says why (2026111011092304). A release that's already there gets only the files it lacks. A release with other bytes under one of those names fails the run, since a download link must never change what it gives. When the upload fails, it prints the command to finish it by hand.

- The packages contain only `/usr/bin/tukfs-hash`. They depend on the glibc that the binary was linked for, which is read off the binary and is 2.28 for both. Both also need `libgcc_s`.

- Any 2 builds of one commit give the same bytes, including the packages. The build number and the packages' mtimes come from the commit time. cargo's home is mapped to `/cargo` in panic messages, so whose home it is doesn't matter, and the checkout's own paths are already relative. Before the set replaces the old one, release checks look at the stamped `--version`, each build's architecture, each package's files and bytes, and whether any build needs a glibc newer than 2.28. The release builds aren't the ones the tests stage tested, so the integration test runs again on the x86_64 one, and the unit tests run on arm64 under qemu in the same image.

- A run with no options, the merge gate, and `--backlog-run-full` then run the arm64 unit tests and the integration test on the arm64 Linux test VM, vmDebARM64, on the arm64 release build. The qemu run stays as the quick check. The VM is held through the shared host lock for as long as it's used. The VM state helper then puts it back the way it was found, whether paused, off, or running. Its work folder goes under the box's temp root, or `/var/tmp` when that's in memory, since the scan refuses tmpfs. The folder has a `.box-run` mark. Old folders there are removed after 2 days, but only when they have that mark, so a folder that was made by hand or kept by the integration test stays (2026102814341410). `--quick` leaves it out, since the VM is emulated and takes about 3 minutes, and `--no-remote` skips it (2026102416215927).
	- The step is a `SKIP`, in the step and in the summary at the end, when the VM isn't there, when the box is held elsewhere for over 15 minutes, when it's missing a tool that the integration test needs, or when the run doesn't have an arm64 build. The run goes on. Like a missing test root, a skip keeps the tree from being recorded for the pre-push hook.

- Each run works in `<HOST_TEMP>/tukfs-hash/<YYYYmmDD-HHMMSS>_<NNN>/`, or under `RUN_TMP_ROOT` in `cicd/config.bash` when `HOST_TEMP` isn't set, with `TMPDIR`, `TEMP`, and `TMP` pointed there. The folder has the run's PID in `run.pid`, and it's removed at the end, on a failure or a stop too. A run also removes this project's run folders whose process is gone, such as a killed run's folder with its frozen copy, and it leaves alone any folder there without the mark. The integration test makes its own folder the same way, under the `HOST_TEMP` it's given, so each test root gets one. `--keep-temp` keeps them and prints where, and the sweep leaves a kept folder for 2 days (2026102416215934, 2026102518150001). A folder's marks are removed last, so one whose removal fails partway is still swept at the next run (2026110210514819).

- The integration test runs once on each test root in `IT_ROOTS` in `cicd/config.bash`, ext4 and ZFS. Its btrfs subvolume check needs btrfs, so each run is also given `IT_BTRFS`, `/tmp` by default, as `TUKFS_IT_BTRFS`. The test makes a second folder of the same kind under `<IT_BTRFS>/tukfs-hash/` for that check, with 3 small files, and the sandbox can write there too. Few boxes have btrfs, so where that folder isn't on btrfs the check skips with a note, and the tree is still recorded, unlike with a missing test root (2026110211132205).
	- Every container is named `tukfs-hash-<run folder name>-<step>-<n>`, and containers and images are labeled `dev.project=tukfs-hash` and `dev.run=<run folder name>`. The containers don't use any volumes. The run removes its containers by that label at the end, once a stop has killed the running ones by ID, and says what that freed. `--keep-temp` keeps them. A new image keeps the tag before it (2026102416215928). The run leaves docker's build cache alone, since every project shares it. The daemon's own gc trims it, which is set under `builder.gc` in `/etc/docker/daemon.json` on b23 (2026110311291911).

- The dogfood copy goes to `~/synced/0-0/common/exec/util/linux/bin/tukfs-hash`, where the scan wrappers look, rather than the `app/linux/` dir. The stage leaves the copy there alone while it's running. Another user's run, such as one through sudo, is found by its name, since its exe link can't be read (2026102814341417). `utility/dogfood_tukfs-hash` keeps up to 10 dated versions in `~/.local/bin/tukfs-hash_versions/`, with a link to the newest at `~/.local/bin/tukfs-hash`.
	- `dogfood_tukfs-hash.ps1` copies a new build in, rotates the pool, points the fixed name at the newest, and prints the newest version's own path in the pool, never the fixed name. That way a run that repoints the name while this one starts can't swap the build, and the process shows which version it is. The fixed name is there for PATH. The bash launcher execs that path in its own place, with every argument but `--no-update` as typed, so the exit code is the build's own, on a Ctrl+C too. pwsh would expand wildcards and `~` in them, and can't pass a name that isn't UTF-8 (2026102814341409). A copy that's running is never deleted, so a long scan keeps going while a newer build is put in the pool.
	- Anything at the fixed name that isn't a link into the pool is left alone, and the newest version runs from the pool instead.
	- The pool keeps at most 10 versions and at least 5, and between those only as many as fit in 1 GB. The ones that stay are picked by a GFS rotation, which keeps the oldest, the newest, the last of each recent hour, day, week, month, and year, and the few most recent. Under 10 and 1 GB, versions without any of those roles stay too, as spares. When the count or the size limit cuts in, the newest and oldest stay first, then the roles from year down to frequent, newest first within each, so a burst of builds can't push out the week and day ones (2026102814341441).
	- Each is named `tukfs-hash_<yyyyMMdd-HHmmss>_<role>`, from the build's write time in local time. Old versions are removed one file at a time, matched by that name, and one that's running is never removed. Another user's run, such as one through sudo, doesn't have an exe link to read, so it's found by its name and first argument, as in the dogfood stage. A run through the fixed name keeps the version that was newest when it started, by the time each was added to the pool, which is the pool file's write time (2026102819305559).

## Test sandbox

- A scan writes xattrs, and as root it can write them on every file. A bug in the code under test could do that outside its test folder. So every step that runs test code on the box runs in `cicd/utility/sandbox.bash`, through bubblewrap. Those steps are the build, clippy, and the unit tests when there isn't an image, the integration test on each test root, the release check's integration test, the soak, the fuzz tests, the profiler's scans, and the demo gif's commands.

- Inside, the whole filesystem is read-only except for the folders the step is given, which are its own temp folder and the build dirs. Home, `/tmp`, and `/run` are empty, so the sockets there can't be reached, such as docker's, ssh-agent's, tmux's, and the session bus. The step doesn't have a network, it can't see or signal any other process, and sudo can't raise anything. Only the Rust toolchain and cargo's crate cache are shown from home, read-only, and cargo runs offline from a `cargo fetch` that's done right before it.

- ZFS doesn't show any pool to a user namespace that it isn't delegated to, so `zpool list` fails inside. A scan needs it to find the pool's disks. The sandbox puts a stand-in first on PATH that prints what the real one printed outside, for the pools of the writable folders only.

- The integration test passes the same checks in it as without it, on ext4 and ZFS. Writing outside the folders it's given fails with "Read-only file system".

- When bubblewrap is missing or user namespaces are turned off, the step fails and says so. `--no-sandbox` runs the steps without it, with a warning on each. The build image doesn't need one, since the container already has only the run's dirs mounted.

## Leak and memory checks

- Each leak check has a length in `cicd/config.bash`, based on its measured time with the image and build dirs warm. The fast ones, which take under a minute each, run in every run but `--backlog-run-quick`, including `--quick`. They're the known-advisory scan, the soak, the unit tests under ASan and LSan, then TSan, and the parser fuzz tests at 20 s each. Miri and CodeQL take minutes, so they run in a run with no options, `--long`, the merge gate, and `--backlog-run-full`, and in `--quick` only with `--leakcheck`. The only ones that take hours are the fuzz tests again at an hour each, and they run only in `--long`. `--backlog-run-quick` runs the leak checks only for a leak area or `--leakcheck`. They end the tests stage in that order, and any report fails the run (2026102517244901).

- `--no-codeql` leaves out only CodeQL, which is about 11 of a full run's 17 minutes. It drops each leak check step whose command names codeql.

- The sanitizers, Miri, and CodeQL run in the image from `cicd/container/`, with the pinned nightly and CodeQL, without a network, and with only the run's own dirs and `target/leakcheck/` mounted. Its crates are fetched once per lock file into `target/leakcheck/cargo-home`. Without docker they run on the host with a note, and CodeQL is skipped.

- The soak and the advisory scan run on the host. A scan finds its workers from the root's disks through `/dev`, which a container doesn't have, and cargo-deny fetches RustSec's database. The soak and the fuzz tests run in the test sandbox. So do the sanitizers and Miri without docker. The advisory scan only reads `Cargo.lock`, so it runs as is.

- The soak in `src/soak.rs` runs scan, change, scan, runs, report, gone, and accept 20 times in one process, and fails when the heap at round 20 is over round 10's by more than 4 KB. The Rust heap is measured by dhat's count. SQLite's heap is measured by its own count, since SQLite allocates through libc, which dhat doesn't see. Both are back to 0 bytes live after every round, so the margin can be small. The soak is behind the `soak` feature, since dhat then counts every allocation in the test binary.

- The bundled SQLite is built by clang with the same sanitizer as the Rust code, with its lookaside and page cache pools off so each block is a malloc of its own.

- SQLite sets itself up on first use with plain reads and writes, and TSan caught 2 test threads doing that at once. `db::init()` does it once, behind a `Once`, before any connection opens. A scan already did it on the main thread before its workers started.

- The parser fuzz tests are plain unit tests named `fuzz_*`. There's one beside each parser, for the mount table, `zfs diff` and find-new output, lists, `--since` dates, and the base64url, hex, and inode xattr values. A generator for each format makes well-formed input with odd bytes in it, and parsing that input has to give back what was built. Real samples are also damaged, with bits flipped, cut short, or with the separator bytes put in. The parser can't panic on those, and what comes out has to make sense, such as each line that a snapshot diff can't use being named by its own number and text (2026102517244907).
	- Each case is a pure function of one seed, so a failure prints the `TUKFS_FUZZ_SEED` that runs it again alone. `TUKFS_FUZZ_SECS` is the wall time per parser, which is 1 s in the plain unit tests, with at least 300 cases. Each run starts from a new seed, so runs add up.
	- Each also checks that its generator still makes every kind of line it's meant to, so a change that stops one fails rather than passing on less.
	- `cicd/utility/fuzz.bash SECS` runs only those, from the unit tests' release build, on a quarter of the cores at a time. Miri skips them, since they're safe code and get too few cases in the time.

- Miri skips what it can't run, which is SQLite, since it's C, plus xattrs, `openat2`, and `mktime`. It also skips 2 tests of safe code that take it over 15 minutes. Each says why in its `#[cfg_attr(miri, ignore = ...)]`.

- CodeQL runs over a copy of the tree with every crate vendored and its full source extracted. A finding in a crate counts only when it comes from a security or correctness query, and only in code that's built into the release binary. Findings that were looked at and aren't bugs are listed in `cicd/codeql/vendored-reviewed.tsv` by crate version, since cargo vendor writes the code again each run and a comment there would be lost. A crate update leaves its lines stale, which fails the run until they're looked at again.

- `--backlog-run-quick codeql-ours` runs `codeql-scan.bash --ours`, which takes about 3 minutes rather than 10 to 15, so a worker can run it on its own change. It leaves the crates in the cargo home, where only their signatures are extracted, as CodeQL's default setup does for Rust, and reports only on our code, with the same bait, file checks and suppressions. Its output goes in `cicd/artifacts/codeql-ours/`. No other run takes it, since it doesn't stand in for the full scan: the crates' own findings, and any finding in our code whose flow runs through a crate's code, show up only there (2026111015123269).

## Profiling

- A full run draws a flamegraph of a scan into `cicd/artifacts/profiling/`, GFS-rotated, and prints `cicd/utility/flame-report.py`'s summary of it in the log. `--quick` and `--gate` leave it out.

- `perf` can't record on b23, since `kernel.perf_event_paranoid` is 3, so the sampler is pprof, which runs in the process on SIGPROF. It's behind the `profiling` feature and the `profiling` cargo profile, which is release with names kept. pprof's flamegraph writer is inferno, which is CDDL-1.0, so a build with the feature never leaves the box. A release build doesn't change by a byte. The hook is at the bottom of `src/main.rs`, so the lines above it keep their numbers, which show up in the release build's panic messages.

- The workload runs on a generated tree of about 1.5 GB on ext4, which is synced first so the scan reads the disk. It's a first scan, then bytes changed with the mtime put back and some ordinary edits, then a rescan with `--rmlint` and a `--since` past the first scan, so every file is read again with blake2b. Each scan adds its samples to one graph, under its own name below the root.

- libc isn't on the sampler's blocklist, unlike shcl's, since a scan's reads and attribute calls end there. libgcc, the vdso, and the loader are, since unwinding from inside them isn't safe. `_Unwind_FindEnclosingFunction` is defined in the binary, as in shcl, since otherwise LTO leaves one name on most of a scan.

- A thread in the kernel gets fewer SIGPROFs than its share. It gets about 35% against a busy thread in user code, where 50% would be fair. So the graph understates system time. The subtitle has each scan's user and system CPU from `getrusage`, which doesn't, and wall time past the CPU is waiting on the disk. Judge I/O against hashing from those numbers.

- blake3's assembly doesn't have unwind info or symbol sizes, so its samples come back without a name. The profiling build names them by where the functions start.

- Before any graph is drawn, an attribution check runs 2 threads for the same time. The first thread runs 2 loops at 3 to 1, inlined into one function, and the second reads a cached file. The loops have to split about 3 to 1, and the reader has to get a share. Each of those fails with its fix taken out.

- pprof's crates count for the advisory scan, which ignores 2 advisories in quick-xml's reader, since inferno only writes. CodeQL's copy of the tree leaves them out, along with `src/profiling.rs`. uuid is one of those crates, and CodeQL took its `Display` for a secret that every `format!` in the tree could log.

- The report puts self time in the bucket of the nearest known caller. The buckets are blake3, blake2b, SQLite, xattr reads, xattr writes, file reads, and the walk. They're keyed on function names, so a rename moves time into "other".

## Demo gif

- The gif at the top of README.md is drawn on each full run by `cicd/utility/gen-demo-gif.py`, from `cicd/demo/scenario.toml`, which follows `cicd/demo/script.txt`. The commands run for real, against that run's release build, in a home folder that's made in the run's temp dir, with the database there too. `--quick` and `--gate` leave it out.

- The output shows the home as `/home/<user>`, with the prompt's made-up user, and this box's host and user names as the prompt's. After that, a line with the real user, home, host, or a temp path fails the stage rather than going into the README. The host is caught next to `-`, `_`, or `.` too, such as `<host>-old`.

- The demo files are the same bytes every run, and dates, times, the disk name, the worker count, and the scan's own run time in the output are pinned, so a render only changes when the output or the script does. `assets/demo.gif` is replaced only when it differs.

- A step that exits with anything but what the scenario says fails the stage, since the gif would show an error as if it were the tool working. A missing Pillow or font is a warning, and the run goes on.

- An unknown key in the scenario, such as a misspelled `pause`, fails the stage, and so does a value of the wrong type. Otherwise the step would fall back to the default without a word.

- Every frame time is a whole number of 20 ms frames, which is 50 fps, and that's checked after the gif is written.

- Each render is GFS-rotated into `../private/demo/gif/`, outside the repo. `private` is a link, so it's resolved first, and a link below it fails the stage.

## Rejected

- PostgreSQL was rejected. Hashing runs at disk speed, and a single SQLite writer keeps up easily. A server adds a daemon and a data folder, and a single file is easier to snapshot and copy.

- Hashing from snapshots instead of live files was rejected. It would avoid unstable files, but it can't leave attributes on the live ones.

## Copyright and license

> Copyright © 2026 t00mietum (CryptogID: ปʬϝღถɔ4რఠΔթะ9ƾǝu)<br>
> Licensed under [GPL-2.0](../license.md). No warranty.
