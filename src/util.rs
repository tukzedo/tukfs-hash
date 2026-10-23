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
		.map_or(0, |d| d.as_micros() as i64)
}

/// The folder resolved and the name left alone, so a symlink stays a symlink.
/// A scan stores names that way, walking down from a resolved root.
pub fn canonical_name(p: &Path) -> Result<std::path::PathBuf, String> {
	let parent = p
		.parent()
		.filter(|d| !d.as_os_str().is_empty())
		.unwrap_or(Path::new("."));
	let dir = std::fs::canonicalize(parent).map_err(|e| format!("{}: {e}", parent.display()))?;
	let name = p
		.file_name()
		.ok_or_else(|| format!("{}: not a file name", p.display()))?;
	Ok(dir.join(name))
}

pub fn cpath(p: &Path) -> io::Result<CString> {
	CString::new(p.as_os_str().as_bytes()).map_err(|_| io::Error::from(io::ErrorKind::InvalidInput))
}

const B64U: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

/// base64url with no padding, the form nemo-anywhere writes.
pub fn b64u_encode(data: &[u8]) -> String {
	let mut out = String::with_capacity(data.len().div_ceil(3) * 4);
	for chunk in data.chunks(3) {
		let b = [
			chunk[0],
			*chunk.get(1).unwrap_or(&0),
			*chunk.get(2).unwrap_or(&0),
		];
		let n = u32::from(b[0]) << 16 | u32::from(b[1]) << 8 | u32::from(b[2]);
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

const HEX: &[u8; 16] = b"0123456789abcdef";

fn push_hex(out: &mut String, b: u8) {
	out.push(char::from(HEX[usize::from(b >> 4)]));
	out.push(char::from(HEX[usize::from(b & 15)]));
}

pub fn hex(data: &[u8]) -> String {
	let mut s = String::with_capacity(data.len() * 2);
	for &b in data {
		push_hex(&mut s, b);
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

/// Values in xattrs may end in NUL (rmlint) or a newline (setfattr by hand).
pub fn trim_value(v: &[u8]) -> &[u8] {
	let end = v
		.iter()
		.rposition(|&c| c != 0 && !c.is_ascii_whitespace())
		.map_or(0, |i| i + 1);
	&v[..end]
}

fn tm_of(us: i64) -> libc::tm {
	let t: libc::time_t = us.div_euclid(1_000_000) as libc::time_t;
	// SAFETY: libc::tm is integers and one pointer, and all zeros is valid for each.
	let mut tm: libc::tm = unsafe { std::mem::zeroed() };
	// SAFETY: t and tm are live locals for the call.
	unsafe { libc::localtime_r(&raw const t, &raw mut tm) };
	tm
}

pub fn local_midnight_us(us: i64) -> i64 {
	let mut tm = tm_of(us);
	tm.tm_hour = 0;
	tm.tm_min = 0;
	tm.tm_sec = 0;
	tm.tm_isdst = -1;
	// SAFETY: tm is a live local.
	unsafe { libc::mktime(&raw mut tm) as i64 * 1_000_000 }
}

/// "YYYY-MM-DD" to local midnight.
pub fn parse_date(s: &str) -> Option<i64> {
	let mut it = s.splitn(3, '-').map(|p| p.parse::<i32>().ok());
	let (year, month, day) = (it.next()??, it.next()??, it.next()??);
	if !(1970..=9999).contains(&year) || !(1..=12).contains(&month) || !(1..=31).contains(&day) {
		return None;
	}
	// SAFETY: libc::tm is integers and one pointer, and all zeros is valid for each.
	let mut tm: libc::tm = unsafe { std::mem::zeroed() };
	tm.tm_year = year - 1900;
	tm.tm_mon = month - 1;
	tm.tm_mday = day;
	tm.tm_isdst = -1;
	// SAFETY: tm is a live local.
	let t = unsafe { libc::mktime(&raw mut tm) };
	// mktime rolls Feb 31 over into March, and says so only in tm.
	let same_day = tm.tm_year == year - 1900 && tm.tm_mon == month - 1 && tm.tm_mday == day;
	(t != -1 && same_day).then_some(t as i64 * 1_000_000)
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

/// A name as text that maps back to its bytes, so 2 names never print the same:
/// a backslash doubled, and control characters and bytes that aren't UTF-8 as
/// \xHH. Tabs and newlines get escaped too, which keeps tab-separated output
/// in its columns.
pub fn escape_name(b: &[u8]) -> String {
	let mut out = String::with_capacity(b.len());
	let hex_byte = |out: &mut String, byte: u8| {
		out.push_str("\\x");
		push_hex(out, byte);
	};
	for chunk in b.utf8_chunks() {
		for c in chunk.valid().chars() {
			if c == '\\' {
				out.push_str("\\\\");
			} else if c.is_control() {
				for byte in c.encode_utf8(&mut [0; 4]).bytes() {
					hex_byte(&mut out, byte);
				}
			} else {
				out.push(c);
			}
		}
		for &byte in chunk.invalid() {
			hex_byte(&mut out, byte);
		}
	}
	out
}

pub fn show_path(p: &Path) -> String {
	escape_name(p.as_os_str().as_bytes())
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
		assert!(parse_date("2026-02-31").is_none());
		assert!(parse_date("2026-04-31").is_none());
		assert!(parse_date("2026-02-29").is_none());
		assert!(parse_date("2028-02-29").is_some());
		assert!(parse_date("2026-12-31").is_some());
		assert!(parse_date("yesterday").is_none());
	}

	#[test]
	fn escapes_names() {
		assert_eq!(escape_name(b"plain name.txt"), "plain name.txt");
		assert_eq!(escape_name("caf\u{e9}".as_bytes()), "caf\u{e9}");
		assert_eq!(escape_name(b"caf\xe9"), "caf\\xe9");
		assert_eq!(escape_name(b"a\tb\nc\\d"), "a\\x09b\\x0ac\\\\d");
		// The escaped form of one name is never another name's plain form.
		assert_ne!(escape_name(b"\\xe9"), escape_name(b"\xe9"));
	}

	// Pinned, since rmlint's xattr bytes and the listed names depend on them.
	#[test]
	fn hex_and_escape_pinned() {
		let all: Vec<u8> = (0..=255).collect();
		let want = all
			.iter()
			.map(|b| format!("{b:02x}"))
			.collect::<Vec<_>>()
			.concat();
		assert_eq!(hex(&all), want);
		assert_eq!(hex(&[]), "");
		assert_eq!(hex(&[0x0f, 0xf0, 0x5a]), "0ff05a");
		assert_eq!(escape_name(b""), "");
		assert_eq!(escape_name(b"\x00\x1f\x7f"), "\\x00\\x1f\\x7f");
		// C1 controls are escaped byte by byte, as UTF-8.
		assert_eq!(escape_name("a\u{85}b".as_bytes()), "a\\xc2\\x85b");
		assert_eq!(escape_name(b"\xff\xfe\\x"), "\\xff\\xfe\\\\x");
		assert_eq!(escape_name("\u{1f600}\r".as_bytes()), "\u{1f600}\\x0d");
	}
}
