// Copyright © 2026 t00mietum (CryptogID: ปʬϝღถɔ4რఠΔթะ9ƾǝu)
// Licensed under GPL-2.0-only. No warranty.

// Compares the files a snapshot diff says changed. A real edit moves the
// modified time. A file whose bytes changed under the same size and time was
// changed by something that didn't go through the filesystem's write path,
// such as bad RAM under the page cache. `cp -p`, `rsync -t`, tar and `touch -r`
// also do it, so each hit still needs a look.

use std::collections::BTreeSet;
use std::ffi::OsString;
use std::fs::{self, File};
use std::io::{self, BufRead, BufReader, Read};
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};

pub enum Source {
	// `zfs diff -H` output, with the dataset's mount point to strip.
	ZfsDiff(PathBuf, PathBuf),
	// `btrfs subvolume find-new` output; paths are already relative.
	FindNew(PathBuf),
	// One relative path per line.
	List(PathBuf),
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
				.fold(0u32, |a, c| a * 8 + (c - b'0') as u32);
			out.push(v as u8);
			i += 5;
		} else {
			out.push(s[i]);
			i += 1;
		}
	}
	out
}

pub fn parse_zfs_diff(text: &[u8], mount: &Path) -> Vec<(PathBuf, PathBuf)> {
	let mut out = Vec::new();
	let rel = |p: &[u8]| -> Option<PathBuf> {
		let p = PathBuf::from(OsString::from_vec(zfs_unescape(p)));
		p.strip_prefix(mount).ok().map(|r| r.to_path_buf())
	};
	for line in text.split(|&c| c == b'\n') {
		let f: Vec<&[u8]> = line.split(|&c| c == b'\t').collect();
		// With -t the first field is a time; skip it if present.
		let f = if f.len() > 2 && f[0].iter().all(|c| c.is_ascii_digit() || *c == b'.') {
			&f[1..]
		} else {
			&f[..]
		};
		match f {
			[b"M", p, ..] => {
				if let Some(r) = rel(p) {
					out.push((r.clone(), r));
				}
			}
			[b"R", old, new, ..] => {
				if let (Some(o), Some(n)) = (rel(old), rel(new)) {
					out.push((o, n));
				}
			}
			_ => {}
		}
	}
	out
}

// "inode 257 file offset 0 len 4096 disk start 0 offset 0 gen 9 flags NONE name"
pub fn parse_find_new(text: &[u8]) -> Vec<(PathBuf, PathBuf)> {
	let mut seen = BTreeSet::new();
	for line in text.split(|&c| c == b'\n') {
		if !line.starts_with(b"inode ") {
			continue;
		}
		let mut rest = line;
		let mut ok = true;
		for _ in 0..16 {
			match rest.iter().position(|&c| c == b' ') {
				Some(i) => rest = &rest[i + 1..],
				None => {
					ok = false;
					break;
				}
			}
		}
		if ok && !rest.is_empty() {
			seen.insert(PathBuf::from(OsString::from_vec(rest.to_vec())));
		}
	}
	seen.into_iter().map(|p| (p.clone(), p)).collect()
}

pub struct Diff {
	pub differing: u64,
	pub runs: Vec<(u64, u64)>,
}

// Byte runs that differ. Runs a few bytes apart are merged, since a scribble
// rarely changes every byte it touches.
pub fn compare(a: &Path, b: &Path) -> io::Result<Diff> {
	let mut fa = File::open(a)?;
	let mut fb = File::open(b)?;
	let mut ba = vec![0u8; 1 << 20];
	let mut bb = vec![0u8; 1 << 20];
	let mut off: u64 = 0;
	let mut d = Diff {
		differing: 0,
		runs: Vec::new(),
	};
	let (la, lb) = (fa.metadata()?.len(), fb.metadata()?.len());
	while off < la.min(lb) {
		let na = read_full(&mut fa, &mut ba)?;
		let nb = read_full(&mut fb, &mut bb)?;
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

pub fn run(old: &Path, new: &Path, src: Source, show_all: bool) -> Result<i32, String> {
	let read = |p: &Path| fs::read(p).map_err(|e| format!("{}: {e}", p.display()));
	let pairs = match &src {
		Source::ZfsDiff(f, mount) => parse_zfs_diff(&read(f)?, mount),
		Source::FindNew(f) => parse_find_new(&read(f)?),
		Source::List(f) => {
			let r = BufReader::new(File::open(f).map_err(|e| format!("{}: {e}", f.display()))?);
			r.split(b'\n')
				.map_while(Result::ok)
				.filter(|l| !l.is_empty())
				.map(|l| {
					let p = PathBuf::from(OsString::from_vec(l));
					(p.clone(), p)
				})
				.collect()
		}
	};
	let (mut checked, mut flagged) = (0u64, 0u64);
	for (ro, rn) in &pairs {
		let (po, pn) = (old.join(ro), new.join(rn));
		let (Ok(mo), Ok(mn)) = (fs::symlink_metadata(&po), fs::symlink_metadata(&pn)) else {
			continue;
		};
		if !mo.file_type().is_file() || !mn.file_type().is_file() {
			continue;
		}
		checked += 1;
		let same_time = mo.mtime() == mn.mtime() && mo.mtime_nsec() == mn.mtime_nsec();
		let name = String::from_utf8_lossy(rn.as_os_str().as_bytes()).into_owned();
		if !same_time {
			if show_all {
				out!("edited\t{name}\tmtime moved");
			}
			continue;
		}
		if mo.len() != mn.len() {
			flagged += 1;
			out!(
				"size-changed-same-mtime\t{name}\t{} -> {} bytes",
				mo.len(),
				mn.len()
			);
			continue;
		}
		match compare(&po, &pn) {
			Ok(d) if d.differing == 0 => {
				if show_all {
					out!("same\t{name}\tmetadata only");
				}
			}
			Ok(d) => {
				flagged += 1;
				out!("content-changed-same-mtime\t{name}\t{}", describe(&d));
			}
			Err(e) => {
				flagged += 1;
				out!("read-error\t{name}\t{e}");
			}
		}
	}
	err!(
		"{} listed, {checked} regular files in both, {flagged} flagged",
		pairs.len()
	);
	Ok(if flagged > 0 { 4 } else { 0 })
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn zfs_diff_lines() {
		let text = b"M\t/home/u/a\\0040b.txt\nR\t/home/u/old\t/home/u/new\n+\t/home/u/added\nM\t/other/x\n1700000000.5\tM\t/home/u/t\n";
		let p = parse_zfs_diff(text, Path::new("/home/u"));
		assert_eq!(
			p,
			vec![
				(PathBuf::from("a b.txt"), PathBuf::from("a b.txt")),
				(PathBuf::from("old"), PathBuf::from("new")),
				(PathBuf::from("t"), PathBuf::from("t")),
			]
		);
	}

	#[test]
	fn find_new_lines() {
		let text = b"inode 257 file offset 0 len 4096 disk start 0 offset 0 gen 9 flags INLINE dir/a file\n\
inode 257 file offset 4096 len 4096 disk start 12 offset 0 gen 9 flags NONE dir/a file\n\
transid marker was 12\n";
		let p = parse_find_new(text);
		assert_eq!(
			p,
			vec![(PathBuf::from("dir/a file"), PathBuf::from("dir/a file"))]
		);
	}

	#[test]
	fn finds_a_scribble() {
		let dir = std::env::temp_dir().join(format!("test_tukfs-hash_cmp_{}", std::process::id()));
		fs::create_dir_all(&dir).unwrap();
		let a: Vec<u8> = (0..3_000_000u32).map(|i| (i * 7) as u8).collect();
		let mut b = a.clone();
		for x in &mut b[2_097_168..2_097_184] {
			*x ^= 0x5a;
		}
		b[2_097_170] = a[2_097_170];
		fs::write(dir.join("a"), &a).unwrap();
		fs::write(dir.join("b"), &b).unwrap();
		let d = compare(&dir.join("a"), &dir.join("b")).unwrap();
		assert_eq!(d.differing, 15);
		assert_eq!(d.runs, vec![(2_097_168, 16)]);
		assert!(describe(&d).contains("1 starting on a 16-byte boundary"));
		fs::write(dir.join("b"), &a[..100]).unwrap();
		let d = compare(&dir.join("a"), &dir.join("b")).unwrap();
		assert_eq!(d.differing, a.len() as u64 - 100);
		fs::remove_dir_all(dir).unwrap();
	}
}
