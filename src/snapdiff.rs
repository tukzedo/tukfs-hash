// Copyright © 2026 t00mietum (CryptogID: ปʬϝღถɔ4რఠΔթะ9ƾǝu)
// Licensed under GPL-2.0-only. No warranty.

// Compares the files a snapshot diff says changed. A real edit moves the
// modified time. A file whose bytes changed under the same size and time was
// changed by something that didn't go through the filesystem's write path,
// such as bad RAM under the page cache. `cp -p`, `rsync -t`, tar and `touch -r`
// also do it, so each hit still needs a look.

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::ffi::OsStr;
use std::fs::{self, File, Metadata};
use std::io::{self, Read};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{DirEntryExt, MetadataExt};
use std::path::{Component, Path, PathBuf};

use crate::util::{escape_name, show_path};

/// Where the list of changed files comes from.
#[derive(Debug)]
pub enum Source {
	/// `zfs diff` output, with the dataset's mount point to strip.
	ZfsDiff(PathBuf, PathBuf),
	/// `btrfs subvolume find-new` output; paths are already relative.
	FindNew(PathBuf),
	/// One relative path per line.
	List(PathBuf),
}

/// A file to compare, by its name in each snapshot. find-new gives the inode
/// too, which finds the old copy after a rename.
#[derive(Debug, PartialEq)]
pub struct Pair {
	pub old: PathBuf,
	pub new: PathBuf,
	pub ino: Option<u64>,
}

impl Pair {
	fn same(p: PathBuf) -> Pair {
		Pair {
			// Owned per side, since a rename gives two names.
			old: p.clone(),
			new: p,
			ino: None,
		}
	}
}

/// A change list, as parsed.
#[derive(Debug, Default, PartialEq)]
pub struct Parsed {
	pub pairs: Vec<Pair>,
	/// Line number and text.
	pub unusable: Vec<(usize, Vec<u8>)>,
	pub outside: Vec<(usize, Vec<u8>)>,
}

// zfs diff writes odd bytes as a backslash and four octal digits, \0040 for a
// space.
fn zfs_unescape(s: &[u8]) -> Vec<u8> {
	let mut out = Vec::with_capacity(s.len());
	let mut i = 0;
	while i < s.len() {
		if s[i] == b'\\'
			&& i + 4 < s.len()
			&& s[i + 1..i + 5].iter().all(|c| (b'0'..=b'7').contains(c))
		{
			let v = s[i + 1..i + 5]
				.iter()
				.fold(0u32, |a, c| a * 8 + u32::from(c - b'0'));
			out.push(v as u8);
			i += 5;
		} else {
			out.push(s[i]);
			i += 1;
		}
	}
	out
}

// -t prints "%10lld.%09lld", space padded.
fn is_time(f: &[u8]) -> bool {
	let t = f.trim_ascii_start();
	t.contains(&b'.') && t.iter().all(|c| c.is_ascii_digit() || *c == b'.')
}

fn is_link_delta(f: &[u8]) -> bool {
	f.len() > 3
		&& f[0] == b'('
		&& matches!(f[1], b'+' | b'-')
		&& f[f.len() - 1] == b')'
		&& f[2..f.len() - 1].iter().all(u8::is_ascii_digit)
}

fn strip_mount(p: &[u8], mounts: &[&Path]) -> Option<PathBuf> {
	let p = Path::new(OsStr::from_bytes(p));
	mounts
		.iter()
		.find_map(|m| p.strip_prefix(m).ok())
		.map(Path::to_path_buf)
}

/// Takes -H or not, -t and -F. M and R lines are compared, and so is a path
/// with both a - and a + line, which is a file replaced by a new one, as rsync,
/// tar and atomic saves do.
pub fn parse_zfs_diff(text: &[u8], mounts: &[&Path]) -> Parsed {
	let mut parsed = Parsed::default();
	let (mut removed, mut added) = (BTreeSet::new(), BTreeSet::new());
	for (i, line) in text.split(|&c| c == b'\n').enumerate() {
		if line.is_empty() {
			continue;
		}
		let line_no = i + 1;
		let mut f: Vec<&[u8]> = line.split(|&c| c == b'\t').collect();
		if f.len() > 2 && is_time(f[0]) {
			f.remove(0);
		}
		let kind = f.remove(0);
		if !matches!(kind, b"M" | b"R" | b"-" | b"+") {
			parsed.unusable.push((line_no, line.to_vec()));
			continue;
		}
		// Without -H a rename is "old -> new" in one field. Spaces in names are
		// escaped, so the arrow can't be part of one.
		if kind == b"R"
			&& let Some(last) = f.pop()
		{
			match last.windows(4).position(|w| w == b" -> ") {
				Some(at) => f.extend([&last[..at], &last[at + 4..]]),
				None => f.push(last),
			}
		}
		// A link count change ends in "(+1)" or "(-1)".
		if kind == b"M" && f.last().is_some_and(|l| is_link_delta(l)) {
			f.pop();
		}
		let want = if kind == b"R" { 2 } else { 1 };
		// -F puts a one-character type before the names.
		let (ftype, names) = if f.len() == want {
			(None, &f[..])
		} else if f.len() == want + 1 && f[0].len() == 1 && b"BC/>|@P=F?".contains(&f[0][0]) {
			(Some(f[0][0]), &f[1..])
		} else {
			parsed.unusable.push((line_no, line.to_vec()));
			continue;
		};
		let mut rel: Vec<PathBuf> = names
			.iter()
			.map_while(|n| strip_mount(&zfs_unescape(n), mounts))
			.collect();
		if rel.len() != names.len() {
			parsed.outside.push((line_no, line.to_vec()));
			continue;
		}
		if ftype.is_some_and(|t| t != b'F') {
			continue;
		}
		// The pops run left to right, so a rename's new name comes off first.
		match (kind, rel.pop(), rel.pop()) {
			(b"R", Some(new), Some(old)) => parsed.pairs.push(Pair {
				old,
				new,
				ino: None,
			}),
			(b"M", Some(p), None) => parsed.pairs.push(Pair::same(p)),
			(b"-", Some(p), None) => {
				removed.insert(p);
			}
			(b"+", Some(p), None) => {
				added.insert(p);
			}
			_ => parsed.unusable.push((line_no, line.to_vec())),
		}
	}
	parsed.pairs.extend(
		removed
			.into_iter()
			.filter(|p| added.contains(p))
			.map(Pair::same),
	);
	parsed
}

// "inode 257 file offset 0 len 4096 disk start 0 offset 0 gen 9 flags NONE name"
fn find_new_line(line: &[u8]) -> Option<(u64, PathBuf)> {
	let f: Vec<&[u8]> = line.splitn(17, |&c| c == b' ').collect();
	if f.len() != 17 || f[0] != b"inode" || f[2] != b"file" || f[14] != b"flags" || f[16].is_empty()
	{
		return None;
	}
	let ino = std::str::from_utf8(f[1]).ok()?.parse().ok()?;
	Some((ino, PathBuf::from(OsStr::from_bytes(f[16]))))
}

/// Parses `btrfs subvolume find-new` output.
pub fn parse_find_new(text: &[u8]) -> Parsed {
	let mut parsed = Parsed::default();
	let mut seen = BTreeMap::new();
	for (i, line) in text.split(|&c| c == b'\n').enumerate() {
		if line.is_empty() || line.starts_with(b"transid marker was ") {
			continue;
		}
		match find_new_line(line) {
			Some((ino, name)) => {
				seen.insert(name, ino);
			}
			None => parsed.unusable.push((i + 1, line.to_vec())),
		}
	}
	parsed.pairs = seen
		.into_iter()
		.map(|(p, ino)| Pair {
			ino: Some(ino),
			..Pair::same(p)
		})
		.collect();
	parsed
}

/// Parses one relative path per line.
pub fn parse_list(text: &[u8]) -> Parsed {
	Parsed {
		pairs: text
			.split(|&c| c == b'\n')
			.filter(|l| !l.is_empty())
			.map(|l| Pair::same(PathBuf::from(OsStr::from_bytes(l))))
			.collect(),
		..Parsed::default()
	}
}

// An absolute name makes join() drop --old and --new, so a file would be
// compared with itself.
fn stays_inside(p: &Path) -> bool {
	p.components()
		.all(|c| matches!(c, Component::Normal(_) | Component::CurDir))
}

/// Bytes that differ, and where, as runs of start and length.
#[derive(Debug)]
pub struct Diff {
	pub differing: u64,
	pub runs: Vec<(u64, u64)>,
}

/// Read buffers for `compare`, made once per run rather than per file.
#[derive(Debug)]
pub struct CompareBufs {
	a: Vec<u8>,
	b: Vec<u8>,
}

impl Default for CompareBufs {
	fn default() -> Self {
		Self {
			a: vec![0u8; 1 << 20],
			b: vec![0u8; 1 << 20],
		}
	}
}

/// Byte runs that differ. Runs a few bytes apart are merged, since a scribble
/// rarely changes every byte it touches.
pub fn compare(mut fa: File, mut fb: File, bufs: &mut CompareBufs) -> io::Result<Diff> {
	let CompareBufs { a: ba, b: bb } = bufs;
	let mut off: u64 = 0;
	let mut d = Diff {
		differing: 0,
		runs: Vec::new(),
	};
	let (la, lb) = (fa.metadata()?.len(), fb.metadata()?.len());
	while off < la.min(lb) {
		let na = read_full(&mut fa, ba)?;
		let nb = read_full(&mut fb, bb)?;
		let n = na.min(nb);
		if n == 0 {
			break;
		}
		if ba[..n] != bb[..n] {
			for i in 0..n {
				if ba[i] != bb[i] {
					d.differing += 1;
					let pos = off + i as u64;
					match d.runs.last_mut() {
						Some((s, l)) if pos <= *s + *l + 4 => *l = pos - *s + 1,
						_ => d.runs.push((pos, 1)),
					}
				}
			}
		}
		off += n as u64;
	}
	// The tail of the longer file has nothing to match.
	if la != lb {
		let common = la.min(lb);
		d.differing += la.max(lb) - common;
		d.runs.push((common, la.max(lb) - common));
	}
	Ok(d)
}

fn read_full(f: &mut File, buf: &mut [u8]) -> io::Result<usize> {
	let mut n = 0;
	while n < buf.len() {
		match f.read(&mut buf[n..]) {
			Ok(0) => break,
			Ok(k) => n += k,
			Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
			Err(e) => return Err(e),
		}
	}
	Ok(n)
}

fn describe(d: &Diff) -> String {
	let aligned = d.runs.iter().filter(|(s, _)| s % 16 == 0).count();
	let shown: Vec<String> = d
		.runs
		.iter()
		.take(8)
		.map(|(s, l)| format!("{s}+{l}"))
		.collect();
	format!(
		"{} bytes differ in {} run(s), {} starting on a 16-byte boundary: {}{}",
		d.differing,
		d.runs.len(),
		aligned,
		shown.join(" "),
		if d.runs.len() > 8 { " ..." } else { "" }
	)
}

struct Job {
	name: String,
	new_path: PathBuf,
	new_md: Metadata,
	old: Option<(PathBuf, Metadata)>,
}

#[derive(Default)]
struct Tally {
	checked: u64,
	flagged: u64,
	missing: u64,
	missing_new: u64,
	unchecked: u64,
}

impl Tally {
	// A file zfs diff or find-new says is there and isn't means the snapshots
	// aren't the ones diffed, or one went away.
	fn missing(&mut self, expected: bool, name: &str, side: &str) {
		self.missing += 1;
		if expected {
			self.unchecked += 1;
			out!("missing\t{name}\tnot in {side}");
		}
	}
}

// Old copies of renamed files, found by inode. Snapshots of one btrfs
// subvolume keep inode numbers, and the birth time rules out a number used
// again after a delete. One walk serves every file the pair needs.
fn find_by_inode(
	old: &Path,
	wanted: &mut HashMap<u64, usize>,
	jobs: &mut [Job],
	tally: &mut Tally,
) {
	let Ok(dev) = fs::symlink_metadata(old).map(|m| m.dev()) else {
		return;
	};
	let mut dirs = vec![old.to_path_buf()];
	while let Some(dir) = dirs.pop() {
		let entries = match fs::read_dir(&dir) {
			Ok(rd) => rd,
			Err(e) => {
				tally.unchecked += 1;
				out!("walk-error\t{}\t{e}", show_path(&dir));
				continue;
			}
		};
		for ent in entries {
			let ent = match ent {
				Ok(ent) => ent,
				Err(e) => {
					tally.unchecked += 1;
					out!("walk-error\t{}\t{e}", show_path(&dir));
					break;
				}
			};
			let Ok(ft) = ent.file_type() else { continue };
			if ft.is_dir() {
				let p = ent.path();
				if fs::symlink_metadata(&p).is_ok_and(|m| m.dev() == dev) {
					dirs.push(p);
				}
				continue;
			}
			let Some(&job) = wanted.get(&ent.ino()) else {
				continue;
			};
			let p = ent.path();
			let Ok(md) = fs::symlink_metadata(&p) else {
				continue;
			};
			let same_birth = match (md.created(), jobs[job].new_md.created()) {
				(Ok(a), Ok(b)) => a == b,
				_ => true,
			};
			if md.is_file() && same_birth {
				jobs[job].old = Some((p, md));
				wanted.remove(&ent.ino());
				if wanted.is_empty() {
					return;
				}
			}
		}
	}
}

/// The `snapdiff` command.
#[allow(clippy::too_many_lines, reason = "split by 2026102308220558")]
pub fn run(old: &Path, new: &Path, src: &Source, show_all: bool) -> Result<i32, String> {
	for dir in [old, new] {
		let md = fs::metadata(dir).map_err(|e| format!("{}: {e}", show_path(dir)))?;
		if !md.is_dir() {
			return Err(format!("{}: not a folder", show_path(dir)));
		}
	}
	let read = |p: &Path| fs::read(p).map_err(|e| format!("{}: {e}", show_path(p)));
	// Which side each listed file has to be on. zfs diff names files in both
	// snapshots, find-new files in the new one, and a list can name anything.
	let (parsed, need_old, need_new) = match src {
		Source::ZfsDiff(f, mount) => {
			// zfs prints the real mount point, and --mount may go through a symlink.
			let resolved = fs::canonicalize(mount).ok().filter(|r| r != mount);
			let mut mounts = vec![mount.as_path()];
			mounts.extend(resolved.as_deref());
			let parsed = parse_zfs_diff(&read(f)?, &mounts);
			if let Some((line_no, text)) = parsed.outside.first() {
				return Err(format!(
					"{}: {} line(s) aren't under --mount {}, the first at line {line_no}: {}",
					show_path(f),
					parsed.outside.len(),
					show_path(mount),
					escape_name(text)
				));
			}
			(parsed, true, true)
		}
		Source::FindNew(f) => (parse_find_new(&read(f)?), false, true),
		Source::List(f) => (parse_list(&read(f)?), false, false),
	};
	if let Some(p) = parsed
		.pairs
		.iter()
		.flat_map(|p| [&p.old, &p.new])
		.find(|p| !stays_inside(p))
	{
		return Err(format!(
			"{}: names have to be relative to --old and --new, with no ..",
			show_path(p)
		));
	}
	for (line_no, text) in parsed.unusable.iter().take(5) {
		err!("line {line_no} not understood: {}", escape_name(text));
	}

	let mut tally = Tally::default();
	let mut jobs = Vec::new();
	let mut wanted = HashMap::new();
	for pair in &parsed.pairs {
		let name = show_path(&pair.new);
		let new_path = new.join(&pair.new);
		let new_md = match fs::symlink_metadata(&new_path) {
			Ok(m) => m,
			Err(e) if e.kind() == io::ErrorKind::NotFound => {
				tally.missing_new += 1;
				tally.missing(need_new, &name, "--new");
				continue;
			}
			Err(e) => {
				tally.unchecked += 1;
				out!("stat-error\t{name}\t{e}");
				continue;
			}
		};
		if !new_md.is_file() {
			continue;
		}
		let old_path = old.join(&pair.old);
		let old_found = match fs::symlink_metadata(&old_path) {
			Ok(m) => Some((old_path, m)),
			Err(e) if e.kind() == io::ErrorKind::NotFound => {
				if let Some(ino) = pair.ino {
					wanted.insert(ino, jobs.len());
				}
				None
			}
			Err(e) => {
				tally.unchecked += 1;
				out!("stat-error\t{name}\t{e}");
				continue;
			}
		};
		jobs.push(Job {
			name,
			new_path,
			new_md,
			old: old_found,
		});
	}
	if !wanted.is_empty() {
		find_by_inode(old, &mut wanted, &mut jobs, &mut tally);
	}

	let mut bufs = CompareBufs::default();
	for job in &jobs {
		let name = &job.name;
		let Some((old_path, mo)) = &job.old else {
			tally.missing(need_old, name, "--old");
			continue;
		};
		let mn = &job.new_md;
		if !mo.is_file() {
			continue;
		}
		tally.checked += 1;
		let same_time = mo.mtime() == mn.mtime() && mo.mtime_nsec() == mn.mtime_nsec();
		if !same_time {
			if show_all {
				out!("edited\t{name}\tmtime moved");
			}
			continue;
		}
		if mo.len() != mn.len() {
			tally.flagged += 1;
			out!(
				"size-changed-same-mtime\t{name}\t{} -> {} bytes",
				mo.len(),
				mn.len()
			);
			continue;
		}
		let open_both = || -> io::Result<(File, File)> {
			Ok((File::open(old_path)?, File::open(&job.new_path)?))
		};
		let (fa, fb) = match open_both() {
			Ok(f) => f,
			Err(e) => {
				tally.unchecked += 1;
				out!("open-error\t{name}\t{e}");
				continue;
			}
		};
		match compare(fa, fb, &mut bufs) {
			Ok(d) if d.differing == 0 => {
				if show_all {
					out!("same\t{name}\tmetadata only");
				}
			}
			Ok(d) => {
				tally.flagged += 1;
				out!("content-changed-same-mtime\t{name}\t{}", describe(&d));
			}
			Err(e) => {
				tally.flagged += 1;
				out!("read-error\t{name}\t{e}");
			}
		}
	}

	let t = &tally;
	err!(
		"{} listed, {} regular files in both, {} flagged, {} missing, {} not checked, {} lines not understood",
		parsed.pairs.len(),
		t.checked,
		t.flagged,
		t.missing,
		t.unchecked,
		parsed.unusable.len()
	);
	// A list with CRLF ends, or the wrong folders, finds nothing to compare.
	let nothing = t.checked == 0 && t.missing_new > 0;
	if nothing {
		err!(
			"nothing compared: {} listed file(s) aren't in --new",
			t.missing_new
		);
	}
	let mut code = 0;
	if t.flagged > 0 {
		code |= 4;
	}
	if t.unchecked > 0 || !parsed.unusable.is_empty() || nothing {
		code |= 8;
	}
	Ok(code)
}

#[cfg(test)]
mod tests {
	use super::*;
	use crate::testutil::{Rng, scratch, test_id};

	fn mounts(m: &str) -> Vec<&Path> {
		vec![Path::new(m)]
	}

	fn same(p: &str) -> Pair {
		Pair::same(PathBuf::from(p))
	}

	#[test]
	fn zfs_diff_lines() {
		let _id = test_id("ddwzy");
		let text = b"M\t/home/u/a\\0040b.txt\nR\t/home/u/old\t/home/u/new\n+\t/home/u/added\nM\t/other/x\n1700000000.5\tM\t/home/u/t\n";
		let p = parse_zfs_diff(text, &mounts("/home/u"));
		assert_eq!(
			p.pairs,
			vec![
				same("a b.txt"),
				Pair {
					old: PathBuf::from("old"),
					new: PathBuf::from("new"),
					ino: None
				},
				same("t"),
			]
		);
		assert_eq!(p.outside, vec![(4, b"M\t/other/x".to_vec())]);
		assert!(p.unusable.is_empty());
	}

	#[test]
	fn zfs_diff_type_column() {
		let _id = test_id("ddy5v");
		let text = b"M\t/\t/home/u/\nM\tF\t/home/u/a\n R\tF\t/home/u/b\t/home/u/c\n  170000.000000001\tM\tF\t/home/u/t\n+\t@\t/home/u/link\nM\t@\t/home/u/link2\n";
		let p = parse_zfs_diff(text, &mounts("/home/u"));
		assert_eq!(
			p.unusable,
			vec![(3, b" R\tF\t/home/u/b\t/home/u/c".to_vec())]
		);
		assert_eq!(p.pairs, vec![same("a"), same("t")]);
		let p = parse_zfs_diff(b"R\tF\t/home/u/b\t/home/u/c\n", &mounts("/home/u"));
		assert_eq!(p.pairs.len(), 1);
		// A lone "/" is the dataset's own folder when there is no type column.
		let p = parse_zfs_diff(b"M\t/\n", &mounts("/"));
		assert_eq!(p.pairs, vec![same("")]);
	}

	#[test]
	fn zfs_diff_link_count() {
		let _id = test_id("ddy5w");
		let text = b"M\tF\t/home/u/h\t(+1)\nM\t/home/u/h2\t(-12)\nM\t/home/u/h3\t(1)\n";
		let p = parse_zfs_diff(text, &mounts("/home/u"));
		assert_eq!(p.pairs, vec![same("h"), same("h2")]);
		assert_eq!(p.unusable, vec![(3, b"M\t/home/u/h3\t(1)".to_vec())]);
	}

	#[test]
	fn zfs_diff_without_h() {
		let _id = test_id("ddy5x");
		let text = b"R\t/home/u/old\\0040x -> /home/u/new\nR\tF\t/home/u/p -> /home/u/q\n";
		let p = parse_zfs_diff(text, &mounts("/home/u"));
		assert_eq!(p.pairs[0].old, PathBuf::from("old x"));
		assert_eq!(p.pairs[0].new, PathBuf::from("new"));
		assert_eq!(p.pairs[1].new, PathBuf::from("q"));
		assert!(p.unusable.is_empty());
	}

	#[test]
	fn zfs_diff_replaced_files() {
		let _id = test_id("ddy5y");
		let text =
			b"-\t/home/u/saved\n+\t/home/u/saved\n-\t/home/u/gone\n+\t/home/u/born\nM\t/home/u/\n";
		let p = parse_zfs_diff(text, &mounts("/home/u"));
		assert_eq!(p.pairs, vec![same(""), same("saved")]);
	}

	#[test]
	fn zfs_diff_junk_and_outside() {
		let _id = test_id("ddwzz");
		let text = b"X\t/home/u/a\nM\n\nM\t/home/u/a\t/home/u/b\t/home/u/c\nM\t/home/user2/a\nR\t/home/u/a\t/elsewhere/b\n";
		let p = parse_zfs_diff(text, &mounts("/home/u"));
		assert!(p.pairs.is_empty());
		assert_eq!(
			p.unusable.iter().map(|u| u.0).collect::<Vec<_>>(),
			vec![1, 2, 4]
		);
		assert_eq!(
			p.outside.iter().map(|u| u.0).collect::<Vec<_>>(),
			vec![5, 6]
		);
		// Either spelling of the mount point is taken.
		let p = parse_zfs_diff(
			b"M\t/real/u/a\n",
			&[Path::new("/home/u"), Path::new("/real/u")],
		);
		assert_eq!(p.pairs, vec![same("a")]);
	}

	#[test]
	fn find_new_lines() {
		let _id = test_id("ddx00");
		let text = b"inode 257 file offset 0 len 4096 disk start 0 offset 0 gen 9 flags INLINE dir/a file\n\
inode 257 file offset 4096 len 4096 disk start 12 offset 0 gen 9 flags NONE dir/a file\n\
inode 300 file offset 0 len 4096 disk start 12 offset 0 gen 9 flags COMPRESS|PREALLOC b\n\
inode x file offset 0 len 4096 disk start 12 offset 0 gen 9 flags NONE c\n\
something else\n\
transid marker was 12\n";
		let p = parse_find_new(text);
		assert_eq!(
			p.pairs,
			vec![
				Pair {
					ino: Some(300),
					..same("b")
				},
				Pair {
					ino: Some(257),
					..same("dir/a file")
				}
			]
		);
		assert_eq!(
			p.unusable.iter().map(|u| u.0).collect::<Vec<_>>(),
			vec![4, 5]
		);
	}

	#[test]
	fn names_stay_inside() {
		let _id = test_id("ddy5z");
		assert!(stays_inside(Path::new("a/b")));
		assert!(stays_inside(Path::new("")));
		assert!(!stays_inside(Path::new("/etc/passwd")));
		assert!(!stays_inside(Path::new("a/../../b")));
	}

	#[test]
	#[cfg_attr(miri, ignore = "3 MB byte by byte; over 15 min under Miri, safe code")]
	fn finds_a_scribble() {
		let _id = test_id("ddx01");
		let dir = scratch("snapdiff_cmp");
		let mut bufs = CompareBufs::default();
		let mut cmp = |a: &str, b: &str| {
			compare(
				File::open(dir.join(a)).unwrap(),
				File::open(dir.join(b)).unwrap(),
				&mut bufs,
			)
			.unwrap()
		};
		let a: Vec<u8> = (0..3_000_000u32).map(|i| (i * 7) as u8).collect();
		let mut b = a.clone();
		for x in &mut b[2_097_168..2_097_184] {
			*x ^= 0x5a;
		}
		b[2_097_170] = a[2_097_170];
		fs::write(dir.join("a"), &a).unwrap();
		fs::write(dir.join("b"), &b).unwrap();
		let d = cmp("a", "b");
		assert_eq!(d.differing, 15);
		assert_eq!(d.runs, vec![(2_097_168, 16)]);
		assert!(describe(&d).contains("1 starting on a 16-byte boundary"));
		fs::write(dir.join("b"), &a[..100]).unwrap();
		let d = cmp("a", "b");
		assert_eq!(d.differing, a.len() as u64 - 100);
	}

	#[test]
	fn buffers_carry_nothing_between_pairs() {
		let _id = test_id("dej04");
		let dir = scratch("snapdiff_bufs");
		let mut bufs = CompareBufs::default();
		let mut cmp = |a: &[u8], b: &[u8]| {
			fs::write(dir.join("a"), a).unwrap();
			fs::write(dir.join("b"), b).unwrap();
			compare(
				File::open(dir.join("a")).unwrap(),
				File::open(dir.join("b")).unwrap(),
				&mut bufs,
			)
			.unwrap()
		};
		let big: Vec<u8> = (0..5000u32).map(|i| (i * 13) as u8).collect();
		let other: Vec<u8> = big.iter().map(|x| !x).collect();
		assert_eq!(cmp(&big, &other).differing, 5000);
		assert_eq!(cmp(b"same", b"same").differing, 0);
		let d = cmp(b"0123456789", b"0123456780");
		assert_eq!((d.differing, d.runs), (1, vec![(9, 1)]));
		assert_eq!(cmp(b"", b"").differing, 0);
	}

	// zfs diff's own escape: all but printable ASCII, and space and backslash.
	fn zfs_path(base: &[u8], rel: &[u8]) -> Vec<u8> {
		let mut full = base.to_vec();
		if !full.ends_with(b"/") {
			full.push(b'/');
		}
		full.extend_from_slice(rel);
		let mut out = Vec::with_capacity(full.len());
		for c in full {
			if c > b' ' && c != b'\\' && c < 0x7f {
				out.push(c);
			} else {
				out.extend(format!("\\{c:04o}").bytes());
			}
		}
		out
	}

	fn fuzz_name(r: &mut Rng, newlines: bool) -> Vec<u8> {
		const BITS: &[&[u8]] = &[
			b"a",
			b"file.txt",
			b" ",
			b"\t",
			b"\\",
			b"->",
			b" -> ",
			b"(+1)",
			b"\xff",
			b"caf\xc3\xa9",
			b"-",
			b"\\0040",
			b"F",
			b"\n",
		];
		let bits = if newlines {
			BITS
		} else {
			&BITS[..BITS.len() - 1]
		};
		let mut name = Vec::new();
		for i in 0..=r.below(3) {
			if i > 0 {
				name.push(b'/');
			}
			for _ in 0..=r.below(3) {
				name.extend_from_slice(r.pick(bits));
			}
		}
		name
	}

	fn rel(b: &[u8]) -> PathBuf {
		PathBuf::from(OsStr::from_bytes(b))
	}

	// What went bad is reported by its own line number and text.
	fn bad_lines_are_named(text: &[u8], p: &Parsed) {
		let lines: Vec<&[u8]> = text.split(|&c| c == b'\n').collect();
		for list in [&p.unusable, &p.outside] {
			assert!(list.windows(2).all(|w| w[0].0 < w[1].0));
			for (n, t) in list {
				assert_eq!(lines[n - 1], t.as_slice());
			}
		}
		assert!(
			p.unusable
				.iter()
				.all(|u| p.outside.iter().all(|o| o.0 != u.0))
		);
	}

	#[test]
	#[cfg_attr(miri, ignore = "safe code, and too few cases in the time to matter")]
	#[allow(clippy::too_many_lines, reason = "one generator, top to bottom")]
	fn fuzz_zfs_diff() {
		let _id = test_id("deeb7");
		let real: &[u8] = b"M\t/home/u/a\\0040b.txt\nR\t/home/u/old\t/home/u/new\n+\t/home/u/added\nM\t/other/x\n1700000000.5\tM\t/home/u/t\nM\tF\t/home/u/h\t(+1)\nR\t/home/u/old\\0040x -> /home/u/new\n-\t/home/u/saved\n+\t/home/u/saved\nX\t/home/u/a\n";
		crate::testutil::fuzz("zfs diff", |r| {
			let mut covered = 0;
			let mount: &[u8] = r.pick(&[b"/home/u".as_slice(), b"/mnt/my disk", b"/"]);
			let both = [mount, b"/real/u"];
			let bases = if mount == b"/" {
				&both[..1]
			} else {
				&both[..=r.below(2)]
			};
			let mounts: Vec<&Path> = bases
				.iter()
				.map(|b| Path::new(OsStr::from_bytes(b)))
				.collect();
			let (tabbed, timed, typed) = (r.one_in(2), r.one_in(3), r.one_in(2));
			let (mut text, mut want) = (Vec::new(), Parsed::default());
			let (mut removed, mut added, mut gone) =
				(BTreeSet::new(), BTreeSet::new(), Vec::<Vec<u8>>::new());
			for i in 0..r.below(16) {
				let line_no = i + 1;
				if r.one_in(10) {
					text.push(b'\n');
					continue;
				}
				let kind = *r.pick(b"MMR-+X");
				let ftype = if typed { *r.pick(b"FFFF/@") } else { b'F' };
				let name = if kind == b'+' && !gone.is_empty() && r.one_in(2) {
					r.pick(&gone).clone()
				} else {
					fuzz_name(r, true)
				};
				let outside = mount != b"/" && r.one_in(8);
				let base: &[u8] = if outside { b"/other" } else { r.pick(bases) };
				let mut line = Vec::new();
				if timed {
					line.extend(
						format!(
							"{:>10}.{:09}\t",
							r.below(2_000_000_000),
							r.below(1_000_000_000)
						)
						.bytes(),
					);
					covered |= 1;
				}
				line.push(kind);
				if typed {
					line.extend([b'\t', ftype]);
					covered |= 2;
				}
				line.push(b'\t');
				line.extend(zfs_path(base, &name));
				let new_name = fuzz_name(r, true);
				if kind == b'R' {
					line.extend_from_slice(if tabbed { b"\t" } else { b" -> " });
					line.extend(zfs_path(r.pick(bases), &new_name));
					covered |= if tabbed { 4 } else { 8 };
				}
				if kind == b'M' && r.one_in(4) {
					line.extend(format!("\t({}{})", r.pick(&['+', '-']), 1 + r.below(20)).bytes());
					covered |= 16;
				}
				text.extend_from_slice(&line);
				text.push(b'\n');
				if kind == b'X' {
					want.unusable.push((line_no, line));
					covered |= 32;
				} else if outside {
					want.outside.push((line_no, line));
					covered |= 64;
				} else if ftype != b'F' {
				} else if kind == b'M' {
					want.pairs.push(same_bytes(&name));
				} else if kind == b'R' {
					want.pairs.push(Pair {
						old: rel(&name),
						new: rel(&new_name),
						ino: None,
					});
				} else if kind == b'-' {
					removed.insert(rel(&name));
					gone.push(name);
				} else {
					added.insert(rel(&name));
				}
			}
			let replaced: Vec<_> = removed
				.intersection(&added)
				.cloned()
				.map(Pair::same)
				.collect();
			if !replaced.is_empty() {
				covered |= 128;
			}
			want.pairs.extend(replaced);
			assert_eq!(
				parse_zfs_diff(&text, &mounts),
				want,
				"{}",
				escape_name(&text)
			);
			let bad = crate::testutil::mutate(r, real);
			let p = parse_zfs_diff(&bad, &[Path::new("/home/u")]);
			bad_lines_are_named(&bad, &p);
			// Mount points are stripped, so no name comes out absolute. The
			// other sources are checked for that in run.
			assert!(
				p.pairs
					.iter()
					.all(|x| !x.old.has_root() && !x.new.has_root())
			);
			if !p.unusable.is_empty() {
				covered |= 256;
			}
			covered
		})
		.covers(0x1ff);
	}

	fn same_bytes(b: &[u8]) -> Pair {
		Pair::same(rel(b))
	}

	#[test]
	#[cfg_attr(miri, ignore = "safe code, and too few cases in the time to matter")]
	fn fuzz_find_new_and_list() {
		let _id = test_id("deeb8");
		let real: &[u8] = b"inode 257 file offset 0 len 4096 disk start 0 offset 0 gen 9 flags INLINE dir/a file\n\
inode 300 file offset 0 len 4096 disk start 12 offset 0 gen 9 flags COMPRESS|PREALLOC b\n\
inode x file offset 0 len 4096 disk start 12 offset 0 gen 9 flags NONE c\n\
transid marker was 12\n";
		crate::testutil::fuzz("find-new", |r| {
			let mut covered = 0;
			let (mut text, mut seen, mut unusable, mut names) =
				(Vec::new(), BTreeMap::new(), Vec::new(), Vec::new());
			for i in 0..r.below(16) {
				// find-new prints names raw, so one with a newline can't be told apart.
				let name = fuzz_name(r, false);
				let ino = r.next_u64() >> r.below(64);
				let flags = r.pick(&["NONE", "INLINE", "COMPRESS|PREALLOC"]);
				let good = format!(
					"inode {ino} file offset {} len 4096 disk start {} offset 0 gen {} flags {flags} ",
					r.below(1 << 30),
					r.below(1 << 30),
					r.below(99)
				);
				let mut line = good.clone().into_bytes();
				match r.below(8) {
					0 => {
						line = format!("transid marker was {ino}").into_bytes();
						covered |= 1;
					}
					1 => {
						// Each of these is one field off.
						let off = r.below(4);
						line = match off {
							0 => {
								good.replacen(&format!("inode {ino}"), &format!("inode -{ino}"), 1)
							}
							1 => good.replacen(" file ", " FILE ", 1),
							2 => good.replacen(" flags ", " flagz ", 1),
							_ => good.clone(),
						}
						.into_bytes();
						// The last has no name.
						if off < 3 {
							line.extend_from_slice(&name);
						}
						unusable.push((i + 1, line.clone()));
						covered |= 2;
					}
					_ => {
						line.extend_from_slice(&name);
						if seen.insert(rel(&name), ino).is_some() {
							covered |= 4;
						}
					}
				}
				text.extend_from_slice(&line);
				text.push(b'\n');
				names.push(line);
			}
			let pairs = seen
				.into_iter()
				.map(|(p, ino)| Pair {
					ino: Some(ino),
					..Pair::same(p)
				})
				.collect();
			assert_eq!(
				parse_find_new(&text),
				Parsed {
					pairs,
					unusable,
					outside: Vec::new()
				},
				"{}",
				escape_name(&text)
			);
			// Each line of a list is one name, as it stands.
			let want: Vec<Pair> = names
				.iter()
				.filter(|n| !n.is_empty())
				.map(|n| same_bytes(n))
				.collect();
			assert_eq!(parse_list(&text).pairs, want);
			let bad = crate::testutil::mutate(r, real);
			let p = parse_find_new(&bad);
			bad_lines_are_named(&bad, &p);
			assert!(p.pairs.windows(2).all(|w| w[0].new < w[1].new));
			assert!(p.pairs.iter().all(|x| x.ino.is_some() && x.old == x.new));
			let lines = bad.split(|&c| c == b'\n').filter(|l| !l.is_empty()).count();
			assert!(p.pairs.len() + p.unusable.len() <= lines);
			assert_eq!(parse_list(&bad).pairs.len(), lines);
			if !p.unusable.is_empty() {
				covered |= 8;
			}
			covered
		})
		.covers(0xf);
	}
}
