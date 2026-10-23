// Copyright © 2026 t00mietum (CryptogID: ปʬϝღถɔ4რఠΔթะ9ƾǝu)
// Licensed under GPL-2.0-only. No warranty.

// Output that can't be written is dropped. A long scan shouldn't die because
// the terminal or the tee in front of it went away.
macro_rules! out {
	($($t:tt)*) => {{
		use std::io::Write;
		let _ = writeln!(std::io::stdout(), $($t)*);
	}};
}
macro_rules! err {
	($($t:tt)*) => {{
		use std::io::Write;
		let _ = writeln!(std::io::stderr(), $($t)*);
	}};
}

mod accept;
mod beneath;
mod db;
mod gone;
mod mounts;
mod scan;
mod snapdiff;
mod util;
mod xattr;

use std::ffi::{OsStr, OsString};
use std::fmt::Write as _;
use std::os::unix::ffi::OsStrExt;
use std::path::PathBuf;
use std::sync::atomic::AtomicBool;
use std::sync::Arc;

const USAGE: &str = "\
tukfs-hash - checksum every file, remember it, and notice when one changes on its own

Usage:
	tukfs-hash scan --db FILE --root DIR [--root DIR ...] [options]
	tukfs-hash plan --root DIR [--root DIR ...] [--threads DIR=N ...]
	tukfs-hash runs --db FILE
	tukfs-hash report --db FILE [--run N] [--kind KIND] [--limit N]
	tukfs-hash gone --db FILE [--run N] [--limit N]
	tukfs-hash accept --db FILE PATH...
	tukfs-hash prune --db FILE
	tukfs-hash snapdiff --old DIR --new DIR (--zfs-diff FILE --mount DIR | --find-new FILE | --list FILE) [--all]

scan options:
	--exclude DIR       Don't go into DIR. Repeatable.
	--no-xattr DIR      Checksum files under DIR, but leave no attributes on them. Repeatable.
	--no-xattrs         Leave no attributes anywhere.
	--rmlint            Take blake2b too for every file read, from the same read, and
	                    keep it in the database. Where rmlint's own attributes are
	                    missing or out of date, write them as `rmlint --xattr` would.
	--threads DIR=N     Workers for the disks under DIR. Default 1 with a hard drive, else 2, or 4 on NVMe.
	--since YYYY-MM-DD  Skip files checksummed since then with the same size and time. Default today.
	--resume            Continue the last scan, if it didn't finish, with its date.
	                    Refused when its roots differ, or it was a --verify
	                    and this isn't, or the other way round.
	--verify            Only read files with a checksum stored at their size and
	                    time, however recently, and compare. New and edited files
	                    are left for the next full scan. Writes no attributes.
	--progress SECS     Seconds between progress lines. Default 30.

A scan never crosses into another mount. Each root's mount is walked on its
own, and roots on the same disks share workers so no disk is read by two at
once. Ctrl+C stops after the files in hand; --resume picks up from there.

A file that reads differently from what was stored, at the same size and
time, is read again with its cache dropped. If the second read matches, it's
a cache-mismatch and only memory was wrong. If not, the stored checksums are
left as they were, so every later scan reports it again.

accept reads each PATH twice and takes what it reads as now as good: for a
file changed on purpose with its time put back, or one restored and checked
by hand. It replaces the database record and any blake3 set on the file,
removes rmlint's blake2b if it no longer matches, and logs an accepted event.
Each name of a hard-linked file has its own record.

gone lists names the newest finished scan, or run N, didn't see: under its
roots, with no event of their own in that run, and not last seen by another
run from a deeper root, which may be a mount the walk stops at. A folder
left out with --exclude counts as not seen.

prune removes contents no name points at any more. Each edit leaves one.

Attributes, as nemo-anywhere reads them:
	user.blake3.b64u    checksum, base64url with no padding
	user.blake3.bytes   size it was taken at
	user.blake3.mtime   modified time it was taken at, microseconds since 1970
	user.blake3.date    when it was taken, microseconds since 1970
	user.blake3.inode   device:inode:checksum of the file it was taken from
rmlint's user.rmlint.blake2b.* are checked when present and current, and
written with --rmlint.
Files on NTFS, APFS or HFS+ are read but never get attributes, and the
database can't go on one. Linux's drivers for them aren't trusted to write.

snapdiff takes `zfs diff` output with or without -H, -t and -F, and compares
M and R lines, and a path with both - and +. Lines outside --mount, and names
that aren't relative, are refused. A file renamed between btrfs snapshots is
found in --old by its inode.

Names that aren't plain text are printed with \\xHH escapes, and a backslash
as \\\\.

Exit codes: 0 fine, 1 error, 2 stopped, 4 mismatches or read errors found,
8 some files or folders couldn't be checked, or input wasn't understood
(snapdiff). 2, 4 and 8 add up, so 6 is a stop after a mismatch and 12 is both
kinds found. A resumed scan counts what its earlier parts found too. accept
exits 1 if any file wasn't taken.
";

fn take_value<'a>(
	args: &mut std::slice::Iter<'a, OsString>,
	flag: &str,
) -> Result<&'a OsStr, String> {
	args.next()
		.map(OsString::as_os_str)
		.ok_or_else(|| format!("{flag} needs a value"))
}

fn take_text(args: &mut std::slice::Iter<'_, OsString>, flag: &str) -> Result<String, String> {
	let v = take_value(args, flag)?;
	v.to_str()
		.map(str::to_string)
		.ok_or_else(|| format!("{flag}: {} isn't text", util::escape_name(v.as_bytes())))
}

fn main() {
	// Paths can be any bytes, so not env::args, which panics on them.
	let argv: Vec<OsString> = std::env::args_os().skip(1).collect();
	let code = match real_main(&argv) {
		Ok(c) => c,
		Err(e) => {
			err!("tukfs-hash: {e}");
			1
		}
	};
	std::process::exit(code);
}

#[allow(clippy::too_many_lines, reason = "split by 2026101916404110")]
fn real_main(argv: &[OsString]) -> Result<i32, String> {
	let shown = |a: &OsStr| util::escape_name(a.as_bytes());
	let Some(cmd) = argv.first().map(|c| c.to_str().unwrap_or_default()) else {
		let _ = std::io::Write::write_all(&mut std::io::stdout(), USAGE.as_bytes());
		return Ok(1);
	};
	if cmd == "-h" || cmd == "--help" || cmd == "help" {
		let _ = std::io::Write::write_all(&mut std::io::stdout(), USAGE.as_bytes());
		return Ok(0);
	}
	if cmd == "--version" {
		out!("tukfs-hash {}", env!("CARGO_PKG_VERSION"));
		return Ok(0);
	}

	let mut db = None;
	let mut roots = Vec::new();
	let mut excludes = Vec::new();
	let mut no_xattr = Vec::new();
	let mut threads = Vec::new();
	let mut since = None;
	let mut resume = false;
	let mut mode = scan::Mode::Full;
	let mut write_xattrs = true;
	let mut rmlint = false;
	let mut progress = 30;
	let mut run_id = None;
	let mut kind = None;
	let mut limit = 200;
	let (mut old, mut new, mut zfs_diff, mut mount, mut find_new, mut list) =
		(None, None, None, None, None, None);
	let mut show_all = false;
	let mut files = Vec::new();
	let mut only_files = false;

	let mut it = argv[1..].iter();
	while let Some(arg) = it.next() {
		let p = |v: &OsStr| PathBuf::from(v);
		if cmd == "accept" {
			if only_files || !arg.as_bytes().starts_with(b"-") {
				files.push(p(arg));
				continue;
			}
			if arg == "--" {
				only_files = true;
				continue;
			}
		}
		let a = arg.to_str().unwrap_or_default();
		match a {
			"--db" => db = Some(p(take_value(&mut it, a)?)),
			"--root" => roots.push(p(take_value(&mut it, a)?)),
			"--exclude" => excludes.push(p(take_value(&mut it, a)?)),
			"--no-xattr" => no_xattr.push(p(take_value(&mut it, a)?)),
			"--no-xattrs" => write_xattrs = false,
			"--rmlint" => rmlint = true,
			"--threads" => {
				let v = take_value(&mut it, a)?.as_bytes();
				let eq = v
					.iter()
					.rposition(|&c| c == b'=')
					.ok_or("--threads takes DIR=N")?;
				let n: usize = std::str::from_utf8(&v[eq + 1..])
					.ok()
					.and_then(|n| n.parse().ok())
					.ok_or_else(|| format!("--threads: bad count in {}", util::escape_name(v)))?;
				threads.push((p(OsStr::from_bytes(&v[..eq])), n));
			}
			"--since" => {
				let v = take_text(&mut it, a)?;
				since = Some(
					util::parse_date(&v)
						.ok_or_else(|| format!("--since: {v} is not YYYY-MM-DD"))?,
				);
			}
			"--resume" => resume = true,
			"--verify" => mode = scan::Mode::Verify,
			"--progress" => {
				progress = take_text(&mut it, a)?
					.parse()
					.map_err(|_| "--progress takes seconds")?;
			}
			"--run" => {
				run_id = Some(
					take_text(&mut it, a)?
						.parse::<i64>()
						.map_err(|_| "--run takes a number")?,
				);
			}
			"--kind" => kind = Some(take_text(&mut it, a)?),
			"--limit" => {
				limit = take_text(&mut it, a)?
					.parse()
					.map_err(|_| "--limit takes a number")?;
			}
			"--old" => old = Some(p(take_value(&mut it, a)?)),
			"--new" => new = Some(p(take_value(&mut it, a)?)),
			"--zfs-diff" => zfs_diff = Some(p(take_value(&mut it, a)?)),
			"--mount" => mount = Some(p(take_value(&mut it, a)?)),
			"--find-new" => find_new = Some(p(take_value(&mut it, a)?)),
			"--list" => list = Some(p(take_value(&mut it, a)?)),
			"--all" => show_all = true,
			_ => return Err(format!("unknown option {}; see --help", shown(arg))),
		}
	}
	let need_db = || db.clone().ok_or_else(|| "--db is required".to_string());

	match cmd {
		"scan" => {
			if roots.is_empty() {
				return Err("scan needs at least one --root".into());
			}
			if resume && since.is_some() {
				return Err("--resume uses the old run's date; drop --since".into());
			}
			if mode == scan::Mode::Verify && since.is_some() {
				return Err("--verify reads every known file again; drop --since".into());
			}
			let stop = Arc::new(AtomicBool::new(false));
			for sig in [
				signal_hook::consts::SIGINT,
				signal_hook::consts::SIGTERM,
				signal_hook::consts::SIGHUP,
			] {
				// A second signal ends it at once.
				signal_hook::flag::register_conditional_shutdown(sig, 130, stop.clone())
					.map_err(|e| e.to_string())?;
				signal_hook::flag::register(sig, stop.clone()).map_err(|e| e.to_string())?;
			}
			scan::run(
				&scan::Opts {
					db: need_db()?,
					roots,
					excludes,
					no_xattr,
					threads,
					since,
					resume,
					mode,
					write_xattrs,
					rmlint,
					progress_secs: progress,
					args: argv.iter().map(|a| shown(a)).collect::<Vec<_>>().join(" "),
				},
				&stop,
			)
		}
		"plan" => {
			let plan = scan::plan(&roots, &threads)?;
			for d in &plan.dropped {
				out!("skip {d}");
			}
			for (name, rs, n) in &plan.groups {
				out!("group {name}, {n} worker(s)");
				for r in rs {
					out!("\t{}", util::show_path(r));
				}
			}
			Ok(0)
		}
		"runs" => runs(&need_db()?),
		"report" => report(&need_db()?, run_id, kind.as_deref(), limit),
		"gone" => gone::run(&need_db()?, run_id, limit),
		"prune" => prune(&need_db()?),
		"accept" => accept::run(
			&need_db()?,
			&files,
			&argv.iter().map(|a| shown(a)).collect::<Vec<_>>().join(" "),
		),
		"snapdiff" => {
			let (Some(old), Some(new)) = (old, new) else {
				return Err("snapdiff needs --old and --new".into());
			};
			let src = match (zfs_diff, mount, find_new, list) {
				(Some(f), Some(m), None, None) => snapdiff::Source::ZfsDiff(f, m),
				(None, None, Some(f), None) => snapdiff::Source::FindNew(f),
				(None, None, None, Some(f)) => snapdiff::Source::List(f),
				_ => {
					return Err(
						"snapdiff takes one of --zfs-diff with --mount, --find-new, or --list"
							.into(),
					)
				}
			};
			snapdiff::run(&old, &new, &src, show_all)
		}
		_ => Err(format!("unknown command {}; see --help", shown(&argv[0]))),
	}
}

fn runs(db: &std::path::Path) -> Result<i32, String> {
	let conn = db::open_ro(db)?;
	let e = |e: rusqlite::Error| e.to_string();
	// Until a newer version has opened it for writing.
	let verify = if db::has_column(&conn, "runs", "verify").map_err(e)? {
		"verify"
	} else {
		"0"
	};
	let mut st = conn
		.prepare(&format!("SELECT id, started_us, finished_us, cutoff_us, status, host, summary, {verify} FROM runs ORDER BY id"))
		.map_err(e)?;
	let rows = st
		.query_map([], |r| {
			Ok((
				r.get::<_, i64>(0)?,
				r.get::<_, i64>(1)?,
				r.get::<_, Option<i64>>(2)?,
				r.get::<_, i64>(3)?,
				r.get::<_, String>(4)?,
				r.get::<_, Option<String>>(5)?,
				r.get::<_, Option<String>>(6)?,
				r.get::<_, bool>(7)?,
			))
		})
		.map_err(e)?;
	for row in rows {
		let (id, start, fin, cutoff, status, host, summary, verify) = row.map_err(e)?;
		let skipping = if db::RunStatus::parse(&status) == Some(db::RunStatus::Accept) {
			String::new()
		} else if verify {
			", verify".into()
		} else {
			format!(", skipping since {}", util::fmt_local(cutoff))
		};
		out!(
			"run {id} on {} {status}: started {}, finished {}{skipping}",
			host.unwrap_or_default(),
			util::fmt_local(start),
			fin.map_or_else(|| "-".into(), util::fmt_local),
		);
		if let Some(s) = summary {
			for l in s.lines() {
				out!("\t{l}");
			}
		}
	}
	let (files, paths): (i64, i64) = conn
		.query_row(
			"SELECT (SELECT count(*) FROM files), (SELECT count(*) FROM paths)",
			[],
			|r| Ok((r.get(0)?, r.get(1)?)),
		)
		.map_err(e)?;
	out!("{paths} paths, {files} distinct contents");
	Ok(0)
}

fn prune(db_arg: &std::path::Path) -> Result<i32, String> {
	let db_path = scan::canonical_db(db_arg)?;
	if !db_path.is_file() {
		return Err(format!("{}: no such database", util::show_path(&db_path)));
	}
	let _lock = scan::lock(&db_path)?;
	let conn = db::open_rw(&db_path)?;
	let n = db::prune(&conn).map_err(|e| format!("database: {e}"))?;
	if let Err(x) = db::close_rw(conn) {
		err!(
			"warning: {} is left in WAL mode ({x}). Something else likely has it open. The next run puts it back.",
			util::show_path(&db_path)
		);
	}
	scan::give_back(&db_path);
	out!("removed {n} content(s) no name points at");
	Ok(0)
}

// The ones that mean damage first.
fn damage_first(k: db::Kind) -> u8 {
	use db::Kind as K;
	match k {
		K::XattrMismatch | K::RmlintMismatch | K::DbMismatch | K::CacheMismatch => 0,
		K::ReadError => 1,
		K::Unsupported
		| K::Unstable
		| K::DirError
		| K::StatError
		| K::OpenError
		| K::DbError
		| K::XattrError
		| K::Accepted => 2,
	}
}

fn report(
	db: &std::path::Path,
	run: Option<i64>,
	kind: Option<&str>,
	limit: i64,
) -> Result<i32, String> {
	let conn = db::open_ro(db)?;
	let e = |e: rusqlite::Error| e.to_string();
	let run: i64 = match run {
		Some(r) => r,
		None => conn
			.query_row("SELECT max(id) FROM runs", [], |r| r.get(0))
			.map_err(|_| "no runs yet".to_string())?,
	};
	out!("run {run}");
	let mut st = conn
		.prepare("SELECT kind, count(*) FROM events WHERE run_id = ?1 GROUP BY kind ORDER BY kind")
		.map_err(e)?;
	let counts: Vec<(String, i64)> = st
		.query_map([run], |r| Ok((r.get(0)?, r.get(1)?)))
		.map_err(e)?
		.collect::<Result<_, _>>()
		.map_err(e)?;
	if counts.is_empty() {
		out!("\tno events");
		return Ok(0);
	}
	for (k, n) in &counts {
		out!("\t{k}: {n}");
	}
	let mut order = String::new();
	for k in db::Kind::ALL {
		_ = write!(order, " WHEN '{}' THEN {}", k.name(), damage_first(k));
	}
	let mut st = conn
		.prepare(&format!(
			"SELECT kind, path, detail FROM events WHERE run_id = ?1 AND (?2 IS NULL OR kind = ?2)
			ORDER BY CASE kind{order} ELSE 2 END, id
			LIMIT ?3"
		))
		.map_err(e)?;
	let rows = st
		.query_map(rusqlite::params![run, kind, limit], |r| {
			Ok((
				r.get::<_, String>(0)?,
				db::path_text(r.get_ref(1)?),
				r.get::<_, Option<String>>(2)?,
			))
		})
		.map_err(e)?;
	for row in rows {
		let (k, p, d) = row.map_err(e)?;
		out!("{k}\t{p}\t{}", d.unwrap_or_default());
	}
	Ok(0)
}

#[cfg(test)]
mod tests {
	use super::*;

	// Same order as the old `LIKE '%mismatch'`, then `read-error`.
	#[test]
	fn damage_sorts_first() {
		for k in db::Kind::ALL {
			let n = k.name();
			let was = if n.ends_with("mismatch") {
				0
			} else {
				u8::from(n != "read-error") + 1
			};
			assert_eq!(damage_first(k), was, "{n}");
		}
	}
}
