<!-- markdownlint-disable MD007 -- Unordered list indentation -->
<!-- markdownlint-disable MD010 -- No hard tabs -->
<!-- markdownlint-disable MD041 -- First line in a file should be a top-level heading -->

<!-- TOC ignore:true -->
# tukfs-hash code style guide

The pipeline's format and lint steps check most code style, so the formatter and linter configs in the repo are the real rules. This guide says where they are, why a few of them are set the way they are, and what they can't check. `cicd/cicd.bash --backlog-run-quick` runs the format check, the build, the linters, and the tests without changing any tracked file, and [contributing.md](../contributing.md) has the rest of the process.

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

- Use LF line endings everywhere, Windows checkouts included. `.gitattributes` enforces it, so a shebang line never ends in a CR.

- Indent with tabs and line things up with spaces. Python is the exception. It uses 4 spaces because ruff's formatter does.

- Keep comments short, and say why rather than what. If the reason would take a paragraph, put it in [design.md](design.md) and point the comment at the section or a backlog ID, like `reason = "split by 2026102308220558"`.

- Stick to ASCII in source. The `©` in copyright lines is fine, and so is text about unicode itself. Write `-` for a dash and `->` for an arrow.

- Start each file with its copyright and license lines, under the shebang if there is one. The forms differ, so copy them from a file of the same kind:
	- Rust and `tests/integration.bash` are GPL-2.0-only, like the program.
	- The pipeline scripts under `cicd/`, `install.bash`, and the dogfood runner under `utility/` are MIT, with an `SPDX-License-Identifier` line.
	- PowerShell files use `Copyright (C) <year> t00mietum`, in ASCII and without an ID.
	- A few helpers under `cicd/utility/` are shared with other repos and name their own author. Leave those lines alone.

## Rust

- Run `cargo fmt` and don't hand-format against it. The gate runs `cargo fmt --check`. [rustfmt.toml](../rustfmt.toml) only turns on `hard_tabs`, and the rest is rustfmt's edition 2024 style. If a data table reads better laid out by hand, mark it `#[rustfmt::skip]`.

- The toolchain is pinned in [rust-toolchain.toml](../rust-toolchain.toml). Only rustup's `cargo` reads that file, and a distro's cargo ignores it. The oldest supported Rust is `rust-version` in [Cargo.toml](../Cargo.toml). Clippy warns about standard library calls newer than that, but not about newer language features.

- Clippy lints are set in `[lints.clippy]` in Cargo.toml, so an editor's clippy sees the same ones as the gate. The gate runs clippy with `--all-targets --all-features -- -D warnings`, which means any warning fails it.
	- `pedantic` is on.
	- The 4 cast lints are off. The code casts stat values to and from SQLite's i64 on purpose, and rmlint stores its times as floats.
	- `mem_forget` and `undocumented_unsafe_blocks` are on.
	- [clippy.toml](../clippy.toml) lists words that `doc_markdown` shouldn't ask to have in backticks.

- Put an `#[allow]` on the one item that needs it, with a `reason = "..."`. Never put one on the whole crate. Pedantic flags long functions and structs with lots of bools, so either split them up or give them their own allow.

- Every `unsafe` block needs a `// SAFETY:` comment right above it, saying why it's sound.

- Don't use `println!` or `eprintln!` outside tests. A scan's own lines go through `say::out` and `say::err` in `src/say.rs`, and other commands use the `out!` and `err!` macros in `main.rs`. `println!` panics when stdout is closed, such as when the output is piped into `head`, and a long scan shouldn't die over that.

### Rules the compiler doesn't check

- Event names and run statuses are only written out in `Kind` and `RunStatus` in `src/db.rs`. When you add an event kind, give it an exit bit in `Kind::exit_bits` and a place in `damage_first` in `src/main.rs`. Both are exhaustive matches, so the build fails until you do.

- Rows in the `paths` table are never deleted. The scan updates rows by id, and it counts on an id from a lookup staying valid for the whole run.

- If you change the tables, bump `SCHEMA` in `src/db.rs`. The first `scan`, `accept`, or `prune` by the new binary upgrades an older database, and after that an older binary refuses to open it.

- Lock every Mutex in `src/scan.rs` through `locked()`. It still works after another thread panicked while holding the lock, so a caught panic in a worker doesn't turn into an abort, and its message isn't lost.

- The rules for when a file is skipped are a table in design.md, under "Skipping". When a fix changes how a file is skipped, mention the row it changes. Add a row for a new case before writing the code.

- tukfs-hash never writes to NTFS, APFS, HFS+, or a plain FUSE mount of a disk or image, because Linux's drivers for those aren't trusted to write. `mounts::hands_off` returns whether a mount is one of those, so new code that writes an attribute or a database should call it first.

## Tests

- Every test has an ID, and its status line prints it. IDs are 5 characters of lower-case Crockford base 32. Get a new one from `python3 cicd/utility/test-ids.py new`, and never change it after that. The lint step runs `test-ids.py check`, which fails if a test is missing an ID or 2 tests share one.

- In Rust the ID is the first line of the test, as `let _id = test_id("ddx08");`, right under the `fn` line. Only `#[...]` lines are allowed between `#[test]` and `fn`. The check fails on an attribute that rustfmt splits over several lines, or on a `const` above the ID.

- In `tests/integration.bash` each check starts with its ID, like `check ddx0a "first scan exit" "${rc}" 0`.

- A bug fix should come with a test that fails before the fix and passes after it, when one can be written.

- Tests only write inside their own folder under `tukfs-hash/` in the temp folder. Unit tests get one from `scratch()` in `src/testutil.rs`, under `TMPDIR`. The integration test makes its own under `HOST_TEMP`, or under `TMPDIR` if `HOST_TEMP` isn't set. The pipeline runs both in a sandbox that won't let them write anywhere else.

## Bash

- Name scripts `*.bash`, and start them with `#!/usr/bin/env bash` and `set -Eeuo pipefail`.

- The header is `##` comments with `Purpose`, `Syntax`, and `Exit`, then the copyright lines. A `History: At bottom of script.` line points to the dated list at the end of the file.

- shellcheck runs on every tracked `*.bash`, plus a few files without the suffix that are listed in `SHELLCHECK_EXTRA` in `cicd/config.bash`. [.shellcheckrc](../.shellcheckrc) lets it follow `source` lines, so a run by hand gives the same result as the pipeline. Put a `disable` at the top of the script or on the line it's for, with the reason after it on the same line.

- Functions look like `fName(){ ... }`. Locals are lower camelCase, like `mdFiles`. Settings and exported names are upper case. Always write variables with braces, as `${name}`.

- Keep it compact. A short `if` or a `||` guard can be one line.

## Python

- Python is only used for the pipeline's own tools under `cicd/`. Scripts run as `python3`, from a `#!/usr/bin/env python3` shebang.

- ruff checks it with the rules in [cicd/ruff.toml](../cicd/ruff.toml), for Python 3.11. Lines can be 120 columns, because the report tables read better unwrapped. `ruff format --check` runs too. `SIM108` is off, because it turns a long `if`/`else` into a one-line ternary that's harder to read.

- mypy runs in strict mode with `warn_unreachable`, per [cicd/mypy.ini](../cicd/mypy.ini). So every function needs full type hints.

## PowerShell

- The rules are in [PSScriptAnalyzerSettings.psd1](../PSScriptAnalyzerSettings.psd1) at the repo root. The lint step runs `cicd/utility/lint-ps1.ps1` with those settings over every tracked `.ps1`, and reports at every severity. Use tab indents, and single quotes for strings that don't expand anything.

- Keep `.ps1` files pure ASCII, comments and strings included, with no byte order mark. Windows PowerShell needs a BOM to read a non-ASCII script, but a BOM breaks the shebang line on Linux.

## Markdown

- markdownlint checks every tracked `.md` except `license.md`, which is the GPL text as published. MD013 is off because the docs aren't hard-wrapped. Each paragraph or bullet is one line, and the viewer wraps it.

- Lists are indented with tabs, so each doc starts with `markdownlint-disable` comments for MD007 and MD010, one per line with the rule's name. Only add one for a rule the doc breaks on purpose.

- If a doc has a table of contents, copy the format from this file, between `<!-- TOC -->` and `<!-- /TOC -->`.
