// Copyright © 2026 t00mietum (CryptogID: ปʬϝღถɔ4რఠΔթะ9ƾǝu)
// Licensed under GPL-2.0-only. No warranty.

// One SQLite file. `files` is one row per distinct content and `paths` one row
// per name, the same split nemo-anywhere's cache uses, minus thumbnails.
//
// Unlike that cache this one is never thrown away and rebuilt. Its whole point
// is to remember what a file read as last time, so a damaged database, or one
// with newer tables, is refused and left alone.

use rusqlite::types::{ToSqlOutput, ValueRef};
use rusqlite::{Connection, OpenFlags, OptionalExtension, ToSql, params};
use std::path::Path;
use std::sync::mpsc::{Receiver, RecvTimeoutError};
use std::time::{Duration, Instant};

/// The table version this binary writes.
pub const SCHEMA: i64 = 4;

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
	roots       BLOB,
	verify      INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE files (
	id    INTEGER PRIMARY KEY,
	b3    BLOB NOT NULL UNIQUE,
	bytes INTEGER NOT NULL,
	b2b   BLOB
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

/// Names are bytes on Linux. Most are UTF-8 and go in as text, so the sqlite3
/// shell can match them with a plain string; the rest go in as blobs.
#[derive(Debug)]
pub struct PathKey<'a>(pub &'a [u8]);

impl ToSql for PathKey<'_> {
	fn to_sql(&self) -> rusqlite::Result<ToSqlOutput<'_>> {
		Ok(match std::str::from_utf8(self.0) {
			Ok(s) => ToSqlOutput::Borrowed(ValueRef::Text(s.as_bytes())),
			Err(_) => ToSqlOutput::Borrowed(ValueRef::Blob(self.0)),
		})
	}
}

/// A stored path, escaped for showing.
pub fn path_text(v: ValueRef<'_>) -> String {
	match v {
		ValueRef::Text(t) | ValueRef::Blob(t) => crate::util::escape_name(t),
		_ => String::new(),
	}
}

/// SQLite sets itself up on first use with plain reads and writes, which race
/// when two threads get there at once. So once, here, before any connection.
/// The PRNG is seeded too, since the first open of a file sets its pid the
/// same way.
pub fn init() {
	static ONCE: std::sync::Once = std::sync::Once::new();
	ONCE.call_once(|| {
		let mut b = [0u8; 1];
		// SAFETY: neither takes a pointer but b, which outlives the call and is
		// as long as the length passed.
		unsafe {
			rusqlite::ffi::sqlite3_initialize();
			rusqlite::ffi::sqlite3_randomness(1, b.as_mut_ptr().cast());
		}
	});
}

/// Opens the database to write, creating it if needed.
pub fn open_rw(path: &Path) -> Result<Connection, String> {
	init();
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
	// resumed. 3 added runs.verify, so a resume keeps the run's mode. 4 renamed
	// b2 to b2b, so it reads as blake2b.
	let step = match schema {
		Some(1) => Some(("ALTER TABLE runs ADD COLUMN roots BLOB;", 2)),
		Some(2) => Some((
			"ALTER TABLE runs ADD COLUMN verify INTEGER NOT NULL DEFAULT 0;",
			3,
		)),
		Some(3) => Some((
			"ALTER TABLE files RENAME COLUMN b2 TO b2b;
			UPDATE events SET kind = 'b2b-rmlint-mismatch' WHERE kind = 'b2-rmlint-mismatch';",
			4,
		)),
		_ => None,
	};
	if let Some((alter, to)) = step {
		conn.execute_batch(&format!(
			"BEGIN; {alter} UPDATE meta SET value = {to} WHERE key = 'schema'; COMMIT;"
		))
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

/// A database a newer program hasn't opened for writing yet can lack columns
/// that readers ask for.
pub fn has_column(conn: &Connection, table: &str, column: &str) -> rusqlite::Result<bool> {
	conn.query_row(
		"SELECT count(*) FROM pragma_table_info(?1) WHERE name = ?2",
		[table, column],
		|r| r.get::<_, i64>(0),
	)
	.map(|n| n > 0)
}

/// Contents no name points at any more. Every edit leaves one behind.
pub fn prune(conn: &Connection) -> rusqlite::Result<usize> {
	conn.execute(
		"DELETE FROM files WHERE NOT EXISTS (SELECT 1 FROM paths WHERE paths.file_id = files.id)",
		[],
	)
}

/// Opens the database read only, for a worker's lookups.
pub fn open_ro(path: &Path) -> Result<Connection, String> {
	init();
	let conn = Connection::open_with_flags(
		path,
		OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
	)
	.map_err(|e| format!("{}: {e}", path.display()))?;
	conn.busy_timeout(Duration::from_secs(30)).ok();
	Ok(conn)
}

/// Puts the file back in rollback mode. See design.md, Database. Leaving WAL
/// mode checkpoints on its own, and an explicit TRUNCATE checkpoint after
/// `quick_check` fails with "table is locked" on SQLite 3.46 to 3.50.
pub fn close_rw(conn: Connection) -> Result<(), String> {
	// Short, since a failure here only warns.
	conn.busy_timeout(Duration::from_secs(5)).ok();
	let mode = conn
		.pragma_update_and_check(None, "journal_mode", "DELETE", |r| r.get::<_, String>(0))
		.map_err(|e| e.to_string());
	conn.close().map_err(|(_, e)| e.to_string())?;
	match mode?.to_ascii_lowercase().as_str() {
		"delete" => Ok(()),
		other => Err(format!("still in {other} mode")),
	}
}

/// What the database holds for a path.
#[derive(Debug, Clone)]
pub struct Prior {
	pub id: i64,
	pub bytes: i64,
	pub mtime_us: i64,
	pub ino: i64,
	pub hashed_us: i64,
	pub seen_run: i64,
	pub b3: Vec<u8>,
}

/// The query `lookup` runs.
pub const LOOKUP: &str = "SELECT p.id, p.bytes, p.mtime_us, p.ino, p.hashed_us, p.seen_run, f.b3
	FROM paths p JOIN files f ON f.id = p.file_id WHERE p.path = ?1";

/// Only a missing row means nothing is known. A busy or broken database is not
/// the same as no record, and taking it for one would overwrite the row unseen.
pub fn lookup(stmt: &mut rusqlite::Statement<'_>, path: &[u8]) -> rusqlite::Result<Option<Prior>> {
	stmt.query_row([PathKey(path)], |r| {
		Ok(Prior {
			id: r.get(0)?,
			bytes: r.get(1)?,
			mtime_us: r.get(2)?,
			ino: r.get(3)?,
			hashed_us: r.get(4)?,
			seen_run: r.get(5)?,
			b3: r.get(6)?,
		})
	})
	.optional()
}

/// `lookup` for each path, in one read transaction. A transaction of its own
/// took most of each lookup's time (2026102810135573). Errors stay per path.
pub fn lookup_each(conn: &Connection, paths: &[&[u8]]) -> Vec<Result<Option<Prior>, String>> {
	let opened = conn
		.unchecked_transaction()
		.and_then(|txn| Ok((txn, conn.prepare_cached(LOOKUP)?)));
	match opened {
		Ok((txn, mut st)) => {
			let found = paths
				.iter()
				.map(|p| lookup(&mut st, p).map_err(|e| e.to_string()))
				.collect();
			drop(st);
			// Only read, so nothing is lost if the end fails.
			_ = txn.finish();
			found
		}
		Err(e) => vec![Err(e.to_string()); paths.len()],
	}
}

/// A file's sums and stat, as read, for the writer to store.
#[derive(Debug)]
pub struct Hashed {
	pub path: Vec<u8>,
	pub b3: [u8; 32],
	pub b2b: Option<[u8; 64]>,
	pub bytes: i64,
	pub mtime_us: i64,
	pub ino: i64,
	#[allow(clippy::struct_field_names, reason = "named for its column")]
	pub hashed_us: i64,
}

/// What an event says about a file. The names are stored, so they don't change.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
	XattrMismatch,
	RmlintMismatch,
	DbMismatch,
	CacheMismatch,
	ReadError,
	Unsupported,
	Unstable,
	DirError,
	StatError,
	OpenError,
	DbError,
	XattrError,
	Accepted,
}

impl Kind {
	/// Every kind.
	pub const ALL: [Kind; 13] = [
		Kind::XattrMismatch,
		Kind::RmlintMismatch,
		Kind::DbMismatch,
		Kind::CacheMismatch,
		Kind::ReadError,
		Kind::Unsupported,
		Kind::Unstable,
		Kind::DirError,
		Kind::StatError,
		Kind::OpenError,
		Kind::DbError,
		Kind::XattrError,
		Kind::Accepted,
	];

	/// The name stored and shown.
	pub fn name(self) -> &'static str {
		match self {
			Kind::XattrMismatch => "b3-xattr-mismatch",
			Kind::RmlintMismatch => "b2b-rmlint-mismatch",
			Kind::DbMismatch => "b3-db-mismatch",
			Kind::CacheMismatch => "cache-mismatch",
			Kind::ReadError => "read-error",
			Kind::Unsupported => "read-unsupported",
			Kind::Unstable => "unstable",
			Kind::DirError => "dir-error",
			Kind::StatError => "stat-error",
			Kind::OpenError => "open-error",
			Kind::DbError => "db-error",
			Kind::XattrError => "xattr-error",
			Kind::Accepted => "accepted",
		}
	}

	/// The kind with that name.
	pub fn parse(name: &str) -> Option<Kind> {
		Kind::ALL.into_iter().find(|k| k.name() == name)
	}

	/// 4 is something flagged, 8 is something left unchecked. Unstable files
	/// are live ones, like a running VM's disk, and would set 8 on every run.
	/// A failed attribute write comes after the check. Only accept writes
	/// accepted, and it isn't a scan's to count.
	pub fn exit_bits(self) -> i32 {
		match self {
			Kind::XattrMismatch
			| Kind::RmlintMismatch
			| Kind::DbMismatch
			| Kind::CacheMismatch
			| Kind::ReadError => 4,
			Kind::Unsupported
			| Kind::DirError
			| Kind::StatError
			| Kind::OpenError
			| Kind::DbError => 8,
			Kind::Unstable | Kind::XattrError | Kind::Accepted => 0,
		}
	}
}

impl ToSql for Kind {
	fn to_sql(&self) -> rusqlite::Result<ToSqlOutput<'_>> {
		Ok(ToSqlOutput::Borrowed(ValueRef::Text(
			self.name().as_bytes(),
		)))
	}
}

/// A run's `status`, as stored.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RunStatus {
	Running,
	Stopped,
	Failed,
	Done,
	Killed,
	Accept,
}

impl RunStatus {
	/// Every status.
	pub const ALL: [RunStatus; 6] = [
		RunStatus::Running,
		RunStatus::Stopped,
		RunStatus::Failed,
		RunStatus::Done,
		RunStatus::Killed,
		RunStatus::Accept,
	];

	/// The text stored and shown.
	pub fn text(self) -> &'static str {
		match self {
			RunStatus::Running => "running",
			RunStatus::Stopped => "stopped",
			RunStatus::Failed => "failed",
			RunStatus::Done => "done",
			RunStatus::Killed => "killed",
			RunStatus::Accept => "accept",
		}
	}

	/// The status with that text.
	pub fn parse(text: &str) -> Option<RunStatus> {
		RunStatus::ALL.into_iter().find(|s| s.text() == text)
	}
}

impl ToSql for RunStatus {
	fn to_sql(&self) -> rusqlite::Result<ToSqlOutput<'_>> {
		Ok(ToSqlOutput::Borrowed(ValueRef::Text(
			self.text().as_bytes(),
		)))
	}
}

/// What workers send the database writer.
#[derive(Debug)]
pub enum Msg {
	Hashed(Box<Hashed>),
	/// A paths row id. No paths row is ever deleted, and the upsert keeps the id.
	Seen(i64),
	Event {
		kind: Kind,
		path: Vec<u8>,
		detail: String,
	},
}

/// One message's rows, inside the caller's transaction.
pub fn apply(
	tx: &rusqlite::Transaction<'_>,
	run_id: i64,
	now: i64,
	m: Msg,
) -> rusqlite::Result<()> {
	match m {
		Msg::Hashed(h) => {
			let b2b: Option<&[u8]> = h.b2b.as_ref().map(|b| &b[..]);
			let id: i64 = tx
				.prepare_cached(
					"INSERT INTO files (b3, bytes, b2b) VALUES (?1, ?2, ?3)
					ON CONFLICT(b3) DO UPDATE SET bytes = excluded.bytes, b2b = coalesce(excluded.b2b, files.b2b)
					RETURNING id",
				)?
				.query_row(params![&h.b3[..], h.bytes, b2b], |r| r.get(0))?;
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
		Msg::Seen(id) => {
			tx.prepare_cached("UPDATE paths SET seen_run = ?1 WHERE id = ?2")?
				.execute(params![run_id, id])?;
		}
		Msg::Event { kind, path, detail } => {
			tx.prepare_cached(
				"INSERT INTO events (run_id, at_us, kind, path, detail) VALUES (?1, ?2, ?3, ?4, ?5)",
			)?
			.execute(params![run_id, now, kind, PathKey(&path), detail])?;
		}
	}
	Ok(())
}

fn commit(conn: &mut Connection, run_id: i64, msgs: &mut Vec<Msg>) -> rusqlite::Result<()> {
	if msgs.is_empty() {
		return Ok(());
	}
	let tx = conn.transaction()?;
	let now = crate::util::now_us();
	for m in msgs.drain(..) {
		apply(&tx, run_id, now, m)?;
	}
	tx.commit()
}

/// The only thread that writes. Batches go in at most a second apart, so a stop
/// or a crash loses little. Events go first and on their own, so a bad row
/// among the rest can't take a mismatch down with it.
///
/// After a failure the rest are dropped, but events are still kept, until one
/// of those fails too. `halt` stops the workers. A panic is a failure too, and
/// the connection still comes back, so the run can be marked failed.
pub fn writer(
	mut conn: Connection,
	run_id: i64,
	rx: &Receiver<Msg>,
	halt: impl Fn(),
) -> (Connection, Result<(), String>) {
	let r = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
		batches(&mut conn, run_id, rx, &halt)
	}))
	.unwrap_or_else(|_| {
		halt();
		Err("the database writer panicked".into())
	});
	(conn, r)
}

#[cfg(test)]
/// Writers on these databases panic at their first batch.
pub static PANIC_ON: std::sync::Mutex<Vec<String>> = std::sync::Mutex::new(Vec::new());

fn batches(
	conn: &mut Connection,
	run_id: i64,
	rx: &Receiver<Msg>,
	halt: &impl Fn(),
) -> Result<(), String> {
	let mut events: Vec<Msg> = Vec::new();
	let mut rest: Vec<Msg> = Vec::with_capacity(4096);
	let mut failed: Option<String> = None;
	let mut events_ok = true;
	let mut last = Instant::now();
	loop {
		let done = match rx.recv_timeout(Duration::from_millis(250)) {
			Ok(m @ Msg::Event { .. }) => {
				if events_ok {
					events.push(m);
				}
				false
			}
			Ok(m) => {
				if failed.is_none() {
					rest.push(m);
				}
				false
			}
			Err(RecvTimeoutError::Timeout) => false,
			Err(RecvTimeoutError::Disconnected) => true,
		};
		let n = events.len() + rest.len();
		if n > 0 && (done || n >= 20000 || last.elapsed() >= Duration::from_secs(1)) {
			#[cfg(test)]
			if conn
				.path()
				.is_some_and(|p| PANIC_ON.lock().unwrap().iter().any(|q| q == p))
			{
				panic!("test fault");
			}
			let r = commit(conn, run_id, &mut events);
			if r.is_err() {
				events_ok = false;
			}
			if let Err(x) = r.and_then(|()| commit(conn, run_id, &mut rest)) {
				events.clear();
				rest.clear();
				if failed.is_none() {
					failed = Some(format!("database write: {x}"));
					halt();
				}
			}
			last = Instant::now();
		}
		if done {
			return failed.map_or(Ok(()), Err);
		}
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	use crate::testutil::{scratch, test_id};
	use std::sync::mpsc::sync_channel;

	// What's in databases already. A new variant has to be added here too.
	#[test]
	fn kind_names_are_the_stored_ones() {
		let _id = test_id("deavw");
		let stored = |k: Kind| match k {
			Kind::XattrMismatch => "b3-xattr-mismatch",
			Kind::RmlintMismatch => "b2b-rmlint-mismatch",
			Kind::DbMismatch => "b3-db-mismatch",
			Kind::CacheMismatch => "cache-mismatch",
			Kind::ReadError => "read-error",
			Kind::Unsupported => "read-unsupported",
			Kind::Unstable => "unstable",
			Kind::DirError => "dir-error",
			Kind::StatError => "stat-error",
			Kind::OpenError => "open-error",
			Kind::DbError => "db-error",
			Kind::XattrError => "xattr-error",
			Kind::Accepted => "accepted",
		};
		let names: std::collections::BTreeSet<_> = Kind::ALL.iter().map(|k| k.name()).collect();
		assert_eq!(names.len(), 13, "ALL is missing one, or 2 share a name");
		for k in Kind::ALL {
			assert_eq!(k.name(), stored(k));
			assert_eq!(Kind::parse(stored(k)), Some(k));
		}
		assert_eq!(Kind::parse("b2-rmlint-mismatch"), None);
		assert_eq!(Kind::parse(""), None);
	}

	#[test]
	fn run_statuses_are_the_stored_ones() {
		let _id = test_id("deavx");
		let stored = |s: RunStatus| match s {
			RunStatus::Running => "running",
			RunStatus::Stopped => "stopped",
			RunStatus::Failed => "failed",
			RunStatus::Done => "done",
			RunStatus::Killed => "killed",
			RunStatus::Accept => "accept",
		};
		let texts: std::collections::BTreeSet<_> =
			RunStatus::ALL.iter().map(|s| s.text()).collect();
		assert_eq!(texts.len(), 6, "ALL is missing one, or 2 share a text");
		for s in RunStatus::ALL {
			assert_eq!(s.text(), stored(s));
			assert_eq!(RunStatus::parse(stored(s)), Some(s));
		}
		assert_eq!(RunStatus::parse("Done"), None);
		assert_eq!(RunStatus::parse("paused"), None);
	}

	// Bound as text, so a query by the old literal still finds the row.
	#[test]
	#[cfg_attr(miri, ignore = "SQLite is C, which Miri can't run")]
	fn enums_are_stored_as_their_text() {
		let _id = test_id("deavy");
		init();
		let c = Connection::open_in_memory().unwrap();
		let (k, s): (String, String) = c
			.query_row(
				"SELECT ?1, ?2",
				params![Kind::DirError, RunStatus::Killed],
				|r| Ok((r.get(0)?, r.get(1)?)),
			)
			.unwrap();
		assert_eq!((k.as_str(), s.as_str()), ("dir-error", "killed"));
	}

	// The folder goes with the Scratch, so a test holds it to its end.
	fn temp_db(tag: &str) -> (crate::testutil::Scratch, std::path::PathBuf) {
		let dir = scratch(&format!("db_{tag}"));
		let p = dir.join("t.sqlite");
		(dir, p)
	}

	#[test]
	#[cfg_attr(miri, ignore = "SQLite is C, which Miri can't run")]
	fn round_trip_and_non_utf8_names() {
		let _id = test_id("ddwzs");
		let (_dir, p) = temp_db("rt");
		let conn = open_rw(&p).unwrap();
		let (tx, rx) = sync_channel(16);
		let t = std::thread::spawn(move || writer(conn, 1, &rx, || {}));
		let odd = b"/x/caf\xe9".to_vec();
		for (path, d) in [
			(b"/x/a".to_vec(), 1u8),
			(odd.clone(), 2),
			(b"/x/b".to_vec(), 1),
		] {
			tx.send(Msg::Hashed(Box::new(Hashed {
				path,
				b3: [d; 32],
				b2b: None,
				bytes: 3,
				mtime_us: 9,
				ino: 1,
				hashed_us: 100,
			})))
			.unwrap();
		}
		drop(tx);
		let (conn, r) = t.join().unwrap();
		r.unwrap();
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
	}

	fn hashed(path: &[u8], d: u8) -> Msg {
		Msg::Hashed(Box::new(Hashed {
			path: path.to_vec(),
			b3: [d; 32],
			b2b: None,
			bytes: 3,
			mtime_us: 9,
			ino: 1,
			hashed_us: 100,
		}))
	}

	fn ev(path: &[u8]) -> Msg {
		Msg::Event {
			kind: Kind::DbMismatch,
			path: path.to_vec(),
			detail: String::new(),
		}
	}

	#[test]
	#[cfg_attr(miri, ignore = "SQLite is C, which Miri can't run")]
	fn a_bad_row_keeps_the_events() {
		let _id = test_id("ddy8d");
		let (_dir, p) = temp_db("wfail");
		let conn = open_rw(&p).unwrap();
		conn.execute_batch(
			"CREATE TRIGGER boom BEFORE INSERT ON paths BEGIN SELECT RAISE(ABORT, 'boom'); END;",
		)
		.unwrap();
		let halts = std::sync::Arc::new(std::sync::atomic::AtomicU64::new(0));
		let halts_seen = halts.clone();
		let (tx, rx) = sync_channel(16);
		let t = std::thread::spawn(move || {
			writer(conn, 1, &rx, move || {
				halts_seen.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
			})
		});
		// The row comes first in the batch, and still doesn't take the event
		// with it.
		tx.send(hashed(b"/x/a", 1)).unwrap();
		tx.send(ev(b"/x/b")).unwrap();
		std::thread::sleep(Duration::from_millis(1500));
		// After the failure: rows are dropped, events still kept.
		tx.send(hashed(b"/x/c", 2)).unwrap();
		tx.send(ev(b"/x/d")).unwrap();
		drop(tx);
		let (conn, r) = t.join().unwrap();
		assert!(r.unwrap_err().contains("boom"));
		assert_eq!(halts.load(std::sync::atomic::Ordering::Relaxed), 1);
		let n = |q: &str| -> i64 { conn.query_row(q, [], |r| r.get(0)).unwrap() };
		assert_eq!(n("SELECT count(*) FROM events"), 2);
		assert_eq!(n("SELECT count(*) FROM paths"), 0);
		close_rw(conn).unwrap();
	}

	#[test]
	#[cfg_attr(miri, ignore = "SQLite is C, which Miri can't run")]
	fn close_rw_says_when_wal_stays() {
		let _id = test_id("ddy8e");
		let (_dir, p) = temp_db("walstays");
		close_rw(open_rw(&p).unwrap()).unwrap();
		let conn = open_rw(&p).unwrap();
		let other = Connection::open(&p).unwrap();
		other
			.query_row("SELECT count(*) FROM runs", [], |r| r.get::<_, i64>(0))
			.unwrap();
		assert!(close_rw(conn).is_err());
		assert!(p.with_extension("sqlite-wal").exists());
		drop(other);
		close_rw(open_rw(&p).unwrap()).unwrap();
		assert!(!p.with_extension("sqlite-wal").exists());
	}

	#[test]
	#[cfg_attr(miri, ignore = "SQLite is C, which Miri can't run")]
	fn seen_marks_only_its_row() {
		let _id = test_id("deaw2");
		let (_dir, p) = temp_db("seen");
		let conn = open_rw(&p).unwrap();
		let (tx, rx) = sync_channel(16);
		let t = std::thread::spawn(move || writer(conn, 1, &rx, || {}));
		tx.send(hashed(b"/x/a", 1)).unwrap();
		tx.send(hashed(b"/x/b", 2)).unwrap();
		drop(tx);
		let (conn, r) = t.join().unwrap();
		r.unwrap();
		let mut st = conn.prepare(LOOKUP).unwrap();
		let a = lookup(&mut st, b"/x/a").unwrap().unwrap();
		drop(st);

		let (tx, rx) = sync_channel(16);
		let t = std::thread::spawn(move || writer(conn, 2, &rx, || {}));
		tx.send(Msg::Seen(a.id)).unwrap();
		drop(tx);
		let (conn, r) = t.join().unwrap();
		r.unwrap();
		let mut st = conn.prepare(LOOKUP).unwrap();
		assert_eq!(lookup(&mut st, b"/x/a").unwrap().unwrap().seen_run, 2);
		assert_eq!(lookup(&mut st, b"/x/b").unwrap().unwrap().seen_run, 1);
		drop(st);
		close_rw(conn).unwrap();
	}

	#[test]
	#[cfg_attr(miri, ignore = "SQLite is C, which Miri can't run")]
	fn lookup_error_is_not_no_row() {
		let _id = test_id("ddy6g");
		let (_dir, p) = temp_db("lookup");
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
		let got = lookup_each(&conn, &[b"/x/none", b"/x/junk", b"/x/none"]);
		assert!(matches!(got[..], [Ok(None), Err(_), Ok(None)]), "{got:?}");
		// Each batch's transaction ends, so the writer isn't held back.
		assert!(conn.is_autocommit());
		close_rw(conn).unwrap();
	}

	#[test]
	#[cfg_attr(miri, ignore = "SQLite is C, which Miri can't run")]
	fn takes_schema_1_forward() {
		let _id = test_id("ddy78");
		let (_dir, p) = temp_db("schema1");
		close_rw(open_rw(&p).unwrap()).unwrap();
		let c = Connection::open(&p).unwrap();
		// Was only roots dropped. Schema 1 had neither column.
		c.execute_batch(
			"ALTER TABLE runs DROP COLUMN roots;
			ALTER TABLE runs DROP COLUMN verify;
			ALTER TABLE files RENAME COLUMN b2b TO b2;
			INSERT INTO runs (started_us, cutoff_us, status) VALUES (1, 1, 'stopped');
			UPDATE meta SET value = 1 WHERE key = 'schema';",
		)
		.unwrap();
		drop(c);
		let c = open_rw(&p).unwrap();
		let (n, roots, verify): (i64, Option<Vec<u8>>, i64) = c
			.query_row("SELECT count(*), roots, verify FROM runs", [], |r| {
				Ok((r.get(0)?, r.get(1)?, r.get(2)?))
			})
			.unwrap();
		assert_eq!((n, roots, verify), (1, None, 0));
		let schema: i64 = c
			.query_row("SELECT value FROM meta WHERE key = 'schema'", [], |r| {
				r.get(0)
			})
			.unwrap();
		assert_eq!(schema, SCHEMA);
		close_rw(c).unwrap();
	}

	#[test]
	#[cfg_attr(miri, ignore = "SQLite is C, which Miri can't run")]
	fn takes_schema_2_forward() {
		let _id = test_id("ddy79");
		let (_dir, p) = temp_db("schema2");
		close_rw(open_rw(&p).unwrap()).unwrap();
		let c = Connection::open(&p).unwrap();
		c.execute_batch(
			"ALTER TABLE runs DROP COLUMN verify;
			ALTER TABLE files RENAME COLUMN b2b TO b2;
			INSERT INTO runs (started_us, cutoff_us, status, roots) VALUES (1, 1, 'stopped', x'2f61');
			UPDATE meta SET value = 2 WHERE key = 'schema';",
		)
		.unwrap();
		assert!(!has_column(&c, "runs", "verify").unwrap());
		drop(c);
		let c = open_rw(&p).unwrap();
		assert!(has_column(&c, "runs", "verify").unwrap());
		let (roots, verify): (Vec<u8>, i64) = c
			.query_row("SELECT roots, verify FROM runs", [], |r| {
				Ok((r.get(0)?, r.get(1)?))
			})
			.unwrap();
		assert_eq!((roots, verify), (b"/a".to_vec(), 0));
		close_rw(c).unwrap();
	}

	#[test]
	#[cfg_attr(miri, ignore = "SQLite is C, which Miri can't run")]
	fn takes_schema_3_forward() {
		let _id = test_id("de5k3");
		let (_dir, p) = temp_db("schema3");
		close_rw(open_rw(&p).unwrap()).unwrap();
		let c = Connection::open(&p).unwrap();
		c.execute_batch(
			"ALTER TABLE files RENAME COLUMN b2b TO b2;
			INSERT INTO files (b3, bytes, b2) VALUES (x'01', 1, x'02');
			INSERT INTO events (run_id, at_us, kind, path) VALUES (1, 1, 'b2-rmlint-mismatch', '/a'), (1, 1, 'read-error', '/b');
			UPDATE meta SET value = 3 WHERE key = 'schema';",
		)
		.unwrap();
		drop(c);
		let c = open_rw(&p).unwrap();
		assert!(!has_column(&c, "files", "b2").unwrap());
		let kept: Vec<u8> = c
			.query_row("SELECT b2b FROM files", [], |r| r.get(0))
			.unwrap();
		assert_eq!(kept, [2]);
		let kinds: String = c
			.query_row(
				"SELECT group_concat(kind, ' ') FROM (SELECT kind FROM events ORDER BY path)",
				[],
				|r| r.get(0),
			)
			.unwrap();
		assert_eq!(kinds, "b2b-rmlint-mismatch read-error");
		close_rw(c).unwrap();
	}

	#[test]
	#[cfg_attr(miri, ignore = "SQLite is C, which Miri can't run")]
	fn prune_drops_only_unnamed_contents() {
		let _id = test_id("ddy9e");
		let (_dir, p) = temp_db("prune");
		let conn = open_rw(&p).unwrap();
		conn.execute_batch(
			"INSERT INTO files (id, b3, bytes) VALUES (1, x'01', 1), (2, x'02', 2), (3, x'03', 3);
			INSERT INTO paths (path, file_id, bytes, mtime_us, ino, hashed_us, seen_run)
			VALUES ('/x/a', 1, 1, 9, 1, 100, 1), ('/x/b', 1, 1, 9, 2, 100, 1), ('/x/c', 3, 3, 9, 3, 100, 1);",
		)
		.unwrap();
		assert_eq!(prune(&conn).unwrap(), 1);
		let ids: Vec<i64> = conn
			.prepare("SELECT id FROM files ORDER BY id")
			.unwrap()
			.query_map([], |r| r.get(0))
			.unwrap()
			.collect::<Result<_, _>>()
			.unwrap();
		assert_eq!(ids, [1, 3]);
		assert_eq!(prune(&conn).unwrap(), 0);
		close_rw(conn).unwrap();
	}

	#[test]
	#[cfg_attr(miri, ignore = "SQLite is C, which Miri can't run")]
	fn refuses_other_schema() {
		let _id = test_id("ddwzt");
		let (_dir, p) = temp_db("schema");
		close_rw(open_rw(&p).unwrap()).unwrap();
		let c = Connection::open(&p).unwrap();
		c.execute("UPDATE meta SET value = 99 WHERE key = 'schema'", [])
			.unwrap();
		drop(c);
		assert!(open_rw(&p).unwrap_err().contains("version"));
	}
}
