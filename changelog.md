<!-- markdownlint-disable MD007 -- Unordered list indentation -->
<!-- markdownlint-disable MD010 -- No hard tabs -->
<!-- markdownlint-disable MD041 -- First line in a file should be a top-level heading -->

# Changelog

## 1.0.0-rc.1

- `install.bash` installs the newest release with one command, either for the user or system-wide with `--target system`. It checks the download's sum, and it still works when the temp folder is mounted noexec. A download that was cut off isn't run.

- The repo has a code style guide and a contributing.md now, and the README links to both.

- On a kernel older than 5.6, which has no openat2, a scan keeps each root's folder open and checks that the folder is still at its path. So a folder that's replaced mid-scan, or a file that's mounted over, is caught the same way as on a newer kernel.

- Each root is opened once, so a mount or symlink that shows up in its path later doesn't send the scan to another filesystem.

- Under sudo, the database is opened through the same folder that was checked.

- `--log` only takes a regular file, and it refuses the database's own files. Each line is written in a single write, so 2 scans can share a log. When the disk is full there's one warning about it. A failed plan is still written to the log, and the log file isn't scanned under another name.

- On a terminal, the summary lists every event kind. Root names that aren't plain text are escaped.

- In a btrfs subvolume that isn't a mount point, the progress percent is worked out from that subvolume's own files.

- Files under 128 KiB are read with a plain read instead of a direct read, because a direct read costs more for small files.

- snapdiff `--find-new` compares a file when its date can't be trusted. That happens in a snapshot that was made writable and then read-only again, and for a file whose birth time is after the run started. `--zfs-diff` uses less memory when the list has a lot of deleted files.

- A release run that skips a check because a tool is missing doesn't record its tree, and it doesn't upload. When a run is stopped during publish, the publisher is stopped before it commits.

## 1.0.0-beta.2

- A scan shows how far along it is, as `~N% of SIZE`, for whole filesystems and for folders.

- On a terminal, a scan's lines are cut to fit the terminal's width. `--log FILE` appends every line in full, error lines included.

- A read error found by `--verify` stays open until the file reads cleanly, so a plain scan the same day reads the file again.

- `--exclude` and `--no-xattr` match a folder under any of its names, bind mounts included. A root inside an excluded folder is skipped.

- A path that can't be resolved stops the scan.

- A root that's a bind mount of a folder inside another root is skipped.

- Under sudo, a database or log folder is refused when it isn't owned by the user or by root.

- An attribute that can't be read is reported as `xattr-error`, and the file's attributes are left alone.

- On NTFS, APFS, and HFS+, a scan goes by the database row when the row matches the file's size and time. Nothing is written to those filesystems, and that includes the log.

- Each command refuses an option it doesn't take.

- snapdiff reads its change list as it goes, so its memory use doesn't grow with a long list. `--find-new` lists files in the change list's order.

- SQLite is updated to 3.54.1 to fix RUSTSEC-2026-0459.

- A release run on `main` tags the commit and puts the release set on the git host.

## 1.0.0-beta.1

- This is the first version, with the scan, plan, runs, report, gone, accept, prune, and snapdiff commands.

- A scan checks each file against the blake3 stored on it, rmlint's blake2b, and its own database. Before a file is called a mismatch, its cache is dropped and it's read again.

- `--rmlint` also works out blake2b from the same read. It writes rmlint's attributes where they're missing or out of date.

- `scan --verify` only rereads files that have a stored checksum, and it doesn't write any attributes. `--resume` picks up a stopped scan.

- Nothing is written to NTFS, APFS, or HFS+. Files in git work trees don't get any attributes.

- `--version` shows the build number. A local pipeline builds, lints, tests, and publishes the program.

- A build between releases shows its date after the build number, in the local time zone.

- A build with uncommitted changes shows `-dirty` after the build number, and it's never shown as a release.

- There are release builds for x86_64 and arm64 Linux. Each one has a `.deb` and an `.rpm`, and the set has a sha256 sums file. Every file name has the version in it. Building one commit twice gives the same bytes.

- `dogfood_tukfs-hash` runs the newest dogfood build, and it keeps a few older ones.

- The local pipeline also runs the tests under AddressSanitizer, ThreadSanitizer, and Miri. It runs a soak of repeated scans, CodeQL, and a scan for known advisories too.

- On each full run, the local pipeline draws a flamegraph of a scan and a rescan, with a summary of where the time went. It lints its own Python as well.

- The README has a demo gif, which is drawn from the release build on each full run of the local pipeline.

- SQLite is set up once before the first connection, rather than by whichever thread opens one first.
