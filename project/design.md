<!-- markdownlint-disable MD007 -- Unordered list indentation -->
<!-- markdownlint-disable MD010 -- No hard tabs -->
<!-- markdownlint-disable MD033 -- No inline html -->
<!-- markdownlint-disable MD041 -- First line in a file should be a top-level heading -->

# tukfs-hash design

## Summary

Started in October 2026 after bad RAM was found on a workstation. The question was which files on disk it had changed. Files that went bad in memory before being written have valid filesystem checksums, so a scrub can't see them. What gives them away is content that changed while the size and time didn't.

## Database

- `files` is one row per distinct content: blake3, size, and blake2b when rmlint had one or the scan had `--rmlint`. `paths` is one row per name, pointing at a `files` row, with the size, time, inode and when it was read. The split is the same one nemo-anywhere's cache uses, without thumbnails.

- `runs` has one row per scan, with its skip date and a summary. `events` has every mismatch, read error, unstable file and failed attribute write, by run.

- Names go in as text when they're UTF-8 and as blobs when they aren't, so the sqlite3 shell can match most of them with a plain string.

- Unlike nemo-anywhere's cache, this one is never thrown away and rebuilt. A damaged file, or one with another table version, is refused and left alone, since it's the only record of what files used to read as.

- One writer thread commits at most a second apart. Events go in first, in their own transaction, so a row the database refuses can't take a mismatch with it.

- The folder walk looks up each file's row before it queues the file, 256 at a time in one read transaction. A transaction per lookup cost most of the lookup, about a sixth of the CPU on small files. Each batch ends before it waits on the queue, so it doesn't hold back the writer's checkpoints for long.

- Under sudo the database and its lock, `-wal` and `-shm` files are handed back to the user who ran it. A symlink at any of the 4 names is refused rather than followed, since that user could point one at a system file before a root run. The handover goes by an fd opened without following links, and only for regular files.

- A database inside a root leaves out only its own names, the file and its `-wal`, `-shm`, `-journal` and `.lock`. Anything else beside it is read, whatever its name starts with.

- WAL while running, rollback mode after, so a user without write access to the folder can still open it read-only. Leaving WAL mode needs the file to itself. When something else has it open, the run warns and keeps its result, and the next run tries again.

- Pages are 16 KiB, to match the dataset's recordsize.

- Every edit leaves a `files` row no path points at. `prune` deletes those and nothing else. They're never looked up, since a lookup goes from the path. A content that comes back after a prune gets a new row. It takes the lock like a scan, and isn't a run.

## Reading files

- Each root is walked on its own and the walk stops at every mount point, so bind mounts, snapshots and other filesystems are only read when they are listed.
	- It also stops at any folder on another device than the root. That covers a btrfs subvolume that isn't mounted, and anything mounted after the mount table was read.
	- A mount that's been mounted over isn't a mount point any more, and neither is anything mounted on it, since no path reaches them. The table's parent IDs show which those are. The same goes for which mount a root or the database is on.
	- A root that's the same folder as another, or inside another on the same mount and device, is dropped, so nothing is read twice. A btrfs subvolume inside another root is kept, since that root's walk stops at it. A root that can't be resolved, or is gone by the time its walk starts, is a `dir-error`, so the run exits 8.

- Every file and folder is opened from the root's own folder, and no symlink is followed and no mount crossed anywhere on the way. A folder swapped for a symlink after it was listed counts as gone, rather than sending the scan, which runs as root, somewhere else. Kernels before 5.6 have no `openat2`, so there it goes one folder at a time.

- Roots on the same disks share one group of workers. One worker for any group with a hard drive, 2 on SATA flash and 4 on NVMe. Two readers on one hard drive make it seek between them.

- Folders go in name order and files in inode order, which on most filesystems is close to the order on disk.
	- A folder with over a million files is queued a million at a time, each part in inode order, so its list stays bounded.
	- The names of a folder's subfolders are all held until it's done, for the name order. Only names are kept, not whole paths.

- A file is checked with fstat before and after reading. If the size, time or ctime moved, it's recorded as unstable and not stored. Running VM images and live databases land there.

- The first worker to reach a hard-linked inode claims it. Other names wait for that result rather than reading the file again, and the entry is dropped once every name has been seen. Each name still gets compared with its own database row.
	- A name skipped by its row or attributes counts as seen too. Names outside the roots never come, so a group keeps only its newest 262,144 results, and a later name of an older one is read again.

- A file's cached pages are dropped before it's read, so a scribble in the page cache isn't hashed as if it were on disk. ZFS ignores that advice and answers from the ARC, so there a second read can't tell memory from disk.
	- The read itself is `O_DIRECT` where the filesystem takes it, so the bytes go from the disk to the read buffer and nothing is cached. Filling the page cache and then dropping it cost about as much CPU as blake3 did.
	- Files under 64 KiB are read plain. Going direct costs about 35 us of sys CPU per file, more than the drops cost on a file that small.
	- Where `O_DIRECT` is refused, at the start or partway through, it's a plain read, and the drops before and after it still apply. ZFS 2.3 takes it with `direct=standard`, but whether a block already in the ARC is still served from there hasn't been checked, so the line above stands.

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

- The skip date is the start of today, or `--since`, but never later than the run's start. `--verify`'s is its own start.

- Each case has one answer. This table is the rule, and a fix to how a file is skipped names its row. Rows whose item is still open aren't met yet.

	| Row              | Case                                                                                                                                                                | Answer                                                        | Item
	| :---             | :---                                                                                                                                                                | :---                                                          | :---
	| `db-fresh`       | A row at the file's size, time and inode, read between the skip date and now                                                                                        | skip                                                          | -
	| `db-old`         | The same, read before the skip date                                                                                                                                 | read                                                          | -
	| `db-future`      | A row read later than now                                                                                                                                           | read                                                          | 2026102814341401
	| `db-changed`     | A row at another size, time or inode                                                                                                                                | read                                                          | -
	| `db-mismatch`    | The last read disagreed with what's stored, and nothing has accepted it since, whatever the dates                                                                   | read                                                          | 2026102814341402
	| `resume-seen`    | A resumed run, where an earlier part reached the path at its current size, time and inode, mismatch or not                                                          | skip, and not reported again                                  | 2026101406340909, 2026102814341415
	| `x-fresh`        | No row disagrees, the set is current at the size and time, `user.blake3.inode` names this device, inode and checksum, and its date is between the skip date and now | skip                                                          | 2026101406340902
	| `x-copy`         | The inode name is missing or names another inode, as after `cp -a`                                                                                                  | read                                                          | 2026101406340902
	| `x-future`       | The set's date is later than now                                                                                                                                    | read                                                          | 2026101406340902
	| `x-row-differs`  | The set is fresh, but the row at that size and time has another checksum                                                                                            | read                                                          | 2026101406340902
	| `x-mismatch`     | The set is fresh, but the path is a `db-mismatch`                                                                                                                   | read                                                          | 2026102814341402
	| `x-dev`          | The device number changed since, at a reboot or remount                                                                                                             | read                                                          | -
	| `link-done`      | Another name of the inode was read in this run at the same size and time                                                                                            | not read again, but compared with this name's own row and set | 2026101406340906
	| `link-dropped`   | That result was dropped as older than the newest 262,144                                                                                                            | read                                                          | 2026101406340921
	| `link-writing`   | The name that claimed the inode is still writing its set                                                                                                            | judged only after the claim is done                           | 2026102814341429
	| `verify-known`   | `--verify`, with a blake3 stored at the current size and time, not read in this run                                                                                 | read                                                          | -
	| `verify-unknown` | `--verify`, with nothing stored at the current size and time                                                                                                        | skip, with nothing written                                    | 2026101406340931

- A resumed run keeps its original skip date. Anything it already read counts as fresh even when `--since` is later than when it began.

## Runs and exit codes

- `--resume` only continues the newest scan, and only when it didn't finish and has the same roots. An older stopped run would bring back its old skip date, and 2 wrappers share one database, so one could finish the other's run over the wrong roots. Roots are compared as `plan` keeps them, so the order they're given in doesn't matter. Runs from before the root list was kept can't be resumed.

- A run still marked `running` when the next one starts was killed, since the lock is held. It's marked `killed`. If it's the newest, `--resume` takes it like a stopped one.

- A run that can't go on is marked `failed` and exits 1. That's a write the database refused, a folder walk that couldn't open the database, or a panic. The other workers stop, the events so far are kept, and the summary is still written. `--resume` takes it like a stopped one once the cause is fixed.

- `scan --verify` reads every file that has a blake3 stored at its current size and time, in the database or on the file, and compares it the same way a scan does. Its skip date is its own start, so only what it already read in an earlier part is skipped. New and edited files aren't read. A clean read updates the database row, so a scan later that day skips it, but no attributes are written, so ctimes don't move.
	- It's a scan flag rather than its own command, since it needs everything a scan has: the walk and its mount rules, workers per disk, the claim on hard links, stop and resume, events and exit codes. A command that went through the database's rows instead would read in name order, not disk order, and couldn't open files safely from their root.
	- `runs.verify` marks these runs. `--resume` only continues one with `--verify`, and a full scan only without it. Otherwise one would finish the other with the wrong skip date and the wrong rules for attributes.

- A resumed run doesn't read again what an earlier part already judged at the same size and time, mismatches included, so it doesn't report them twice.

- The exit code comes from the run's events in the database, not from the counters of the process that ends it. A file reported by 2 parts counts once, so a resume doesn't double it.

- Each event kind sets one exit code bit, and the bits add up with 2 for a stop. This table is the rule:

	| Event                                                                                        | Bit
	| :---                                                                                         | :---
	| `b3-xattr-mismatch`, `b2b-rmlint-mismatch`, `b3-db-mismatch`, `cache-mismatch`, `read-error` | 4
	| `read-unsupported`, `dir-error`, `stat-error`, `open-error`, `db-error`                      | 8
	| `unstable`, `xattr-error`                                                                    | none
	| a kind this version doesn't know                                                             | 8

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
	- A root below a folder with `.git` is in one too. The search stops where the filesystem changes, as git's does.

- Dropbox folders get them like any other. Dropbox already keeps its own attribute on each file, and rmlint's attributes have sat on most of them without trouble. Other attributes on a file are left as they are.

- Nothing is written to NTFS, APFS or HFS+, not attributes and not the database. Linux's drivers for them aren't reliable enough to trust with writes, and this tool only runs on Linux. They're still read and recorded.
	- A FUSE mount of a disk or image with no type of its own, `fuseblk` or a user's plain `fuse`, counts too. That's ntfs-3g or exfat-fuse in practice, and exfat has no attributes anyway. A `fuseblk` given a subtype shows as `fuseblk.<name>`, and counts the same.
	- The walk stays on its root's device, so a root's filesystem decides for every file under it.

- With `--rmlint`, rmlint's `user.rmlint.blake2b.*` are written too, where they're missing or their time is stale. The format is what rmlint 2.10 writes: hex ending in a NUL, and the time as C's `%.17g` of seconds plus nanoseconds. A current one that disagrees is a mismatch and stays, the same as ours.
	- The same places get none: git work trees, `--no-xattr`, `--verify` and the filesystems above.
	- A file skipped as already read isn't read for it. The next run that reads it fills it in.

- Writing changes ctime, and Linux has no call to set it back. Only changing the system clock or editing the inode on an unmounted ext4 could, and neither is safe to do per file.

- On ZFS with `xattr=on`, each file's attributes are a hidden folder plus a file per name. `xattr=sa` keeps them in the inode and is much faster.

## Snapshot diffs

- `snapdiff` counts every line it can't use and every file it couldn't stat or open, and exits 8 for them. A run that skipped input quietly would read as clean.

- A path with both a `-` and a `+` line in `zfs diff` is a file replaced by a new one. rsync without `--inplace`, tar and atomic saves do that, and they keep the time, so these get compared too.

- btrfs `find-new` names a file by its current name only. When that name isn't in the old snapshot, the old snapshot is walked once for the inode numbers it still needs, since snapshots of one subvolume keep them. A matching birth time rules out a number used again after a delete. A walk is only paid for when a listed file is missing from the old side, which new files also cause.

## Build and release

- `Cargo.toml` is the only place the version is kept. A release tag and the build stamp both read it from there, so they can't disagree.

- The build number is the commit time in minutes since 2000-01-01 UTC, rounded, in lower-case Crockford base32. `cicd/cicd.bash` passes it in at compile time through `build.rs`, and `--version` prints it after the version. It comes from the commit rather than the clock, so 2 builds of one commit match. A plain `cargo build` has none.

- A build that isn't a release shows its date after the build number, such as `build debj2 (2026-10-23)`. The date is worked out from the build number when `--version` runs, in the local time zone of whoever runs it, so the same binary can show a different day in another zone. A release is a commit tagged `v<version>`, so the tag goes on before the release is built. A release build leaves the date off. The release check runs `--version` in the box's zone, UTC+14 and UTC-12, since the last 2 never share a date.

- A build of a tree that differs from its commit's, such as one with uncommitted work in the frozen copy, gets `-dirty` after the build number, such as `build debj2-dirty (2026-10-23)`, and is never a release, tag or not. The number still names the commit it was built on. Untracked files that aren't ignored count, the same as for the tree the gate records. The merge gate builds the pushed commit, so it's never marked (2026102814341434).

- Feature branches merge into `dev` with `--no-ff`. A `dev` to `main` merge is a release, and gets tagged. Pulls are `--ff-only`.

- The pipeline runs here, not on a hosted service. The pre-push hook runs `--merge-gate` on a push to `main`, and a push to `dev` or a feature branch isn't gated. The merge gate runs every check of a run with no options, so it takes most of an hour. A push to `main` that changes only the paths in `cicd/docs-paths`, which are `.md` files and `assets/`, skips it.
	- A backlog worker runs `--backlog-run-quick`, alone or with the areas `--help` lists, and a round runs `--backlog-run-full` at its end. `--gate` and `--ci` are other names for `--backlog-run-quick` and `--merge-gate`.
	- None of the 3 syncs, dogfoods, publishes, installs, rewrites a tracked file, or prompts. The demo gif they draw stays in the run's temp dir.
	- A run records the tree it tested only when it's at least as thorough as the merge gate, and the hook lets that tree through without running it again. It records once the demo gif has passed too, in the run that started, not in the one on the frozen copy. `--no-gif` makes a run partial (2026102814341404). A run with no options records the tree with the gif it copied into the checkout, since the merge gate draws the same bytes from that tree and publish commits it. When anything else changed during the run, it records nothing (2026102819580272).
	- A run with no options publishes last. It refuses when the checkout no longer holds the tree the run tested, other than the demo gif it drew, or when the upstream has commits the run didn't take. On a box without rar it publishes with no backup (2026102814341411, 2026102814341426).
	- In the 3 check-only modes a missing tool fails the run. The check scripts see this as `TUKFS_GATE_STRICT`. A check that needs the leak check image, on a box with no docker and without the tool, is a skip instead, and the run doesn't record its tree (2026102814341405).

- `rust-toolchain.toml` pins the stable toolchain, so lint results don't move with the box. The dated nightly for sanitizer and Miri runs is in `cicd/tool-pins.env`.

- Release builds are Linux only, since the tool reads Linux xattrs, mounts and snapshots. Both are built in a Debian 10 image, `cicd/container-release/`, so they need its glibc 2.28 and not the box's. That covers RHEL 8, Debian 10, Ubuntu 18.10 and anything newer. arm64 is cross-built there with Debian's cross gcc, which also compiles the bundled SQLite. It takes about as long as x86_64, so every run builds both. The debug build, clippy, the unit tests and the release build the integration test runs are built in the same image, into `target/ctr`, so they use its pinned toolchain, the merge gate included, and the integration test can run that build on any box. Without docker, or when the image can't be set up, they build on the box with one note line, and `--no-container` does that on purpose. The integration test and the soak run on the box, since they scan its real disks.
	- The release stage does the same, so a box without docker still gets a release build, and the run doesn't fail on it, the merge gate included. Only x86_64 builds then, into `target/release-host`, since the box has no arm64 cross gcc. It needs the box's glibc, so the floor check gives a note rather than failing. Such a run doesn't record its tree for the pre-push hook, the same as one with a missing tool (2026102509342993).

- The release set, in `cicd/artifacts/release/`, is named `tukfs-hash-<version>-linux-x86_64` and `tukfs-hash-<version>-linux-arm64`, the same names plus `.deb` and `.rpm`, and `tukfs-hash-<version>-sha256sums.txt`. Download links depend on these, so they stay. The x86_64 name is never amd64, though the `.deb` has to say amd64 inside.
	- Only a run that can ship writes it there. The backlog runs and the merge gate build theirs in the run's temp dir, and the other hosts and the gif read it from there, so a check run leaves the set as the last run that can ship left it (2026102814341427).

- The packages hold `/usr/bin/tukfs-hash` and nothing else. They depend on the glibc the binary was linked for, read off the binary, which is 2.28 for both. Both also need `libgcc_s`.

- 2 builds of one commit give the same bytes, packages included. The build number and the packages' mtimes come from the commit time. cargo's home is mapped to `/cargo` in panic messages, so whose home it is doesn't matter, and the checkout's own paths are already relative. Release checks run over the set before it replaces the old one: the stamped `--version`, each build's architecture, each package's files and bytes, and that no build needs a glibc newer than 2.28. The release builds aren't the ones the tests stage tested, so the integration test runs again on the x86_64 one, and the unit tests run on arm64 under qemu in the same image.

- A run with no options, the merge gate and `--backlog-run-full` then run the arm64 unit tests and the integration test on the arm64 Linux test VM, vmDebARM64, on the arm64 release build. The qemu run stays as the quick check. The VM is held through the shared host lock for as long as it's used, and put back the way it was found, paused, off or running, by the VM state helper. Its work folder goes under the box's temp root, or `/var/tmp` when that's in memory, since the scan refuses tmpfs. The folder carries a `.box-run` mark, and old ones there go after 2 days only with that mark, so a folder made by hand or kept by the integration test stays (2026102814341410). `--quick` leaves it out, since the VM is emulated and takes about 3 minutes, and `--no-remote` skips it (2026102416215927).
	- A VM that isn't there, a box held elsewhere past 15 minutes, a box missing a tool the integration test needs, or a run with no arm64 build, is a `SKIP` in the step and in the summary at the end, and the run goes on. Like a missing test root, it keeps the tree from being recorded for the pre-push hook.

- Each run works in `<HOST_TEMP>/tukfs-hash/<YYYYmmDD-HHMMSS>_<NNN>/`, or under `RUN_TMP_ROOT` in `cicd/config.bash` when `HOST_TEMP` isn't set, with `TMPDIR`, `TEMP` and `TMP` pointed there. The folder holds the run's PID in `run.pid`, and goes at the end, on a failure or a stop too. A run also removes this project's run folders whose process is gone, such as a killed run's with its frozen copy, and leaves any folder there without its mark. The integration test makes its own folder the same way, under the `HOST_TEMP` it's given, so each test root gets one. `--keep-temp` keeps them and prints where, and the sweep leaves a kept folder for 2 days (2026102416215934, 2026102518150001).
	- Every container is named `tukfs-hash-<run folder name>-<step>-<n>`, and containers and images are labeled `dev.project=tukfs-hash` and `dev.run=<run folder name>`. Nothing uses a volume. The run removes its containers by that label at the end, once a stop has killed the running ones by ID, and says what that freed. `--keep-temp` keeps them. A new image keeps the tag before it, and the build cache prune keeps a week of every project's cache (2026102416215928).

- The dogfood copy goes to `~/synced/0-0/common/exec/util/linux/bin/tukfs-hash`, where the scan wrappers look, rather than the `app/linux/` dir. The stage leaves the copy there alone while it's running. Another user's run, such as one through sudo, is known by its name, since its exe link can't be read (2026102814341417). `utility/dogfood_tukfs-hash` keeps up to 10 dated versions in `~/.local/bin/tukfs-hash_versions/`, with a link to the newest at `~/.local/bin/tukfs-hash`.
	- `dogfood_tukfs-hash.ps1` copies a new build in, rotates the pool, points the fixed name at the newest, and prints the path to run. The bash launcher runs that in its own place, with every argument but `--no-update` as typed, so the exit code is the build's own, on a Ctrl+C too. pwsh would expand wildcards and `~` in them, and can't pass a name that isn't UTF-8 (2026102814341409). A copy that's running is never deleted, so a long scan keeps going while a newer build arrives.
	- Anything at the fixed name that isn't a link into the pool is left alone, and the newest version runs from the pool instead.
	- The pool keeps at most 10 versions and at least 5, and between those only as many as fit in 1 GB. Which ones stay is a GFS rotation: the oldest, the newest, the last of each recent hour, day, week, month and year, and the few most recent. Under 10 and 1 GB, versions with none of those roles stay too, as spares. When the count or the bytes cut in, the newest and oldest stay first, then the roles from year down to frequent, newest first within each, so a burst of builds can't push out the week and day ones (2026102814341441).
	- Each is named `tukfs-hash_<yyyyMMdd-HHmmss>_<role>`, from the build's write time in local time. Old versions go one file at a time, matched by that name, and never one that's running. Another user's run, such as one through sudo, has no exe link to read, so it's known by its name and first argument, as in the dogfood stage. A run through the fixed name holds the version that was newest when it started, by the time each came into the pool, which is the pool file's write time (2026102819305559).

## Leak and memory checks

- Each leak check has a length in `cicd/config.bash`, by its measured time with the image and build dirs warm. The fast ones, under a minute each, run in every run but `--backlog-run-quick`, `--quick` included: the known-advisory scan, the soak, the unit tests under ASan and LSan, then TSan, and the parser fuzz tests at 20 s each. The ones that take minutes, Miri and CodeQL, run in a run with no options, `--long`, the merge gate and `--backlog-run-full`, and in `--quick` only with `--leakcheck`. Ones that take hours run only in `--long`, which is the fuzz tests again at an hour each. `--backlog-run-quick` runs them only for a leak area or `--leakcheck`. They end the tests stage in that order, and any report fails the run (2026102517244901).

- `--no-codeql` leaves out only CodeQL, which is about 11 of a full run's 17 minutes. It drops each leak check step whose command names codeql.

- The sanitizers, Miri and CodeQL run in the image from `cicd/container/`, with the pinned nightly and CodeQL, no network, and only the run's own dirs and `target/leakcheck/` mounted. Its crates are fetched once per lock file into `target/leakcheck/cargo-home`. Without docker they run on the host with a note, and CodeQL skips.

- The soak and the advisory scan run on the host. A scan finds its workers from the root's disks through `/dev`, which a container doesn't have, and cargo-deny fetches RustSec's database.

- The soak, `src/soak.rs`, runs scan, change, scan, status and accept 20 times in one process, and holds the heap at round 20 to round 10 within 4 KB. The Rust heap is dhat's count. SQLite's is its own, since it allocates through libc, which dhat doesn't see. Both are back to 0 bytes live after every round, so the margin can be small. It's behind the `soak` feature, since dhat then counts every allocation in the test binary.

- The bundled SQLite is built by clang with the same sanitizer as the Rust code, with its lookaside and page cache pools off so each block is a malloc of its own.

- SQLite sets itself up on first use with plain reads and writes, and TSan caught 2 test threads doing that at once. `db::init()` does it once, behind a `Once`, before any connection opens. A scan already did it on the main thread before its workers started.

- The parser fuzz tests are plain unit tests named `fuzz_*`, beside each parser: the mount table, `zfs diff` and find-new output, lists, `--since` dates, and the base64url, hex and inode xattr values. A generator that knows each format makes well-formed input with the odd bytes in it, and its parse has to come out as built. Real samples gone bad, with bits flipped, cut short and the separator bytes put in, have to give no panic, and what comes out has to hold up, such as each line a snapshot diff can't use named by its own number and text (2026102517244907).
	- Each case is a pure function of one seed, so a failure prints the `TUKFS_FUZZ_SEED` that runs it again alone. `TUKFS_FUZZ_SECS` is the wall time per parser, 1 s in the plain unit tests and at least 300 cases. Each run starts from a new seed, so runs add up.
	- Each also checks that its generator still makes every kind of line it's meant to, so a change that stops one fails rather than passing on less.
	- `cicd/utility/fuzz.bash SECS` runs only those, from the unit tests' release build, a quarter of the cores at a time. Miri skips them, since they're safe code and get too few cases in the time.

- Miri skips what it can't run: SQLite, which is C, xattrs, `openat2` and `mktime`. 2 tests of safe code that take it over 15 minutes are skipped too. Each says why in its `#[cfg_attr(miri, ignore = ...)]`.

- CodeQL runs over a copy with every crate vendored, their full source extracted. A crate's finding counts only from a security or correctness query, and only in code the release binary builds. Ones looked at and found not to be bugs are in `cicd/codeql/vendored-reviewed.tsv` by crate version, since cargo vendor writes the code again each run and a comment there wouldn't last. A crate update leaves its lines stale, which fails until they're looked at again.

## Profiling

- A full run draws a flamegraph of a scan into `cicd/artifacts/profiling/`, GFS-rotated, and prints `cicd/utility/flame-report.py`'s summary of it in the log. `--quick` and `--gate` leave it out.

- `perf` can't record on b23, since `kernel.perf_event_paranoid` is 3, so the sampler is pprof, in the process, on SIGPROF. It's behind the `profiling` feature and the `profiling` cargo profile, which is release with names kept. pprof's flamegraph writer is inferno, which is CDDL-1.0, so a build with the feature never leaves the box. A release build doesn't change by a byte. The hook in `src/main.rs` sits at the bottom of the file so the lines above keep their numbers, which are in the release build's panic messages.

- The workload is a generated tree of about 1.5 GB on ext4, synced first so the scan reads the disk: a first scan, then bytes changed with the mtime put back and some ordinary edits, then a rescan with `--rmlint` and a `--since` past the first scan, so every file is read again with blake2b. Each scan adds its samples to one graph, under its own name below the root.

- libc isn't on the sampler's blocklist, unlike shcl's, since a scan's reads and attribute calls end there. libgcc, the vdso and the loader are, since unwinding from inside them isn't safe. `_Unwind_FindEnclosingFunction` is answered in the binary, as in shcl, or LTO leaves one name on most of a scan.

- A thread in the kernel gets fewer SIGPROFs than its share: about 35% against a busy thread in user code, where 50% would be fair. So the graph understates system time. The subtitle has each scan's user and system CPU from `getrusage`, which doesn't, and wall time past the CPU is waiting on the disk. Read I/O against hashing off those.

- blake3's assembly has no unwind info and no symbol sizes, so its samples come back with no name. The profiling build names them by where the functions start.

- Before any graph is drawn, an attribution check runs 2 threads for the same time: 2 loops at 3 to 1 inlined into one function, and a reader of a cached file. The loops have to split about 3 to 1, and the reader has to get a share. Each of those fails with its fix taken out.

- pprof's crates count for the advisory scan, which ignores 2 advisories in quick-xml's reader, since inferno only writes. CodeQL's copy of the tree leaves them out, and `src/profiling.rs`. uuid is one of them, and its `Display` read to CodeQL as a secret that every `format!` in the tree could log.

- The report buckets self time by the nearest caller it knows: blake3, blake2b, SQLite, xattr reads, xattr writes, file reads and the walk. They're keyed on function names, so a rename moves time into "other".

## Demo gif

- The gif at the top of README.md is drawn on each full run by `cicd/utility/gen-demo-gif.py`, from `cicd/demo/scenario.toml`, which follows `cicd/demo/script.txt`. The commands really run, against that run's release build, in a home made in the run's temp dir, with the database there too. `--quick` and `--gate` leave it out.

- The output shows the home as `/home/<user>`, with the prompt's made-up user, and this box's host and user names as the prompt's. After that, a line with the real user, home, host or a temp path fails the stage rather than going into the README. The host is caught next to `-`, `_` or `.` too, such as `<host>-old`.

- The demo files are the same bytes every run, and dates, times, the disk name, the worker count and the scan's own run time in the output are pinned, so a render only changes when the output or the script does. `assets/demo.gif` is replaced only when it differs.

- A step that exits with anything but what the scenario says fails the stage, since the gif would show an error as if it were the tool working. No Pillow or font is a warning, and the run goes on.

- Every frame time is a whole number of 20 ms frames, 50 fps, which is checked after the gif is written.

- Each render is GFS-rotated into `../private/demo/gif/`, outside the repo. `private` is a link, so it's resolved first, and a link below it fails the stage.

## Rejected

- PostgreSQL. Hashing runs at disk speed and one SQLite writer keeps up easily. A server adds a daemon and a data folder, and a single file is easier to snapshot and copy.

- Hashing from snapshots instead of live files. It would avoid unstable files but can't leave attributes on the live ones.

## Copyright and license

> Copyright © 2026 t00mietum (CryptogID: ปʬϝღถɔ4რఠΔթะ9ƾǝu)<br>
> Licensed under [GPL-2.0](../license.md). No warranty.
