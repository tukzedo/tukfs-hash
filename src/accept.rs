// Copyright © 2026 t00mietum (CryptogID: ปʬϝღถɔ4რఠΔթะ9ƾǝu)
// Licensed under GPL-2.0-only. No warranty.

// Takes what the named files read as now as good. A mismatch keeps the old
// checksums, so without this a file changed on purpose, with its time put
// back, is reported on every run.

use crate::db::{self, Hashed, Msg};
use crate::scan::{self, read_sums, ReadFail, Sums};
use crate::util::{b64u_encode, canonical_name, now_us, show_path};
use crate::xattr::{self, OnFile};
use rusqlite::{params, Connection};
use std::os::fd::AsRawFd;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64};

pub fn run(db_arg: &Path, paths: &[PathBuf], args: &str) -> Result<i32, String> {
	if paths.is_empty() {
		return Err("accept needs at least one file".into());
	}
	let db_path = scan::canonical_db(db_arg)?;
	if !db_path.is_file() {
		return Err(format!("{}: no such database", show_path(&db_path)));
	}
	let _lock = scan::lock(&db_path)?;
	let mut conn = db::open_rw(&db_path)?;
	let e = |e: rusqlite::Error| format!("database: {e}");
	// Its own status, so `scan --resume` never takes it for a stopped scan.
	conn.execute(
		"INSERT INTO runs (started_us, cutoff_us, status, host, args) VALUES (?1, ?1, 'accept', ?2, ?3)",
		params![now_us(), scan::host(), args],
	)
	.map_err(e)?;
	let run_id = conn.last_insert_rowid();
	let mut buf = vec![0u8; 1 << 20];
	let mut taken = 0;
	for p in paths {
		match one(&mut conn, run_id, p, &mut buf) {
			Ok(()) => taken += 1,
			Err(msg) => err!("{}: {msg}", show_path(p)),
		}
	}
	conn.execute(
		"UPDATE runs SET finished_us = ?1, summary = ?2 WHERE id = ?3",
		params![
			now_us(),
			format!("accepted {taken} of {}", paths.len()),
			run_id
		],
	)
	.map_err(e)?;
	if let Err(x) = db::close_rw(conn) {
		err!(
			"warning: {} is left in WAL mode ({x}). Something else likely has it open. The next run puts it back.",
			show_path(&db_path)
		);
	}
	scan::give_back(&db_path);
	out!("run {run_id}: accepted {taken} of {}", paths.len());
	Ok(if taken == paths.len() { 0 } else { 1 })
}

fn fail_text(f: ReadFail) -> String {
	match f {
		ReadFail::Stopped => "stopped".into(),
		ReadFail::Io(e, at) => format!("{e} at byte {at}"),
		ReadFail::Unstable => "changed while being read".into(),
	}
}

fn digest_text(d: Option<&[u8]>) -> String {
	d.map_or_else(|| "none".into(), b64u_encode)
}

fn one(conn: &mut Connection, run_id: i64, given: &Path, buf: &mut [u8]) -> Result<(), String> {
	let path = canonical_name(given)?;
	let e = |e: rusqlite::Error| format!("database: {e}");
	// A scan never follows one, so it has no record under this name.
	if std::fs::symlink_metadata(&path).is_ok_and(|m| m.file_type().is_symlink()) {
		return Err("a symlink; name the file it points to".into());
	}
	let file = scan::open_noatime(&path).map_err(|e| e.to_string())?;
	let before = file.metadata().map_err(|e| e.to_string())?;
	if !before.file_type().is_file() {
		return Err("not a regular file".into());
	}
	let fd = file.as_raw_fd();
	let onfile = OnFile::read(fd);
	let mtime_s = before.mtime() as f64 + before.mtime_nsec() as f64 / 1e9;
	let rmlint = onfile.b2_current(mtime_s);

	// Read twice, so a fault in memory during this read isn't what gets
	// taken as good.
	let (stop, counted) = (AtomicBool::new(false), AtomicU64::new(0));
	let read = |buf: &mut [u8]| -> Result<Sums, String> {
		read_sums(&file, &before, rmlint.is_some(), buf, &stop, &counted).map_err(fail_text)
	};
	let sums = read(buf)?;
	let again = read(buf)?;
	if again != sums {
		return Err(format!(
			"read as {}, then as {}. Nothing taken; check the RAM",
			b64u_encode(&sums.b3),
			b64u_encode(&again.b3)
		));
	}

	let pbytes = path.as_os_str().as_bytes();
	let prior = {
		let mut stmt = conn.prepare_cached(db::LOOKUP).map_err(e)?;
		db::lookup(&mut stmt, pbytes).map_err(e)?
	};
	let mut detail = format!(
		"now {}; database had {}, file had {}",
		b64u_encode(&sums.b3),
		digest_text(prior.as_ref().map(|p| &p.b3[..])),
		digest_text(onfile.b3.as_ref().map(|d| &d[..])),
	);
	let drop_rmlint = matches!((rmlint, sums.b2), (Some(old), Some(new)) if old != new);
	if drop_rmlint {
		detail.push_str("; rmlint's blake2b removed");
	}
	let hashed_us = now_us();
	let (bytes, mt) = (before.len() as i64, scan::mtime_us(&before));
	let tx = conn.transaction().map_err(e)?;
	let now = now_us();
	db::apply(
		&tx,
		run_id,
		now,
		Msg::Hashed(Box::new(Hashed {
			path: pbytes.to_vec(),
			b3: sums.b3,
			b2: sums.b2,
			bytes,
			mtime_us: mt,
			ino: before.ino() as i64,
			hashed_us,
		})),
	)
	.map_err(e)?;
	db::apply(
		&tx,
		run_id,
		now,
		Msg::Event {
			kind: "accepted",
			path: pbytes.to_vec(),
			detail,
		},
	)
	.map_err(e)?;
	tx.commit().map_err(e)?;

	// Only a set that's already there is replaced. Where a scan left none,
	// such as in a git work tree, accept doesn't add one.
	let mut written = Ok(());
	if onfile.b3.is_some() {
		let id = (before.dev(), before.ino());
		written = xattr::write_b3(fd, &sums.b3, bytes, mt, hashed_us, id, false);
	}
	if drop_rmlint && written.is_ok() {
		written = xattr::remove_rmlint(fd);
	}
	if let Err(x) = written {
		let tx = conn.transaction().map_err(e)?;
		db::apply(
			&tx,
			run_id,
			now_us(),
			Msg::Event {
				kind: "xattr-error",
				path: pbytes.to_vec(),
				detail: x.to_string(),
			},
		)
		.map_err(e)?;
		tx.commit().map_err(e)?;
		return Err(format!(
			"taken in the database, but its attributes weren't updated: {x}"
		));
	}

	out!("accepted\t{}\t{}", show_path(&path), b64u_encode(&sums.b3));
	if before.nlink() > 1 {
		out!(
			"\t{} other name(s) for this file keep their own records; accept those too",
			before.nlink() - 1
		);
	}
	Ok(())
}
