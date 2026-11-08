// Copyright © 2026 t00mietum (CryptogID: ปʬϝღถɔ4რఠΔթะ9ƾǝu)
// Licensed under GPL-2.0-only. No warranty.

// Compares the files a snapshot diff says changed. A real edit moves the
// modified time. A file whose bytes changed under the same size and time was
// changed by something that didn't go through the filesystem's write path,
// such as bad RAM under the page cache. `cp -p`, `rsync -t`, tar and `touch -r`
// also do it, so each hit still needs a look.

use std::collections::{BTreeSet, HashMap, btree_set};
use std::ffi::OsStr;
use std::fs::{self, File, Metadata};
use std::io::{self, BufRead, BufReader, Read};
use std::mem;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{DirEntryExt, MetadataExt};
use std::path::{Component, Path, PathBuf};

use crate::beneath::{self, Root};
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
			// Owned per side, since a rename gives 2 names.
			old: p.clone(),
			new: p,
			ino: None,
		}
	}
}

/// How a change list is laid out.
#[derive(Debug, Clone, Copy)]
enum Format<'a> {
	/// With the mount points to strip.
	ZfsDiff(&'a [&'a Path]),
	FindNew,
	List,
}

/// One thing a change list says.
#[derive(Debug, PartialEq)]
enum Entry {
	Pair(Pair),
	/// Line number and text.
	Unusable(usize, Vec<u8>),
	Outside(usize, Vec<u8>),
}

// zfs diff writes odd bytes as a backslash and 4 octal digits, \0040 for a
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

enum ZfsLine {
	Pair(Pair),
	Removed(PathBuf),
	Added(PathBuf),
	/// A folder, link or anything else that isn't a file.
	Skip,
	Unusable,
	Outside,
}

/// Takes -H or not, -t and -F. M and R lines are compared, and so is a path
/// with both a - and a + line, which is a file replaced by a new one, as rsync,
/// tar and atomic saves do.
fn zfs_diff_line(line: &[u8], mounts: &[&Path]) -> ZfsLine {
	let mut f: Vec<&[u8]> = line.split(|&c| c == b'\t').collect();
	if f.len() > 2 && is_time(f[0]) {
		f.remove(0);
	}
	let kind = f.remove(0);
	if !matches!(kind, b"M" | b"R" | b"-" | b"+") {
		return ZfsLine::Unusable;
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
		return ZfsLine::Unusable;
	};
	let mut rel: Vec<PathBuf> = names
		.iter()
		.map_while(|n| strip_mount(&zfs_unescape(n), mounts))
		.collect();
	if rel.len() != names.len() {
		return ZfsLine::Outside;
	}
	if ftype.is_some_and(|t| t != b'F') {
		return ZfsLine::Skip;
	}
	// The pops run left to right, so a rename's new name comes off first.
	match (kind, rel.pop(), rel.pop()) {
		(b"R", Some(new), Some(old)) => ZfsLine::Pair(Pair {
			old,
			new,
			ino: None,
		}),
		(b"M", Some(p), None) => ZfsLine::Pair(Pair::same(p)),
		(b"-", Some(p), None) => ZfsLine::Removed(p),
		(b"+", Some(p), None) => ZfsLine::Added(p),
		_ => ZfsLine::Unusable,
	}
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

/// Reads a change list a line at a time, so a long one takes no more memory
/// than a short one. Only zfs diff's - and + names are held to the end, since
/// the 2 lines of a replaced file can be far apart.
struct ChangeList<'a, R> {
	input: R,
	format: Format<'a>,
	line: Vec<u8>,
	line_no: usize,
	// find-new prints a line per extent, a file's all together.
	last_name: Vec<u8>,
	removed: BTreeSet<PathBuf>,
	added: BTreeSet<PathBuf>,
	replaced: Option<btree_set::IntoIter<PathBuf>>,
}

impl<'a, R: BufRead> ChangeList<'a, R> {
	fn new(input: R, format: Format<'a>) -> Self {
		ChangeList {
			input,
			format,
			line: Vec::new(),
			line_no: 0,
			last_name: Vec::new(),
			removed: BTreeSet::new(),
			added: BTreeSet::new(),
			replaced: None,
		}
	}

	fn entry(&mut self) -> Option<Entry> {
		let line = &self.line[..];
		let unusable = || Some(Entry::Unusable(self.line_no, line.to_vec()));
		match self.format {
			Format::ZfsDiff(mounts) => match zfs_diff_line(line, mounts) {
				ZfsLine::Pair(p) => Some(Entry::Pair(p)),
				ZfsLine::Removed(p) => {
					self.removed.insert(p);
					None
				}
				ZfsLine::Added(p) => {
					self.added.insert(p);
					None
				}
				ZfsLine::Skip => None,
				ZfsLine::Unusable => unusable(),
				ZfsLine::Outside => Some(Entry::Outside(self.line_no, line.to_vec())),
			},
			Format::FindNew => {
				if line.starts_with(b"transid marker was ") {
					return None;
				}
				let Some((ino, name)) = find_new_line(line) else {
					return unusable();
				};
				let bytes = name.as_os_str().as_bytes();
				if bytes == self.last_name {
					return None;
				}
				self.last_name.clear();
				self.last_name.extend_from_slice(bytes);
				Some(Entry::Pair(Pair {
					ino: Some(ino),
					..Pair::same(name)
				}))
			}
			Format::List => Some(Entry::Pair(Pair::same(PathBuf::from(OsStr::from_bytes(
				line,
			))))),
		}
	}
}

impl<R: BufRead> Iterator for ChangeList<'_, R> {
	type Item = io::Result<Entry>;

	fn next(&mut self) -> Option<Self::Item> {
		loop {
			if let Some(tail) = &mut self.replaced {
				return tail.next().map(|p| Ok(Entry::Pair(Pair::same(p))));
			}
			self.line.clear();
			match self.input.read_until(b'\n', &mut self.line) {
				Ok(0) => {
					let added = mem::take(&mut self.added);
					self.removed.retain(|p| added.contains(p));
					self.replaced = Some(mem::take(&mut self.removed).into_iter());
					continue;
				}
				Ok(_) => {}
				Err(e) => return Some(Err(e)),
			}
			self.line_no += 1;
			if self.line.last() == Some(&b'\n') {
				self.line.pop();
			}
			if self.line.is_empty() {
				continue;
			}
			if let Some(entry) = self.entry() {
				return Some(Ok(entry));
			}
		}
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

// A file whose old copy is looked for by inode once the list is read, with
// the one under its own name to fall back on.
struct Held {
	name: String,
	new_rel: PathBuf,
	new_md: Metadata,
	by_name: Option<(PathBuf, Metadata)>,
	by_inode: Option<(PathBuf, Metadata)>,
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

// What a name beneath a root is, with no symlink followed and no mount
// crossed on the way. None when nothing is there by that path.
fn stat_beneath(root: &Root, rel: &Path) -> io::Result<Option<Metadata>> {
	// A symlink at the name itself comes back as the link, which isn't a file.
	match root.open_at(rel, libc::O_PATH).and_then(|f| f.metadata()) {
		Ok(m) => Ok(Some(m)),
		Err(e) if beneath::moved(&e) => Ok(None),
		Err(e) => Err(e),
	}
}

// Old copies of renamed files, found by inode. Snapshots of one btrfs
// subvolume keep inode numbers, and the birth time rules out a number used
// again after a delete. One walk serves every file the pair needs.
fn find_by_inode(
	old: &Root,
	wanted: &mut HashMap<u64, usize>,
	held: &mut [Held],
	tally: &mut Tally,
) {
	let dev = old.dev;
	let mut dirs = vec![old.path.clone()];
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
			let Some(&at) = wanted.get(&ent.ino()) else {
				continue;
			};
			let p = ent.path();
			let Ok(md) = fs::symlink_metadata(&p) else {
				continue;
			};
			let same_birth = match (md.created(), held[at].new_md.created()) {
				(Ok(a), Ok(b)) => a == b,
				_ => true,
			};
			if md.is_file() && same_birth {
				held[at].by_inode = Some((old.rel(&p).to_path_buf(), md));
				wanted.remove(&ent.ino());
				if wanted.is_empty() {
					return;
				}
			}
		}
	}
}

// Compares each file as it's read off the list, holding back only the ones
// whose old copy has to be found by inode.
struct Checker<'a> {
	old: &'a Root,
	new: &'a Root,
	need_old: bool,
	need_new: bool,
	show_all: bool,
	tally: Tally,
	bufs: CompareBufs,
	held: Vec<Held>,
	wanted: HashMap<u64, usize>,
}

impl Checker<'_> {
	fn pair(&mut self, pair: &Pair) {
		let name = show_path(&pair.new);
		let new_md = match stat_beneath(self.new, &pair.new) {
			Ok(Some(m)) => m,
			Ok(None) => {
				self.tally.missing_new += 1;
				self.tally.missing(self.need_new, &name, "--new");
				return;
			}
			Err(e) => {
				self.tally.unchecked += 1;
				out!("stat-error\t{name}\t{e}");
				return;
			}
		};
		if !new_md.is_file() {
			return;
		}
		let by_name = match stat_beneath(self.old, &pair.old) {
			Ok(found) => found.map(|m| (pair.old.clone(), m)),
			Err(e) => {
				self.tally.unchecked += 1;
				out!("stat-error\t{name}\t{e}");
				return;
			}
		};
		// The old name can be some other file, as after `mv c a`.
		if let Some(ino) = pair.ino
			&& by_name.as_ref().is_none_or(|(_, m)| m.ino() != ino)
		{
			self.wanted.insert(ino, self.held.len());
			self.held.push(Held {
				name,
				new_rel: pair.new.clone(),
				new_md,
				by_name,
				by_inode: None,
			});
			return;
		}
		match by_name {
			Some((old_rel, mo)) => self.check(&name, (&old_rel, &mo), (&pair.new, &new_md)),
			None => self.tally.missing(self.need_old, &name, "--old"),
		}
	}

	fn finish(&mut self) {
		if !self.wanted.is_empty() {
			find_by_inode(self.old, &mut self.wanted, &mut self.held, &mut self.tally);
		}
		for h in mem::take(&mut self.held) {
			match h.by_inode.or(h.by_name) {
				Some((old_rel, mo)) => {
					self.check(&h.name, (&old_rel, &mo), (&h.new_rel, &h.new_md));
				}
				None => self.tally.missing(self.need_old, &h.name, "--old"),
			}
		}
	}

	fn check(
		&mut self,
		name: &str,
		(old_rel, mo): (&Path, &Metadata),
		(new_rel, mn): (&Path, &Metadata),
	) {
		if !mo.is_file() {
			return;
		}
		self.tally.checked += 1;
		let same_time = mo.mtime() == mn.mtime() && mo.mtime_nsec() == mn.mtime_nsec();
		if !same_time {
			if self.show_all {
				out!("edited\t{name}\tmtime moved");
			}
			return;
		}
		if mo.len() != mn.len() {
			self.tally.flagged += 1;
			out!(
				"size-changed-same-mtime\t{name}\t{} -> {} bytes",
				mo.len(),
				mn.len()
			);
			return;
		}
		let open_both = || -> io::Result<(File, File)> {
			Ok((self.old.open_read(old_rel)?, self.new.open_read(new_rel)?))
		};
		let (fa, fb) = match open_both() {
			Ok(f) => f,
			Err(e) => {
				self.tally.unchecked += 1;
				out!("open-error\t{name}\t{e}");
				return;
			}
		};
		match compare(fa, fb, &mut self.bufs) {
			Ok(d) if d.differing == 0 => {
				if self.show_all {
					out!("same\t{name}\tmetadata only");
				}
			}
			Ok(d) => {
				self.tally.flagged += 1;
				out!("content-changed-same-mtime\t{name}\t{}", describe(&d));
			}
			Err(e) => {
				self.tally.flagged += 1;
				out!("read-error\t{name}\t{e}");
			}
		}
	}
}

/// The `snapdiff` command.
pub fn run(old: &Path, new: &Path, src: &Source, show_all: bool) -> Result<i32, String> {
	// The folders themselves were named by a person and may be symlinks. Only
	// what's beneath them is held to no symlinks and no mounts, as scan does.
	let open_root = |dir: &Path| -> Result<Root, String> {
		let fail = |e: io::Error| format!("{}: {e}", show_path(dir));
		if !fs::metadata(dir).map_err(fail)?.is_dir() {
			return Err(format!("{}: not a folder", show_path(dir)));
		}
		fs::canonicalize(dir)
			.and_then(|real| Root::open(&real))
			.map_err(fail)
	};
	let (old, new) = (&open_root(old)?, &open_root(new)?);
	// Which side each listed file has to be on. zfs diff names files in both
	// snapshots, find-new files in the new one, and a list can name anything.
	let resolved;
	let mut mounts = Vec::new();
	let (list, format, need_old, need_new) = match src {
		Source::ZfsDiff(f, mount) => {
			// zfs prints the real mount point, and --mount may go through a symlink.
			resolved = fs::canonicalize(mount).ok().filter(|r| r != mount);
			mounts.push(mount.as_path());
			mounts.extend(resolved.as_deref());
			(f, Format::ZfsDiff(&mounts), true, true)
		}
		Source::FindNew(f) => (f, Format::FindNew, false, true),
		Source::List(f) => (f, Format::List, false, false),
	};
	let read_error = |e: io::Error| format!("{}: {e}", show_path(list));
	let input = BufReader::new(File::open(list).map_err(read_error)?);

	let mut checker = Checker {
		old,
		new,
		need_old,
		need_new,
		show_all,
		tally: Tally::default(),
		bufs: CompareBufs::default(),
		held: Vec::new(),
		wanted: HashMap::new(),
	};
	let (mut listed, mut unusable) = (0u64, 0u64);
	let mut outside: Option<(u64, usize, Vec<u8>)> = None;
	for entry in ChangeList::new(input, format) {
		match entry.map_err(read_error)? {
			Entry::Unusable(line_no, text) => {
				unusable += 1;
				if unusable <= 5 {
					err!("line {line_no} not understood: {}", escape_name(&text));
				}
			}
			// The run fails, so the rest is only read to count them.
			Entry::Outside(line_no, text) => outside.get_or_insert((0, line_no, text)).0 += 1,
			Entry::Pair(pair) => {
				listed += 1;
				if outside.is_some() {
					continue;
				}
				if let Some(p) = [&pair.old, &pair.new]
					.into_iter()
					.find(|p| !stays_inside(p))
				{
					return Err(format!(
						"{}: names have to be relative to --old and --new, with no ..",
						show_path(p)
					));
				}
				checker.pair(&pair);
			}
		}
	}
	if let Some((count, line_no, text)) = outside
		&& let Source::ZfsDiff(_, mount) = src
	{
		return Err(format!(
			"{}: {count} line(s) aren't under --mount {}, the first at line {line_no}: {}",
			show_path(list),
			show_path(mount),
			escape_name(&text)
		));
	}
	checker.finish();

	let t = &checker.tally;
	err!(
		"{listed} listed, {} regular files in both, {} flagged, {} missing, {} not checked, {unusable} lines not understood",
		t.checked,
		t.flagged,
		t.missing,
		t.unchecked,
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
	if t.unchecked > 0 || unusable > 0 || nothing {
		code |= 8;
	}
	Ok(code)
}

#[cfg(test)]
mod tests {
	use super::*;
	use crate::testutil::{Rng, scratch, test_id};

	#[derive(Debug, Default, PartialEq)]
	struct Parsed {
		pairs: Vec<Pair>,
		unusable: Vec<(usize, Vec<u8>)>,
		outside: Vec<(usize, Vec<u8>)>,
	}

	fn parse(text: &[u8], format: Format) -> Parsed {
		let mut parsed = Parsed::default();
		for entry in ChangeList::new(text, format) {
			match entry.unwrap() {
				Entry::Pair(p) => parsed.pairs.push(p),
				Entry::Unusable(n, t) => parsed.unusable.push((n, t)),
				Entry::Outside(n, t) => parsed.outside.push((n, t)),
			}
		}
		parsed
	}

	fn parse_zfs_diff(text: &[u8], mounts: &[&Path]) -> Parsed {
		parse(text, Format::ZfsDiff(mounts))
	}

	fn parse_find_new(text: &[u8]) -> Parsed {
		parse(text, Format::FindNew)
	}

	fn parse_list(text: &[u8]) -> Parsed {
		parse(text, Format::List)
	}

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
		// In the list's own order, which is by inode.
		assert_eq!(
			p.pairs,
			vec![
				Pair {
					ino: Some(257),
					..same("dir/a file")
				},
				Pair {
					ino: Some(300),
					..same("b")
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

	#[test]
	#[cfg_attr(miri, ignore = "Miri has no openat2")]
	fn the_inode_comes_before_the_name() {
		let _id = test_id("df0pp");
		let dir = scratch("snapdiff_mv");
		let (old, new) = (dir.join("old"), dir.join("new"));
		fs::create_dir(&old).unwrap();
		fs::create_dir(&new).unwrap();
		let when = std::time::UNIX_EPOCH + std::time::Duration::from_secs(1_600_000_000);
		let put = |p: &Path, bytes: &[u8]| {
			fs::write(p, bytes).unwrap();
			File::options()
				.write(true)
				.open(p)
				.unwrap()
				.set_modified(when)
				.unwrap();
		};
		// `mv c a`, with a link keeping c's inode. Old a has the same size and
		// time but other bytes, so a pairing by name flags it.
		put(&old.join("a"), b"aaaa");
		put(&old.join("c"), b"cccc");
		fs::hard_link(old.join("c"), new.join("a")).unwrap();
		// An atomic save gives a new inode, so the old copy is the one by name.
		put(&old.join("b"), b"bbbb");
		put(&new.join("b"), b"BBBB");
		let list = dir.join("find-new");
		let run_on = |name: &str| {
			let ino = fs::metadata(new.join(name)).unwrap().ino();
			fs::write(
				&list,
				format!(
					"inode {ino} file offset 0 len 4096 disk start 0 offset 0 gen 9 flags NONE {name}\n"
				),
			)
			.unwrap();
			run(&old, &new, &Source::FindNew(list.clone()), false).unwrap()
		};
		assert_eq!(run_on("a"), 0);
		assert_eq!(run_on("b"), 4);
	}

	#[test]
	#[cfg_attr(miri, ignore = "Miri has no openat2")]
	fn a_symlinked_folder_is_not_followed() {
		let _id = test_id("df0qt");
		let dir = scratch("snapdiff_link");
		let [old, new, elsewhere] = ["old", "new", "elsewhere"].map(|d| dir.join(d));
		for d in [&old, &new, &elsewhere, &new.join("in"), &old.join("out")] {
			fs::create_dir(d).unwrap();
		}
		let when = std::time::UNIX_EPOCH + std::time::Duration::from_secs(1_600_000_000);
		let put = |p: &Path, bytes: &[u8]| {
			fs::write(p, bytes).unwrap();
			File::options()
				.write(true)
				.open(p)
				.unwrap()
				.set_modified(when)
				.unwrap();
		};
		// Same size and time as the listed file, other bytes, so reaching it
		// flags the file.
		put(&elsewhere.join("f"), b"ffff");
		put(&new.join("in/f"), b"FFFF");
		put(&old.join("out/f"), b"FFFF");
		std::os::unix::fs::symlink(&elsewhere, old.join("in")).unwrap();
		std::os::unix::fs::symlink(&elsewhere, new.join("out")).unwrap();
		let list = dir.join("list");
		let run_on = |line: &str| {
			fs::write(&list, format!("{line}\n")).unwrap();
			run(&old, &new, &Source::List(list.clone()), true).unwrap()
		};
		// Not in --old, which a list allows.
		assert_eq!(run_on("in/f"), 0);
		// Not in --new, so nothing was compared.
		assert_eq!(run_on("out/f"), 8);
		// --old and --new through symlinks are still taken.
		std::os::unix::fs::symlink(&old, dir.join("old-link")).unwrap();
		fs::write(&list, "out/f\n").unwrap();
		let via = |o: &Path| run(o, &new, &Source::List(list.clone()), true).unwrap();
		assert_eq!(via(&dir.join("old-link")), 8);
		fs::remove_file(new.join("out")).unwrap();
		fs::create_dir(new.join("out")).unwrap();
		put(&new.join("out/f"), b"FFFF");
		assert_eq!(via(&dir.join("old-link")), 0);
		put(&new.join("out/f"), b"FFFf");
		assert_eq!(via(&dir.join("old-link")), 4);
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
			let (mut text, mut pairs, mut unusable, mut names) =
				(Vec::new(), Vec::new(), Vec::new(), Vec::new());
			let mut last: Option<Vec<u8>> = None;
			for i in 0..r.below(16) {
				// find-new prints names raw, so one with a newline can't be told apart.
				// A file in several extents gets a line for each, one after another.
				let name = match &last {
					Some(prev) if r.one_in(3) => prev.clone(),
					_ => fuzz_name(r, false),
				};
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
						if last.as_ref() == Some(&name) {
							covered |= 4;
						} else {
							pairs.push(Pair {
								ino: Some(ino),
								..same_bytes(&name)
							});
							last = Some(name);
						}
					}
				}
				text.extend_from_slice(&line);
				text.push(b'\n');
				names.push(line);
			}
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
			assert!(p.pairs.windows(2).all(|w| w[0].new != w[1].new));
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
