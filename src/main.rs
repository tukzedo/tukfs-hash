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

mod db;
mod mounts;
mod scan;
mod snapdiff;
mod util;
mod xattr;

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
	tukfs-hash snapdiff --old DIR --new DIR (--zfs-diff FILE --mount DIR | --find-new FILE | --list FILE) [--all]

scan options:
	--exclude DIR       Don't go into DIR. Repeatable.
	--no-xattr DIR      Checksum files under DIR, but leave no attributes on them. Repeatable.
	--no-xattrs         Leave no attributes anywhere.
	--threads DIR=N     Workers for the disks under DIR. Default 1 with a hard drive, else 2, or 4 on NVMe.
	--since YYYY-MM-DD  Skip files checksummed since then with the same size and time. Default today.
	--resume            Continue the last run that didn't finish, with its date.
	--progress SECS     Seconds between progress lines. Default 30.

A scan never crosses into another mount. Each root's mount is walked on its
own, and roots on the same disks share workers so no disk is read by two at
once. Ctrl+C stops after the files in hand; --resume picks up from there.

Attributes, as nemo-anywhere reads them:
	user.blake3.b64u    checksum, base64url with no padding
	user.blake3.bytes   size it was taken at
	user.blake3.mtime   modified time it was taken at, microseconds since 1970
	user.blake3.date    when it was taken, microseconds since 1970
rmlint's user.rmlint.blake2b.* are checked when present and current.

Exit codes: 0 fine, 1 error, 2 stopped, 4 mismatches or read errors found.
";

fn take_value(args: &mut std::slice::Iter<'_, String>, flag: &str) -> Result<String, String> {
	args.next()
		.cloned()
		.ok_or_else(|| format!("{flag} needs a value"))
}

fn main() {
	let argv: Vec<String> = std::env::args().skip(1).collect();
	let code = match real_main(&argv) {
		Ok(c) => c,
		Err(e) => {
			err!("tukfs-hash: {e}");
			1
		}
	};
	std::process::exit(code);
}

fn real_main(argv: &[String]) -> Result<i32, String> {
	let Some(cmd) = argv.first() else {
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
	let mut write_xattrs = true;
	let mut progress = 30;
	let mut run_id = None;
	let mut kind = None;
	let mut limit = 200;
	let (mut old, mut new, mut zfs_diff, mut mount, mut find_new, mut list) =
		(None, None, None, None, None, None);
	let mut show_all = false;

	let mut it = argv[1..].iter();
	while let Some(a) = it.next() {
		let p = |v: String| PathBuf::from(v);
		match a.as_str() {
			"--db" => db = Some(p(take_value(&mut it, a)?)),
			"--root" => roots.push(p(take_value(&mut it, a)?)),
			"--exclude" => excludes.push(p(take_value(&mut it, a)?)),
			"--no-xattr" => no_xattr.push(p(take_value(&mut it, a)?)),
			"--no-xattrs" => write_xattrs = false,
			"--threads" => {
				let v = take_value(&mut it, a)?;
				let (d, n) = v.rsplit_once('=').ok_or("--threads takes DIR=N")?;
				let n: usize = n
					.parse()
					.map_err(|_| format!("--threads: bad count in {v}"))?;
				threads.push((p(d.to_string()), n));
			}
			"--since" => {
				let v = take_value(&mut it, a)?;
				since = Some(
					util::parse_date(&v)
						.ok_or_else(|| format!("--since: {v} is not YYYY-MM-DD"))?,
				);
			}
			"--resume" => resume = true,
			"--progress" => {
				progress = take_value(&mut it, a)?
					.parse()
					.map_err(|_| "--progress takes seconds")?
			}
			"--run" => {
				run_id = Some(
					take_value(&mut it, a)?
						.parse::<i64>()
						.map_err(|_| "--run takes a number")?,
				)
			}
			"--kind" => kind = Some(take_value(&mut it, a)?),
			"--limit" => {
				limit = take_value(&mut it, a)?
					.parse()
					.map_err(|_| "--limit takes a number")?
			}
			"--old" => old = Some(p(take_value(&mut it, a)?)),
			"--new" => new = Some(p(take_value(&mut it, a)?)),
			"--zfs-diff" => zfs_diff = Some(p(take_value(&mut it, a)?)),
			"--mount" => mount = Some(p(take_value(&mut it, a)?)),
			"--find-new" => find_new = Some(p(take_value(&mut it, a)?)),
			"--list" => list = Some(p(take_value(&mut it, a)?)),
			"--all" => show_all = true,
			_ => return Err(format!("unknown option {a}; see --help")),
		}
	}
	let need_db = || db.clone().ok_or_else(|| "--db is required".to_string());

	match cmd.as_str() {
		"scan" => {
			if roots.is_empty() {
				return Err("scan needs at least one --root".into());
			}
			if resume && since.is_some() {
				return Err("--resume uses the old run's date; drop --since".into());
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
				scan::Opts {
					db: need_db()?,
					roots,
					excludes,
					no_xattr,
					threads,
					since,
					resume,
					write_xattrs,
					progress_secs: progress,
					args: argv.join(" "),
				},
				stop,
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
					out!("\t{}", r.display());
				}
			}
			Ok(0)
		}
		"runs" => runs(&need_db()?),
		"report" => report(&need_db()?, run_id, kind.as_deref(), limit),
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
			snapdiff::run(&old, &new, src, show_all)
		}
		_ => Err(format!("unknown command {cmd}; see --help")),
	}
}

fn runs(db: &std::path::Path) -> Result<i32, String> {
	let conn = db::open_ro(db)?;
	let e = |e: rusqlite::Error| e.to_string();
	let mut st = conn
		.prepare("SELECT id, started_us, finished_us, cutoff_us, status, host, summary FROM runs ORDER BY id")
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
			))
		})
		.map_err(e)?;
	for row in rows {
		let (id, start, fin, cutoff, status, host, summary) = row.map_err(e)?;
		out!(
			"run {id} on {} {status}: started {}, finished {}, skipping since {}",
			host.unwrap_or_default(),
			util::fmt_local(start),
			fin.map(util::fmt_local).unwrap_or_else(|| "-".into()),
			util::fmt_local(cutoff)
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
	// The ones that mean damage first.
	let mut st = conn
		.prepare(
			"SELECT kind, path, detail FROM events WHERE run_id = ?1 AND (?2 IS NULL OR kind = ?2)
			ORDER BY CASE WHEN kind LIKE '%mismatch' THEN 0 WHEN kind = 'read-error' THEN 1 ELSE 2 END, id
			LIMIT ?3",
		)
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
