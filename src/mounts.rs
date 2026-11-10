// Copyright © 2026 t00mietum (CryptogID: ปʬϝღถɔ4რఠΔթะ9ƾǝu)
// Licensed under GPL-2.0-only. No warranty.

// Which disks are under which folder, so that no two workers read the same
// disk at once. 2 readers on one hard drive make it seek between them, and
// both go slower than one would alone.

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::ffi::OsString;
use std::fs;
use std::os::unix::ffi::OsStringExt;
use std::path::{Path, PathBuf};
use std::process::Command;

/// One line of the mount table.
#[derive(Debug, Clone)]
pub struct Mount {
	pub id: u64,
	pub parent: u64,
	/// Major and minor, as the table gives them.
	pub dev: String,
	/// The folder of the filesystem that's mounted, `/` for the whole of it.
	pub root: PathBuf,
	pub point: PathBuf,
	pub fstype: String,
	pub source: String,
}

// Mount points use octal escapes for space, tab, newline and backslash. Every
// other byte comes through raw, UTF-8 or not.
fn unescape(b: &[u8]) -> PathBuf {
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

/// Bytes, not text, since a mount point needn't be UTF-8 (2026102519331112).
pub fn parse_mountinfo(text: &[u8]) -> Vec<Mount> {
	let mut out = Vec::new();
	for line in text.split(|&c| c == b'\n') {
		let Some(at) = line.windows(3).position(|w| w == b" - ") else {
			continue;
		};
		let l: Vec<&[u8]> = line[..at].split(|&c| c == b' ').collect();
		let r: Vec<&[u8]> = line[at + 3..].split(|&c| c == b' ').collect();
		if l.len() < 5 || r.len() < 2 {
			continue;
		}
		let num = |b: &[u8]| std::str::from_utf8(b).ok()?.parse::<u64>().ok();
		let (Some(id), Some(parent)) = (num(l[0]), num(l[1])) else {
			continue;
		};
		out.push(Mount {
			id,
			parent,
			dev: String::from_utf8_lossy(l[2]).into_owned(),
			root: unescape(l[3]),
			point: unescape(l[4]),
			fstype: String::from_utf8_lossy(r[0]).into_owned(),
			source: String::from_utf8_lossy(r[1]).into_owned(),
		});
	}
	out
}

#[cfg(test)]
thread_local! {
	/// Reads past this many fail, so a test can lose the table partway.
	pub static READS_LEFT: std::cell::Cell<Option<u32>> = const { std::cell::Cell::new(None) };
}

/// The mount table, from `/proc/self/mountinfo`.
pub fn read_mounts() -> Result<Vec<Mount>, String> {
	#[cfg(test)]
	if READS_LEFT.with(|n| n.replace(n.get().map(|v| v.saturating_sub(1)))) == Some(0) {
		return Err("/proc/self/mountinfo: test fault".into());
	}
	let text =
		fs::read("/proc/self/mountinfo").map_err(|e| format!("/proc/self/mountinfo: {e}"))?;
	Ok(visible(parse_mountinfo(&text)))
}

/// Only the mounts a path can reach. One mounted over another, or over a folder
/// above it, hides it and all that's mounted on it (2026102814341407). Works
/// from the table alone, so kernels without `STATX_MNT_ID` get it too.
pub fn visible(mounts: Vec<Mount>) -> Vec<Mount> {
	let index: HashMap<u64, usize> = mounts.iter().enumerate().map(|(i, m)| (m.id, i)).collect();
	let parent_of = |i: usize| index.get(&mounts[i].parent).copied().filter(|&p| p != i);
	// Lookups by parent and point, so a table of thousands stays linear
	// (2026110715441800).
	let mut at: HashMap<(u64, &Path), Vec<usize>> = HashMap::new();
	for (i, m) in mounts.iter().enumerate() {
		at.entry((m.parent, m.point.as_path())).or_default().push(i);
	}
	let covered: Vec<bool> = (0..mounts.len())
		.map(|i| {
			at.get(&(mounts[i].id, mounts[i].point.as_path()))
				.is_some_and(|on| on.iter().any(|&k| k != i))
		})
		.collect();
	// Each step up drops one part, and none above the shallowest sibling can
	// match, so a chain of nested mounts doesn't look all the way up from each.
	let depth: Vec<usize> = mounts
		.iter()
		.map(|m| m.point.components().count())
		.collect();
	let mut top: HashMap<u64, usize> = HashMap::new();
	for (m, &d) in mounts.iter().zip(&depth) {
		top.entry(m.parent)
			.and_modify(|t| *t = d.min(*t))
			.or_insert(d);
	}
	// A sibling on a folder above it was mounted later, or it'd be the parent.
	let shadowed = |i: usize| {
		let m = &mounts[i];
		let steps = top
			.get(&m.parent)
			.map_or(0, |&t| depth[i].saturating_sub(t));
		m.point.ancestors().skip(1).take(steps).any(|above| {
			at.get(&(m.parent, above)).is_some_and(|on| {
				on.iter()
					.any(|&s| mounts[s].id != m.id && mounts[s].id != m.parent)
			})
		})
	};
	// Whether a path gets to a mount's point at all, covered or not.
	let mut reach: Vec<Option<bool>> = vec![None; mounts.len()];
	let mut on_chain = vec![false; mounts.len()];
	for start in 0..mounts.len() {
		let mut chain = Vec::new();
		let mut up = Some(start);
		// Up to one already known, the namespace's root, or a loop.
		while let Some(i) = up
			&& reach[i].is_none()
			&& !on_chain[i]
		{
			chain.push(i);
			on_chain[i] = true;
			up = parent_of(i);
		}
		while let Some(i) = chain.pop() {
			on_chain[i] = false;
			let through = parent_of(i).and_then(|p| {
				let r = reach[p]?;
				Some(r && (mounts[i].point == mounts[p].point || !covered[p]))
			});
			reach[i] = Some(through.unwrap_or(true) && !shadowed(i));
		}
	}
	let keep: Vec<bool> = (0..mounts.len())
		.map(|i| reach[i] == Some(true) && !covered[i])
		.collect();
	mounts
		.into_iter()
		.zip(keep)
		.filter_map(|(m, k)| k.then_some(m))
		.collect()
}

/// The mount a path is on, from a table already cut down by `visible`. Of 2
/// at one point, the later line is the one on top.
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

/// The path in `outer`'s tree that's `inner`'s folder of the same filesystem,
/// where a walk from `outer` gets to it and stops at no mount below it that a
/// walk from `inner` doesn't (2026102814341414). A bind mount of a folder
/// inside another root is the case. Only the table is read, so the caller
/// still checks the device and inode.
pub fn seen_from(mounts: &[Mount], outer: &Path, inner: &Path) -> Option<PathBuf> {
	let om = mount_for(mounts, outer)?;
	let im = mount_for(mounts, inner)?;
	if om.dev != im.dev {
		return None;
	}
	let place = |m: &Mount, p: &Path| p.strip_prefix(&m.point).ok().map(|r| m.root.join(r));
	let (op, ip) = (place(om, outer)?, place(im, inner)?);
	let at = outer.join(ip.strip_prefix(&op).ok()?);
	if mount_for(mounts, &at)?.id != om.id {
		return None;
	}
	let below = |base: &Path| {
		mounts
			.iter()
			.filter_map(|m| m.point.strip_prefix(base).ok())
			.filter(|r| !r.as_os_str().is_empty())
			.collect::<Vec<_>>()
	};
	let stops = below(inner);
	below(&at)
		.iter()
		.all(|r| stops.iter().any(|s| r.starts_with(s)))
		.then_some(at)
}

/// `path`'s folder in each mount of the same filesystem that shows a folder
/// above the one `path`'s mount shows, with that mount's point. A bind mount
/// of a subfolder is the case: the folders above it in its filesystem are
/// only seen there (2026111011092307). The caller checks the device and inode.
pub fn wider_views(mounts: &[Mount], path: &Path) -> Vec<(PathBuf, PathBuf)> {
	let Some(m) = mount_for(mounts, path) else {
		return Vec::new();
	};
	let Ok(rel) = path.strip_prefix(&m.point) else {
		return Vec::new();
	};
	let inner = m.root.join(rel);
	mounts
		.iter()
		.filter(|o| o.dev == m.dev && o.root != m.root && m.root.starts_with(&o.root))
		.filter_map(|o| {
			let at = o.point.join(inner.strip_prefix(&o.root).ok()?);
			// Not when a mount below its point hides the folder there.
			(mount_for(mounts, &at)?.id == o.id).then(|| (at, o.point.clone()))
		})
		.collect()
}

// btrfs gives every subvolume's top folder this inode.
const BTRFS_SUBVOL_INO: u64 = 256;

/// Whether `path` is the top of its filesystem, so the filesystem's used
/// space stands for what's under it. A btrfs subvolume's top counts, since
/// its used space is the whole filesystem's anyway. A bind mount of a folder
/// doesn't, wherever it's mounted (2026111011092313).
pub fn shows_whole(mounts: &[Mount], path: &Path, ino: u64) -> bool {
	mount_for(mounts, path).is_some_and(|m| {
		(path == m.point && m.root == Path::new("/"))
			|| (m.fstype == "btrfs" && ino == BTRFS_SUBVOL_INO)
	})
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
	fs::read(format!("/sys/block/{kname}/loop/backing_file"))
		.ok()
		.map(backing_path)
}

// The kernel prints the backing file's name raw, so it can be any bytes.
fn backing_path(mut s: Vec<u8>) -> PathBuf {
	while s.last() == Some(&b'\n') {
		s.pop();
	}
	if s.ends_with(b" (deleted)") {
		s.truncate(s.len() - b" (deleted)".len());
	}
	PathBuf::from(OsString::from_vec(s))
}

/// The disks a mount's data sits on.
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

/// Whether the kernel calls a disk rotational.
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

/// A root and the disks under it.
#[derive(Debug)]
pub struct RootDisks {
	pub root: PathBuf,
	pub disks: BTreeSet<String>,
}

/// Roots that share disks, and every disk under any of them.
#[derive(Debug)]
pub struct DiskGroup {
	pub disks: BTreeSet<String>,
	pub roots: Vec<PathBuf>,
}

/// Roots that share any disk end up in one group.
pub fn group_roots(roots: Vec<RootDisks>) -> Vec<DiskGroup> {
	let mut groups: Vec<DiskGroup> = Vec::new();
	for RootDisks { root, disks } in roots {
		let mut merged = DiskGroup {
			disks,
			roots: vec![root],
		};
		let mut keep = Vec::new();
		for g in groups.drain(..) {
			if g.disks.is_disjoint(&merged.disks) {
				keep.push(g);
			} else {
				merged.disks.extend(g.disks);
				let mut r = g.roots;
				r.extend(merged.roots);
				merged.roots = r;
			}
		}
		keep.push(merged);
		groups = keep;
	}
	groups
}

/// A group's name, from its disks.
pub fn group_name(disks: &BTreeSet<String>) -> String {
	disks
		.iter()
		.map(String::as_str)
		.collect::<Vec<_>>()
		.join("+")
}

/// Every mount point, for stopping a walk at the edge of its own filesystem.
pub fn mount_points(mounts: &[Mount]) -> BTreeMap<PathBuf, String> {
	mounts
		.iter()
		.map(|m| (m.point.clone(), m.fstype.clone()))
		.collect()
}

/// Linux's NTFS, APFS and HFS+ drivers aren't trusted to write. Those get read
/// and nothing more, no attributes and no database. A FUSE mount of a disk or
/// an image file with no type of its own is ntfs-3g, exfat-fuse or the like:
/// fuseblk for a block device, plain fuse for a file mounted by a user.
/// fuseblk with a subtype shows as `fuseblk.<name>`.
pub fn hands_off(m: &Mount) -> bool {
	let t = m.fstype.strip_prefix("fuse.").unwrap_or(&m.fstype);
	match t {
		"fuseblk" | "ntfs" | "ntfs3" | "ntfs-3g" | "lowntfs-3g" | "apfs" | "apfs-fuse" | "hfs"
		| "hfsplus" => true,
		_ if t.starts_with("fuseblk.") => true,
		"fuse" => m.source.starts_with('/'),
		_ => false,
	}
}

/// The filesystem type, where a path is on one that's never written to.
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
	use std::ffi::OsStr;
	use std::os::unix::ffi::OsStrExt;
	use std::time::Duration;

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
		let m = parse_mountinfo(SAMPLE.as_bytes());
		assert_eq!(m.len(), 5);
		assert_eq!(m[3].point, PathBuf::from("/mnt/my disk"));
		assert_eq!(m[1].fstype, "zfs");
		assert_eq!(m[1].source, "zf10/secure_home/u");
	}

	#[test]
	fn finds_deepest_mount() {
		let _id = test_id("ddwzw");
		let m = parse_mountinfo(SAMPLE.as_bytes());
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
			id: 1,
			parent: 0,
			dev: "8:1".into(),
			root: PathBuf::from("/"),
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
		let all = parse_mountinfo(
			format!(
				"{SAMPLE}70 22 8:49 / /mnt/win rw - ntfs3 /dev/sdd1 rw\n71 22 8:50 / /mnt/mac ro - apfs /dev/sdd2 ro\n"
			)
			.as_bytes(),
		);
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
		let rd = |root: &str, disks: &[&str]| RootDisks {
			root: PathBuf::from(root),
			disks: s(disks),
		};
		let roots = vec![
			rd("/a", &["nvme0n1", "nvme1n1"]),
			rd("/b", &["sda"]),
			rd("/c", &["nvme1n1"]),
			rd("/d", &["sdb", "sda"]),
		];
		let g = group_roots(roots);
		assert_eq!(g.len(), 2);
		assert_eq!(g[0].roots, vec![PathBuf::from("/a"), PathBuf::from("/c")]);
		assert_eq!(g[1].roots, vec![PathBuf::from("/b"), PathBuf::from("/d")]);
		assert_eq!(group_name(&g[1].disks), "sda+sdb");
	}

	#[test]
	fn fuseblk_with_a_subtype() {
		let _id = test_id("des5e");
		let all = parse_mountinfo(
			b"22 1 8:1 / / rw - ext4 /dev/sda1 rw\n\
			70 22 8:49 / /mnt/win rw - fuseblk.ntfs-3g /dev/sdd1 rw\n\
			71 22 8:50 / /mnt/stick rw - fuseblk.exfat /dev/sde1 rw\n",
		);
		assert_eq!(
			hands_off_at(&all, Path::new("/mnt/win/a")).as_deref(),
			Some("fuseblk.ntfs-3g")
		);
		assert_eq!(
			hands_off_at(&all, Path::new("/mnt/stick")).as_deref(),
			Some("fuseblk.exfat")
		);
		assert_eq!(hands_off_at(&all, Path::new("/home")), None);
	}

	// base on mnt, hid on mnt/sub, then vis over mnt.
	const OVER: &[u8] = b"22 1 8:1 / / rw - ext4 /dev/sda1 rw
30 22 8:1 /base /t/mnt rw - ext4 /dev/sda1 rw
31 30 8:1 /hid /t/mnt/sub rw - ext4 /dev/sda1 rw
32 30 8:1 /vis /t/mnt rw - ext4 /dev/sda1 rw
";

	#[test]
	fn mounted_over_point_is_walked() {
		let _id = test_id("des5f");
		let ids = |v: &[Mount]| v.iter().map(|m| m.id).collect::<Vec<_>>();
		let all = parse_mountinfo(OVER);
		assert_eq!(ids(&all), [22, 30, 31, 32]);
		let shown = visible(all);
		assert_eq!(ids(&shown), [22, 32]);
		let points = mount_points(&shown);
		assert!(!points.contains_key(Path::new("/t/mnt/sub")));
		assert!(points.contains_key(Path::new("/t/mnt")));
	}

	#[test]
	fn type_comes_from_the_mount_on_top() {
		let _id = test_id("des5g");
		for (top, want) in [("tmpfs", None), ("ntfs3", Some("ntfs3"))] {
			let text = String::from_utf8_lossy(OVER).replace(
				"/vis /t/mnt rw - ext4 /dev/sda1",
				&format!("/ /t/mnt rw - {top} /dev/sdd1"),
			);
			let all = visible(parse_mountinfo(text.as_bytes()));
			let under = Path::new("/t/mnt/sub/f");
			assert_eq!(mount_for(&all, under).map(|m| m.fstype.as_str()), Some(top));
			assert_eq!(hands_off_at(&all, under).as_deref(), want);
		}
	}

	#[test]
	fn hidden_by_a_later_mount_above() {
		let _id = test_id("des5h");
		let ids = |text: &[u8]| {
			visible(parse_mountinfo(text))
				.iter()
				.map(|m| m.id)
				.collect::<Vec<_>>()
		};
		// b on a/b, then a over the folder a: both hang off the root.
		assert_eq!(
			ids(b"1 1 0:1 / / rw - ext4 /dev/sda1 rw\n\
				2 1 0:2 / /a/b rw - ext4 /dev/sdb1 rw\n\
				3 2 0:3 / /a/b/c rw - ext4 /dev/sdc1 rw\n\
				4 1 0:4 / /a rw - ext4 /dev/sdd1 rw\n\
				5 1 0:5 / /ab rw - ext4 /dev/sde1 rw\n"),
			[1, 4, 5]
		);
		// A root over the namespace's own, a parent not in the table, and a
		// loop that can't happen but mustn't hang.
		assert_eq!(
			ids(b"1 0 0:1 / / rw - rootfs rootfs rw\n\
				2 1 0:2 / / rw - ext4 /dev/sda1 rw\n\
				3 2 0:3 / /x rw - ext4 /dev/sdb1 rw\n\
				8 9 0:8 / /y rw - ext4 /dev/sdc1 rw\n\
				9 8 0:9 / /y/z rw - ext4 /dev/sdd1 rw\n"),
			[2, 3, 8, 9]
		);
	}

	// The filter as 2026102814341407 wrote it, which checks every sibling of
	// each mount. Kept as the model the faster one has to match.
	fn visible_by_siblings(mounts: Vec<Mount>) -> Vec<Mount> {
		let mut kids: HashMap<u64, Vec<usize>> = HashMap::new();
		for (i, m) in mounts.iter().enumerate() {
			kids.entry(m.parent).or_default().push(i);
		}
		let index: HashMap<u64, usize> =
			mounts.iter().enumerate().map(|(i, m)| (m.id, i)).collect();
		let on = |id: u64| kids.get(&id).map_or(&[][..], Vec::as_slice);
		let parent_of = |i: usize| index.get(&mounts[i].parent).copied().filter(|&p| p != i);
		let covered = |i: usize| {
			on(mounts[i].id)
				.iter()
				.any(|&k| k != i && mounts[k].point == mounts[i].point)
		};
		let shadowed = |i: usize| {
			let m = &mounts[i];
			on(m.parent).iter().any(|&s| {
				let s = &mounts[s];
				s.id != m.id
					&& s.id != m.parent
					&& s.point != m.point
					&& m.point.starts_with(&s.point)
			})
		};
		let mut reach: Vec<Option<bool>> = vec![None; mounts.len()];
		for start in 0..mounts.len() {
			let mut chain = Vec::new();
			let mut at = Some(start);
			while let Some(i) = at
				&& reach[i].is_none()
				&& !chain.contains(&i)
			{
				chain.push(i);
				at = parent_of(i);
			}
			while let Some(i) = chain.pop() {
				let through = parent_of(i).and_then(|p| {
					let r = reach[p]?;
					Some(r && (mounts[i].point == mounts[p].point || !covered(p)))
				});
				reach[i] = Some(through.unwrap_or(true) && !shadowed(i));
			}
		}
		let keep: Vec<bool> = (0..mounts.len())
			.map(|i| reach[i] == Some(true) && !covered(i))
			.collect();
		mounts
			.into_iter()
			.zip(keep)
			.filter_map(|(m, k)| k.then_some(m))
			.collect()
	}

	fn mount(id: u64, parent: u64, point: &str) -> Mount {
		Mount {
			id,
			parent,
			dev: format!("0:{id}"),
			root: PathBuf::from("/"),
			point: PathBuf::from(point),
			fstype: "ext4".into(),
			source: "/dev/sda1".into(),
		}
	}

	#[test]
	#[cfg_attr(miri, ignore = "safe code, and too few cases in the time to matter")]
	fn fuzz_visible() {
		let _id = test_id("df1ny");
		let points = ["/", "/a", "/a/b", "/a/b/c", "/a/c", "/ab", "/b", "/b/a"];
		crate::testutil::fuzz("visible", 0b111, |r| {
			let n = 1 + r.below(14);
			let mut all = Vec::with_capacity(n);
			let mut covered = 0;
			for i in 1..=n as u64 {
				// Now and then a repeated ID, a parent not in the table, or one
				// that makes a loop.
				let id = if r.one_in(20) {
					1 + r.below(n) as u64
				} else {
					i
				};
				let parent = if r.one_in(10) {
					r.below(n + 3) as u64
				} else {
					1 + r.below(i as usize) as u64
				};
				if id != i || parent >= i {
					covered |= 4;
				}
				all.push(mount(id, parent, r.pick(&points)));
			}
			let ids = |v: &[Mount]| {
				v.iter()
					.map(|m| (m.id, m.parent, m.point.clone()))
					.collect::<Vec<_>>()
			};
			let want = visible_by_siblings(all.clone());
			let got = visible(all.clone());
			assert_eq!(ids(&got), ids(&want), "{:?}", ids(&all));
			covered | if want.len() < all.len() { 1 } else { 2 }
		})
		.covers();
	}

	#[test]
	#[cfg_attr(miri, ignore = "times thousands of mounts")]
	fn thousands_of_mounts_stay_fast() {
		let _id = test_id("df1nz");
		let flat: Vec<Mount> = std::iter::once(mount(1, 0, "/"))
			.chain((2..=8000).map(|i| mount(i, 1, &format!("/srv/c{i}"))))
			.collect();
		let mut deep = vec![mount(1, 0, "/")];
		let mut point = String::new();
		for i in 2..=1000 {
			point.push_str("/d");
			deep.push(mount(i, i - 1, &point));
		}
		// The sibling scan took 20 s or so on the flat one, in a release build.
		// The sanitizer runs are debug builds with an unoptimized std, about
		// 10 times slower, and deep took 1.4 s under ASan on a busy box.
		let limit = Duration::from_secs(if cfg!(debug_assertions) { 10 } else { 1 });
		for (name, table) in [("flat", flat), ("deep", deep)] {
			let n = table.len();
			let start = std::time::Instant::now();
			let kept = visible(table).len();
			let took = start.elapsed();
			assert_eq!(kept, n, "{name}");
			assert!(took < limit, "{name}: {took:?}");
		}
	}

	// tree/sub bound on bind and on tree/b, and another disk on tree/m.
	const BIND: &[u8] = b"1 0 8:1 / / rw - ext4 /dev/sda1 rw
2 1 8:1 /t/tree/sub /t/bind rw - ext4 /dev/sda1 rw
3 1 8:1 /t/tree/sub /t/tree/b rw - ext4 /dev/sda1 rw
4 1 8:2 / /t/tree/m rw - ext4 /dev/sdb1 rw
5 1 8:1 /u/x /t/ux rw - ext4 /dev/sda1 rw
6 1 8:3 /t/tree/sub /t/other rw - ext4 /dev/sdc1 rw
";

	#[test]
	fn bind_of_a_folder_inside_another_root() {
		let _id = test_id("df0qb");
		let seen = |extra: &str, outer: &str, inner: &str| {
			let text = [BIND, extra.as_bytes()].concat();
			let all = visible(parse_mountinfo(&text));
			seen_from(&all, Path::new(outer), Path::new(inner))
		};
		let sub = Some(PathBuf::from("/t/tree/sub"));
		assert_eq!(seen("", "/t/tree", "/t/bind"), sub);
		assert_eq!(seen("", "/t/tree", "/t/tree/b"), sub);
		assert_eq!(
			seen("", "/t", "/t/bind/d"),
			Some(PathBuf::from("/t/tree/sub/d"))
		);
		assert_eq!(
			seen("", "/t/tree", "/t/tree/a"),
			Some(PathBuf::from("/t/tree/a"))
		);
		assert_eq!(seen("", "/t/bind", "/t/tree"), None);
		assert_eq!(seen("", "/t/tree", "/t/ux"), None);
		assert_eq!(seen("", "/t/tree", "/t/other"), None);
		assert_eq!(seen("", "/t/tree", "/t/tree/m"), None);
		// The outer walk would stop where the inner one doesn't.
		let deep = "7 1 8:4 / /t/tree/sub/deep rw - ext4 /dev/sdd1 rw\n";
		assert_eq!(seen(deep, "/t/tree", "/t/bind"), None);
		let both = format!("{deep}8 2 8:4 / /t/bind/deep rw - ext4 /dev/sdd1 rw\n");
		assert_eq!(seen(&both, "/t/tree", "/t/bind"), sub);
		let over = "7 1 8:4 / /t/tree/sub rw - ext4 /dev/sdd1 rw\n";
		assert_eq!(seen(over, "/t/tree", "/t/bind"), None);
	}

	#[test]
	fn a_bind_mounts_folder_where_more_is_shown() {
		let _id = test_id("df4j5");
		let views = |extra: &str, path: &str| {
			let text = [BIND, extra.as_bytes()].concat();
			wider_views(&visible(parse_mountinfo(&text)), Path::new(path))
		};
		let pair = |at: &str, top: &str| (PathBuf::from(at), PathBuf::from(top));
		assert_eq!(views("", "/t/bind"), vec![pair("/t/tree/sub", "/")]);
		assert_eq!(views("", "/t/bind/d"), vec![pair("/t/tree/sub/d", "/")]);
		assert_eq!(views("", "/t/ux"), vec![pair("/u/x", "/")]);
		// The whole filesystem is already seen, or no other mount shows more.
		assert!(views("", "/t/tree/a").is_empty());
		assert!(views("", "/t/other").is_empty());
		assert!(views("", "/t/tree/m").is_empty());
		// A bind of a folder inside the bind is seen through both above it.
		let nested = "7 1 8:1 /t/tree/sub/d /t/nd rw - ext4 /dev/sda1 rw\n";
		assert_eq!(
			views(nested, "/t/nd"),
			vec![
				pair("/t/tree/sub/d", "/"),
				pair("/t/bind/d", "/t/bind"),
				pair("/t/tree/b/d", "/t/tree/b"),
			]
		);
		// Something mounted over the folder hides it there.
		let over = "7 1 8:4 / /t/tree/sub rw - ext4 /dev/sdd1 rw\n";
		assert!(views(over, "/t/bind").is_empty());
	}

	#[test]
	fn only_a_filesystems_top_shows_all_of_it() {
		let _id = test_id("df4j6");
		let btrfs = "7 1 0:27 /@home /home rw - btrfs /dev/sde1 rw\n\
			8 1 0:27 /@home/u/dir /t/bd rw - btrfs /dev/sde1 rw\n";
		let all = visible(parse_mountinfo(&[BIND, btrfs.as_bytes()].concat()));
		let whole = |path: &str, ino| shows_whole(&all, Path::new(path), ino);
		assert!(whole("/", 2));
		assert!(whole("/t/tree/m", 2));
		assert!(!whole("/t/tree/m/x", 9));
		assert!(!whole("/t/tree", 9));
		// Bind mounts of a folder, from this filesystem and from another.
		assert!(!whole("/t/bind", 9));
		assert!(!whole("/t/other", 9));
		// A btrfs subvolume, mounted or not, and a folder in one.
		assert!(whole("/home", 256));
		assert!(whole("/home/u", 256));
		assert!(!whole("/home/u", 300));
		assert!(!whole("/t/bd", 300));
	}

	#[test]
	fn mount_point_not_utf8() {
		let _id = test_id("deebw");
		let text = b"22 1 0:21 / / rw - ext4 /dev/sda1 rw\n\
			80 22 0:50 / /mnt/caf\xe9\\040x rw - tmpfs n\xffne rw\n";
		let m = parse_mountinfo(text);
		assert_eq!(m.len(), 2);
		assert_eq!(m[1].point.as_os_str().as_bytes(), b"/mnt/caf\xe9 x");
		assert_eq!(m[1].fstype, "tmpfs");
		assert_eq!(m[1].source, "n\u{fffd}ne");
		let under = Path::new(OsStr::from_bytes(b"/mnt/caf\xe9 x/a"));
		assert_eq!(
			mount_for(&m, under).map(|m| m.fstype.as_str()),
			Some("tmpfs")
		);
	}

	#[test]
	fn loop_backing_file_not_utf8() {
		let _id = test_id("deebx");
		for (raw, want) in [
			(&b"/x/caf\xe9.img\n"[..], &b"/x/caf\xe9.img"[..]),
			(b"/x/a b.img (deleted)\n", b"/x/a b.img"),
			(b"/x/\xff\n\n", b"/x/\xff"),
		] {
			assert_eq!(backing_path(raw.to_vec()).as_os_str().as_bytes(), want);
		}
	}

	const BITS: &[&[u8]] = &[
		b"a",
		b"bin",
		"é".as_bytes(),
		"日本".as_bytes(),
		b"\xe9",
		b"\xff\xfe",
		b" ",
		b"\t",
		b"\n",
		b"\\",
		b"\\040",
		b"-",
		b" - ",
		b"0",
	];

	// The kernel's own escape, which unescape undoes.
	fn mangle(s: &[u8]) -> Vec<u8> {
		let mut out = Vec::with_capacity(s.len());
		for &c in s {
			match c {
				b' ' => out.extend_from_slice(b"\\040"),
				b'\t' => out.extend_from_slice(b"\\011"),
				b'\n' => out.extend_from_slice(b"\\012"),
				b'\\' => out.extend_from_slice(b"\\134"),
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
		crate::testutil::fuzz("mountinfo", 0b1_1111, |r| {
			let mut covered = 0;
			let mut text = Vec::new();
			let mut want = Vec::new();
			for i in 0..r.below(12) {
				let mut point = Vec::new();
				for _ in 0..=r.below(4) {
					point.extend_from_slice(b"/");
					for _ in 0..=r.below(3) {
						point.extend_from_slice(r.pick(BITS));
					}
				}
				let fstype = *r.pick(&["ext4", "zfs", "btrfs", "fuse.sshfs", "ntfs3", "tmpfs"]);
				let source =
					*r.pick(&["/dev/sdc1", "zf10/a/b", "none", "UUID=1-2", "//host/share"]);
				let optional = [" shared:1", " master:3", " propagate_from:2", " unbindable"];
				let root = [&b"/"[..], r.pick(BITS)].concat();
				let mut left = format!("{} {} 0:{i} ", 20 + i, 1 + i).into_bytes();
				left.extend(mangle(&root));
				left.push(b' ');
				left.extend(mangle(&point));
				left.extend_from_slice(b" rw,noatime");
				for _ in 0..r.below(3) {
					left.extend_from_slice(r.pick(&optional).as_bytes());
					covered |= 1;
				}
				let right = format!("{fstype} {source} rw,xattr");
				// Junk has no " - ", or too few fields on a side, and is skipped.
				let shape = r.below(8);
				let (head, sep, tail): (Vec<u8>, &[u8], &str) = match shape {
					0 => (left, b" _ ", &right),
					1 => {
						let cut: Vec<&[u8]> = left.splitn(5, |&c| c == b' ').take(4).collect();
						(cut.join(&b' '), b" - ", &right)
					}
					2 => (left, b" - ", fstype),
					_ => {
						want.push((
							(20 + i as u64, 1 + i as u64),
							format!("0:{i}"),
							PathBuf::from(OsString::from_vec(root)),
							PathBuf::from(OsString::from_vec(point.clone())),
							fstype,
							source,
						));
						(left, b" - ", &right)
					}
				};
				covered |= if shape < 3 { 2 } else { 8 };
				text.extend(head);
				text.extend_from_slice(sep);
				text.extend_from_slice(tail.as_bytes());
				text.push(b'\n');
				if point.iter().any(|c| b"\n \\".contains(c)) {
					covered |= 4;
				}
				if std::str::from_utf8(&point).is_err() {
					covered |= 16;
				}
			}
			let got = parse_mountinfo(&text);
			let got: Vec<_> = got
				.iter()
				.map(|m| {
					(
						(m.id, m.parent),
						m.dev.clone(),
						m.root.clone(),
						m.point.clone(),
						m.fstype.as_str(),
						m.source.as_str(),
					)
				})
				.collect();
			assert_eq!(got, want, "{}", text.escape_ascii());
			// Real lines gone bad: no panic, and no field runs past a space.
			let bad = crate::testutil::mutate(r, &real);
			let got = parse_mountinfo(&bad);
			assert!(got.len() <= bad.split(|&c| c == b'\n').count());
			for m in &got {
				assert!(
					!m.fstype.contains([' ', '\n']) && !m.source.contains([' ', '\n']),
					"{m:?}"
				);
			}
			covered
		})
		.covers();
	}
}
