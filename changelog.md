<!-- markdownlint-disable MD007 -- Unordered list indentation -->
<!-- markdownlint-disable MD010 -- No hard tabs -->
<!-- markdownlint-disable MD041 -- First line in a file should be a top-level heading -->

# Changelog

## 0.1.0

- First version: scan, plan, runs, report and snapdiff.

- `--version` gives the build number and the copyright line, and a local pipeline builds, lints, tests and publishes it.

- Release builds for x86_64 and arm64 Linux, each with a `.deb` and an `.rpm`, and a sha256 sums file, all named by version. 2 builds of one commit give the same bytes.

- `dogfood_tukfs-hash` runs the newest dogfood build, and keeps a few older ones.

- The local pipeline also runs the tests under AddressSanitizer, ThreadSanitizer and Miri, a soak of repeated scans, CodeQL, and a known-advisory scan.

- SQLite is set up once before the first connection, rather than by whichever thread opens one first.
