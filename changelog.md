<!-- markdownlint-disable MD007 -- Unordered list indentation -->
<!-- markdownlint-disable MD010 -- No hard tabs -->
<!-- markdownlint-disable MD041 -- First line in a file should be a top-level heading -->

# Changelog

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
