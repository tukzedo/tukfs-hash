// Copyright © 2026 t00mietum (CryptogID: ปʬϝღถɔ4რఠΔթะ9ƾǝu)
// Licensed under GPL-2.0-only. No warranty.

// One SQLite file. `files` is one row per distinct content and `paths` one row
// per name, the same split nemo-anywhere's cache uses, minus thumbnails.
//
// Unlike that cache this one is never thrown away and rebuilt. Its whole point
// is to remember what a file read as last time, so a damaged database, or one
// with newer tables, is refused and left alone.

use rusqlite::types::{ToSqlOutput, ValueRef};
use rusqlite::{params, Connection, OpenFlags, OptionalExtension, ToSql};
use std::path::Path;
use std::sync::mpsc::{Receiver, RecvTimeoutError};
use std::time::{Duration, Instant};

pub const SCHEMA: i64 = 2;

// Matches the dataset's recordsize, so a page write is one record write.
const PAGE_SIZE: i64 = 16384;

const CREATE: &str = "
CREATE TABLE meta (key TEXT PRIMARY KEY, value) WITHOUT ROWID;
CREATE TABLE runs (
	id          INTEGER PRIMARY KEY,
	started_us  INTEGER NOT NULL,
	finished_us INTEGER,
	cutoff_us   INTEGER NOT NULL,
	status      TEXT NOT NULL,
	host        TEXT,
	args        TEXT,
	summary     TEXT,
	roots       BLOB
);
CREATE TABLE files (
	id    INTEGER PRIMARY KEY,
	b3    BLOB NOT NULL UNIQUE,
	bytes INTEGER NOT NULL,
	b2    BLOB
);
CREATE TABLE paths (
	id        INTEGER PRIMARY KEY,
	path      NOT NULL UNIQUE,
	file_id   INTEGER NOT NULL REFERENCES files(id),
	bytes     INTEGER NOT NULL,
	mtime_us  INTEGER NOT NULL,
	ino       INTEGER NOT NULL,
	hashed_us INTEGER NOT NULL,
	seen_run  INTEGER NOT NULL
);
CREATE INDEX paths_file ON paths(file_id);
CREATE TABLE events (
	id     INTEGER PRIMARY KEY,
	run_id INTEGER NOT NULL,
	at_us  INTEGER NOT NULL,
	kind   TEXT NOT NULL,
	path   NOT NULL,
	detail TEXT
);
CREATE INDEX events_run_kind ON events(run_id, kind);
";

// Names are bytes on Linux. Most are UTF-8 and go in as text, so the sqlite3
// shell can match them with a plain string; the rest go in as blobs.
pub struct PathKey<'a>(pub &'a [u8]);

impl ToSql for PathKey<'_> {
	fn to_sql(&self) -> rusqlite::Result<ToSqlOutput<'_>> {
		Ok(match std::str::from_utf8(self.0) {
			Ok(s) => ToSqlOutput::Borrowed(ValueRef::Text(s.as_bytes())),
			Err(_) => ToSqlOutput::Borrowed(ValueRef::Blob(self.0)),
		})
	}
}

pub fn path_text(v: ValueRef<'_>) -> String {
	match v {
		ValueRef::Text(t) | ValueRef::Blob(t) => crate::util::escape_name(t),
		_ => String::new(),
	}
}

pub fn open_rw(path: &Path) -> Result<Connection, String> {
	let fresh = !path.exists();
	let conn = Connection::open(path).map_err(|e| format!("{}: {e}", path.display()))?;
	let e = |e: rusqlite::Error| format!("{}: {e}", path.display());
	conn.busy_timeout(Duration::from_secs(30)).map_err(e)?;
	if fresh {
		conn.pragma_update(None, "page_size", PAGE_SIZE)
			.map_err(e)?;
		conn.execute_batch(CREATE).map_err(e)?;
		conn.execute("INSERT INTO meta VALUES ('schema', ?1)", [SCHEMA])
			.map_err(e)?;
	}
	let check: String = conn
		.query_row("PRAGMA quick_check", [], |r| r.get(0))
		.map_err(e)?;
	if check != "ok" {
		return Err(format!(
			"{}: damaged ({check}). Left as is; restore it from a snapshot.",
			path.display()
		));
	}
	let schema: Option<i64> = conn
		.query_row("SELECT value FROM meta WHERE key = 'schema'", [], |r| {
			r.get(0)
		})
		.optional()
		.map_err(e)?;
	// 2 added runs.roots, for --resume. Older runs have none, and can't be
	// resumed.
	if schema == Some(1) {
		conn.execute_batch(
			"BEGIN;
			ALTER TABLE runs ADD COLUMN roots BLOB;
			UPDATE meta SET value = 2 WHERE key = 'schema';
			COMMIT;",
		)
		.map_err(e)?;
		drop(conn);
		return open_rw(path);
	}
	if schema != Some(SCHEMA) {
		return Err(format!(
			"{}: tables are version {schema:?}, this program knows {SCHEMA}",
			path.display()
		));
	}
	conn.pragma_update_and_check(None, "journal_mode", "WAL", |_| Ok(()))
		.map_err(e)?;
	// A power cut can lose the last second of rows, and the next run hashes
	// those files again. Not worth an fsync per batch.
	conn.pragma_update(None, "synchronous", "NORMAL")
		.map_err(e)?;
	conn.pragma_update(None, "cache_size", -65536).map_err(e)?;
	Ok(conn)
}

pub fn open_ro(path: &Path) -> Result<Connection, String> {
	let conn = Connection::open_with_flags(
		path,
		OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
	)
	.map_err(|e| format!("{}: {e}", path.display()))?;
	conn.busy_timeout(Duration::from_secs(30)).ok();
	Ok(conn)
}

// Puts the file back in rollback mode, so a user without write access to the
// folder can still open it read-only after a run as root. Leaving WAL mode
// checkpoints on its own; an explicit TRUNCATE checkpoint after quick_check
// fails with "table is locked" on SQLite 3.46 to 3.50.
pub fn close_rw(conn: Connection) -> rusqlite::Result<()> {
	conn.pragma_update_and_check(None, "journal_mode", "DELETE", |_| Ok(()))?;
	conn.close().map_err(|(_, e)| e)
}

#[derive(Debug, Clone)]
pub struct Prior {
	pub bytes: i64,
	pub mtime_us: i64,
	pub ino: i64,
	pub hashed_us: i64,
	pub seen_run: i64,
	pub b3: Vec<u8>,
}

pub const LOOKUP: &str = "SELECT p.bytes, p.mtime_us, p.ino, p.hashed_us, p.seen_run, f.b3
	FROM paths p JOIN files f ON f.id = p.file_id WHERE p.path = ?1";

// Only a missing row means nothing is known. A busy or broken database is not
// the same as no record, and taking it for one would overwrite the row unseen.
pub fn lookup(stmt: &mut rusqlite::Statement<'_>, path: &[u8]) -> rusqlite::Result<Option<Prior>> {
	stmt.query_row([PathKey(path)], |r| {
		Ok(Prior {
			bytes: r.get(0)?,
			mtime_us: r.get(1)?,
			ino: r.get(2)?,
			hashed_us: r.get(3)?,
			seen_run: r.get(4)?,
			b3: r.get(5)?,
		})
	})
	.optional()
}

pub struct Hashed {
	pub path: Vec<u8>,
	pub b3: [u8; 32],
	pub b2: Option<[u8; 64]>,
	pub bytes: i64,
	pub mtime_us: i64,
	pub ino: i64,
	pub hashed_us: i64,
}

pub enum Msg {
	Hashed(Box<Hashed>),
	Seen(Vec<u8>),
	Event {
		kind: &'static str,
		path: Vec<u8>,
		detail: String,
	},
}

// One message's rows, inside the caller's transaction.
pub fn apply(
	tx: &rusqlite::Transaction<'_>,
	run_id: i64,
	now: i64,
	m: Msg,
) -> rusqlite::Result<()> {
	match m {
		Msg::Hashed(h) => {
			let b2: Option<&[u8]> = h.b2.as_ref().map(|b| &b[..]);
			let id: i64 = tx
				.prepare_cached(
					"INSERT INTO files (b3, bytes, b2) VALUES (?1, ?2, ?3)
					ON CONFLICT(b3) DO UPDATE SET bytes = excluded.bytes, b2 = coalesce(excluded.b2, files.b2)
					RETURNING id",
				)?
				.query_row(params![&h.b3[..], h.bytes, b2], |r| r.get(0))?;
			tx.prepare_cached(
				"INSERT INTO paths (path, file_id, bytes, mtime_us, ino, hashed_us, seen_run)
				VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
				ON CONFLICT(path) DO UPDATE SET file_id = excluded.file_id, bytes = excluded.bytes,
				mtime_us = excluded.mtime_us, ino = excluded.ino, hashed_us = excluded.hashed_us,
				seen_run = excluded.seen_run",
			)?
			.execute(params![
				PathKey(&h.path),
				id,
				h.bytes,
				h.mtime_us,
				h.ino,
				h.hashed_us,
				run_id
			])?;
		}
		Msg::Seen(p) => {
			tx.prepare_cached("UPDATE paths SET seen_run = ?1 WHERE path = ?2")?
				.execute(params![run_id, PathKey(&p)])?;
		}
		Msg::Event { kind, path, detail } => {
			tx.prepare_cached("INSERT INTO events (run_id, at_us, kind, path, detail) VALUES (?1, ?2, ?3, ?4, ?5)")?
				.execute(params![run_id, now, kind, PathKey(&path), detail])?;
		}
	}
	Ok(())
}

// The only thread that writes. Batches go in one transaction each, at most a
// second apart, so a stop or a crash loses little.
pub fn writer(mut conn: Connection, run_id: i64, rx: Receiver<Msg>) -> Result<Connection, String> {
	let e = |e: rusqlite::Error| format!("database write: {e}");
	let mut pending: Vec<Msg> = Vec::with_capacity(4096);
	let mut last = Instant::now();
	loop {
		let done = match rx.recv_timeout(Duration::from_millis(250)) {
			Ok(m) => {
				pending.push(m);
				false
			}
			Err(RecvTimeoutError::Timeout) => false,
			Err(RecvTimeoutError::Disconnected) => true,
		};
		if !pending.is_empty()
			&& (done || pending.len() >= 20000 || last.elapsed() >= Duration::from_secs(1))
		{
			let tx = conn.transaction().map_err(e)?;
			let now = crate::util::now_us();
			for m in pending.drain(..) {
				apply(&tx, run_id, now, m).map_err(e)?;
			}
			tx.commit().map_err(e)?;
			last = Instant::now();
		}
		if done {
			return Ok(conn);
		}
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	use std::sync::mpsc::sync_channel;

	fn temp_db(tag: &str) -> std::path::PathBuf {
		let dir =
			std::env::temp_dir().join(format!("test_tukfs-hash_db_{tag}_{}", std::process::id()));
		std::fs::create_dir_all(&dir).unwrap();
		dir.join("t.sqlite")
	}

	#[test]
	fn round_trip_and_non_utf8_names() {
		let p = temp_db("rt");
		let conn = open_rw(&p).unwrap();
		let (tx, rx) = sync_channel(16);
		let t = std::thread::spawn(move || writer(conn, 1, rx));
		let odd = b"/x/caf\xe9".to_vec();
		for (path, d) in [
			(b"/x/a".to_vec(), 1u8),
			(odd.clone(), 2),
			(b"/x/b".to_vec(), 1),
		] {
			tx.send(Msg::Hashed(Box::new(Hashed {
				path,
				b3: [d; 32],
				b2: None,
				bytes: 3,
				mtime_us: 9,
				ino: 1,
				hashed_us: 100,
			})))
			.unwrap();
		}
		drop(tx);
		let conn = t.join().unwrap().unwrap();
		let n: i64 = conn
			.query_row("SELECT count(*) FROM files", [], |r| r.get(0))
			.unwrap();
		assert_eq!(n, 2, "two names with one content share a files row");
		let mut st = conn.prepare(LOOKUP).unwrap();
		assert_eq!(lookup(&mut st, &odd).unwrap().unwrap().b3, vec![2u8; 32]);
		assert_eq!(lookup(&mut st, b"/x/a").unwrap().unwrap().hashed_us, 100);
		let typ: String = conn
			.query_row(
				"SELECT typeof(path) FROM paths WHERE path = '/x/a'",
				[],
				|r| r.get(0),
			)
			.unwrap();
		assert_eq!(typ, "text");
		drop(st);
		close_rw(conn).unwrap();
		std::fs::remove_dir_all(p.parent().unwrap()).unwrap();
	}

	#[test]
	fn lookup_error_is_not_no_row() {
		let p = temp_db("lookup");
		let conn = open_rw(&p).unwrap();
		conn.execute_batch(
			"INSERT INTO files (id, b3, bytes) VALUES (1, x'01', 3);
			INSERT INTO paths (path, file_id, bytes, mtime_us, ino, hashed_us, seen_run)
			VALUES ('/x/junk', 1, 'three', 9, 1, 100, 1);",
		)
		.unwrap();
		let mut st = conn.prepare(LOOKUP).unwrap();
		assert!(lookup(&mut st, b"/x/none").unwrap().is_none());
		assert!(lookup(&mut st, b"/x/junk").is_err());
		drop(st);
		close_rw(conn).unwrap();
		std::fs::remove_dir_all(p.parent().unwrap()).unwrap();
	}

	#[test]
	fn takes_schema_1_forward() {
		let p = temp_db("schema1");
		close_rw(open_rw(&p).unwrap()).unwrap();
		let c = Connection::open(&p).unwrap();
		c.execute_batch(
			"ALTER TABLE runs DROP COLUMN roots;
			INSERT INTO runs (started_us, cutoff_us, status) VALUES (1, 1, 'stopped');
			UPDATE meta SET value = 1 WHERE key = 'schema';",
		)
		.unwrap();
		drop(c);
		let c = open_rw(&p).unwrap();
		let (n, roots): (i64, Option<Vec<u8>>) = c
			.query_row("SELECT count(*), roots FROM runs", [], |r| {
				Ok((r.get(0)?, r.get(1)?))
			})
			.unwrap();
		assert_eq!((n, roots), (1, None));
		close_rw(c).unwrap();
		std::fs::remove_dir_all(p.parent().unwrap()).unwrap();
	}

	#[test]
	fn refuses_other_schema() {
		let p = temp_db("schema");
		close_rw(open_rw(&p).unwrap()).unwrap();
		let c = Connection::open(&p).unwrap();
		c.execute("UPDATE meta SET value = 99 WHERE key = 'schema'", [])
			.unwrap();
		drop(c);
		assert!(open_rw(&p).unwrap_err().contains("version"));
		std::fs::remove_dir_all(p.parent().unwrap()).unwrap();
	}
}
