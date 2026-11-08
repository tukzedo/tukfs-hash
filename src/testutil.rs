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
#[derive(Debug)]
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
		// test's line can't end up in the middle of it.
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
#[derive(Debug)]
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
/// `scratch()` gives, right under BASE, no link, where its path says, ours,
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

/// splitmix64, so a case is a pure function of its seed on every box.
#[derive(Debug)]
pub struct Rng(u64);

impl Rng {
	/// The next number.
	pub fn next_u64(&mut self) -> u64 {
		self.0 = self.0.wrapping_add(0x9e37_79b9_7f4a_7c15);
		let mut z = self.0;
		z = (z ^ (z >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
		z = (z ^ (z >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
		z ^ (z >> 31)
	}

	/// 0 to n - 1.
	pub fn below(&mut self, n: usize) -> usize {
		(self.next_u64() % n.max(1) as u64) as usize
	}

	/// True about once in n.
	pub fn one_in(&mut self, n: usize) -> bool {
		self.below(n) == 0
	}

	/// One of the items.
	pub fn pick<'a, T>(&mut self, items: &'a [T]) -> &'a T {
		&items[self.below(items.len())]
	}
}

/// What a fuzz run did.
#[derive(Debug)]
pub struct Fuzzed {
	pub cases: u64,
	covered: u32,
	replay: bool,
}

impl Fuzzed {
	/// The guard that the generator still makes what it's meant to: each bit
	/// is something some case must have hit. A replayed seed can't hit them all.
	pub fn covers(&self, want: u32) {
		assert!(
			self.replay || self.covered & want == want,
			"{} cases never hit {:#b}",
			self.cases,
			want & !self.covered
		);
	}
}

fn fuzz_env(name: &str) -> Option<String> {
	std::env::var(name).ok().filter(|v| !v.is_empty())
}

/// Runs `case` over one seed after another until `TUKFS_FUZZ_SECS` of wall
/// time is gone, 1 s when unset. Each run starts from a new seed, and a
/// failure names its own, which `TUKFS_FUZZ_SEED` runs again alone. A case
/// returns the coverage bits it hit.
pub fn fuzz(name: &str, case: impl Fn(&mut Rng) -> u32) -> Fuzzed {
	let one = |seed: u64| {
		std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| case(&mut Rng(seed))))
			.unwrap_or_else(|_| {
				panic!("{name}: seed {seed} failed; TUKFS_FUZZ_SEED={seed} runs it again")
			})
	};
	if let Some(seed) = fuzz_env("TUKFS_FUZZ_SEED") {
		let seed = seed.parse().expect("TUKFS_FUZZ_SEED is a number");
		return Fuzzed {
			cases: 1,
			covered: one(seed),
			replay: true,
		};
	}
	let secs: f64 = fuzz_env("TUKFS_FUZZ_SECS").map_or(1.0, |s| {
		s.parse()
			.ok()
			.filter(|s: &f64| s.is_finite() && *s >= 0.0)
			.expect("TUKFS_FUZZ_SECS is seconds")
	});
	let until = std::time::Instant::now() + Duration::from_secs_f64(secs);
	let start = std::time::SystemTime::now()
		.duration_since(std::time::UNIX_EPOCH)
		.map_or(0, |d| d.as_nanos() as u64);
	let mut done = Fuzzed {
		cases: 0,
		covered: 0,
		replay: false,
	};
	// At least a few hundred, so a busy box still gets some coverage.
	while done.cases < 300 || std::time::Instant::now() < until {
		done.covered |= one(start.wrapping_add(done.cases));
		done.cases += 1;
	}
	done
}

/// Real input gone bad: bits flipped, cut short, bytes dropped, doubled or
/// changed, and the bytes the parsers split on put in.
pub fn mutate(rng: &mut Rng, input: &[u8]) -> Vec<u8> {
	const SPLICE: &[&[u8]] = &[
		b"\n",
		b"\t",
		b" ",
		b"\\",
		b" - ",
		b" -> ",
		b":",
		b"-",
		b"\\0040",
		b"\\040",
		b"\\777",
		b"\r",
		b"\0",
		b"(+1)",
		b"\xff",
		b"/",
		b"..",
		b"9999999999999999999999",
	];
	let mut out = input.to_vec();
	for _ in 0..=rng.below(8) {
		let at = rng.below(out.len() + 1);
		match rng.below(6) {
			0 if at < out.len() => out[at] ^= 1 << rng.below(8),
			1 => out.truncate(at),
			2 if at < out.len() => {
				out.remove(at);
			}
			3 => {
				let end = (at + rng.below(24)).min(out.len());
				out = [&out[..end], &out[at..]].concat();
			}
			4 => out = [&out[..at], rng.pick(SPLICE), &out[at..]].concat(),
			_ if at < out.len() => out[at] = rng.next_u64() as u8,
			_ => {}
		}
	}
	out
}

#[cfg(test)]
mod tests {
	use super::*;
	use std::collections::BTreeSet;
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

	#[test]
	fn a_case_is_its_seed() {
		let _id = test_id("deebc");
		let run = |seed| {
			let mut r = Rng(seed);
			mutate(&mut r, b"M\t/home/u/a\nR\t/home/u/b\t/home/u/c\n")
		};
		assert_eq!(run(7), run(7));
		assert!((0..50).map(run).collect::<BTreeSet<_>>().len() > 40);
		let mut r = Rng(0);
		// Pinned, so a change to the generator shows here first.
		assert_eq!(r.next_u64(), 0xe220_a839_7b1d_cdaf);
		let hit = std::cell::Cell::new(0u64);
		let f = fuzz("self", |r| {
			hit.set(hit.get() + 1);
			1 << r.below(3)
		});
		assert_eq!(f.cases, hit.get());
		assert!(f.cases >= 300);
		f.covers(0b111);
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
