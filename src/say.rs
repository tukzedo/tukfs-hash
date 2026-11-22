// Copyright © 2026 t00mietum (CryptogID: ปʬϝღถɔ4რఠΔթะ9ƾǝu)
// Licensed under GPL-2.0-only. No warranty.

// A scan's own lines. On a terminal each one fits the width, and --log gets each in full. See design.md, Runs and exit codes.

use crate::beneath;
use crate::util::show_path;
use std::ffi::OsStr;
use std::fs::File;
use std::io::{self, IsTerminal, Write};
use std::os::fd::{AsRawFd, RawFd};
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock, PoisonError};

static LOG: OnceLock<Mutex<Log>> = OnceLock::new();

struct Log<W = File> {
	to: W,
	path: PathBuf,
	// Once, since every line after a full disk fails the same way.
	warned: bool,
}

// A terminal shows a tab as far as the next multiple of 8.
const TAB: usize = 8;

/// How a line too long for the terminal is made to fit.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Fit {
	/// Cut at the width, with `~` as the last column.
	Cut,
	/// Broken at each ` | ` that's needed, with the rest indented by a tab, so nothing in it is lost. A part too long for a row of its own is broken at its `, ` marks too, and only an item still too long is cut.
	Break,
}

/// Appends every line from here on to `path`, and returns the log's device and inode, so the scan can leave the log out under any name (2026111918562707). Under sudo, a log the scan makes is handed to the user who ran sudo, as the database is, so their own scan can add to it. One that was already there keeps its owner (2026111019430926). Anything but a regular file is refused, and so is one of the database's files (2026111918562702, 2026111918562724).
pub fn open_log(path: &Path, db: &Path, sudo: Option<(u32, u32)>, mounts: &[crate::mounts::Mount]) -> Result<(u64, u64), String> {
	let failed = |e: String| format!("--log {e}");
	let path = crate::util::canonical_name(path).map_err(failed)?;
	if let Some(t) = crate::mounts::hands_off_at(mounts, &path) {
		return Err(failed(format!("{} is on {t}, which isn't written to from Linux; put the log elsewhere", show_path(&path))));
	}
	let dir = crate::scan::open_dir("--log", &path, sudo)?;
	let name = path.file_name().unwrap_or_default();
	// A database that won't resolve fails the run later, with the reason in the log.
	let db = crate::scan::canonical_db(db).ok();
	let own = || failed(format!("{}: is one of the database's files; refused", show_path(&path)));
	if db.as_deref().is_some_and(|db| crate::scan::is_db_name(db, &dir, name)) {
		return Err(own());
	}
	let (f, made) = open_append(&dir, name).map_err(|e| match e.raw_os_error() {
		Some(libc::ELOOP) => failed(format!("{}: is a symbolic link; refused", show_path(&path))),
		// A FIFO with no reader, or a socket.
		Some(libc::ENXIO) => failed(format!("{}: not a regular file; refused", show_path(&path))),
		_ => failed(format!("{}: {e}", show_path(&path))),
	})?;
	if !made && db.as_deref().is_some_and(|db| crate::scan::is_db_file(db, &f)) {
		return Err(own());
	}
	if made
		&& let Some((uid, gid)) = sudo
		&& let Err(e) = std::os::unix::fs::fchown(&f, Some(uid), Some(gid))
	{
		err(&format!("warning: can't give {} to uid {uid}: {e}", show_path(&path)));
	}
	let id = f.metadata().map(|m| (m.dev(), m.ino())).map_err(|e| failed(format!("{}: {e}", show_path(&path))))?;
	let _ = LOG.set(Mutex::new(Log { to: f, path, warned: false }));
	Ok(id)
}

// Returns the file, and whether this call made it. Under sudo, a link planted at the name would have root append to whatever it points at, so it's never followed.
// O_CREAT stays on the second try so the kernel's protected_regular and protected_fifos checks still apply, as they do to a shell's >>, and O_NONBLOCK keeps a FIFO from waiting for a reader (2026111918562702).
fn open_append(dir: &File, name: &OsStr) -> io::Result<(File, bool)> {
	let flags = libc::O_WRONLY | libc::O_APPEND | libc::O_NOCTTY | libc::O_NONBLOCK | libc::O_CREAT;
	let (f, made) = match beneath::openat(dir.as_raw_fd(), name, flags | libc::O_EXCL) {
		Ok(f) => (f, true),
		Err(e) if e.kind() == io::ErrorKind::AlreadyExists => (beneath::openat(dir.as_raw_fd(), name, flags)?, false),
		Err(e) => return Err(e),
	};
	if !f.metadata()?.file_type().is_file() {
		return Err(io::Error::other("not a regular file; refused"));
	}
	Ok((f, made))
}

/// Prints each line of `text` on stdout, fitted to a terminal, and in full to the log.
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

/// Prints a line on stderr, and in the log. It's never cut, since it says what went wrong.
pub fn err(text: &str) {
	to_log(text);
	to_stderr(text);
}

// stderr is unbuffered, so writeln! would make 2 writes, which 2 scans that share a file through 2>> could mix.
fn to_stderr(text: &str) {
	let _ = io::stderr().lock().write_all(line(text).as_bytes());
}

fn line(text: &str) -> String {
	let mut l = String::with_capacity(text.len() + 1);
	l.push_str(text);
	l.push('\n');
	l
}

// A line that can't be written is dropped, as stdout's are, but a warning goes to stderr once, since the log is the record that was asked for (2026111918562723).
fn to_log(text: &str) {
	let Some(log) = LOG.get() else {
		return;
	};
	let warning = log.lock().unwrap_or_else(PoisonError::into_inner).put(text);
	if let Some(w) = warning {
		to_stderr(&w);
	}
}

impl<W: Write> Log<W> {
	// The text and its newline in one write, so O_APPEND keeps it whole when 2 scans share a log (2026111918562715). Returns the warning to give, on the first write that fails.
	fn put(&mut self, text: &str) -> Option<String> {
		let e = self.to.write_all(line(text).as_bytes()).err()?;
		if std::mem::replace(&mut self.warned, true) {
			return None;
		}
		Some(format!("warning: can't write to --log {}: {e}, so it's missing lines", show_path(&self.path)))
	}
}

// Asked each time, so a resized window is followed.
fn width(fd: RawFd, tty: bool) -> Option<usize> {
	if !tty {
		return None;
	}
	let mut ws = libc::winsize { ws_row: 0, ws_col: 0, ws_xpixel: 0, ws_ypixel: 0 };
	// SAFETY: fd is stdout's or stderr's, open for the whole run, and TIOCGWINSZ fills the winsize it's given, which outlives the call.
	if unsafe { libc::ioctl(fd, libc::TIOCGWINSZ, &raw mut ws) } != 0 || ws.ws_col == 0 {
		return None;
	}
	Some(usize::from(ws.ws_col))
}

// The column after c, where a tab goes to the next stop.
fn step(n: usize, c: char) -> usize {
	if c == '\t' { n / TAB * TAB + TAB } else { n + 1 }
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
		if let Some(row) = rows.last_mut()
			&& cols(row) + 3 + cols(part) <= width
		{
			row.push_str(" | ");
			row.push_str(part);
			continue;
		}
		let lead = if rows.is_empty() { "" } else { "\t" };
		let whole = format!("{lead}{part}");
		if cols(&whole) <= width {
			rows.push(whole);
		} else {
			broken_at_commas(part, lead, width, &mut rows);
		}
	}
	rows.iter().map(|r| cut(r, width)).collect()
}

// Breaks a list that's too long for a row of its own, such as the events line's kinds, so the kinds late in it aren't cut off (2026111918562709). Each row but the last ends with its comma.
fn broken_at_commas(part: &str, lead: &str, width: usize, rows: &mut Vec<String>) {
	let mut items = part.split(", ").peekable();
	let mut row = lead.to_string();
	let mut empty = true;
	while let Some(item) = items.next() {
		let comma = if items.peek().is_some() { "," } else { "" };
		if !empty && cols(&row) + 1 + cols(item) + comma.len() > width {
			rows.push(std::mem::replace(&mut row, "\t".to_string()));
			empty = true;
		}
		if !empty {
			row.push(' ');
		}
		row.push_str(item);
		row.push_str(comma);
		empty = false;
	}
	rows.push(row);
}

#[cfg(test)]
mod tests {
	use super::*;
	use crate::testutil::test_id;
	use std::os::unix::fs::OpenOptionsExt;

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
		assert_eq!(fitted(line, Some(30), Fit::Break), ["sda: files 3 hashed 3", "\tMISMATCH 1 read-err 0", "\t~100% of 3 MiB"]);
		assert_eq!(fitted(line, Some(48), Fit::Break), ["sda: files 3 hashed 3 | MISMATCH 1 read-err 0", "\t~100% of 3 MiB"]);
		for w in 10..80 {
			for r in fitted(line, Some(w), Fit::Break) {
				assert!(cols(&r) <= w, "{w}: {r}");
			}
		}
	}

	// The events line has no ` | `, so at 80 columns it was cut after its second kind, and read-error, which sets exit 4, sorts early among the rest (2026111918562709).
	#[test]
	fn long_events_line_shows_all() {
		let _id = test_id("dfjyx");
		let kinds = ["b3-db-mismatch 3", "b3-xattr-mismatch 3", "b2b-rmlint-mismatch 3", "dir-error 1", "open-error 1", "read-error 2", "unstable 1"];
		let line = format!("events in the whole run: {}", kinds.join(", "));
		let rows = fitted(&line, Some(80), Fit::Break);
		assert_eq!(rows, ["events in the whole run: b3-db-mismatch 3, b3-xattr-mismatch 3,", "\tb2b-rmlint-mismatch 3, dir-error 1, open-error 1, read-error 2,", "\tunstable 1"]);
		for w in 10..120 {
			let rows = fitted(&line, Some(w), Fit::Break);
			for r in &rows {
				assert!(cols(r) <= w, "{w}: {r}");
			}
			// Each kind is whole once a row has room for it.
			if w >= "events in the whole run: b3-db-mismatch 3,".len() {
				let joined = rows.join(" ").replace('\t', "");
				assert_eq!(joined, line, "{w}: {rows:?}");
			}
		}
		// A part that fits a row of its own still moves whole, as before.
		let summary = "sda: files 3 hashed 3 | events in the whole run: dir-error 1, read-error 2";
		assert_eq!(fitted(summary, Some(60), Fit::Break), ["sda: files 3 hashed 3", "\tevents in the whole run: dir-error 1, read-error 2"]);
	}

	// Under sudo the scan is root's, and the name the user's (2026111019145405).
	#[test]
	#[cfg_attr(miri, ignore = "Miri can't make links")]
	fn log_link_refused() {
		let _id = test_id("df4xq");
		let d = crate::testutil::scratch("say_log_link");
		std::os::unix::fs::symlink(d.join("elsewhere"), d.join("scan.log")).unwrap();
		let got = open_log(&d.join("scan.log"), &d.join("t.sqlite"), None, &[]).unwrap_err();
		assert!(got.starts_with("--log "), "{got}");
		assert!(!d.join("elsewhere").exists());
	}

	// Nothing is written to NTFS, APFS or HFS+, the log included.
	#[test]
	fn a_log_on_ntfs_is_refused() {
		let _id = test_id("dfdmk");
		let d = crate::testutil::scratch("say_log_ntfs");
		let win = crate::mounts::Mount {
			id: 1,
			parent: 0,
			dev: "0:1".into(),
			root: "/".into(),
			point: std::fs::canonicalize(&*d).unwrap(),
			fstype: "ntfs3".into(),
			source: "/dev/sdz1".into(),
		};
		let got = open_log(&d.join("scan.log"), &d.join("t.sqlite"), None, &[win]).unwrap_err();
		assert!(got.contains("is on ntfs3"), "{got}");
		assert!(!d.join("scan.log").exists());
	}

	// Only a log that open_append made is handed over under sudo, so root's own file stays root's (2026111019430926).
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

	// Under sudo a log folder that's neither the user's nor root's is refused before the log is made, as the database's is.
	#[test]
	#[cfg_attr(miri, ignore = "Miri has no O_PATH")]
	fn log_folder_owner_checked() {
		let _id = test_id("df4y4");
		let d = crate::testutil::scratch("say_log_folder");
		let me = std::fs::metadata(&*d).unwrap();
		let log = d.join("scan.log");
		let said = open_log(&log, &d.join("t.sqlite"), Some((me.uid() + 1, me.gid())), &[]).unwrap_err();
		assert!(said.starts_with("--log folder ") && said.ends_with("; refused"), "{said}");
		assert!(!log.exists());
	}

	// A FIFO with no reader hung the scan in open(), and one with a reader took the log (2026111918562702).
	#[test]
	#[cfg_attr(miri, ignore = "Miri can't make a FIFO")]
	fn log_not_regular_refused() {
		let _id = test_id("dfjv7");
		let d = crate::testutil::scratch("say_log_fifo");
		let fifo = d.join("scan.log");
		let c = crate::util::cpath(&fifo).unwrap();
		// SAFETY: c is NUL-terminated and outlives the call.
		assert_eq!(unsafe { libc::mkfifo(c.as_ptr(), 0o600) }, 0);
		let db = d.join("t.sqlite");
		let refused = |log: &Path| {
			let got = open_log(log, &db, None, &[]).unwrap_err();
			assert!(got.ends_with(": not a regular file; refused"), "{got}");
		};
		refused(&fifo);
		let _reader = File::options().read(true).custom_flags(libc::O_NONBLOCK).open(&fifo).unwrap();
		refused(&fifo);
		refused(Path::new("/dev/null"));
	}

	// A log there would put text after the database's last page, in its lock, or in a -wal that SQLite deletes (2026111918562724).
	#[test]
	#[cfg_attr(miri, ignore = "Miri has no O_PATH")]
	fn log_at_db_refused() {
		let _id = test_id("dfjv8");
		let d = crate::testutil::scratch("say_log_db");
		let db = d.join("t.sqlite");
		std::fs::write(&db, "db").unwrap();
		std::fs::write(d.join("t.sqlite.lock"), "").unwrap();
		std::fs::hard_link(&db, d.join("linked.log")).unwrap();
		std::fs::hard_link(d.join("t.sqlite.lock"), d.join("lock.log")).unwrap();
		std::os::unix::fs::symlink(&*d, d.join("alias")).unwrap();
		for name in ["t.sqlite", "t.sqlite.lock", "t.sqlite-wal", "t.sqlite-shm", "t.sqlite-journal", "linked.log", "lock.log", "alias/t.sqlite-wal"] {
			let got = open_log(&d.join(name), &db, None, &[]).unwrap_err();
			assert!(got.ends_with(": is one of the database's files; refused"), "{name}: {got}");
		}
		assert_eq!(std::fs::read(&db).unwrap(), b"db");
		assert!(!d.join("t.sqlite-wal").exists());
		let dir = File::open(&*d).unwrap();
		for other in ["t.sqlite.log", "t.sqlite-wal2", "u.sqlite", "scan.log"] {
			assert!(!crate::scan::is_db_name(&db, &dir, OsStr::new(other)), "{other}");
		}
	}

	// Each write the log gets, as the file would see it.
	#[derive(Default)]
	struct Writes {
		got: Vec<Vec<u8>>,
		fail: Option<i32>,
	}

	impl Write for Writes {
		fn write(&mut self, b: &[u8]) -> io::Result<usize> {
			if let Some(n) = self.fail {
				return Err(io::Error::from_raw_os_error(n));
			}
			self.got.push(b.to_vec());
			Ok(b.len())
		}
		fn flush(&mut self) -> io::Result<()> {
			Ok(())
		}
	}

	fn test_log(fail: Option<i32>) -> Log<Writes> {
		Log {
			to: Writes { got: Vec::new(), fail },
			path: "/x/scan.log".into(),
			warned: false,
		}
	}

	// A line and its newline went out in 2 writes, so 2 scans appending to one log could mix them (2026111918562715).
	#[test]
	fn a_log_line_is_one_write() {
		let _id = test_id("dfjyb");
		let mut l = test_log(None);
		assert_eq!(l.put("run 1 done"), None);
		assert_eq!(l.put("a\nb"), None);
		assert_eq!(l.to.got, [b"run 1 done\n".to_vec(), b"a\nb\n".to_vec()]);
	}

	// A full disk left the log empty without a warning (2026111918562723).
	#[test]
	fn log_write_fail_warns_once() {
		let _id = test_id("dfjyc");
		let mut l = test_log(Some(libc::ENOSPC));
		let first = l.put("a").unwrap();
		assert!(first.starts_with("warning: can't write to --log /x/scan.log: ") && first.ends_with(", so it's missing lines"), "{first}");
		assert_eq!(l.put("b"), None);
		l.to.fail = None;
		assert_eq!(l.put("c"), None);
		assert_eq!(l.to.got, [b"c\n".to_vec()]);
	}
}
