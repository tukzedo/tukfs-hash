// Copyright © 2026 t00mietum (CryptogID: ปʬϝღถɔ4რఠΔթะ9ƾǝu)
// Licensed under GPL-2.0-only. No warranty.

// The checksum left on a file. The first three names and their formats are
// the ones nemo-anywhere reads and writes, so either program can trust what
// the other left. The date and inode are ours; nemo-anywhere ignores them.

use crate::util::{b64u_decode, b64u_encode, hex, trim_value, unhex};
use std::ffi::CStr;
use std::io;
use std::os::fd::RawFd;

/// The blake3 set this writes, matching nemo-anywhere's names.
pub const B3_DIGEST: &CStr = c"user.blake3.b64u";
pub const B3_BYTES: &CStr = c"user.blake3.bytes";
pub const B3_MTIME: &CStr = c"user.blake3.mtime";
pub const B3_DATE: &CStr = c"user.blake3.date";
/// "dev:ino:digest". The digest ties it to what was read, so a digest written
/// later by something else doesn't inherit our date. See design.md, Skipping.
pub const B3_INODE: &CStr = c"user.blake3.inode";

/// Left by `rmlint --xattr`. The checksum is hex, and the time is seconds as a
/// float, so it only matches to within float rounding.
pub const RM_B2B_CKSUM: &CStr = c"user.rmlint.blake2b.cksum";
pub const RM_B2B_MTIME: &CStr = c"user.rmlint.blake2b.mtime";

/// An attribute's value. `None` where it's missing or not supported.
pub fn fget(fd: RawFd, name: &CStr) -> io::Result<Option<Vec<u8>>> {
	let mut buf = vec![0u8; 256];
	loop {
		// SAFETY: buf has buf.len() bytes of room, and name is NUL-terminated.
		let n = unsafe { libc::fgetxattr(fd, name.as_ptr(), buf.as_mut_ptr().cast(), buf.len()) };
		if n >= 0 {
			buf.truncate(n as usize);
			return Ok(Some(buf));
		}
		let err = io::Error::last_os_error();
		match err.raw_os_error() {
			Some(libc::ENODATA | libc::ENOTSUP) => return Ok(None),
			Some(libc::ERANGE) => {
				// SAFETY: a null buffer of size 0 only asks for the length.
				let need = unsafe { libc::fgetxattr(fd, name.as_ptr(), std::ptr::null_mut(), 0) };
				if need < 0 {
					return Err(io::Error::last_os_error());
				}
				buf.resize(need as usize + 16, 0);
			}
			_ => return Err(err),
		}
	}
}

/// Sets an attribute.
pub fn fset(fd: RawFd, name: &CStr, value: &[u8]) -> io::Result<()> {
	// SAFETY: value is value.len() bytes, and name is NUL-terminated.
	let r = unsafe { libc::fsetxattr(fd, name.as_ptr(), value.as_ptr().cast(), value.len(), 0) };
	if r == 0 {
		Ok(())
	} else {
		Err(io::Error::last_os_error())
	}
}

/// A name that isn't there is already gone.
pub fn fremove(fd: RawFd, name: &CStr) -> io::Result<()> {
	// SAFETY: name is NUL-terminated.
	if unsafe { libc::fremovexattr(fd, name.as_ptr()) } == 0 {
		return Ok(());
	}
	let err = io::Error::last_os_error();
	match err.raw_os_error() {
		Some(libc::ENODATA) => Ok(()),
		_ => Err(err),
	}
}

// C's "%.17g", which is what rmlint's time goes through (glib's
// g_ascii_dtostr).
fn g17(v: f64) -> String {
	let sci = format!("{v:.16e}");
	let (mant, exp) = sci.split_once('e').unwrap_or((&sci, "0"));
	let exp: i32 = exp.parse().unwrap_or(0);
	let trim = |s: &str| {
		if s.contains('.') {
			s.trim_end_matches('0').trim_end_matches('.').to_string()
		} else {
			s.to_string()
		}
	};
	if (-4..17).contains(&exp) {
		trim(&format!("{v:.*}", (16 - exp) as usize))
	} else {
		let sign = if exp < 0 { '-' } else { '+' };
		format!("{}e{sign}{:02}", trim(mant), exp.abs())
	}
}

/// Byte for byte what `rmlint --xattr` writes: hex ending in a NUL, then the
/// time. The time goes second so a write that stops part way isn't trusted.
pub fn write_rmlint(fd: RawFd, b2b: &[u8; 64], mtime_s: f64) -> io::Result<()> {
	let mut sum = hex(b2b).into_bytes();
	sum.push(0);
	fset(fd, RM_B2B_CKSUM, &sum)?;
	fset(fd, RM_B2B_MTIME, g17(mtime_s).as_bytes())
}

/// For a file taken as good with a different blake2b. rmlint reads it again
/// once these are gone. The checksum goes first, since it's useless alone.
pub fn remove_rmlint(fd: RawFd) -> io::Result<()> {
	fremove(fd, RM_B2B_CKSUM)?;
	fremove(fd, RM_B2B_MTIME)
}

/// The checksum attributes a file has.
#[derive(Default, Debug, Clone)]
pub struct OnFile {
	pub b3: Option<[u8; 32]>,
	pub b3_bytes: Option<i64>,
	pub b3_mtime_us: Option<i64>,
	pub b3_date_us: Option<i64>,
	pub b3_inode: Option<(u64, u64, [u8; 32])>,
	pub b2b: Option<[u8; 64]>,
	pub b2b_mtime_s: Option<f64>,
}

fn text_of(v: Option<Vec<u8>>) -> Option<Vec<u8>> {
	v.map(|v| trim_value(&v).to_vec())
}

fn int_of(v: Option<Vec<u8>>) -> Option<i64> {
	std::str::from_utf8(&text_of(v)?).ok()?.parse().ok()
}

fn inode_of(v: Option<Vec<u8>>) -> Option<(u64, u64, [u8; 32])> {
	let text = String::from_utf8(text_of(v)?).ok()?;
	let mut it = text.splitn(3, ':');
	let dev = it.next()?.parse().ok()?;
	let ino = it.next()?.parse().ok()?;
	let digest = b64u_decode(it.next()?.as_bytes())?.try_into().ok()?;
	Some((dev, ino, digest))
}

fn inode_text(dev: u64, ino: u64, digest: &[u8; 32]) -> String {
	format!("{dev}:{ino}:{}", b64u_encode(digest))
}

impl OnFile {
	/// A missing or unreadable attribute reads as absent. Nothing here is
	/// trusted until its size and time are checked against the file.
	pub fn read(fd: RawFd) -> OnFile {
		let get = |n| fget(fd, n).ok().flatten();
		let b3 = text_of(get(B3_DIGEST))
			.and_then(|t| b64u_decode(&t))
			.and_then(|d| d.try_into().ok());
		let mut of = OnFile {
			b3,
			..Default::default()
		};
		if of.b3.is_some() {
			of.b3_bytes = int_of(get(B3_BYTES));
			of.b3_mtime_us = int_of(get(B3_MTIME));
			of.b3_date_us = int_of(get(B3_DATE));
			of.b3_inode = inode_of(get(B3_INODE));
		}
		of.b2b = text_of(get(RM_B2B_CKSUM))
			.and_then(|t| unhex(&t))
			.and_then(|d| d.try_into().ok());
		if of.b2b.is_some() {
			of.b2b_mtime_s = text_of(get(RM_B2B_MTIME))
				.and_then(|t| String::from_utf8(t).ok())
				.and_then(|s| s.parse().ok());
		}
		of
	}

	/// The blake3 on the file still describes it.
	pub fn b3_current(&self, bytes: i64, mtime_us: i64) -> Option<[u8; 32]> {
		(self.b3_bytes == Some(bytes) && self.b3_mtime_us == Some(mtime_us))
			.then_some(self.b3)
			.flatten()
	}

	/// Good enough to skip reading: current, read by us from this very inode,
	/// and dated between the cutoff and now. A copy made with `cp -a` or
	/// `rsync -aX` brings the set along but is on another inode. Returns
	/// the digest and its date.
	pub fn b3_fresh(
		&self,
		bytes: i64,
		mtime_us: i64,
		dev: u64,
		ino: u64,
		cutoff_us: i64,
		now_us: i64,
	) -> Option<([u8; 32], i64)> {
		let digest = self.b3_current(bytes, mtime_us)?;
		let date = self.b3_date_us?;
		(self.b3_inode == Some((dev, ino, digest)) && (cutoff_us..=now_us).contains(&date))
			.then_some((digest, date))
	}

	/// rmlint keeps no size, so the time is all there is to go on.
	pub fn b2b_current(&self, mtime_s: f64) -> Option<[u8; 64]> {
		let stored = self.b2b_mtime_s?;
		((stored - mtime_s).abs() < 1e-5)
			.then_some(self.b2b)
			.flatten()
	}
}

/// What `write_b3` writes: the whole set, or only the date on a set that
/// still matches.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum B3Write {
	All,
	DateOnly,
}

/// The time goes after the checksum, since a reader needs the time to match,
/// and the inode goes last, since a skip needs its digest to match. A write
/// that stops part way leaves an old value next to the new checksum and gets
/// thrown away.
pub fn write_b3(
	fd: RawFd,
	digest: &[u8; 32],
	bytes: i64,
	mtime_us: i64,
	date_us: i64,
	(dev, ino): (u64, u64),
	what: B3Write,
) -> io::Result<()> {
	match what {
		B3Write::All => {
			fset(fd, B3_DIGEST, b64u_encode(digest).as_bytes())?;
			fset(fd, B3_BYTES, bytes.to_string().as_bytes())?;
			fset(fd, B3_DATE, date_us.to_string().as_bytes())?;
			fset(fd, B3_MTIME, mtime_us.to_string().as_bytes())?;
		}
		B3Write::DateOnly => fset(fd, B3_DATE, date_us.to_string().as_bytes())?,
	}
	fset(fd, B3_INODE, inode_text(dev, ino, digest).as_bytes())?;
	Ok(())
}

#[cfg(test)]
#[allow(clippy::unreadable_literal, reason = "as rmlint and stat print them")]
mod tests {
	use super::*;
	use crate::testutil::{fuzz, mutate, scratch, test_id};

	#[test]
	fn rmlint_time_tolerance() {
		let _id = test_id("ddx08");
		let of = OnFile {
			b2b: Some([7; 64]),
			b2b_mtime_s: Some(1692238421.9263258),
			..Default::default()
		};
		// st_mtime 1692238421.926325000, as found on a real file.
		assert!(of.b2b_current(1692238421.926325).is_some());
		assert!(of.b2b_current(1692238422.926325).is_none());
	}

	// Expected values are from rmlint 2.10.3 and C's printf.
	#[test]
	fn rmlint_time_text() {
		let _id = test_id("de5g0");
		let t = |s: i64, ns: i64| g17(s as f64 + ns as f64 / 1e9);
		assert_eq!(t(1620310089, 123456789), "1620310089.1234567");
		assert_eq!(t(1704096000, 351000100), "1704096000.3510001");
		assert_eq!(t(1792436463, 762448303), "1792436463.7624483");
		assert_eq!(t(915177600, 0), "915177600");
		assert_eq!(t(5, 500000000), "5.5");
		assert_eq!(t(0, 0), "0");
		assert_eq!(t(-1, 0), "-1");
		assert_eq!(g17(1e20), "1e+20");
		assert_eq!(g17(1.5e-5), "1.5e-05");
		assert_eq!(g17(0.0001), "0.0001");
		assert_eq!(g17(123456789012345678.0), "1.2345678901234568e+17");
	}

	#[test]
	#[cfg_attr(miri, ignore = "Miri can't set xattrs")]
	fn rmlint_set_reads_back() {
		let _id = test_id("de5g1");
		let d = scratch("xattr_rmset");
		let p = d.join("f");
		std::fs::write(&p, "x").unwrap();
		let f = std::fs::File::open(&p).unwrap();
		let fd = std::os::fd::AsRawFd::as_raw_fd(&f);
		let mt = 1620310089.0 + 123456789.0 / 1e9;
		if write_rmlint(fd, &[0xab; 64], mt).is_err() {
			eprintln!("no user xattrs here; skipped");
			return;
		}
		let raw = fget(fd, RM_B2B_CKSUM).unwrap().unwrap();
		assert_eq!(raw.len(), 129);
		assert_eq!(raw.last(), Some(&0));
		assert_eq!(OnFile::read(fd).b2b_current(mt), Some([0xab; 64]));
	}

	#[test]
	fn b3_needs_size_and_time() {
		let _id = test_id("ddx09");
		let of = OnFile {
			b3: Some([1; 32]),
			b3_bytes: Some(10),
			b3_mtime_us: Some(5),
			..Default::default()
		};
		assert!(of.b3_current(10, 5).is_some());
		assert!(of.b3_current(11, 5).is_none());
		assert!(of.b3_current(10, 6).is_none());
	}

	#[test]
	fn b3_fresh_needs_our_inode_and_a_sane_date() {
		let _id = test_id("ddy59");
		let of = OnFile {
			b3: Some([1; 32]),
			b3_bytes: Some(10),
			b3_mtime_us: Some(5),
			b3_date_us: Some(1000),
			b3_inode: Some((7, 42, [1; 32])),
			..Default::default()
		};
		assert_eq!(of.b3_fresh(10, 5, 7, 42, 900, 2000), Some(([1; 32], 1000)));
		// A copy, or the same inode number on another device.
		assert!(of.b3_fresh(10, 5, 7, 43, 900, 2000).is_none());
		assert!(of.b3_fresh(10, 5, 8, 42, 900, 2000).is_none());
		// Older than the cutoff, or later than now.
		assert!(of.b3_fresh(10, 5, 7, 42, 1001, 2000).is_none());
		assert!(of.b3_fresh(10, 5, 7, 42, 900, 999).is_none());
		// A set from before the inode attribute.
		let old = OnFile {
			b3_inode: None,
			..of.clone()
		};
		assert!(old.b3_fresh(10, 5, 7, 42, 900, 2000).is_none());
		// Another digest written since, as nemo-anywhere would.
		let other = OnFile {
			b3: Some([2; 32]),
			..of.clone()
		};
		assert!(other.b3_fresh(10, 5, 7, 42, 900, 2000).is_none());
	}

	#[test]
	fn inode_text_round_trip() {
		let _id = test_id("ddy5a");
		let d = [9u8; 32];
		let t = inode_text(u64::MAX, 3, &d);
		assert_eq!(
			inode_of(Some(format!("{t}\n").into_bytes())),
			Some((u64::MAX, 3, d))
		);
		assert!(inode_of(Some(b"1:2".to_vec())).is_none());
		assert!(inode_of(Some(b"x:2:abc".to_vec())).is_none());
	}

	#[test]
	#[cfg_attr(miri, ignore = "safe code, and too few cases in the time to matter")]
	fn fuzz_inode_values() {
		let _id = test_id("deebb");
		fuzz("inode", |r| {
			let mut covered = 0;
			let dev = r.next_u64() >> r.below(64);
			let ino = r.next_u64() >> r.below(64);
			let digest: [u8; 32] = std::array::from_fn(|_| r.next_u64() as u8);
			let mut stored = inode_text(dev, ino, &digest).into_bytes();
			if r.one_in(2) {
				stored.push(*r.pick(&[0, b'\n']));
				covered |= 1;
			}
			assert_eq!(inode_of(Some(stored.clone())), Some((dev, ino, digest)));
			let bad = mutate(r, &stored);
			if let Some((d, i, g)) = inode_of(Some(bad)) {
				assert_eq!(
					inode_of(Some(inode_text(d, i, &g).into_bytes())),
					Some((d, i, g))
				);
				covered |= 2;
			} else {
				covered |= 4;
			}
			covered
		})
		.covers(7);
	}
}
