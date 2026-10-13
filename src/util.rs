// Copyright © 2026 t00mietum (CryptogID: ปʬϝღถɔ4რఠΔթะ9ƾǝu)
// Licensed under GPL-2.0-only. No warranty.

use std::ffi::CString;
use std::io;
use std::os::unix::ffi::OsStrExt;
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

pub fn now_us() -> i64 {
	SystemTime::now()
		.duration_since(UNIX_EPOCH)
		.map(|d| d.as_micros() as i64)
		.unwrap_or(0)
}

pub fn cpath(p: &Path) -> io::Result<CString> {
	CString::new(p.as_os_str().as_bytes()).map_err(|_| io::Error::from(io::ErrorKind::InvalidInput))
}

const B64U: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

// base64url with no padding, the form nemo-anywhere writes.
pub fn b64u_encode(data: &[u8]) -> String {
	let mut out = String::with_capacity(data.len().div_ceil(3) * 4);
	for chunk in data.chunks(3) {
		let b = [
			chunk[0],
			*chunk.get(1).unwrap_or(&0),
			*chunk.get(2).unwrap_or(&0),
		];
		let n = (b[0] as u32) << 16 | (b[1] as u32) << 8 | b[2] as u32;
		let chars = chunk.len() + 1;
		for i in 0..chars {
			out.push(B64U[(n >> (18 - 6 * i) & 63) as usize] as char);
		}
	}
	out
}

pub fn b64u_decode(s: &[u8]) -> Option<Vec<u8>> {
	if s.len() % 4 == 1 {
		return None;
	}
	let mut out = Vec::with_capacity(s.len() * 3 / 4);
	let mut acc: u32 = 0;
	let mut bits = 0;
	for &c in s {
		let v = B64U.iter().position(|&x| x == c)? as u32;
		acc = acc << 6 | v;
		bits += 6;
		if bits >= 8 {
			bits -= 8;
			out.push((acc >> bits) as u8);
			acc &= (1 << bits) - 1;
		}
	}
	// Leftover bits must be zero, or two texts would decode the same.
	if acc != 0 {
		return None;
	}
	Some(out)
}

pub fn hex(data: &[u8]) -> String {
	let mut s = String::with_capacity(data.len() * 2);
	for b in data {
		s.push_str(&format!("{b:02x}"));
	}
	s
}

pub fn unhex(s: &[u8]) -> Option<Vec<u8>> {
	if !s.len().is_multiple_of(2) {
		return None;
	}
	let val = |c: u8| (c as char).to_digit(16).map(|d| d as u8);
	s.chunks(2)
		.map(|p| Some(val(p[0])? << 4 | val(p[1])?))
		.collect()
}

// Values in xattrs may end in NUL (rmlint) or a newline (setfattr by hand).
pub fn trim_value(v: &[u8]) -> &[u8] {
	let end = v
		.iter()
		.rposition(|&c| c != 0 && !c.is_ascii_whitespace())
		.map_or(0, |i| i + 1);
	&v[..end]
}

fn tm_of(us: i64) -> libc::tm {
	let t: libc::time_t = us.div_euclid(1_000_000) as libc::time_t;
	let mut tm: libc::tm = unsafe { std::mem::zeroed() };
	unsafe { libc::localtime_r(&t, &mut tm) };
	tm
}

pub fn local_midnight_us(us: i64) -> i64 {
	let mut tm = tm_of(us);
	tm.tm_hour = 0;
	tm.tm_min = 0;
	tm.tm_sec = 0;
	tm.tm_isdst = -1;
	unsafe { libc::mktime(&mut tm) as i64 * 1_000_000 }
}

// "YYYY-MM-DD" to local midnight.
pub fn parse_date(s: &str) -> Option<i64> {
	let mut it = s.splitn(3, '-').map(|p| p.parse::<i32>().ok());
	let (y, m, d) = (it.next()??, it.next()??, it.next()??);
	if !(1970..=9999).contains(&y) || !(1..=12).contains(&m) || !(1..=31).contains(&d) {
		return None;
	}
	let mut tm: libc::tm = unsafe { std::mem::zeroed() };
	tm.tm_year = y - 1900;
	tm.tm_mon = m - 1;
	tm.tm_mday = d;
	tm.tm_isdst = -1;
	let t = unsafe { libc::mktime(&mut tm) };
	(t != -1).then_some(t as i64 * 1_000_000)
}

pub fn fmt_local(us: i64) -> String {
	let tm = tm_of(us);
	format!(
		"{:04}-{:02}-{:02} {:02}:{:02}:{:02}",
		tm.tm_year + 1900,
		tm.tm_mon + 1,
		tm.tm_mday,
		tm.tm_hour,
		tm.tm_min,
		tm.tm_sec
	)
}

pub fn human_bytes(n: u64) -> String {
	const UNITS: [&str; 6] = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"];
	let mut v = n as f64;
	let mut u = 0;
	while v >= 1024.0 && u < UNITS.len() - 1 {
		v /= 1024.0;
		u += 1;
	}
	if u == 0 {
		format!("{n} B")
	} else {
		format!("{v:.1} {}", UNITS[u])
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn b64u_round_trip() {
		for len in 0..70 {
			let data: Vec<u8> = (0..len).map(|i| (i * 37 + 11) as u8).collect();
			let text = b64u_encode(&data);
			assert!(!text.contains('='));
			assert_eq!(b64u_decode(text.as_bytes()).unwrap(), data);
		}
	}

	#[test]
	fn b64u_matches_nemo_sample() {
		// A 32-byte digest is 43 characters, as nemo-anywhere stores it.
		let text = b"QCVLFYZQYGbOC-KOfkdZGj3e65bov-K1c1EWf3JLim0";
		let raw = b64u_decode(text).unwrap();
		assert_eq!(raw.len(), 32);
		assert_eq!(b64u_encode(&raw).as_bytes(), text);
	}

	#[test]
	fn b64u_rejects_junk() {
		assert!(b64u_decode(b"abc=").is_none());
		assert!(b64u_decode(b"a").is_none());
		assert!(b64u_decode(b"ab+/").is_none());
		// Nonzero leftover bits.
		assert!(b64u_decode(b"AB").is_none());
	}

	#[test]
	fn hex_round_trip() {
		let data = [0u8, 1, 0xab, 0xff];
		assert_eq!(hex(&data), "0001abff");
		assert_eq!(unhex(b"0001abff").unwrap(), data);
		assert_eq!(unhex(b"0001ABFF").unwrap(), data);
		assert!(unhex(b"0g").is_none());
		assert!(unhex(b"abc").is_none());
	}

	#[test]
	fn trims_values() {
		assert_eq!(trim_value(b"abc\0"), b"abc");
		assert_eq!(trim_value(b"12\n"), b"12");
		assert_eq!(trim_value(b"\0"), b"");
	}

	#[test]
	fn dates() {
		let d = parse_date("2026-10-13").unwrap();
		assert_eq!(local_midnight_us(d + 5 * 3600 * 1_000_000), d);
		assert!(fmt_local(d).starts_with("2026-10-13 00:00:00"));
		assert!(parse_date("2026-13-01").is_none());
		assert!(parse_date("yesterday").is_none());
	}
}
