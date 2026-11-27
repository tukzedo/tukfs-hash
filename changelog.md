<!-- markdownlint-disable MD007 -- Unordered list indentation -->
<!-- markdownlint-disable MD010 -- No hard tabs -->
<!-- markdownlint-disable MD041 -- First line in a file should be a top-level heading -->

# Changelog

## 1.0.0-rc.1

- `install.bash` installs the newest release with one line, for the user or with `--target system`. It checks the download's sum, works with a noexec temp folder, and a cut-off download runs nothing.

- A style guide and contributing.md, linked from the README.

- On a kernel before 5.6, a scan keeps a folder open per root and checks it's still where its path says. A folder replaced mid-scan, or a file mounted over, is caught as it is with openat2.

- A root is opened once, so a mount or symlink that appears in its path later doesn't send the scan to another filesystem.

- Under sudo, the database is opened through the folder that was checked.

- `--log` takes only a regular file, and refuses the database's own files. Each line is one write, so 2 scans can share a log. A full disk is warned about once, a failed plan still reaches the log, and the log isn't scanned under another name.

- On a terminal, the summary keeps every event kind, and root names that aren't plain text are escaped.

- A btrfs subvolume that isn't a mount point gets its percent from its own files.

- Files under 128 KiB get a plain read, which costs less there than a direct read.

- snapdiff `--find-new` compares a file it can't date safely: in a snapshot made writable and read-only again, or with a birth time later than the run's start. `--zfs-diff` memory stays small when the list has many deleted files.

- A release run that skips a check for a missing tool doesn't record its tree or upload. A stop during publish ends the publisher before it commits.

## 1.0.0-beta.2

- A scan shows how far along it is, as `~N% of SIZE`, for whole filesystems and for folders.

- On a terminal, a scan's lines fit its width. `--log FILE` appends every line in full, error lines included.

- A read error found by `--verify` stays open until a clean read, so a plain scan the same day reads the file again.

- `--exclude` and `--no-xattr` match a folder under any of its names, bind mounts included. A path that can't be resolved stops the scan, and a root inside an excluded folder is skipped.

- A root that's a bind mount of a folder inside another root is skipped.

- Under sudo, a database or log folder owned by neither the user nor root is refused.

- An attribute that can't be read is reported as `xattr-error`, and the file's attributes are left alone.

- On NTFS, APFS and HFS+, a scan goes by the database row when it matches the file's size and time. Nothing is written there, the log included.

- Each command refuses an option it doesn't take.

- snapdiff reads its change list as it goes, so a long list doesn't grow its memory. `--find-new` lists files in the change list's order.

- SQLite is updated to 3.54.1, for RUSTSEC-2026-0459.

- A release run on `main` tags the commit and puts the release set on the git host.

## 1.0.0-beta.1

- First version: scan, plan, runs, report, gone, accept, prune and snapdiff.

- A scan checks each file against the blake3 on it, rmlint's blake2b and its own database, and reads a file again with its cache dropped before calling it a mismatch.

- `--rmlint` takes blake2b too from the same read, and writes rmlint's attributes where they're missing or out of date.

- `scan --verify` reads again only files with a checksum stored, and writes no attributes. `--resume` picks up a stopped scan.

- Nothing is written to NTFS, APFS or HFS+, and files in git work trees get no attributes.

- `--version` gives the build number, and a local pipeline builds, lints, tests and publishes it.

- A build between releases shows its date after the build number, in the local time zone.

- A build with uncommitted changes shows `-dirty` after the build number, and is never shown as a release.

- There are release builds for x86_64 and arm64 Linux, each with a `.deb` and an `.rpm`, and a sha256 sums file, all named by version. 2 builds of one commit give the same bytes.

- `dogfood_tukfs-hash` runs the newest dogfood build, and keeps a few older ones.

- The local pipeline also runs the tests under AddressSanitizer, ThreadSanitizer and Miri, a soak of repeated scans, CodeQL, and a known-advisory scan.

- The local pipeline also draws a flamegraph of a scan and a rescan on each full run, with a summary of where the time went, and lints its own Python.

- The README has a demo gif, drawn from the release build on each full run of the local pipeline.

- SQLite is set up once before the first connection, rather than by whichever thread opens one first.
