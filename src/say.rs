// Copyright © 2026 t00mietum (CryptogID: ปʬϝღถɔ4რఠΔթะ9ƾǝu)
// Licensed under GPL-2.0-only. No warranty.

// A scan's own lines. On a terminal none is longer than its width, and
// --log gets each in full. See design.md, Runs and exit codes.

use crate::beneath;
use crate::util::show_path;
use std::ffi::OsStr;
use std::fs::File;
use std::io::{self, IsTerminal, Write};
use std::os::fd::{AsRawFd, RawFd};
use std::path::Path;
use std::sync::{Mutex, OnceLock, PoisonError};

static LOG: OnceLock<Mutex<File>> = OnceLock::new();

// A terminal shows a tab as far as the next multiple of 8.
const TAB: usize = 8;

/// How a line too long for the terminal is made to fit.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Fit {
	/// Cut at the width, with `~` as the last column.
	Cut,
	/// Broken at each ` | ` that's needed, the rest indented by a tab, so
	/// nothing in it is lost. A part still too long is cut.
	Break,
}

/// Appends every line from here on to `path`. Under sudo a log the scan
/// makes is handed to that user, as the database is, so their own scan can
/// add to it. One that was already there keeps its owner (2026111019430926).
pub fn open_log(path: &Path, sudo: Option<(u32, u32)>) -> Result<(), String> {
	let failed = |e: String| format!("--log {e}");
	let path = crate::util::canonical_name(path).map_err(failed)?;
	let dir = crate::scan::open_dir("--log", &path, sudo)?;
	let (f, made) = open_append(&dir, path.file_name().unwrap_or_default()).map_err(|e| match e
		.raw_os_error()
	{
		Some(libc::ELOOP) => failed(format!("{}: is a symbolic link; refused", show_path(&path))),
		_ => failed(format!("{}: {e}", show_path(&path))),
	})?;
	if made
		&& let Some((uid, gid)) = sudo
		&& let Err(e) = std::os::unix::fs::fchown(&f, Some(uid), Some(gid))
	{
		err(&format!(
			"warning: can't give {} to uid {uid}: {e}",
			show_path(&path)
		));
	}
	let _ = LOG.set(Mutex::new(f));
	Ok(())
}

// The file, and whether this made it. Under sudo, a link planted at the name
// would have root append to whatever it points at, so it's never followed.
fn open_append(dir: &File, name: &OsStr) -> io::Result<(File, bool)> {
	let flags = libc::O_WRONLY | libc::O_APPEND | libc::O_NOCTTY;
	match beneath::openat(dir.as_raw_fd(), name, flags | libc::O_CREAT | libc::O_EXCL) {
		Ok(f) => Ok((f, true)),
		Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {
			beneath::openat(dir.as_raw_fd(), name, flags).map(|f| (f, false))
		}
		Err(e) => Err(e),
	}
}

/// Each line of `text` on stdout, fitted to a terminal, and in full to the log.
pub fn out(text: &str, fit: Fit) {
	to_log(text);
	let width = width(libc::STDOUT_FILENO, io::stdout().is_terminal());
	let mut o = io::stdout().lock();
	for l in text.lines() {
		for row in fitted(l, width, fit) {
			let _ = writeln!(o, "{row}");
		}
	}
}

/// A line on stderr, and in the log. It's never cut, since it says what went
/// wrong.
pub fn err(text: &str) {
	to_log(text);
	let _ = writeln!(io::stderr().lock(), "{text}");
}

// A log that can't be written is dropped, as stdout is.
fn to_log(text: &str) {
	if let Some(f) = LOG.get() {
		let _ = writeln!(f.lock().unwrap_or_else(PoisonError::into_inner), "{text}");
	}
}

// Asked each time, so a resized window is followed.
fn width(fd: RawFd, tty: bool) -> Option<usize> {
	if !tty {
		return None;
	}
	let mut ws = libc::winsize {
		ws_row: 0,
		ws_col: 0,
		ws_xpixel: 0,
		ws_ypixel: 0,
	};
	// SAFETY: fd is stdout's or stderr's, open for the whole run, and
	// TIOCGWINSZ fills the winsize it's given, which outlives the call.
	if unsafe { libc::ioctl(fd, libc::TIOCGWINSZ, &raw mut ws) } != 0 || ws.ws_col == 0 {
		return None;
	}
	Some(usize::from(ws.ws_col))
}

// The column after c, a tab going to the next stop.
fn step(n: usize, c: char) -> usize {
	if c == '\t' {
		n / TAB * TAB + TAB
	} else {
		n + 1
	}
}

fn cols(s: &str) -> usize {
	s.chars().fold(0, step)
}

fn cut(s: &str, width: usize) -> String {
	if cols(s) <= width {
		return s.to_string();
	}
	let mut n = 0;
	let mut kept = String::with_capacity(width);
	for c in s.chars() {
		let next = step(n, c);
		if next >= width {
			break;
		}
		kept.push(c);
		n = next;
	}
	kept.push('~');
	kept
}

fn fitted(line: &str, width: Option<usize>, fit: Fit) -> Vec<String> {
	let Some(width) = width.filter(|&w| w > TAB + 1) else {
		return vec![line.to_string()];
	};
	if fit == Fit::Cut || cols(line) <= width {
		return vec![cut(line, width)];
	}
	let mut rows: Vec<String> = Vec::new();
	for part in line.split(" | ") {
		match rows.last_mut() {
			Some(row) if cols(row) + 3 + cols(part) <= width => {
				row.push_str(" | ");
				row.push_str(part);
			}
			Some(_) => rows.push(format!("\t{part}")),
			None => rows.push(part.to_string()),
		}
	}
	rows.iter().map(|r| cut(r, width)).collect()
}

#[cfg(test)]
mod tests {
	use super::*;
	use crate::testutil::test_id;
	use std::os::unix::fs::MetadataExt;

	#[test]
	fn a_line_fits_its_terminal() {
		let _id = test_id("df4xk");
		// Not a terminal: as it is, however long.
		let long = "x".repeat(300);
		assert_eq!(fitted(&long, None, Fit::Cut), [long]);
		assert_eq!(fitted("abcdefghijkl", Some(10), Fit::Cut), ["abcdefghi~"]);
		assert_eq!(fitted("abcdefghij", Some(10), Fit::Cut), ["abcdefghij"]);
		// A tab takes columns to the next stop.
		assert_eq!(fitted("\t/a/b/c/d/e", Some(12), Fit::Cut), ["\t/a/~"]);
		let line = "sda: files 3 hashed 3 | MISMATCH 1 read-err 0 | ~100% of 3 MiB";
		assert_eq!(
			fitted(line, Some(30), Fit::Break),
			[
				"sda: files 3 hashed 3",
				"\tMISMATCH 1 read-err 0",
				"\t~100% of 3 MiB"
			]
		);
		assert_eq!(
			fitted(line, Some(48), Fit::Break),
			[
				"sda: files 3 hashed 3 | MISMATCH 1 read-err 0",
				"\t~100% of 3 MiB"
			]
		);
		for w in 10..80 {
			for r in fitted(line, Some(w), Fit::Break) {
				assert!(cols(&r) <= w, "{w}: {r}");
			}
		}
	}

	// Under sudo the scan is root's, and the name the user's (2026111019145405).
	#[test]
	#[cfg_attr(miri, ignore = "Miri can't make links")]
	fn a_link_at_the_log_is_refused() {
		let _id = test_id("df4xq");
		let d = crate::testutil::scratch("say_log_link");
		std::os::unix::fs::symlink(d.join("elsewhere"), d.join("scan.log")).unwrap();
		let got = open_log(&d.join("scan.log"), None).unwrap_err();
		assert!(got.starts_with("--log "), "{got}");
		assert!(!d.join("elsewhere").exists());
	}

	// Only a log this made is handed over under sudo, so root's own file
	// stays root's (2026111019430926).
	#[test]
	#[cfg_attr(miri, ignore = "Miri has no openat")]
	fn a_log_is_made_only_once() {
		let _id = test_id("df4y3");
		let d = crate::testutil::scratch("say_log_made");
		let dir = File::open(&*d).unwrap();
		let name = OsStr::new("scan.log");
		assert!(open_append(&dir, name).unwrap().1);
		assert!(!open_append(&dir, name).unwrap().1);
	}

	// Under sudo a log folder that's neither the user's nor root's is
	// refused before the log is made, as the database's is.
	#[test]
	#[cfg_attr(miri, ignore = "Miri has no O_PATH")]
	fn a_log_folder_not_the_users_is_refused() {
		let _id = test_id("df4y4");
		let d = crate::testutil::scratch("say_log_folder");
		let me = std::fs::metadata(&*d).unwrap();
		let log = d.join("scan.log");
		let said = open_log(&log, Some((me.uid() + 1, me.gid()))).unwrap_err();
		assert!(
			said.starts_with("--log folder ") && said.ends_with("; refused"),
			"{said}"
		);
		assert!(!log.exists());
	}
}
