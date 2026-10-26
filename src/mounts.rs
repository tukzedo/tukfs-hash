// Copyright © 2026 t00mietum (CryptogID: ปʬϝღถɔ4რఠΔթะ9ƾǝu)
// Licensed under GPL-2.0-only. No warranty.

// Which disks are under which folder, so that no two workers read the same
// disk at once. Two readers on one hard drive make it seek between them, and
// both go slower than one would alone.

use std::collections::{BTreeMap, BTreeSet};
use std::ffi::OsString;
use std::fs;
use std::os::unix::ffi::OsStringExt;
use std::path::{Path, PathBuf};
use std::process::Command;

#[derive(Debug, Clone)]
pub struct Mount {
	pub point: PathBuf,
	pub fstype: String,
	pub source: String,
}

// Mount points use octal escapes for space, tab, newline and backslash.
fn unescape(s: &str) -> PathBuf {
	let b = s.as_bytes();
	let mut out = Vec::with_capacity(b.len());
	let mut i = 0;
	while i < b.len() {
		if b[i] == b'\\'
			&& i + 3 < b.len()
			&& b[i + 1..i + 4].iter().all(|c| (b'0'..=b'7').contains(c))
		{
			let v = u32::from(b[i + 1] - b'0') * 64
				+ u32::from(b[i + 2] - b'0') * 8
				+ u32::from(b[i + 3] - b'0');
			out.push(v as u8);
			i += 4;
		} else {
			out.push(b[i]);
			i += 1;
		}
	}
	PathBuf::from(OsString::from_vec(out))
}

pub fn parse_mountinfo(text: &str) -> Vec<Mount> {
	let mut out = Vec::new();
	for line in text.lines() {
		let Some((left, right)) = line.split_once(" - ") else {
			continue;
		};
		let l: Vec<&str> = left.split(' ').collect();
		let r: Vec<&str> = right.split(' ').collect();
		if l.len() < 5 || r.len() < 2 {
			continue;
		}
		out.push(Mount {
			point: unescape(l[4]),
			fstype: r[0].to_string(),
			source: r[1].to_string(),
		});
	}
	out
}

pub fn read_mounts() -> Result<Vec<Mount>, String> {
	let text = fs::read_to_string("/proc/self/mountinfo")
		.map_err(|e| format!("/proc/self/mountinfo: {e}"))?;
	Ok(parse_mountinfo(&text))
}

/// The mount a path is on. Later lines are mounted over earlier ones, so the
/// last of the longest matches is the one in effect.
pub fn mount_for<'a>(mounts: &'a [Mount], path: &Path) -> Option<&'a Mount> {
	let mut best: Option<&Mount> = None;
	for m in mounts {
		if path.starts_with(&m.point)
			&& best.is_none_or(|b| m.point.as_os_str().len() >= b.point.as_os_str().len())
		{
			best = Some(m);
		}
	}
	best
}

fn kname_of(dev: &str) -> Option<String> {
	let real = fs::canonicalize(dev).ok()?;
	Some(real.file_name()?.to_string_lossy().into_owned())
}

// Down through LUKS, LVM and partitions to whole disks.
fn base_disks(kname: &str, out: &mut BTreeSet<String>) {
	let sys = Path::new("/sys/class/block").join(kname);
	if let Ok(rd) = fs::read_dir(sys.join("slaves")) {
		let mut any = false;
		for e in rd.flatten() {
			any = true;
			base_disks(&e.file_name().to_string_lossy(), out);
		}
		if any {
			return;
		}
	}
	if sys.join("partition").exists()
		&& let Some(parent) = fs::canonicalize(&sys)
			.ok()
			.and_then(|p| p.parent().map(Path::to_path_buf))
		&& let Some(name) = parent.file_name()
	{
		out.insert(name.to_string_lossy().into_owned());
		return;
	}
	out.insert(kname.to_string());
}

fn zpool_disks(pool: &str, out: &mut BTreeSet<String>) -> Result<(), String> {
	let o = Command::new("zpool")
		.args(["list", "-v", "-H", "-P", pool])
		.output()
		.map_err(|e| format!("zpool: {e}"))?;
	if !o.status.success() {
		return Err(format!(
			"zpool list {pool}: {}",
			String::from_utf8_lossy(&o.stderr).trim()
		));
	}
	for line in String::from_utf8_lossy(&o.stdout).lines() {
		let f = line.trim_start().split('\t').next().unwrap_or("");
		if f.starts_with("/dev/")
			&& let Some(k) = kname_of(f)
		{
			base_disks(&k, out);
		}
	}
	Ok(())
}

// A btrfs can span several devices; /sys/fs/btrfs lists them all.
fn btrfs_disks(kname: &str, out: &mut BTreeSet<String>) {
	if let Ok(rd) = fs::read_dir("/sys/fs/btrfs") {
		for fsdir in rd.flatten() {
			let devs = fsdir.path().join("devices");
			if devs.join(kname).exists() {
				for d in fs::read_dir(devs).into_iter().flatten().flatten() {
					base_disks(&d.file_name().to_string_lossy(), out);
				}
				return;
			}
		}
	}
	base_disks(kname, out);
}

// A loop device reads a file, so the disks that matter are the ones under it.
fn loop_backing(kname: &str) -> Option<PathBuf> {
	let s = fs::read_to_string(format!("/sys/block/{kname}/loop/backing_file")).ok()?;
	let s = s.trim_end_matches('\n');
	Some(PathBuf::from(s.strip_suffix(" (deleted)").unwrap_or(s)))
}

pub fn disks_for(m: &Mount, mounts: &[Mount]) -> Result<BTreeSet<String>, String> {
	disks_under(m, mounts, 0)
}

fn disks_under(m: &Mount, mounts: &[Mount], depth: u32) -> Result<BTreeSet<String>, String> {
	let mut out = BTreeSet::new();
	match m.fstype.as_str() {
		"zfs" => {
			let pool = m.source.split('/').next().unwrap_or(&m.source);
			zpool_disks(pool, &mut out)?;
		}
		_ if m.source.starts_with("/dev/") => {
			let k = kname_of(&m.source).ok_or_else(|| format!("cannot resolve {}", m.source))?;
			if m.fstype == "btrfs" {
				btrfs_disks(&k, &mut out);
			} else {
				base_disks(&k, &mut out);
			}
		}
		_ => {
			return Err(format!(
				"{} is {} from {}, not a local disk",
				m.point.display(),
				m.fstype,
				m.source
			));
		}
	}
	if out.is_empty() {
		return Err(format!("no disks found under {}", m.point.display()));
	}
	let mut real = BTreeSet::new();
	for d in out {
		match loop_backing(&d) {
			Some(f) if depth < 4 => {
				let bm = mount_for(mounts, &f)
					.ok_or_else(|| format!("{d}: no mount found for {}", f.display()))?;
				real.extend(disks_under(bm, mounts, depth + 1)?);
			}
			_ => {
				real.insert(d);
			}
		}
	}
	Ok(real)
}

pub fn rotational(disk: &str) -> bool {
	fs::read_to_string(format!("/sys/block/{disk}/queue/rotational")).is_ok_and(|s| s.trim() == "1")
}

/// One worker on anything with a hard drive in it, since one is all it takes
/// to make the whole set wait on seeks. A few on flash.
pub fn default_threads(disks: &BTreeSet<String>) -> usize {
	if disks.iter().any(|d| rotational(d)) {
		1
	} else if disks.iter().all(|d| d.starts_with("nvme")) {
		4
	} else {
		2
	}
}

/// Roots that share any disk end up in one group.
pub fn group_roots(
	roots: Vec<(PathBuf, BTreeSet<String>)>,
) -> Vec<(BTreeSet<String>, Vec<PathBuf>)> {
	let mut groups: Vec<(BTreeSet<String>, Vec<PathBuf>)> = Vec::new();
	for (root, disks) in roots {
		let mut merged = (disks, vec![root]);
		let mut keep = Vec::new();
		for g in groups.drain(..) {
			if g.0.is_disjoint(&merged.0) {
				keep.push(g);
			} else {
				merged.0.extend(g.0);
				let mut r = g.1;
				r.extend(merged.1);
				merged.1 = r;
			}
		}
		keep.push(merged);
		groups = keep;
	}
	groups
}

pub fn group_name(disks: &BTreeSet<String>) -> String {
	disks
		.iter()
		.map(String::as_str)
		.collect::<Vec<_>>()
		.join("+")
}

/// Every mount point, for stopping a walk at the edge of its own filesystem.
pub fn mount_points(mounts: Vec<Mount>) -> BTreeMap<PathBuf, String> {
	mounts.into_iter().map(|m| (m.point, m.fstype)).collect()
}

/// Linux's NTFS, APFS and HFS+ drivers aren't trusted to write. Those get read
/// and nothing more, no attributes and no database. A FUSE mount of a disk or
/// an image file with no type of its own is ntfs-3g, exfat-fuse or the like:
/// fuseblk for a block device, plain fuse for a file mounted by a user.
pub fn hands_off(m: &Mount) -> bool {
	let t = m.fstype.strip_prefix("fuse.").unwrap_or(&m.fstype);
	match t {
		"fuseblk" | "ntfs" | "ntfs3" | "ntfs-3g" | "lowntfs-3g" | "apfs" | "apfs-fuse" | "hfs"
		| "hfsplus" => true,
		"fuse" => m.source.starts_with('/'),
		_ => false,
	}
}

pub fn hands_off_at(mounts: &[Mount], path: &Path) -> Option<String> {
	mount_for(mounts, path)
		.filter(|m| hands_off(m))
		.map(|m| match m.fstype.as_str() {
			"fuse" | "fuseblk" => format!("{} from {}", m.fstype, m.source),
			t => t.to_string(),
		})
}

#[cfg(test)]
mod tests {
	use super::*;
	use crate::testutil::test_id;

	const SAMPLE: &str = "\
22 1 0:21 /@ / rw,noatime shared:1 - btrfs /dev/mapper/luks-x rw
50 22 0:45 / /home/u rw shared:9 - zfs zf10/secure_home/u rw,xattr
51 50 0:46 / /home/u/.cache rw shared:9 - zfs zf10/secure_home/u/.cache rw,xattr
60 22 8:33 / /mnt/my\\040disk rw - ext4 /dev/sdc1 rw
61 22 8:33 / /mnt/ext rw - ext4 /dev/sdc1 rw
";

	#[test]
	fn parses_and_unescapes() {
		let _id = test_id("ddwzv");
		let m = parse_mountinfo(SAMPLE);
		assert_eq!(m.len(), 5);
		assert_eq!(m[3].point, PathBuf::from("/mnt/my disk"));
		assert_eq!(m[1].fstype, "zfs");
		assert_eq!(m[1].source, "zf10/secure_home/u");
	}

	#[test]
	fn finds_deepest_mount() {
		let _id = test_id("ddwzw");
		let m = parse_mountinfo(SAMPLE);
		assert_eq!(
			mount_for(&m, Path::new("/home/u/x")).unwrap().source,
			"zf10/secure_home/u"
		);
		assert_eq!(
			mount_for(&m, Path::new("/home/u/.cache/y")).unwrap().source,
			"zf10/secure_home/u/.cache"
		);
		assert_eq!(
			mount_for(&m, Path::new("/home/user2")).unwrap().fstype,
			"btrfs"
		);
	}

	#[test]
	fn no_writes_on_ntfs_or_mac_disks() {
		let _id = test_id("ddyar");
		let m = |t: &str, src: &str| Mount {
			point: PathBuf::from("/m"),
			fstype: t.into(),
			source: src.into(),
		};
		for t in [
			"ntfs",
			"ntfs3",
			"fuseblk",
			"fuse.ntfs-3g",
			"fuse.lowntfs-3g",
			"apfs",
			"fuse.apfs-fuse",
			"hfs",
			"hfsplus",
		] {
			assert!(hands_off(&m(t, "/dev/sdd1")), "{t}");
		}
		// What ntfs-3g shows when a user mounts an image file.
		assert!(hands_off(&m("fuse", "/x/ntfs.img")));
		for t in [
			"zfs",
			"btrfs",
			"ext4",
			"xfs",
			"vfat",
			"exfat",
			"tmpfs",
			"fuse.sshfs",
		] {
			assert!(!hands_off(&m(t, "/dev/sdd1")), "{t}");
		}
		assert!(!hands_off(&m("fuse", "portal")));
		let all = parse_mountinfo(&format!(
			"{SAMPLE}70 22 8:49 / /mnt/win rw - ntfs3 /dev/sdd1 rw\n71 22 8:50 / /mnt/mac ro - apfs /dev/sdd2 ro\n"
		));
		assert_eq!(
			hands_off_at(&all, Path::new("/mnt/win/a/b")).as_deref(),
			Some("ntfs3")
		);
		assert_eq!(
			hands_off_at(&all, Path::new("/mnt/mac")).as_deref(),
			Some("apfs")
		);
		assert_eq!(hands_off_at(&all, Path::new("/mnt/ext/x")), None);
	}

	#[test]
	fn groups_share_disks() {
		let _id = test_id("ddwzx");
		let s = |v: &[&str]| v.iter().map(ToString::to_string).collect::<BTreeSet<_>>();
		let roots = vec![
			(PathBuf::from("/a"), s(&["nvme0n1", "nvme1n1"])),
			(PathBuf::from("/b"), s(&["sda"])),
			(PathBuf::from("/c"), s(&["nvme1n1"])),
			(PathBuf::from("/d"), s(&["sdb", "sda"])),
		];
		let g = group_roots(roots);
		assert_eq!(g.len(), 2);
		assert_eq!(g[0].1, vec![PathBuf::from("/a"), PathBuf::from("/c")]);
		assert_eq!(g[1].1, vec![PathBuf::from("/b"), PathBuf::from("/d")]);
		assert_eq!(group_name(&g[1].0), "sda+sdb");
	}

	const BITS: &[&str] = &[
		"a", "bin", "é", "日本", " ", "\t", "\n", "\\", "\\040", "-", " - ", "0",
	];

	// The kernel's own escape, which unescape undoes.
	fn mangle(s: &str) -> String {
		let mut out = String::with_capacity(s.len());
		for c in s.chars() {
			match c {
				' ' => out.push_str("\\040"),
				'\t' => out.push_str("\\011"),
				'\n' => out.push_str("\\012"),
				'\\' => out.push_str("\\134"),
				_ => out.push(c),
			}
		}
		out
	}

	#[test]
	#[cfg_attr(miri, ignore = "safe code, and too few cases in the time to matter")]
	fn fuzz_mountinfo() {
		let _id = test_id("deeb6");
		let real = fs::read("/proc/self/mountinfo").unwrap_or_default();
		crate::testutil::fuzz("mountinfo", |r| {
			let mut covered = 0;
			let mut text = String::new();
			let mut want = Vec::new();
			for i in 0..r.below(12) {
				let mut point = String::new();
				for _ in 0..=r.below(4) {
					point.push('/');
					for _ in 0..=r.below(3) {
						point.push_str(r.pick(BITS));
					}
				}
				let fstype = *r.pick(&["ext4", "zfs", "btrfs", "fuse.sshfs", "ntfs3", "tmpfs"]);
				let source =
					*r.pick(&["/dev/sdc1", "zf10/a/b", "none", "UUID=1-2", "//host/share"]);
				let optional = [" shared:1", " master:3", " propagate_from:2", " unbindable"];
				let mut left = format!(
					"{} {} 0:{i} /{} {} rw,noatime",
					20 + i,
					1 + i,
					mangle(r.pick(BITS)),
					mangle(&point)
				);
				for _ in 0..r.below(3) {
					left.push_str(r.pick(&optional));
					covered |= 1;
				}
				let right = format!("{fstype} {source} rw,xattr");
				// Junk has no " - ", or too few fields on a side, and is skipped.
				let shape = r.below(8);
				let line = match shape {
					0 => format!("{left} _ {right}"),
					1 => {
						let cut: Vec<&str> = left.splitn(5, ' ').take(4).collect();
						format!("{} - {right}", cut.join(" "))
					}
					2 => format!("{left} - {fstype}"),
					_ => {
						want.push((PathBuf::from(&point), fstype, source));
						format!("{left} - {right}")
					}
				};
				covered |= if shape < 3 { 2 } else { 8 };
				text.push_str(&line);
				text.push('\n');
				if point.contains(['\n', ' ', '\\']) {
					covered |= 4;
				}
			}
			let got = parse_mountinfo(&text);
			let got: Vec<_> = got
				.iter()
				.map(|m| (m.point.clone(), m.fstype.as_str(), m.source.as_str()))
				.collect();
			assert_eq!(got, want, "{text:?}");
			// Real lines gone bad: no panic, and no field runs past a space.
			let bad = String::from_utf8_lossy(&crate::testutil::mutate(r, &real)).into_owned();
			let got = parse_mountinfo(&bad);
			assert!(got.len() <= bad.lines().count());
			for m in &got {
				assert!(
					!m.fstype.contains([' ', '\n']) && !m.source.contains([' ', '\n']),
					"{m:?}"
				);
			}
			covered
		})
		.covers(0b1111);
	}
}
