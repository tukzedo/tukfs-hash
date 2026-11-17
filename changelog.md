<!-- markdownlint-disable MD007 -- Unordered list indentation -->
<!-- markdownlint-disable MD010 -- No hard tabs -->
<!-- markdownlint-disable MD041 -- First line in a file should be a top-level heading -->

# Changelog

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

- SQLite 3.54.1, for RUSTSEC-2026-0459.

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

- Release builds for x86_64 and arm64 Linux, each with a `.deb` and an `.rpm`, and a sha256 sums file, all named by version. 2 builds of one commit give the same bytes.

- `dogfood_tukfs-hash` runs the newest dogfood build, and keeps a few older ones.

- The local pipeline also runs the tests under AddressSanitizer, ThreadSanitizer and Miri, a soak of repeated scans, CodeQL, and a known-advisory scan.

- The local pipeline also draws a flamegraph of a scan and a rescan on each full run, with a summary of where the time went, and lints its own Python.

- The README has a demo gif, drawn from the release build on each full run of the local pipeline.

- SQLite is set up once before the first connection, rather than by whichever thread opens one first.
