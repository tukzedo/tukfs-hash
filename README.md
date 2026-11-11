<!-- markdownlint-disable MD007 -- Unordered list indentation -->
<!-- markdownlint-disable MD010 -- No hard tabs -->
<!-- markdownlint-disable MD033 -- No inline html -->
<!-- markdownlint-disable MD041 -- First line in a file should be a top-level heading -->

<!-- TOC ignore:true -->
# tukfs-hash

[![License: GPL-2.0](https://img.shields.io/badge/license-GPL--2.0-blue)](license.md) [![Rust 1.89+](https://img.shields.io/badge/rust-1.89%2B-orange)](Cargo.toml)

tukfs-hash checksums every file on a Linux box, remembers what each one read as, and says when a file's contents changed while its size and modified time didn't. That kind of change is what bad RAM, a bad cable, or a filesystem bug leaves behind. A normal edit always moves the time.

It's a utility under [tukfs](https://github.com/tukzedo/tukfs), which is part of [tukzedo](https://github.com/tukzedo/tukzedo-linux). Its database is also the start of tukfs's own, which will use the checksums to find duplicate files.

![A scan, then one byte changed with the size and time left alone, and a second scan that finds it](assets/demo.gif)

<!-- [![tukfs-hash video](https://img.youtube.com/vi/VIDEO_ID/hqdefault.jpg)](https://www.youtube.com/watch?v=VIDEO_ID) -->

<!-- TOC ignore:true -->
## Table of contents

<!-- TOC -->

- [Is this for you](#is-this-for-you)
- [Quick start](#quick-start)
- [What it does](#what-it-does)
	- [Details](#details)
- [Attributes](#attributes)
- [Usage](#usage)
- [Installation](#installation)
	- [Build it yourself](#build-it-yourself)
- [Set up development environment](#set-up-development-environment)
- [Copyright and license](#copyright-and-license)

<!-- /TOC -->

## Is this for you

- You've had bad RAM, a flaky cable, or a crash, and want to know which files changed without anyone editing them.

- Your filesystem's own checksums can't help, since the bytes were already wrong when they were written.

- You want a record of every file's checksum that outlives the disk, in one SQLite file.

It isn't a backup, and it doesn't repair anything. It tells you which files to restore. On ZFS or btrfs a scrub already finds damage that happened on the disk itself, but tukfs-hash finds what went wrong before that.

## Quick start

~~~bash
sudo tukfs-hash scan --db ~/Documents/tukfs.sqlite --root /home --root /srv
tukfs-hash report --db ~/Documents/tukfs.sqlite
~~~

The first scan reads every file and records it. Run the same scan again on a later day, such as once a week. It reads every file again, and exits 4 when one changed while its size and time didn't. `report` lists those files. A file that was read earlier the same day is skipped, so a stopped scan can be run again without starting over.

## What it does

- It reads each regular file once with blake3. Files that already have a current rmlint blake2b checksum get blake2b too, from the same read. With `--rmlint`, every file it reads gets blake2b, which is stored in the database, and rmlint's own attributes are written where they're missing or out of date.

- It compares the result with up to 3 earlier records, where they exist and the size and time still match:
	- The blake3 that this program or nemo-anywhere left on the file, in extended attributes.
	- rmlint's blake2b, in `user.rmlint.blake2b.*`.
	- Its own database from earlier runs.

- A file that doesn't match is read again, after its cached pages are dropped. If the second read matches, only memory was wrong, and that's logged as a `cache-mismatch`. If not, the stored checksums are left as they were, so every later run reports the file until it's fixed or accepted. ZFS has its own cache and ignores the request to drop it, so on ZFS the second read can't tell memory from disk.

- It writes the blake3 back onto the file, in the attributes that nemo-anywhere reads, along with the date it was taken and the inode it came from. Files in git work trees don't get any, since git already checksums what it tracks. Files on NTFS, APFS, or HFS+ don't get any either, since Linux's drivers for those aren't reliable enough to write with. They're still read and recorded, but the database can't be put on one.

- It stores everything in one SQLite file, which can be copied or archived as is.

- It's safe to run as root over a tree that other users can write to. It doesn't follow any symlink or cross any mount on the way to a file, and a folder that's swapped for a link during a scan counts as gone.

- It works with what's already there. Files that nemo-anywhere or `rmlint --xattr` checksummed are compared against those checksums from the first scan.

- Release builds are reproducible, which means 2 builds of one commit give the same bytes wherever the checkout is, and so do the packages.

### Details

- It runs one worker per set of hard drives, so that a drive isn't read by 2 workers at once. Flash gets 2 workers, or 4 on NVMe. It never crosses into another mount or btrfs subvolume.

- It stops cleanly on Ctrl+C, and `--resume` picks up where it left off. A file that was read since the start of the day, or since the `--since` date, isn't read again. `--resume` only takes the newest scan, and only when that scan had the same roots and the same `--verify` setting, so 2 scripts that share one database can't finish each other's runs.

- Progress lines and the summary show roughly how far each group has got, as a share of the space used on its filesystems. The share is only shown when every root in the group is a whole filesystem. It's a rough figure, since compression, reflinks, and snapshots make the space used differ from what gets read.

- `scan --verify` is a quicker check between full runs. It reads again only the files that have a checksum stored at their current size and time, even ones that were read earlier that day, and it doesn't write any attributes. New and edited files aren't read until the next full scan.

- `gone` lists the names that a finished scan didn't see, which are mostly deleted files. `prune` deletes the records of contents that don't have a name pointing at them any more, since every edit leaves one behind.

- `snapdiff` takes the change list from `zfs diff` or `btrfs subvolume find-new` and flags files that changed between 2 snapshots with the same size and time.

## Attributes

| Name                  | Value
| :---                  | :---
| `user.blake3.b64u`    | blake3-256, base64url with no padding
| `user.blake3.bytes`   | size when it was taken
| `user.blake3.date`    | when it was taken, microseconds since 1970
| `user.blake3.mtime`   | modified time when it was taken, microseconds since 1970
| `user.blake3.inode`   | `device:inode:checksum` of the file it was taken from

A reader trusts the checksum only when both the size and time match the file. The time is written after the checksum, and the inode is written last, so a write that stops part way is thrown away. An attribute that can't be read, such as on a disk error, is reported as `xattr-error`, and that file's attributes are left as they are.

A file is skipped without being read only when `user.blake3.inode` matches the file's own device and inode, and the checksum next to it. A copy that's made with `cp -a` or `rsync -aX` brings the attributes along, so it gets read and compared. A file is never skipped by attributes from before `user.blake3.inode` existed.

With `--rmlint`, `user.rmlint.blake2b.cksum` and `user.rmlint.blake2b.mtime` are written the same way `rmlint --xattr` writes them, so rmlint can use them without reading the file. A current rmlint checksum that doesn't match is reported and left as it was. blake2b is slower than blake3, at about a CPU second per GB, and the difference only shows when the disk is faster than that.

Writing an attribute changes the file's ctime, and Linux doesn't have a way to set it back.

## Usage

~~~text
tukfs-hash scan --db FILE --root DIR [--root DIR ...] [options]
tukfs-hash plan --root DIR [--root DIR ...] [--threads DIR=N ...]
tukfs-hash runs --db FILE
tukfs-hash report --db FILE [--run N] [--kind KIND] [--limit N]
tukfs-hash gone --db FILE [--run N] [--limit N]
tukfs-hash accept --db FILE PATH...
tukfs-hash prune --db FILE
tukfs-hash snapdiff --old DIR --new DIR (--zfs-diff FILE --mount DIR | --find-new FILE | --list FILE) [--all]
~~~

`tukfs-hash --help` lists the options, and so does `-h` or `--help` after a command. Each command refuses an option that isn't shown for it, rather than ignoring it. `report` and `gone` list 200 lines unless `--limit` gives another number, and say on stderr how many were left off. `snapdiff --all` also lists the files that didn't change. Run `scan` as root so it can read every file. The database is handed back to the user who ran sudo when the run ends. Its folder has to be that user's or root's.

`accept` reads each file twice and takes its current contents as good. It's for a file that was changed on purpose and had its time put back, or one that was restored from a backup and checked by hand. It replaces the database record and any blake3 that's already on the file, and removes rmlint's blake2b if that no longer matches. On NTFS, APFS, or HFS+ only the database record changes, and from then on a scan there goes by that record rather than by any attributes still on the file. Each name of a hard-linked file has its own record, so name each one.

`gone` takes the newest finished scan, or run N, and lists the names under its roots that it didn't see. A name that had an error in that run, or that's under a folder the run couldn't list, isn't counted. Neither is a name that another run last saw from a deeper root, since that root may be a mount the walk stops at. A folder that was left out with `--exclude` does count as not seen.

The exit codes are:

| Code | Meaning
| :--- | :---
| 0    | Fine
| 1    | Error
| 2    | Stopped
| 4    | Mismatches or read errors found
| 8    | Some files or folders couldn't be checked, or snapdiff didn't understand some of its input

The codes 2, 4, and 8 add up, so 6 is a stop after a mismatch, and 12 means both kinds were found. A resumed scan counts what its earlier parts found too. `accept` exits 1 if any file wasn't taken. A second Ctrl+C ends a scan at once, with 130. A root that can't be resolved is an error, and the scan doesn't read anything. So is a path given to `--exclude` or `--no-xattr` that can't be resolved. A root inside an `--exclude` folder is skipped, and the scan says so.

Names that aren't plain text are printed with `\xHH` escapes, and a backslash is printed as `\\`, so 2 different names can't ever print the same.

## Installation

Release builds are on the [releases page](https://github.com/tukzedo/tukfs-hash/releases). The only one so far is 1.0.0-beta.1, which is marked as a pre-release. Each release has a binary for x86_64 Linux and one for arm64, a `.deb` and an `.rpm` of each, and a sha256 sums file. They need glibc 2.28 or newer, so they run on RHEL 8, Debian 10, Ubuntu 18.10, and anything newer.

Download the build for the box and the sums file into one folder. Then check it, and install the package or the plain binary. On arm64, put `arm64` in place of `x86_64`.

~~~bash
sha256sum -c --ignore-missing tukfs-hash-*-sha256sums.txt
sudo apt install ./tukfs-hash-*-linux-x86_64.deb    # Debian, Ubuntu
sudo dnf install ./tukfs-hash-*-linux-x86_64.rpm    # Fedora, RHEL
sudo install -m 0755 tukfs-hash-*-linux-x86_64 /usr/local/bin/tukfs-hash    # any other
~~~

The packages put it at `/usr/bin/tukfs-hash`.

### Build it yourself

~~~bash
cargo build --release
sudo install -m 0755 target/release/tukfs-hash /usr/local/bin/
~~~

It needs only glibc and libgcc_s to run. Building it needs Rust through rustup, which picks up the toolchain that `rust-toolchain.toml` pins.

## Set up development environment

Development needs these:

- Rust, installed through rustup, since only rustup's `cargo` reads `rust-toolchain.toml`. The leak checks also need the dated nightly in `cicd/tool-pins.env`, with `rust-src` and `miri`, unless they run under docker.

- `sqlite3`, `getfattr` and `setfattr` from attr, `b2sum`, and `python3`, for the integration test.

- `bwrap` from bubblewrap, for the pipeline's test sandbox.

- docker, which is optional. Without it the release build is x86_64 only, and CodeQL is skipped.

- shellcheck, markdownlint, ruff, mypy, PSScriptAnalyzer under pwsh, cargo-deny, and nfpm, at the versions in `cicd/tool-pins.env`. A run warns when one has drifted. The merge gate fails when one is missing, except for ruff and mypy, which it skips with a note.

- Pillow for the demo gif, and gifsicle to make it smaller.

~~~bash
cargo build --release
tests/integration.bash
~~~

The integration test needs `sqlite3`, `getfattr`, `setfattr`, `b2sum`, and `python3`, and a `HOST_TEMP`, or else a `TMPDIR`, on a filesystem with user xattrs. It works in a folder of its own under `tukfs-hash/` there, and `--keep-temp` leaves that folder in place. Its btrfs subvolume check runs only on btrfs, so a btrfs folder for it can be given in `TUKFS_IT_BTRFS`.

`rust-toolchain.toml` pins the Rust toolchain, and only rustup's `cargo` reads it. `cicd/cicd.bash` runs the whole local pipeline. It formats, builds, lints, and tests, then makes release builds for x86_64 and arm64 Linux with a `.deb` and an `.rpm` of each, and then runs dogfood, draws the demo gif above, and publishes. On `main` it also uploads the release set to the git host as release `v<version>`, and tags the commit first if it isn't tagged yet. The release builds run in a Debian 10 image under docker, so each one needs only glibc 2.28 or newer. The test steps that run on the box, such as the integration test, run in a bubblewrap sandbox where they can write only to their own temp and build folders, so the pipeline needs `bwrap`. `--no-sandbox` runs them without it. Without docker, or with `--no-container`, only the x86_64 build is made, on the box, and it needs the box's glibc. Where an arm64 Linux test VM is set up, the arm64 build's unit and integration tests also run there. A VM that isn't there is skipped, and `--no-remote` skips it on purpose. The gif needs Pillow, and is skipped without it. `cicd/cicd.bash --merge-gate` runs every check without publishing anything, and the pre-push hook runs it on pushes to `main` after `git config core.hooksPath cicd/hooks`. It's skipped on pushes that only change docs. `--help` lists the rest.

A full run also runs the leak and memory checks. Those are the tests under ASan, TSan, and Miri on the nightly that `cicd/tool-pins.env` names, a heap soak of repeated scans, fuzz tests of the parsers, CodeQL over every crate, and `cargo deny check advisories`. The sanitizers, Miri, and CodeQL run in a docker image that's built from `cicd/container/` the first time, which takes a few minutes and about 4 GB. Without docker they use the host's nightly, and CodeQL is skipped. `--quick` keeps the ones that take under a minute, and any that take hours run only with `--long`. `--no-leakcheck` leaves them all out, and `--no-codeql` leaves out only CodeQL.

## Copyright and license

> Copyright © 2026 t00mietum (CryptogID: ปʬϝღถɔ4რఠΔթะ9ƾǝu)<br>
> Licensed under [GPL-2.0](license.md). No warranty.
