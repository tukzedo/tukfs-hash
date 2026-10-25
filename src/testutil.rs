// Copyright © 2026 t00mietum (CryptogID: ปʬϝღถɔ4რఠΔթะ9ƾǝu)
// Licensed under GPL-2.0-only. No warranty.

// What the unit tests share: a status line with each test's ID, and scratch
// folders under <TMPDIR>/tukfs-hash/ that go even when a test fails. A run
// that was killed leaves its folders, and the next one sweeps them once
// they're a day old.

use std::fs;
use std::io::{self, Write as _};
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::Once;
use std::time::Duration;

/// Held for the length of a test. Its line goes out when it drops, as a
/// failure when that's by a panic.
pub struct TestId(&'static str);

/// Every test calls this first. A new test's ID comes from
/// `cicd/utility/test-ids.py new`.
pub fn test_id(id: &'static str) -> TestId {
	TestId(id)
}

impl Drop for TestId {
	fn drop(&mut self) {
		let status = if std::thread::panicking() {
			"FAIL"
		} else {
			"PASS"
		};
		// libtest names each test's thread after the test, and captures only
		// the print macros, so this goes past it. One write, so another
		// test's line can't land in the middle of it.
		let thread = std::thread::current();
		let line = format!("{status} {} {}\n", self.0, thread.name().unwrap_or("?"));
		let _ = io::stderr().write_all(line.as_bytes());
	}
}

const PREFIX: &str = "test_tukfs-hash_unit_";
// Left that long in case someone's looking at what a killed run left.
const STALE: Duration = Duration::from_secs(86_400);
static SWEEP: Once = Once::new();

/// A test's own folder, removed when it drops, by a panic too.
pub struct Scratch {
	dir: PathBuf,
	base: PathBuf,
}

impl std::ops::Deref for Scratch {
	type Target = Path;
	fn deref(&self) -> &Path {
		&self.dir
	}
}

impl AsRef<Path> for Scratch {
	fn as_ref(&self) -> &Path {
		&self.dir
	}
}

impl Drop for Scratch {
	fn drop(&mut self) {
		if let Err(e) = safe_rm(&self.dir, &self.base) {
			eprintln!("left {}: {e}", self.dir.display());
		}
	}
}

fn tag_ok(tag: &str) -> bool {
	!tag.is_empty()
		&& tag
			.bytes()
			.all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_')
}

/// An empty <TMPDIR>/tukfs-hash/test_tukfs-hash_unit_<TAG>_<pid>. TAG is
/// a-z, 0-9 and _, and no 2 tests share one.
pub fn scratch(tag: &str) -> Scratch {
	assert!(tag_ok(tag), "bad scratch tag: {tag}");
	let base = base().unwrap_or_else(|e| {
		panic!(
			"no scratch base under {}: {e}",
			std::env::temp_dir().display()
		)
	});
	let dir = base.join(format!("{PREFIX}{tag}_{}", std::process::id()));
	// From an earlier run that had this pid.
	if fs::symlink_metadata(&dir).is_ok() {
		safe_rm(&dir, &base).unwrap_or_else(|e| panic!("{}: {e}", dir.display()));
	}
	fs::create_dir(&dir).unwrap_or_else(|e| panic!("{}: {e}", dir.display()));
	Scratch { dir, base }
}

fn base() -> io::Result<PathBuf> {
	let base = fs::canonicalize(std::env::temp_dir())?.join("tukfs-hash");
	match fs::create_dir(&base) {
		Err(e) if e.kind() != io::ErrorKind::AlreadyExists => return Err(e),
		_ => {}
	}
	if !fs::symlink_metadata(&base)?.is_dir() || fs::canonicalize(&base)? != base {
		return Err(io::Error::other(format!(
			"{} is a link or not a folder",
			base.display()
		)));
	}
	SWEEP.call_once(|| sweep(&base));
	Ok(base)
}

/// The pid in a name `scratch()` gives, or None for any other name.
fn pid_of(name: &str) -> Option<u32> {
	let (tag, pid) = name.strip_prefix(PREFIX)?.rsplit_once('_')?;
	let digits =
		!pid.is_empty() && !pid.starts_with('0') && pid.bytes().all(|b| b.is_ascii_digit());
	if !tag_ok(tag) || !digits {
		return None;
	}
	pid.parse().ok()
}

/// What killed runs left in BASE: a day old, and their pid gone. Without
/// /proc there's no telling, so nothing goes.
fn sweep(base: &Path) {
	let Ok(list) = fs::read_dir(base) else {
		return;
	};
	if !Path::new("/proc/self").exists() {
		return;
	}
	for e in list.flatten() {
		let Some(pid) = e.file_name().to_str().and_then(pid_of) else {
			continue;
		};
		if pid == std::process::id() || Path::new("/proc").join(pid.to_string()).exists() {
			continue;
		}
		let p = e.path();
		let old = fs::symlink_metadata(&p)
			.and_then(|m| m.modified())
			.ok()
			.and_then(|t| t.elapsed().ok())
			.is_some_and(|age| age > STALE);
		if old && let Err(err) = safe_rm(&p, base) {
			eprintln!("left {}: {err}", p.display());
		}
	}
}

/// `remove_dir_all`, but only on what can only be a scratch folder: a name
/// `scratch()` gives, right under BASE, not a link, where its path says, ours,
/// and nothing past the filesystem it's on.
fn safe_rm(dir: &Path, base: &Path) -> io::Result<()> {
	let refuse = |why: &str| Err(io::Error::other(format!("not removed, {why}")));
	let named = dir
		.file_name()
		.and_then(|n| n.to_str())
		.is_some_and(|n| pid_of(n).is_some());
	if !named || dir.parent() != Some(base) {
		return refuse("not a scratch folder");
	}
	let md = fs::symlink_metadata(dir)?;
	if !md.is_dir() {
		return refuse("a link or not a folder");
	}
	if fs::canonicalize(dir)? != dir {
		return refuse("a link on the way");
	}
	// /proc/self is the euid's. Miri's geteuid makes one up.
	if md.uid() != fs::metadata("/proc/self")?.uid() {
		return refuse("not ours");
	}
	remove_tree(dir, &md, md.dev())
}

fn remove_tree(dir: &Path, md: &fs::Metadata, dev: u64) -> io::Result<()> {
	if md.dev() != dev {
		return Err(io::Error::other(format!(
			"not removed, {} is on another filesystem",
			dir.display()
		)));
	}
	// A test can leave a folder it made read-only.
	if md.mode() & 0o700 != 0o700 {
		fs::set_permissions(dir, fs::Permissions::from_mode(0o700))?;
	}
	for e in fs::read_dir(dir)? {
		let p = e?.path();
		let m = fs::symlink_metadata(&p)?;
		if m.is_dir() {
			remove_tree(&p, &m, dev)?;
		} else {
			fs::remove_file(&p)?;
		}
	}
	fs::remove_dir(dir)
}

#[cfg(test)]
mod tests {
	use super::*;
	use std::time::SystemTime;

	// A failed test's folder goes, a read-only one inside it too.
	#[test]
	fn a_scratch_folder_goes_on_a_panic() {
		let _id = test_id("debap");
		let (tx, rx) = std::sync::mpsc::channel();
		let failed = std::thread::spawn(move || {
			let d = scratch("testutil_panic");
			fs::create_dir(d.join("ro")).unwrap();
			fs::write(d.join("ro/f"), "x").unwrap();
			fs::set_permissions(d.join("ro"), fs::Permissions::from_mode(0o500)).unwrap();
			tx.send(d.to_path_buf()).unwrap();
			panic!("on purpose");
		})
		.join();
		assert!(failed.is_err());
		let dir = rx.recv().unwrap();
		let base = fs::canonicalize(std::env::temp_dir())
			.unwrap()
			.join("tukfs-hash");
		assert_eq!(dir.parent(), Some(base.as_path()));
		assert!(
			fs::symlink_metadata(&dir).is_err(),
			"{} is still there",
			dir.display()
		);
	}

	// Of these only the old one of a pid that's gone may go.
	#[test]
	#[cfg_attr(miri, ignore = "Miri can't start a process")]
	fn only_a_dead_runs_old_folders_are_swept() {
		let _id = test_id("debaq");
		let d = scratch("testutil_sweep");
		let mut child = std::process::Command::new("true").spawn().unwrap();
		let dead = child.id();
		child.wait().unwrap();
		let old = SystemTime::now() - 2 * STALE;
		let make = |name: &str, age: Option<SystemTime>| {
			let p = d.join(name);
			fs::create_dir(&p).unwrap();
			fs::write(p.join("f"), "x").unwrap();
			if let Some(t) = age {
				fs::File::open(&p).unwrap().set_modified(t).unwrap();
			}
			p
		};
		let gone = make(&format!("{PREFIX}old_{dead}"), Some(old));
		let young = make(&format!("{PREFIX}young_{dead}"), None);
		let live = make(&format!("{PREFIX}live_1"), Some(old));
		let odd = make(&format!("{PREFIX}Odd-one_{dead}"), Some(old));
		let target = make("target", Some(old));
		let link = d.join(format!("{PREFIX}link_{dead}"));
		std::os::unix::fs::symlink(&target, &link).unwrap();
		sweep(&d);
		assert!(fs::symlink_metadata(&gone).is_err());
		for p in [&young, &live, &odd, &target] {
			assert!(p.join("f").exists(), "{}", p.display());
		}
		assert!(fs::symlink_metadata(&link).unwrap().is_symlink());
		// A link named like one is refused even when it's old.
		assert!(safe_rm(&link, &d).is_err());
		assert!(target.join("f").exists());
		// Not under the base it's given, so it's left.
		assert!(safe_rm(&young, &d.join("elsewhere")).is_err());
		assert!(young.exists());
	}
}
