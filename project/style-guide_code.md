<!-- markdownlint-disable MD007 -- Unordered list indentation -->
<!-- markdownlint-disable MD010 -- No hard tabs -->
<!-- markdownlint-disable MD041 -- First line in a file should be a top-level heading -->

<!-- TOC ignore:true -->
# tukfs-hash code style guide

How the code in this repo is written. The pipeline's format and lint steps check most of it, so the formatter and linter configs in the repo are the real rules. This guide says where they are, why a few of them are set the way they are, and what they can't check. `cicd/cicd.bash --backlog-run-quick` runs the format check, the build, the linters, and the tests without changing any tracked file, and [contributing.md](../contributing.md) has the rest of the process.

<!-- TOC ignore:true -->
## Table of contents

<!-- TOC -->

- [Every file](#every-file)
- [Rust](#rust)
	- [Rules the compiler doesn't check](#rules-the-compiler-doesnt-check)
- [Tests](#tests)
- [Bash](#bash)
- [Python](#python)
- [PowerShell](#powershell)
- [Markdown](#markdown)

<!-- /TOC -->

## Every file

- Line endings are LF, in the repo and in every checkout, Windows too. `.gitattributes` sets that, so a script's shebang line never ends in a CR.

- Tabs indent, and spaces line up columns. Python is the one exception, with 4 spaces, since that's what ruff's formatter writes.

- Comments are short and say why rather than what. A reason that would take a paragraph goes in [design.md](design.md), and the comment names its section or a backlog ID, such as `reason = "split by 2026102308220558"`.

- Source is ASCII, apart from the `©` in copyright lines and text that is about unicode itself. Write `-` for a dash and `->` for an arrow.

- A file starts with its copyright and license lines, under the shebang if it has one. Copy them from a file of the same kind, since the forms differ:
	- Rust and `tests/integration.bash` are GPL-2.0-only, like the program.
	- The pipeline's scripts under `cicd/`, `install.bash`, and the dogfood runner under `utility/` are MIT, with an `SPDX-License-Identifier` line.
	- A PowerShell file has `Copyright (C) <year> t00mietum`, in ASCII and with no ID.
	- A few helpers under `cicd/utility/` are shared with other repos and name their own author. Leave those lines as they are.

## Rust

- `cargo fmt` is canonical, and the gate runs `cargo fmt --check`. [rustfmt.toml](../rustfmt.toml) sets only `hard_tabs`, and everything else is rustfmt's edition 2024 style. Don't hand-format against it. A data table that reads better laid out by hand gets `#[rustfmt::skip]`.

- The toolchain is pinned in [rust-toolchain.toml](../rust-toolchain.toml), and only rustup's `cargo` reads that file. The oldest Rust it builds on is `rust-version` in [Cargo.toml](../Cargo.toml). Clippy's `incompatible_msrv` checks only standard library calls, so a language feature newer than that version isn't caught.

- The clippy lints are in `[lints.clippy]` in Cargo.toml, so an editor's clippy sees the same ones as the gate. The gate runs clippy with `--all-targets --all-features -- -D warnings`, so every warning fails it.
	- `pedantic` is on.
	- The 4 cast lints are off. Stat values are stored as SQLite's i64, and rmlint stores its time as a float, so those casts are on purpose.
	- `mem_forget` and `undocumented_unsafe_blocks` are on, since a leak in safe Rust is mostly `mem::forget`, and every unsafe block has to say why it's sound.
	- [clippy.toml](../clippy.toml) adds the words that `doc_markdown` would otherwise want in backticks.

- An `#[allow]` goes on the one item that needs it, with a `reason = "..."`, never on the whole crate. A long function or a struct with a lot of bools fails pedantic, and needs either a split or its own allow.

- Every `unsafe` block has a `// SAFETY:` comment right above it.

- Print with the `out!` and `err!` macros in `main.rs` rather than `println!` and `eprintln!`. `println!` panics when stdout is closed, as it is when the output is piped into `head`, and a long scan shouldn't die for that.

### Rules the compiler doesn't check

- Event names and run statuses are written out only in `Kind` and `RunStatus` in `src/db.rs`. A new event kind needs its exit bit in `Kind::exit_bits` and its place in `damage_first` in `src/main.rs`. Both are exhaustive matches, so the build fails until they're given.

- Rows in the `paths` table are never deleted, so a row id from a lookup is good for the whole run. The scan's updates by id rely on that.

- A change to the tables raises `SCHEMA` in `src/db.rs`, and the first `scan`, `accept`, or `prune` by the newer binary upgrades an older database. An older binary then refuses it.

- Every Mutex in `src/scan.rs` is taken through `locked()`, which takes the guard back from a poisoned lock. That way a worker's caught panic can't abort the unwind or lose its reason.

- The rules for when a file is skipped are a table in design.md, under "Skipping". A change to one names its row, and a new case gets a row first.

- Nothing is written to NTFS, APFS, or HFS+, or to a plain FUSE mount of a disk or image, since Linux's drivers for those aren't trusted to write. `mounts::hands_off` decides that. A new place that writes an attribute or a database checks it.

## Tests

- Every test has an ID, which its status line prints. An ID is 5 characters of lower-case Crockford base 32, from `python3 cicd/utility/test-ids.py new`, and it never changes once given. The lint step runs `test-ids.py check`, which fails on a test with no ID or 2 tests with the same one.

- In Rust the ID is the first line of the test, as `let _id = test_id("ddx08");`. It goes right under the `fn` line, and only `#[...]` lines can come between `#[test]` and `fn`. An attribute that rustfmt splits over several lines, or a `const` above the ID, makes the check fail.

- In `tests/integration.bash` each check starts with its ID, as `check ddx0a "first scan exit" "${rc}" 0`.

- A bug fix comes with a test that fails before the fix and passes after it, where one can be written.

- Tests write only in a folder of their own under `tukfs-hash/` in the temp folder. Unit tests get one from `scratch()` in `src/testutil.rs`, under `TMPDIR`. The integration test makes its own under `HOST_TEMP`, or `TMPDIR` when that isn't set. The pipeline runs them in a sandbox that can't write anywhere else.

## Bash

- Scripts are named `*.bash` and start with `#!/usr/bin/env bash` and `set -Eeuo pipefail`.

- The header is `##` comments with `Purpose`, `Syntax`, and `Exit`, then the copyright lines. `History: At bottom of script.` points to a dated list at the end of the file.

- shellcheck checks every tracked `*.bash`, plus the few files without the suffix that `SHELLCHECK_EXTRA` in `cicd/config.bash` lists. [.shellcheckrc](../.shellcheckrc) turns on `external-sources` and sets `source-path=SCRIPTDIR`, so a variable that an include sets counts where it's read, and a run by hand gets the same answer as the pipeline. A `disable` goes at the top of the script, or on the line it's for, with its reason after it on the same line.

- Functions are `fName(){ ... }`. Locals are lower camelCase, such as `mdFiles`, and settings and exported names are upper case. Variables are written `${name}`, with braces.

- The style is compact. A short `if` or a `||` guard can sit on one line.

## Python

- Python is only for the pipeline's own tools, under `cicd/`. It runs as `python3`, from a `#!/usr/bin/env python3` shebang.

- ruff checks it with the rules in [cicd/ruff.toml](../cicd/ruff.toml), for Python 3.11, with 120 columns since the report tables read better unwrapped. `ruff format --check` runs as well. `SIM108` is off, since it turns a long `if`/`else` into a one-line ternary that's harder to read.

- mypy checks it in strict mode with `warn_unreachable`, by [cicd/mypy.ini](../cicd/mypy.ini), so every function has full type hints.

## PowerShell

- [PSScriptAnalyzerSettings.psd1](../PSScriptAnalyzerSettings.psd1) at the repo root sets the rules, and the lint step runs `cicd/utility/lint-ps1.ps1` with it over every tracked `.ps1`. It reports at every severity, with tab indents and single quotes for strings that don't expand anything.

- A `.ps1` file is pure ASCII, in strings and comments too, and has no byte order mark. Windows PowerShell needs a BOM to read a non-ASCII script, and a BOM breaks the shebang line on Linux.

## Markdown

- markdownlint checks every tracked `.md` but `license.md`, which is the GPL's own text, as published. MD013 is off, since the docs aren't hard-wrapped. A paragraph or a bullet is one line, and the viewer wraps it.

- Lists are indented with tabs, so a doc starts with `markdownlint-disable` comments for MD007 and MD010, one per line with the rule's name. Add one only for a rule the doc breaks on purpose.

- A doc that has a table of contents has it in the form the editor's TOC extension writes, between its `<!-- TOC -->` comments.
