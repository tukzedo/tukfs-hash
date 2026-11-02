// Copyright © 2026 t00mietum (CryptogID: ปʬϝღถɔ4რఠΔթะ9ƾǝu)
// Licensed under GPL-2.0-only. No warranty.

// Walks each root, checksums every regular file, and compares the result with
// whatever was known before: the blake3 on the file, rmlint's blake2b on the
// file, and the database. A file whose size and time didn't change but whose
// contents did is the thing this is looking for.

use crate::beneath::{self, Root};
use crate::db::{self, Hashed, Kind, Msg, Prior, RunStatus};
use crate::mounts;
use crate::util::{
	b64u_encode, escape_name, fmt_local, hex, human_bytes, local_midnight_us, now_us,
};
use crate::xattr::{self, OnFile};
use rusqlite::OptionalExtension;
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet, VecDeque};
use std::ffi::OsStr;
use std::fmt::Write as _;
use std::fs::{self, File, OpenOptions};
use std::io;
use std::os::fd::{AsRawFd, RawFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{FileExt, MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering::Relaxed};
use std::sync::mpsc::{Receiver, SyncSender, sync_channel};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError};
use std::time::{Duration, Instant};

/// A full scan, or `--verify`, which rereads only files with a known
/// checksum. See design.md, Runs and exit codes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
	Full,
	Verify,
}

impl Mode {
	// From runs.verify.
	fn stored(verify: bool) -> Mode {
		if verify { Mode::Verify } else { Mode::Full }
	}
}

/// What `scan` was asked to do.
#[derive(Debug)]
pub struct Opts {
	pub db: PathBuf,
	pub roots: Vec<PathBuf>,
	pub excludes: Vec<PathBuf>,
	pub no_xattr: Vec<PathBuf>,
	pub threads: Vec<(PathBuf, usize)>,
	pub since: Option<i64>,
	pub resume: bool,
	pub mode: Mode,
	pub write_xattrs: bool,
	pub rmlint: bool,
	pub progress_secs: u64,
	pub args: String,
}

// Every part of a resumed run counts, and a file reported again by a later
// part counts once.
fn run_events(conn: &rusqlite::Connection, run_id: i64) -> rusqlite::Result<Vec<(String, i64)>> {
	conn.prepare(
		"SELECT kind, count(DISTINCT path) FROM events WHERE run_id = ?1 GROUP BY kind ORDER BY kind",
	)?
	.query_map([run_id], |r| Ok((r.get(0)?, r.get(1)?)))?
	.collect()
}

// A kind this version doesn't know can't be called harmless.
fn exit_bits(counts: &[(String, i64)]) -> i32 {
	counts
		.iter()
		.filter(|(_, n)| *n > 0)
		.map(|(k, _)| Kind::parse(k).map_or(8, Kind::exit_bits))
		.fold(0, |a, b| a | b)
}

const EVENTS_LINE: &str = "events in the whole run:";

fn events_line(counts: Option<&[(String, i64)]>) -> String {
	let Some(counts) = counts else {
		return format!("{EVENTS_LINE} couldn't be counted");
	};
	if counts.is_empty() {
		return format!("{EVENTS_LINE} none");
	}
	let each: Vec<String> = counts.iter().map(|(k, n)| format!("{k} {n}")).collect();
	format!("{EVENTS_LINE} {}", each.join(", "))
}

// Roots as plan() kept them, sorted, so 2 runs over the same folders match.
fn roots_key(groups: &[Planned]) -> Vec<u8> {
	let mut roots: Vec<&[u8]> = groups
		.iter()
		.flat_map(|g| g.roots.iter().map(|r| r.as_os_str().as_bytes()))
		.collect();
	roots.sort_unstable();
	roots.join(&0u8)
}

fn roots_diff(was: &[u8], now: &[u8]) -> String {
	let split = |b: &[u8]| -> BTreeSet<Vec<u8>> {
		b.split(|&c| c == 0)
			.filter(|r| !r.is_empty())
			.map(<[u8]>::to_vec)
			.collect()
	};
	let (was, now) = (split(was), split(now));
	let show = |set: Vec<&Vec<u8>>| {
		let mut v: Vec<String> = set.iter().take(3).map(|r| escape_name(r)).collect();
		if set.len() > 3 {
			v.push(format!("and {} more", set.len() - 3));
		}
		v.join(", ")
	};
	let mut out = Vec::new();
	let gone: Vec<_> = was.difference(&now).collect();
	let added: Vec<_> = now.difference(&was).collect();
	if !gone.is_empty() {
		out.push(format!("not given now: {}", show(gone)));
	}
	if !added.is_empty() {
		out.push(format!("not in that run: {}", show(added)));
	}
	out.join("; ")
}

struct Resumed {
	id: i64,
	cutoff_us: i64,
	started_us: i64,
	summary: Option<String>,
}

// Only the newest unfinished scan, same roots and mode. See design.md, Runs and exit codes.
fn pick_resume(conn: &rusqlite::Connection, roots: &[u8], mode: Mode) -> Result<Resumed, String> {
	let row = conn
		.query_row(
			"SELECT id, status, cutoff_us, started_us, roots, summary, verify FROM runs
			WHERE status != ?1 ORDER BY id DESC LIMIT 1",
			[RunStatus::Accept],
			|r| {
				Ok((
					Resumed {
						id: r.get(0)?,
						cutoff_us: r.get(2)?,
						started_us: r.get(3)?,
						summary: r.get(5)?,
					},
					r.get::<_, String>(1)?,
					r.get::<_, Option<Vec<u8>>>(4)?,
					r.get::<_, bool>(6)?,
				))
			},
		)
		.optional()
		.map_err(|e| format!("database: {e}"))?;
	let Some((run, status, was, was_verify)) = row else {
		return Err("--resume: no scan to resume".into());
	};
	let id = run.id;
	let Some(known) = RunStatus::parse(&status) else {
		return Err(format!("--resume: run {id} is {status}; can't resume it"));
	};
	match known {
		RunStatus::Stopped | RunStatus::Failed | RunStatus::Running | RunStatus::Killed => {}
		RunStatus::Done => {
			return Err(format!(
				"--resume: the last scan, run {id}, finished. Start a new one without --resume."
			));
		}
		RunStatus::Accept => {
			return Err(format!("--resume: run {id} is {status}; can't resume it"));
		}
	}
	let Some(was) = was else {
		return Err(format!(
			"--resume: run {id} is from an older version, which kept no root list. Start a new one without --resume."
		));
	};
	if was != roots {
		return Err(format!(
			"--resume: run {id} was over other roots ({}). Resume it with the same roots, or start a new one without --resume.",
			roots_diff(&was, roots)
		));
	}
	match (Mode::stored(was_verify), mode) {
		(Mode::Verify, Mode::Full) => {
			return Err(format!(
				"--resume: run {id} was a --verify run. Resume it with --verify, or start a new scan without --resume."
			));
		}
		(Mode::Full, Mode::Verify) => {
			return Err(format!(
				"--resume: run {id} was a full scan. Resume it without --verify, or start a new --verify without --resume."
			));
		}
		(Mode::Full, Mode::Full) | (Mode::Verify, Mode::Verify) => {}
	}
	if matches!(known, RunStatus::Running | RunStatus::Killed) {
		out!("run {id} didn't finish and wasn't stopped; it was likely killed");
	}
	Ok(run)
}

#[derive(Default)]
struct Stats {
	files: AtomicU64,
	hashed: AtomicU64,
	skip_db: AtomicU64,
	skip_xattr: AtomicU64,
	skip_unknown: AtomicU64,
	links: AtomicU64,
	bytes: AtomicU64,
	b3_ok: AtomicU64,
	b2b_ok: AtomicU64,
	db_ok: AtomicU64,
	mismatch: AtomicU64,
	read_err: AtomicU64,
	other_err: AtomicU64,
	unstable: AtomicU64,
	xattr_set: AtomicU64,
	xattr_fail: AtomicU64,
	rmlint_set: AtomicU64,
}

impl Stats {
	fn line(&self) -> String {
		let g = |a: &AtomicU64| a.load(Relaxed);
		format!(
			"files {} hashed {} ({}) skipped {} links {} | verified b3 {} b2b {} db {} | MISMATCH {} read-err {} other-err {} unstable {} | xattr set {} fail {} rmlint {}",
			g(&self.files),
			g(&self.hashed),
			human_bytes(g(&self.bytes)),
			g(&self.skip_db) + g(&self.skip_xattr) + g(&self.skip_unknown),
			g(&self.links),
			g(&self.b3_ok),
			g(&self.b2b_ok),
			g(&self.db_ok),
			g(&self.mismatch),
			g(&self.read_err),
			g(&self.other_err),
			g(&self.unstable),
			g(&self.xattr_set),
			g(&self.xattr_fail),
			g(&self.rmlint_set),
		)
	}
}

// Why a run failed, other than a stop. See design.md, Runs and exit codes.
#[derive(Default)]
struct Faults {
	any: AtomicBool,
	why: Mutex<Vec<String>>,
}

impl Faults {
	fn halt(&self, stop: &AtomicBool) {
		self.any.store(true, Relaxed);
		stop.store(true, Relaxed);
	}

	fn add(&self, stop: &AtomicBool, why: String) {
		locked(&self.why).push(why);
		self.halt(stop);
	}
}

// A worker's panic is caught and fails the run, so a lock it poisoned has to
// stay usable. Otherwise a ClaimGuard dropped in the unwind aborts, or the
// reason is lost and the run isn't marked failed.
fn locked<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
	m.lock().unwrap_or_else(PoisonError::into_inner)
}

struct Shared {
	stop: Arc<AtomicBool>,
	faults: Arc<Faults>,
	run_id: i64,
	cutoff_us: i64,
	db: PathBuf,
	excludes: Vec<PathBuf>,
	no_xattr: Vec<PathBuf>,
	mount_points: BTreeMap<PathBuf, String>,
	// Devices of roots on NTFS, APFS or HFS+. The walk stays on its root's.
	no_write_devs: BTreeSet<u64>,
	write_xattrs: bool,
	// blake2b for every file read, not only ones with a current rmlint set.
	rmlint: bool,
	mode: Mode,
	// Never skipped until read clean or accepted.
	open_misses: HashSet<Vec<u8>>,
	tx: SyncSender<Msg>,
}

struct Group {
	name: String,
	roots: Vec<PathBuf>,
	threads: usize,
	stats: Stats,
	done: AtomicBool,
}

struct Job {
	path: PathBuf,
	in_git: bool,
	root: Arc<Root>,
	prior: Option<Prior>,
}

/// Roots that share disks, read by one pool of workers.
#[derive(Debug, Clone)]
pub struct Planned {
	pub name: String,
	pub roots: Vec<PathBuf>,
	pub threads: usize,
}

/// What `plan` makes of the roots given.
#[derive(Debug)]
pub struct Plan {
	pub groups: Vec<Planned>,
	pub dropped: Vec<String>,
	/// Roots that couldn't be resolved, made absolute, with the error. Nothing
	/// under them is read, so a scan logs each as a `dir-error`.
	pub unresolved: Vec<(PathBuf, String)>,
	pub mounts: Vec<mounts::Mount>,
}

/// Roots that resolve to the same place, or sit inside another root on the same
/// mount and device, are dropped, so nothing is read twice. Bind mounts are the
/// usual cause here.
pub fn plan(roots: &[PathBuf], threads: &[(PathBuf, usize)]) -> Result<Plan, String> {
	let mounts = mounts::read_mounts()?;
	let mut dropped = Vec::new();
	let mut unresolved = Vec::new();
	let mut kept: Vec<(PathBuf, u64, BTreeSet<String>)> = Vec::new();
	let mut seen_ids: HashMap<(u64, u64), PathBuf> = HashMap::new();
	let mut canon = Vec::new();
	for r in roots {
		match fs::canonicalize(r) {
			Ok(c) => canon.push(c),
			Err(e) => {
				let abs = std::path::absolute(r).unwrap_or_else(|_| r.clone());
				unresolved.push((abs, e.to_string()));
			}
		}
	}
	// An outer folder sorts before anything inside it.
	canon.sort();
	canon.dedup();
	for c in canon {
		let md = fs::metadata(&c).map_err(|e| format!("{}: {e}", c.display()))?;
		if !md.is_dir() {
			return Err(format!("{}: not a folder", c.display()));
		}
		if let Some(first) = seen_ids.get(&(md.dev(), md.ino())) {
			dropped.push(format!(
				"{}: same folder as {}",
				c.display(),
				first.display()
			));
			continue;
		}
		let m = mounts::mount_for(&mounts, &c)
			.ok_or_else(|| format!("{}: no mount found", c.display()))?;
		// An unmounted btrfs subvolume shares its parent's mount, but the
		// parent's walk stops at it, as at any other device.
		if let Some((other, ..)) = kept.iter().find(|(k, dev, _)| {
			*dev == md.dev()
				&& c.starts_with(k)
				&& mounts::mount_for(&mounts, k).is_some_and(|km| km.point == m.point)
		}) {
			dropped.push(format!("{}: inside {}", c.display(), other.display()));
			continue;
		}
		let disks = mounts::disks_for(m, &mounts)?;
		seen_ids.insert((md.dev(), md.ino()), c.clone());
		kept.push((c, md.dev(), disks));
	}
	let kept = kept.into_iter().map(|(c, _, disks)| (c, disks)).collect();
	let mut groups = Vec::new();
	for (disks, rs) in mounts::group_roots(kept) {
		let mut n = mounts::default_threads(&disks);
		for (p, t) in threads {
			if let Ok(c) = fs::canonicalize(p)
				&& rs.iter().any(|r| c.starts_with(r) || r.starts_with(&c))
			{
				n = *t;
			}
		}
		groups.push(Planned {
			name: mounts::group_name(&disks),
			roots: rs,
			threads: n.max(1),
		});
	}
	Ok(Plan {
		groups,
		dropped,
		unresolved,
		mounts,
	})
}

/// Takes the database's lock file, so 2 scans can't share it.
pub fn lock(db: &Path, mounts: &[mounts::Mount]) -> Result<File, String> {
	if let Some(t) = mounts::hands_off_at(mounts, db) {
		return Err(format!(
			"{} is on {t}, which isn't written to from Linux; put the database elsewhere",
			db.display()
		));
	}
	let p = lock_path(db);
	// Under sudo a link here would make and later chown a file of the user's
	// choosing.
	let f = OpenOptions::new()
		.create(true)
		.truncate(false)
		.write(true)
		.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
		.open(&p)
		.map_err(|e| match e.raw_os_error() {
			Some(libc::ELOOP) => format!("{}: is a symbolic link; refused", p.display()),
			_ => format!("{}: {e}", p.display()),
		})?;
	if !f.metadata().is_ok_and(|m| m.file_type().is_file()) {
		return Err(format!("{}: not a regular file; refused", p.display()));
	}
	// SAFETY: f is open for the length of the call.
	if unsafe { libc::flock(f.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
		let e = io::Error::last_os_error();
		if e.kind() == io::ErrorKind::WouldBlock {
			return Err(format!(
				"{} is locked; another scan is using this database",
				p.display()
			));
		}
		return Err(format!("{}: can't lock: {e}", p.display()));
	}
	Ok(f)
}

/// This box's hostname, or empty.
pub fn host() -> String {
	fs::read_to_string("/proc/sys/kernel/hostname")
		.map(|s| s.trim().to_string())
		.unwrap_or_default()
}

/// Hand the files back to whoever ran this through sudo, so reports and
/// queries need no root. The WAL files are only there when leaving WAL mode
/// failed.
pub fn give_back(db: &Path) {
	let id = |k| std::env::var(k).ok().and_then(|v| v.parse::<u32>().ok());
	let (Some(uid), Some(gid)) = (id("SUDO_UID"), id("SUDO_GID")) else {
		return;
	};
	for (p, e) in hand_over(db, uid, gid) {
		err!(
			"warning: can't give {} back to uid {uid}: {e}",
			crate::util::show_path(&p)
		);
	}
}

// The files that couldn't be handed over. The WAL files are usually gone, so a
// missing one doesn't count.
fn hand_over(db: &Path, uid: u32, gid: u32) -> Vec<(PathBuf, io::Error)> {
	let with = |sfx: &str| {
		let mut s = db.as_os_str().to_owned();
		s.push(sfx);
		PathBuf::from(s)
	};
	let mut failed = Vec::new();
	for p in [db.to_path_buf(), lock_path(db), with("-wal"), with("-shm")] {
		// By fd, so a link swapped in at the name isn't followed.
		let f = match OpenOptions::new()
			.read(true)
			.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_NOCTTY)
			.open(&p)
		{
			Ok(f) => f,
			Err(e) if e.kind() == io::ErrorKind::NotFound => continue,
			Err(e) if e.raw_os_error() == Some(libc::ELOOP) => {
				failed.push((p, io::Error::other("it's a symbolic link")));
				continue;
			}
			Err(e) => {
				failed.push((p, e));
				continue;
			}
		};
		let given = match f.metadata() {
			Ok(m) if m.file_type().is_file() => std::os::unix::fs::fchown(&f, Some(uid), Some(gid)),
			Ok(_) => Err(io::Error::other("not a regular file")),
			Err(e) => Err(e),
		};
		if let Err(e) = given {
			failed.push((p, e));
		}
	}
	failed
}

/// The `scan` command.
pub fn run(o: &Opts, stop: &Arc<AtomicBool>) -> Result<i32, String> {
	let Plan {
		groups: planned,
		dropped,
		unresolved,
		mounts,
	} = plan(&o.roots, &o.threads)?;
	for d in &dropped {
		err!("skipping root {d}");
	}
	for (r, e) in &unresolved {
		err!("skipping root {}: {e}", r.display());
	}
	if planned.is_empty() {
		return Err("nothing to scan".into());
	}
	// Anything that can fail goes before begin(), or the run stays marked
	// running (backlog ...852).
	let hands_off = hands_off(&mounts, &planned)?;
	let db_path = canonical_db(&o.db)?;
	let _lock = lock(&db_path, &mounts)?;
	let conn = db::open_rw(&db_path)?;
	let open_misses = db::open_misses(&conn)?;

	let started = now_us();
	let Resumed {
		id: run_id,
		cutoff_us,
		started_us: run_started,
		summary: earlier,
	} = begin(&conn, o, &roots_key(&planned), started)?;

	let faults = Arc::new(Faults::default());
	let (tx, rx) = sync_channel::<Msg>(65536);
	let writer = {
		let (faults, stop) = (faults.clone(), stop.clone());
		std::thread::spawn(move || db::writer(conn, run_id, &rx, move || faults.halt(&stop)))
	};

	let shared = Arc::new(Shared {
		stop: stop.clone(),
		faults: faults.clone(),
		run_id,
		// Anything this run already read counts as fresh, even when --since
		// is later than when the run began.
		cutoff_us: cutoff_us.min(run_started),
		db: db_path.clone(),
		excludes: o
			.excludes
			.iter()
			.map(|p| fs::canonicalize(p).unwrap_or_else(|_| p.clone()))
			.collect(),
		no_xattr: o
			.no_xattr
			.iter()
			.map(|p| fs::canonicalize(p).unwrap_or_else(|_| p.clone()))
			.collect(),
		mount_points: mounts::mount_points(mounts),
		no_write_devs: hands_off.values().map(|(d, _)| *d).collect(),
		// A quick check leaves ctimes alone.
		write_xattrs: o.write_xattrs && o.mode == Mode::Full,
		rmlint: o.rmlint,
		mode: o.mode,
		open_misses,
		tx,
	});
	// Not read, so not clean either.
	for (r, e) in unresolved {
		event(&shared, Kind::DirError, &r, e);
	}
	let groups = groups(planned, &hands_off);

	let mut handles = Vec::new();
	for g in &groups {
		let g = g.clone();
		let sh = shared.clone();
		handles.push(std::thread::spawn(move || run_group(&g, &sh)));
	}
	drop(shared);

	let t0 = Instant::now();
	watch(&groups, o.progress_secs, t0);
	for h in handles {
		// run_group catches its workers' panics; this is in case it can't.
		if h.join().is_err() {
			faults.add(stop, "a group panicked".into());
		}
	}
	let (conn, written) = writer
		.join()
		.map_err(|_| "the database writer panicked".to_string())?;
	let mut why = std::mem::take(&mut *locked(&faults.why));
	why.extend(written.err());
	let part = Part {
		run_id,
		started_us: started,
		earlier,
		groups: &groups,
		t0,
	};
	finish(conn, &part, why, stop.load(Relaxed), &db_path)
}

// Picks up the run to resume, or starts a new one, and marks it running. A new
// run is its own first part.
fn begin(
	conn: &rusqlite::Connection,
	o: &Opts,
	roots: &[u8],
	started: i64,
) -> Result<Resumed, String> {
	let e = |e: rusqlite::Error| format!("database: {e}");
	let r = if o.resume {
		pick_resume(conn, roots, o.mode)?
	} else {
		// Killed, since the lock is held. See design.md, Runs and exit codes.
		conn.execute(
			"UPDATE runs SET status = ?1 WHERE status = ?2",
			[RunStatus::Killed, RunStatus::Running],
		)
		.map_err(e)?;
		// A verify reads every known file again, however fresh.
		let cutoff = match o.mode {
			Mode::Verify => started,
			Mode::Full => o.since.unwrap_or_else(|| local_midnight_us(started)),
		};
		conn.execute(
			"INSERT INTO runs (started_us, cutoff_us, status, host, args, roots, verify) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
			rusqlite::params![
				started,
				cutoff,
				RunStatus::Running,
				host(),
				o.args,
				roots,
				o.mode == Mode::Verify
			],
		)
		.map_err(e)?;
		Resumed {
			id: conn.last_insert_rowid(),
			cutoff_us: cutoff,
			started_us: started,
			summary: None,
		}
	};
	conn.execute(
		"UPDATE runs SET status = ?1 WHERE id = ?2",
		rusqlite::params![RunStatus::Running, r.id],
	)
	.map_err(e)?;
	if o.mode == Mode::Verify {
		out!("run {}: rereading files with a known checksum", r.id);
	} else {
		out!(
			"run {}: files checksummed since {} are skipped",
			r.id,
			fmt_local(r.cutoff_us)
		);
	}
	Ok(r)
}

// Roots on NTFS, APFS or HFS+, with their device and filesystem type.
fn hands_off(
	mounts: &[mounts::Mount],
	groups: &[Planned],
) -> Result<BTreeMap<PathBuf, (u64, String)>, String> {
	let mut out = BTreeMap::new();
	for r in groups.iter().flat_map(|g| &g.roots) {
		if let Some(t) = mounts::hands_off_at(mounts, r) {
			let dev = fs::metadata(r)
				.map_err(|e| format!("{}: {e}", r.display()))?
				.dev();
			out.insert(r.clone(), (dev, t));
		}
	}
	Ok(out)
}

fn groups(planned: Vec<Planned>, hands_off: &BTreeMap<PathBuf, (u64, String)>) -> Vec<Arc<Group>> {
	let groups: Vec<Arc<Group>> = planned
		.into_iter()
		.map(|p| {
			Arc::new(Group {
				name: p.name,
				roots: p.roots,
				threads: p.threads,
				stats: Stats::default(),
				done: AtomicBool::new(false),
			})
		})
		.collect();
	for g in &groups {
		out!("group {} with {} worker(s):", g.name, g.threads);
		for r in &g.roots {
			if let Some((_, t)) = hands_off.get(r) {
				out!("\t{} ({t}, no attributes written)", r.display());
			} else {
				out!("\t{}", r.display());
			}
		}
	}
	groups
}

fn watch(groups: &[Arc<Group>], progress_secs: u64, t0: Instant) {
	let mut last = Instant::now();
	while !groups.iter().all(|g| g.done.load(Relaxed)) {
		std::thread::sleep(Duration::from_millis(200));
		if last.elapsed() >= Duration::from_secs(progress_secs.max(1)) {
			last = Instant::now();
			let secs = t0.elapsed().as_secs_f64().max(1.0);
			for g in groups {
				let rate = g.stats.bytes.load(Relaxed) as f64 / secs;
				out!(
					"[{}] {} {}/s | {}",
					fmt_local(now_us()),
					g.name,
					human_bytes(rate as u64),
					g.stats.line()
				);
			}
		}
	}
}

// This part of a run, from its start to its summary.
struct Part<'a> {
	run_id: i64,
	started_us: i64,
	earlier: Option<String>,
	groups: &'a [Arc<Group>],
	t0: Instant,
}

fn finish(
	conn: rusqlite::Connection,
	p: &Part,
	mut why: Vec<String>,
	stopped: bool,
	db_path: &Path,
) -> Result<i32, String> {
	let run_id = p.run_id;
	// The stored summary keeps every part's lines; the output shows this
	// part's. The events line is the whole run's either way.
	let mut part = String::new();
	for g in p.groups {
		let _ = writeln!(part, "{}: {}", g.name, g.stats.line());
	}
	let counts = run_events(&conn, run_id)
		.map_err(|x| why.push(format!("database: {x}")))
		.ok();
	part.push_str(&events_line(counts.as_deref()));
	let mut summary = String::new();
	if let Some(prev) = &p.earlier {
		for l in prev.lines().filter(|l| !l.starts_with(EVENTS_LINE)) {
			summary.push_str(l);
			summary.push('\n');
		}
		let _ = writeln!(summary, "resumed {}", fmt_local(p.started_us));
	}
	summary.push_str(&part);
	let mut status = if !why.is_empty() {
		RunStatus::Failed
	} else if stopped {
		RunStatus::Stopped
	} else {
		RunStatus::Done
	};
	if let Err(x) = conn.execute(
		"UPDATE runs SET status = ?1, finished_us = ?2, summary = ?3 WHERE id = ?4",
		rusqlite::params![status, now_us(), summary, run_id],
	) {
		why.push(format!("database: {x}"));
		status = RunStatus::Failed;
	}
	// Everything is committed by now, so this can't change the result.
	if let Err(x) = db::close_rw(conn) {
		err!(
			"warning: {} is left in WAL mode ({x}). Something else likely has it open. The next run puts it back.",
			db_path.display()
		);
	}
	give_back(db_path);

	out!(
		"run {run_id} {} after {}s\n{part}",
		status.text(),
		p.t0.elapsed().as_secs()
	);
	if !why.is_empty() {
		why.dedup();
		out!("Fix the cause, then continue it with the same command plus --resume.");
		return Err(why.join("; "));
	}
	if stopped {
		out!("Continue it with the same command plus --resume.");
	}
	// 2 adds to the others, so a stop says what was found before it.
	Ok(exit_bits(counts.as_deref().unwrap_or_default()) | if stopped { 2 } else { 0 })
}

struct DoneOnDrop<'a>(&'a AtomicBool);

impl Drop for DoneOnDrop<'_> {
	fn drop(&mut self) {
		self.0.store(true, Relaxed);
	}
}

// A panic is a fault, not a hang: it stops the run and marks it failed.
fn guarded(sh: &Shared, who: &str, f: impl FnOnce()) {
	if std::panic::catch_unwind(std::panic::AssertUnwindSafe(f)).is_err() {
		sh.faults.add(&sh.stop, format!("{who} panicked"));
	}
}

fn run_group(g: &Group, sh: &Shared) {
	let _done = DoneOnDrop(&g.done);
	let (jtx, jrx) = sync_channel::<Job>(1024);
	// Only the workers hold the receiver, so once the last one is gone the
	// walk's send fails, rather than waiting on a full queue forever.
	let jrx = Arc::new(Mutex::new(jrx));
	let links = Links::default();
	std::thread::scope(|s| {
		for _ in 0..g.threads {
			let jrx = jrx.clone();
			let links = &links;
			s.spawn(move || guarded(sh, "a worker", || hasher(g, sh, &jrx, links)));
		}
		drop(jrx);
		guarded(sh, "a folder walk", || {
			let look = match db::open_ro(&sh.db) {
				Ok(c) => c,
				Err(e) => return sh.faults.add(&sh.stop, e),
			};
			for r in &g.roots {
				if sh.stop.load(Relaxed) {
					break;
				}
				walk(r, sh, &g.stats, &look, &jtx);
			}
		});
		drop(jtx);
	});
}

fn event(sh: &Shared, kind: Kind, path: &Path, detail: String) {
	_ = send(
		sh,
		Msg::Event {
			kind,
			path: path.as_os_str().as_bytes().to_vec(),
			detail,
		},
	);
}

// The database, its journal files and its lock. Anything else that only
// starts with its name is read like any other file.
fn excluded(sh: &Shared, p: &Path) -> bool {
	let own = p.parent() == sh.db.parent()
		&& p.file_name().zip(sh.db.file_name()).is_some_and(|(n, d)| {
			n.as_bytes()
				.strip_prefix(d.as_bytes())
				.is_some_and(|sfx| matches!(sfx, b"" | b"-wal" | b"-shm" | b"-journal" | b".lock"))
		});
	own || sh.excludes.iter().any(|x| p.starts_with(x))
}

// git looks for `.git` up from the work folder until the filesystem changes,
// so this does too. The root's own folder is the walk's to check.
fn git_tree_above(root: &Path, dev: u64) -> bool {
	root.ancestors()
		.skip(1)
		.take_while(|a| fs::symlink_metadata(a).is_ok_and(|m| m.dev() == dev))
		.any(|a| fs::symlink_metadata(a.join(".git")).is_ok())
}

// A dead writer means nothing more can be recorded, so stop rather than read
// files for nothing.
fn send(sh: &Shared, m: Msg) -> bool {
	if sh.tx.send(m).is_err() {
		sh.faults.halt(&sh.stop);
		return false;
	}
	true
}

fn lock_path(db: &Path) -> PathBuf {
	let mut s = db.as_os_str().to_owned();
	s.push(".lock");
	PathBuf::from(s)
}

/// The database may not exist yet, so only its folder can be resolved.
pub fn canonical_db(db: &Path) -> Result<PathBuf, String> {
	crate::util::canonical_name(db)
}

// A folder with more files than this is queued in parts, each in inode order,
// so its list doesn't grow without end.
const FILES_BATCH: usize = 1 << 20;

// Subfolders still to walk, last name first, so each pop frees one.
struct Frame {
	dir: PathBuf,
	in_git: bool,
	subdirs: Vec<Box<OsStr>>,
}

// The workers are gone.
struct Closed;

// Depth first, files before folders. Folders go in name order; files go in
// inode order, which on most filesystems is close to the order on disk.
fn walk(
	root: &Path,
	sh: &Shared,
	stats: &Stats,
	look: &rusqlite::Connection,
	jobs: &SyncSender<Job>,
) {
	let root = match Root::open(root) {
		Ok(r) => Arc::new(r),
		// A root gone since the plan wasn't read either.
		Err(e) => {
			stats.other_err.fetch_add(1, Relaxed);
			event(sh, Kind::DirError, root, e.to_string());
			return;
		}
	};
	let mut stack: Vec<Frame> = Vec::new();
	let mut next = Some((root.path.clone(), git_tree_above(&root.path, root.dev)));
	while !sh.stop.load(Relaxed) {
		if let Some((dir, git_above)) = next.take() {
			match list_dir(&root, dir, git_above, sh, stats, look, jobs) {
				Ok(Some(f)) => stack.push(f),
				Ok(None) => {}
				Err(Closed) => return,
			}
		}
		let Some(top) = stack.last_mut() else {
			return;
		};
		match top.subdirs.pop() {
			Some(name) => next = Some((top.dir.join(&*name), top.in_git)),
			None => _ = stack.pop(),
		}
	}
}

fn list_dir(
	root: &Arc<Root>,
	dir: PathBuf,
	git_above: bool,
	sh: &Shared,
	stats: &Stats,
	look: &rusqlite::Connection,
	jobs: &SyncSender<Job>,
) -> Result<Option<Frame>, Closed> {
	let opened = root
		.open_at(root.rel(&dir), libc::O_RDONLY | libc::O_DIRECTORY)
		.and_then(|f| Ok((f.metadata()?.dev(), f)));
	let list = match opened.and_then(|(dev, f)| Ok((dev, beneath::List::new(f)?))) {
		// A btrfs subvolume, or something mounted since the scan began. The
		// mount table only knows what was there at the start.
		Ok((dev, _)) if dev != root.dev => return Ok(None),
		Ok((_, l)) => l,
		Err(e) if beneath::moved(&e) => return Ok(None),
		Err(e) => {
			stats.other_err.fetch_add(1, Relaxed);
			event(sh, Kind::DirError, &dir, e.to_string());
			return Ok(None);
		}
	};
	// Asked first, since a big folder's files are queued before the listing
	// ends.
	let mut in_git = git_above || list.has(".git");
	let mut files: Vec<(u64, PathBuf)> = Vec::new();
	let mut subdirs = Vec::new();
	for (seen, ent) in list.enumerate() {
		// The rest of the folder goes unread after an error. An EIO in a
		// damaged folder block is the case.
		let ent = match ent {
			Ok(ent) => ent,
			Err(e) => {
				stats.other_err.fetch_add(1, Relaxed);
				event(
					sh,
					Kind::DirError,
					&dir,
					format!("{e}, after {seen} entries; the rest weren't read"),
				);
				break;
			}
		};
		if &*ent.name == ".git" {
			in_git = true;
		}
		let kind = match ent.kind {
			Ok(k) => k,
			Err(e) if e.kind() == io::ErrorKind::NotFound => continue,
			Err(e) => {
				stats.other_err.fetch_add(1, Relaxed);
				event(sh, Kind::StatError, &dir.join(&*ent.name), e.to_string());
				continue;
			}
		};
		let is_dir = match kind {
			beneath::Kind::Dir => true,
			beneath::Kind::File => false,
			beneath::Kind::Other => continue,
		};
		if is_dir && &*ent.name == ".zfs" && sh.mount_points.get(&dir).is_some_and(|t| t == "zfs") {
			continue;
		}
		let p = dir.join(&*ent.name);
		if sh.mount_points.contains_key(&p) || excluded(sh, &p) {
			continue;
		}
		if is_dir {
			subdirs.push(ent.name);
			continue;
		}
		files.push((ent.ino, p));
		if files.len() >= FILES_BATCH {
			queue(root, &mut files, in_git, sh, stats, look, jobs)?;
		}
	}
	queue(root, &mut files, in_git, sh, stats, look, jobs)?;
	subdirs.sort_unstable_by(|a, b| b.cmp(a));
	Ok(Some(Frame {
		dir,
		in_git,
		subdirs,
	}))
}

// Looked up a batch at a time, each in its own read transaction, which ends
// before the batch waits on the queue so the writer can checkpoint.
const LOOKUP_BATCH: usize = 256;

fn queue(
	root: &Arc<Root>,
	files: &mut Vec<(u64, PathBuf)>,
	in_git: bool,
	sh: &Shared,
	stats: &Stats,
	look: &rusqlite::Connection,
	jobs: &SyncSender<Job>,
) -> Result<(), Closed> {
	files.sort_unstable();
	let mut rest = files.drain(..).map(|(_, p)| p);
	loop {
		let batch: Vec<PathBuf> = rest.by_ref().take(LOOKUP_BATCH).collect();
		if batch.is_empty() {
			return Ok(());
		}
		let keys: Vec<&[u8]> = batch.iter().map(|p| p.as_os_str().as_bytes()).collect();
		let priors = db::lookup_each(look, &keys);
		for (path, prior) in batch.into_iter().zip(priors) {
			let prior = match prior {
				Ok(p) => p,
				Err(e) => {
					stats.other_err.fetch_add(1, Relaxed);
					event(sh, Kind::DbError, &path, e);
					continue;
				}
			};
			let job = Job {
				path,
				in_git,
				root: root.clone(),
				prior,
			};
			jobs.send(job).map_err(|_| Closed)?;
		}
	}
}

// A size and time other than the claimant's mean the file changed between names.
#[derive(Clone, Copy)]
struct LinkVal {
	bytes: i64,
	mtime_us: i64,
	sums: Sums,
}

// Each entry counts down the names still to come and goes when it hits zero,
// so a backup tree full of hard links doesn't keep every inode in memory.
type LinkEntry = Option<(LinkVal, u64)>;

// A name outside the roots or excluded never comes to count down, so only the
// newest results are kept. A later name of an older one is read again.
const LINKS_KEPT: usize = 1 << 18;

// One read per hard-linked inode, or one name's xattr write moves the ctime
// under another's read. See design.md, Reading files.
#[derive(Default)]
struct Links {
	map: Mutex<LinkMap>,
	cv: Condvar,
}

#[derive(Default)]
struct LinkMap {
	entries: HashMap<(u64, u64), LinkEntry>,
	// Filled keys, oldest first. A key can be here twice, or after its
	// entry went; dropping a newer entry early only costs a read.
	filled: VecDeque<(u64, u64)>,
}

impl LinkMap {
	fn fill(&mut self, key: (u64, u64), v: LinkVal, others: u64) {
		self.entries.insert(key, Some((v, others)));
		self.filled.push_back(key);
		while self.filled.len() > LINKS_KEPT {
			let Some(old) = self.filled.pop_front() else {
				break;
			};
			if matches!(self.entries.get(&old), Some(Some(_))) {
				self.entries.remove(&old);
			}
		}
	}

	fn count_down(&mut self, key: (u64, u64)) {
		if let Some(Some((_, left))) = self.entries.get_mut(&key) {
			*left = left.saturating_sub(1);
			if *left == 0 {
				self.entries.remove(&key);
			}
		}
	}
}

enum Claim<'a> {
	Done(LinkVal),
	Mine(ClaimGuard<'a>),
}

struct ClaimGuard<'a> {
	links: &'a Links,
	key: (u64, u64),
	others: u64,
}

impl ClaimGuard<'_> {
	fn fill(self, v: LinkVal) {
		locked(&self.links.map).fill(self.key, v, self.others);
	}
}

impl Drop for ClaimGuard<'_> {
	// Unfilled means the read failed or was stopped; let the next name try.
	fn drop(&mut self) {
		let mut m = locked(&self.links.map);
		if matches!(m.entries.get(&self.key), Some(None)) {
			m.entries.remove(&self.key);
		}
		self.links.cv.notify_all();
	}
}

impl Links {
	fn claim(&self, key: (u64, u64), nlink: u64, bytes: i64, mt: i64) -> Claim<'_> {
		let mut m = locked(&self.map);
		loop {
			match m.entries.get(&key) {
				Some(Some((v, _))) if v.bytes == bytes && v.mtime_us == mt => {
					let v = *v;
					m.count_down(key);
					return Claim::Done(v);
				}
				Some(None) => m = self.cv.wait(m).unwrap_or_else(PoisonError::into_inner),
				_ => {
					m.entries.insert(key, None);
					return Claim::Mine(ClaimGuard {
						links: self,
						key,
						others: nlink.saturating_sub(1),
					});
				}
			}
		}
	}

	// A name skipped without a claim still counts as seen.
	fn passed(&self, md: &fs::Metadata) {
		if md.nlink() > 1 {
			locked(&self.map).count_down((md.dev(), md.ino()));
		}
	}
}

fn hasher(g: &Group, sh: &Shared, jobs: &Mutex<Receiver<Job>>, links: &Links) {
	let mut w = Worker {
		g,
		sh,
		links,
		buf: vec![0u8; 1 << 20],
		xattr_fail_logged: 0,
	};
	loop {
		let Ok(job) = locked(jobs).recv() else {
			return;
		};
		if sh.stop.load(Relaxed) {
			continue;
		}
		w.one_file(&job, job.prior.as_ref());
	}
}

/// The mtime in microseconds, as stored.
pub fn mtime_us(md: &fs::Metadata) -> i64 {
	md.mtime() * 1_000_000 + md.mtime_nsec() / 1000
}

/// rmlint's time, as it works it out.
pub fn mtime_s(md: &fs::Metadata) -> f64 {
	md.mtime() as f64 + md.mtime_nsec() as f64 / 1e9
}

/// Opens a path to read, without following a link or moving its atime.
pub fn open_noatime(p: &Path) -> io::Result<File> {
	let base = libc::O_NOFOLLOW | libc::O_NONBLOCK;
	beneath::with_noatime(|extra| {
		OpenOptions::new()
			.read(true)
			.custom_flags(base | extra)
			.open(p)
	})
}

/// What one read of a file came to.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Sums {
	pub b3: [u8; 32],
	pub b2b: Option<[u8; 64]>,
}

/// Why a read of a file gave no sums.
#[derive(Debug)]
pub enum ReadFail {
	Stopped,
	Io { err: io::Error, at: u64 },
	Unstable,
}

/// `O_DIRECT` wants the buffer, offset and length on the device's block size.
const DIRECT_ALIGN: usize = 4096;
// Below this a plain read and its drops cost less sys CPU than going direct
// (2026102809554675).
const DIRECT_MIN: u64 = 64 << 10;

/// Turns `O_DIRECT` on or off for an open fd. False if the filesystem won't.
fn set_direct(fd: RawFd, on: bool) -> bool {
	// SAFETY: fd is open, and F_GETFL/F_SETFL only touch its status flags.
	unsafe {
		let flags = libc::fcntl(fd, libc::F_GETFL);
		if flags < 0 {
			return false;
		}
		let want = if on {
			flags | libc::O_DIRECT
		} else {
			flags & !libc::O_DIRECT
		};
		want == flags || libc::fcntl(fd, libc::F_SETFL, want) == 0
	}
}

/// Reads the whole file from the start, past the page cache where the
/// filesystem allows it. Its cached pages are dropped first either way, so a
/// scribble in the page cache isn't taken for what's on disk. ZFS ignores the
/// advice; see design.md, Reading files.
pub fn read_sums(
	file: &File,
	before: &fs::Metadata,
	want_b2b: bool,
	buf: &mut [u8],
	stop: &AtomicBool,
	read_bytes: &AtomicU64,
) -> Result<Sums, ReadFail> {
	let fd = file.as_raw_fd();
	// SAFETY: fd is open, and fadvise only changes cache hints.
	unsafe {
		libc::posix_fadvise(fd, 0, 0, libc::POSIX_FADV_DONTNEED);
		libc::posix_fadvise(fd, 0, 0, libc::POSIX_FADV_SEQUENTIAL);
	}
	// Reading around the page cache costs a fraction of filling it and then
	// dropping it again (2026102316421705). Where the filesystem won't, or
	// balks mid-file, or the file is small, it's a plain read and the drops
	// above and below do it.
	let lead = buf.as_ptr().align_offset(DIRECT_ALIGN).min(buf.len());
	let aligned_len = (buf.len() - lead) & !(DIRECT_ALIGN - 1);
	let mut direct =
		!cfg!(miri) && aligned_len > 0 && before.len() >= DIRECT_MIN && set_direct(fd, true);
	let mut b3 = blake3::Hasher::new();
	let mut b2b = want_b2b.then(blake2b_simd::State::new);
	let mut total: u64 = 0;
	let outcome = loop {
		if stop.load(Relaxed) {
			break Err(ReadFail::Stopped);
		}
		let chunk = if direct {
			&mut buf[lead..lead + aligned_len]
		} else {
			&mut *buf
		};
		match file.read_at(chunk, total) {
			Ok(0) => break Ok(()),
			Ok(n) => {
				b3.update(&chunk[..n]);
				if let Some(h) = b2b.as_mut() {
					h.update(&chunk[..n]);
				}
				total += n as u64;
				// Per block, so progress moves through a big file.
				read_bytes.fetch_add(n as u64, Relaxed);
			}
			Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
			Err(e)
				if direct && matches!(e.raw_os_error(), Some(libc::EINVAL | libc::EOPNOTSUPP)) =>
			{
				set_direct(fd, false);
				direct = false;
			}
			Err(err) => break Err(ReadFail::Io { err, at: total }),
		}
	};
	if direct {
		set_direct(fd, false);
	}
	// SAFETY: fd is open, and fadvise only changes cache hints.
	unsafe { libc::posix_fadvise(fd, 0, 0, libc::POSIX_FADV_DONTNEED) };
	outcome?;
	let after = file
		.metadata()
		.map_err(|err| ReadFail::Io { err, at: total })?;
	if after.len() != before.len()
		|| mtime_us(&after) != mtime_us(before)
		|| after.ctime() != before.ctime()
		|| after.ctime_nsec() != before.ctime_nsec()
		|| total != before.len()
	{
		return Err(ReadFail::Unstable);
	}
	Ok(Sums {
		b3: *b3.finalize().as_bytes(),
		b2b: b2b.map(|h| *h.finalize().as_array()),
	})
}

fn report_fail(sh: &Shared, st: &Stats, path: &Path, fail: ReadFail) {
	match fail {
		ReadFail::Stopped => {}
		// The driver can't decode it, like ntfs3 with a Windows-compressed
		// or EFS file. Nothing was read, so nothing's known.
		ReadFail::Io { err, at } if err.raw_os_error() == Some(libc::EOPNOTSUPP) => {
			st.other_err.fetch_add(1, Relaxed);
			event(sh, Kind::Unsupported, path, format!("{err} at byte {at}"));
		}
		// On ZFS an EIO here is a block that failed its checksum with no
		// good copy left. That is the same news as a mismatch.
		ReadFail::Io { err, at } => {
			st.read_err.fetch_add(1, Relaxed);
			event(sh, Kind::ReadError, path, format!("{err} at byte {at}"));
		}
		ReadFail::Unstable => {
			st.unstable.fetch_add(1, Relaxed);
			event(sh, Kind::Unstable, path, "changed while being read".into());
		}
	}
}

// What a file read as before, from each place that remembers. Only records
// taken at the file's current size and time count.
struct Refs<'a> {
	xattr: Option<[u8; 32]>,
	xattr_date: Option<i64>,
	b2b: Option<[u8; 64]>,
	db: Option<&'a Prior>,
}

type Miss = (Kind, String);

impl<'a> Refs<'a> {
	fn new(onfile: &OnFile, prior: Option<&'a Prior>, md: &fs::Metadata) -> Refs<'a> {
		let (bytes, mt) = (md.len() as i64, mtime_us(md));
		Refs {
			xattr: onfile.b3_current(bytes, mt),
			xattr_date: onfile.b3_date_us,
			b2b: onfile.b2b_current(mtime_s(md)),
			db: prior.filter(|p| p.bytes == bytes && p.mtime_us == mt),
		}
	}

	fn misses(&self, s: &Sums) -> Vec<Miss> {
		let mut out = Vec::new();
		if let Some(stored) = self.xattr.filter(|d| *d != s.b3) {
			let when = self.xattr_date.map_or_else(|| "unknown".into(), fmt_local);
			out.push((
				Kind::XattrMismatch,
				format!(
					"on file {} (taken {when}), read now {}",
					b64u_encode(&stored),
					b64u_encode(&s.b3)
				),
			));
		}
		if let (Some(stored), Some(now)) = (self.b2b, s.b2b)
			&& stored != now
		{
			out.push((
				Kind::RmlintMismatch,
				format!("on file {}, read now {}", hex(&stored), hex(&now)),
			));
		}
		if let Some(p) = self.db.filter(|p| p.b3 != s.b3) {
			out.push((
				Kind::DbMismatch,
				format!(
					"database {} (taken {}), read now {}",
					b64u_encode(&p.b3),
					fmt_local(p.hashed_us),
					b64u_encode(&s.b3)
				),
			));
		}
		out
	}

	// Only for a read that agreed with all of them.
	fn tally(&self, s: &Sums, st: &Stats) {
		if self.xattr.is_some() {
			st.b3_ok.fetch_add(1, Relaxed);
		}
		if self.b2b.is_some() && s.b2b.is_some() {
			st.b2b_ok.fetch_add(1, Relaxed);
		}
		if self.db.is_some() {
			st.db_ok.fetch_add(1, Relaxed);
		}
	}
}

#[derive(Debug)]
enum Verdict {
	Clean(Sums),
	// Wrong on the first read, right on a second one with the cache dropped.
	CacheOnly {
		first: Sums,
		second: Sums,
	},
	Changed {
		sums: Sums,
		misses: Vec<Miss>,
		note: String,
	},
}

// A read that disagrees with what's stored is read once more before it's
// believed, to tell a fault in memory from one on disk.
fn judge(
	refs: &Refs,
	first: Sums,
	reread: impl FnOnce() -> Result<Sums, ReadFail>,
) -> Result<Verdict, ReadFail> {
	if refs.misses(&first).is_empty() {
		return Ok(Verdict::Clean(first));
	}
	let second = reread()?;
	let misses = refs.misses(&second);
	if misses.is_empty() {
		return Ok(Verdict::CacheOnly { first, second });
	}
	let note = if second == first {
		"; same on a second read".to_string()
	} else {
		format!("; the first read gave {}", b64u_encode(&first.b3))
	};
	Ok(Verdict::Changed {
		sums: second,
		misses,
		note,
	})
}

// A mismatch leaves every stored checksum as it was, so each later run reports
// the file again until it's fixed or accepted.
fn keep(
	sh: &Shared,
	st: &Stats,
	path: &Path,
	prior: Option<&Prior>,
	misses: Vec<Miss>,
	note: &str,
) {
	for (kind, detail) in misses {
		st.mismatch.fetch_add(1, Relaxed);
		event(sh, kind, path, format!("{detail}{note}"));
	}
	if let Some(p) = prior.filter(|p| p.seen_run != sh.run_id) {
		send(sh, Msg::Seen(p.id));
	}
}

fn hashed_msg(path: &[u8], s: &Sums, md: &fs::Metadata, hashed_us: i64) -> Msg {
	Msg::Hashed(Box::new(Hashed {
		path: path.to_vec(),
		b3: s.b3,
		b2b: s.b2b,
		bytes: md.len() as i64,
		mtime_us: mtime_us(md),
		ino: md.ino() as i64,
		hashed_us,
	}))
}

// One per hashing thread, so the buffer and the counter need no lock.
struct Worker<'a> {
	g: &'a Group,
	sh: &'a Shared,
	links: &'a Links,
	buf: Vec<u8>,
	xattr_fail_logged: u32,
}

impl<'a> Worker<'a> {
	fn one_file(&mut self, job: &Job, prior: Option<&Prior>) {
		let rel = job.root.rel(&job.path);
		let Some(md) = self.stat(job, rel) else {
			return;
		};
		if self.judged_already(job, prior, &md) {
			return;
		}
		let Some((file, before)) = self.open(job, rel) else {
			return;
		};
		let fd = file.as_raw_fd();
		let onfile = OnFile::read(fd);
		let refs = Refs::new(&onfile, prior, &before);
		if self.skip_unread(job, prior, &refs, &onfile, &before) {
			return;
		}
		let Some((sums, claim)) = self.read_judged(job, prior, &refs, &file, &before) else {
			return;
		};
		refs.tally(&sums, &self.g.stats);

		let sh = self.sh;
		let hashed_us = now_us();
		if let Some(c) = claim {
			c.fill(LinkVal {
				bytes: before.len() as i64,
				mtime_us: mtime_us(&before),
				sums,
			});
		}
		// Once nothing more can be recorded, an attribute would vouch for a read
		// the database never got.
		let pbytes = job.path.as_os_str().as_bytes();
		if !send(sh, hashed_msg(pbytes, &sums, &before, hashed_us)) || sh.faults.any.load(Relaxed) {
			return;
		}
		self.write_attrs(job, &refs, &sums, fd, &before, hashed_us);
	}

	fn stat(&self, job: &Job, rel: &Path) -> Option<fs::Metadata> {
		let md = match job
			.root
			.open_at(rel, libc::O_PATH)
			.and_then(|f| f.metadata())
		{
			Ok(m) if m.file_type().is_file() => m,
			Ok(_) => return None,
			Err(e) if beneath::moved(&e) => return None,
			Err(e) => {
				self.g.stats.other_err.fetch_add(1, Relaxed);
				event(self.sh, Kind::StatError, &job.path, e.to_string());
				return None;
			}
		};
		self.g.stats.files.fetch_add(1, Relaxed);
		Some(md)
	}

	// design.md, "Skipping", rows `db-fresh`, `db-future`, `db-mismatch` and
	// `resume-seen`.
	fn judged_already(&self, job: &Job, prior: Option<&Prior>, md: &fs::Metadata) -> bool {
		let (sh, st) = (self.sh, &self.g.stats);
		let Some(p) = prior else {
			return false;
		};
		let fresh = || {
			(sh.cutoff_us..=now_us()).contains(&p.hashed_us)
				&& !sh.open_misses.contains(job.path.as_os_str().as_bytes())
		};
		// An earlier part of this run already judged it, mismatch or not, so
		// a resumed run doesn't read and report it twice.
		if (p.seen_run == sh.run_id || fresh())
			&& p.bytes == md.len() as i64
			&& p.mtime_us == mtime_us(md)
			&& p.ino == md.ino() as i64
		{
			if p.seen_run != sh.run_id {
				send(sh, Msg::Seen(p.id));
			}
			st.skip_db.fetch_add(1, Relaxed);
			self.links.passed(md);
			return true;
		}
		false
	}

	fn open(&self, job: &Job, rel: &Path) -> Option<(File, fs::Metadata)> {
		let (sh, st, path) = (self.sh, &self.g.stats, &job.path);
		let file = match job.root.open_read(rel) {
			Ok(f) => f,
			Err(e) if beneath::moved(&e) => return None,
			Err(e) => {
				st.other_err.fetch_add(1, Relaxed);
				event(sh, Kind::OpenError, path, e.to_string());
				return None;
			}
		};
		match file.metadata() {
			Ok(m) if m.file_type().is_file() => Some((file, m)),
			Ok(_) => None,
			Err(e) => {
				st.other_err.fetch_add(1, Relaxed);
				event(sh, Kind::StatError, path, e.to_string());
				None
			}
		}
	}

	fn skip_unread(
		&self,
		job: &Job,
		prior: Option<&Prior>,
		refs: &Refs,
		onfile: &OnFile,
		before: &fs::Metadata,
	) -> bool {
		let (sh, st) = (self.sh, &self.g.stats);
		// Nothing stored at this size and time to check against: new or edited.
		// The next full scan reads it.
		if sh.mode == Mode::Verify && refs.xattr.is_none() && refs.db.is_none() {
			st.skip_unknown.fetch_add(1, Relaxed);
			self.links.passed(before);
			if let Some(p) = prior.filter(|p| p.seen_run != sh.run_id) {
				send(sh, Msg::Seen(p.id));
			}
			return true;
		}

		// Another name for this inode may have left a fresh set without ever
		// seeing this name's row, so the row gets a say.
		let Some((d, date)) = onfile
			.b3_fresh(
				before.len() as i64,
				mtime_us(before),
				before.dev(),
				before.ino(),
				sh.cutoff_us,
				now_us(),
			)
			.filter(|(d, _)| refs.db.is_none_or(|p| p.b3 == d))
		else {
			return false;
		};
		// Row `x-mismatch`.
		let pbytes = job.path.as_os_str().as_bytes();
		if sh.open_misses.contains(pbytes) {
			return false;
		}
		st.skip_xattr.fetch_add(1, Relaxed);
		self.links.passed(before);
		send(
			sh,
			hashed_msg(pbytes, &Sums { b3: d, b2b: None }, before, date),
		);
		true
	}

	// Sums worth recording, with this name's claim on the inode still to fill.
	// None once the file is dealt with: a failed read, a mismatch, or another
	// name's read.
	fn read_judged(
		&mut self,
		job: &Job,
		prior: Option<&Prior>,
		refs: &Refs,
		file: &File,
		before: &fs::Metadata,
	) -> Option<(Sums, Option<ClaimGuard<'a>>)> {
		let (sh, st, links, path) = (self.sh, &self.g.stats, self.links, &job.path);
		let (bytes, mt) = (before.len() as i64, mtime_us(before));
		let mut claim = None;
		if before.nlink() > 1 {
			match links.claim((before.dev(), before.ino()), before.nlink(), bytes, mt) {
				// Read once, but each name is held to its own records.
				Claim::Done(LinkVal { sums, .. }) => {
					st.links.fetch_add(1, Relaxed);
					let misses = refs.misses(&sums);
					if !misses.is_empty() {
						keep(sh, st, path, prior, misses, "");
						return None;
					}
					refs.tally(&sums, st);
					let pbytes = path.as_os_str().as_bytes();
					send(sh, hashed_msg(pbytes, &sums, before, now_us()));
					return None;
				}
				Claim::Mine(g) => claim = Some(g),
			}
		}

		let want_b2b = sh.rmlint || refs.b2b.is_some();
		let first = match read_sums(file, before, want_b2b, &mut self.buf, &sh.stop, &st.bytes) {
			Ok(s) => s,
			Err(f) => {
				report_fail(sh, st, path, f);
				return None;
			}
		};
		st.hashed.fetch_add(1, Relaxed);
		let verdict = judge(refs, first, || {
			read_sums(file, before, want_b2b, &mut self.buf, &sh.stop, &st.bytes)
		});
		match verdict {
			Err(f) => {
				report_fail(sh, st, path, f);
				None
			}
			Ok(Verdict::Clean(s)) => Some((s, claim)),
			Ok(Verdict::CacheOnly { first, second }) => {
				st.mismatch.fetch_add(1, Relaxed);
				event(
					sh,
					Kind::CacheMismatch,
					path,
					format!(
						"first read {}, then {} with the cache dropped, which matches what was stored",
						b64u_encode(&first.b3),
						b64u_encode(&second.b3)
					),
				);
				Some((second, claim))
			}
			Ok(Verdict::Changed { sums, misses, note }) => {
				if let Some(c) = claim {
					c.fill(LinkVal {
						bytes,
						mtime_us: mt,
						sums,
					});
				}
				keep(sh, st, path, prior, misses, &note);
				None
			}
		}
	}

	fn write_attrs(
		&mut self,
		job: &Job,
		refs: &Refs,
		sums: &Sums,
		fd: RawFd,
		before: &fs::Metadata,
		hashed_us: i64,
	) {
		let (sh, st, path) = (self.sh, &self.g.stats, &job.path);
		// No xattrs in git work trees. See design.md, Attributes.
		if !sh.write_xattrs
			|| job.in_git
			|| sh.no_write_devs.contains(&before.dev())
			|| sh.no_xattr.iter().any(|x| path.starts_with(x))
		{
			return;
		}
		let what = if refs.xattr == Some(sums.b3) {
			xattr::B3Write::DateOnly
		} else {
			xattr::B3Write::All
		};
		let id = (before.dev(), before.ino());
		let (bytes, mt) = (before.len() as i64, mtime_us(before));
		let mut wrote = xattr::write_b3(fd, &sums.b3, bytes, mt, hashed_us, id, what);
		// A current rmlint set got this far only by matching, so this is a
		// missing or stale one.
		if let (Ok(()), Some(b2b), None) = (&wrote, sums.b2b, refs.b2b) {
			wrote = xattr::write_rmlint(fd, &b2b, mtime_s(before));
			if wrote.is_ok() {
				st.rmlint_set.fetch_add(1, Relaxed);
			}
		}
		match wrote {
			Ok(()) => {
				st.xattr_set.fetch_add(1, Relaxed);
			}
			Err(e) => {
				st.xattr_fail.fetch_add(1, Relaxed);
				// A read-only or xattr-less filesystem fails for every
				// file. A few events are enough to say so.
				if self.xattr_fail_logged < 20 {
					self.xattr_fail_logged += 1;
					event(sh, Kind::XattrError, path, e.to_string());
				}
			}
		}
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	use crate::testutil::{scratch, test_id};

	fn sums(b: u8) -> Sums {
		Sums {
			b3: [b; 32],
			b2b: None,
		}
	}

	fn refs(xattr: Option<u8>, db: Option<&Prior>) -> Refs<'_> {
		Refs {
			xattr: xattr.map(|b| [b; 32]),
			xattr_date: None,
			b2b: None,
			db,
		}
	}

	fn prior(b: u8) -> Prior {
		Prior {
			id: 1,
			bytes: 1,
			mtime_us: 1,
			ino: 1,
			hashed_us: 0,
			seen_run: 0,
			b3: vec![b; 32],
		}
	}

	#[test]
	fn a_match_is_not_read_again() {
		let _id = test_id("ddy6h");
		let p = prior(1);
		let v = judge(&refs(Some(1), Some(&p)), sums(1), || panic!("read again")).unwrap();
		assert!(matches!(v, Verdict::Clean(s) if s == sums(1)));
		// Nothing stored to disagree with.
		let v = judge(&refs(None, None), sums(5), || panic!("read again")).unwrap();
		assert!(matches!(v, Verdict::Clean(_)));
	}

	#[test]
	fn a_second_read_tells_cache_from_disk() {
		let _id = test_id("ddy6j");
		let p = prior(1);
		let r = refs(Some(1), Some(&p));
		// Right the second time: only the first read was bad.
		let v = judge(&r, sums(2), || Ok(sums(1))).unwrap();
		assert!(
			matches!(v, Verdict::CacheOnly { first, second } if first == sums(2) && second == sums(1))
		);
		// Wrong both times: on disk.
		let v = judge(&r, sums(2), || Ok(sums(2))).unwrap();
		let Verdict::Changed {
			sums: s,
			misses,
			note,
		} = v
		else {
			panic!("{v:?}")
		};
		assert_eq!(s, sums(2));
		let kinds: Vec<_> = misses.iter().map(|m| m.0.name()).collect();
		assert_eq!(kinds, ["b3-xattr-mismatch", "b3-db-mismatch"]);
		assert!(note.contains("same"));
		// Wrong both times, differently.
		let v = judge(&r, sums(2), || Ok(sums(3))).unwrap();
		assert!(
			matches!(v, Verdict::Changed { sums: s, ref note, .. } if s == sums(3) && note.contains("first read"))
		);
		// A failed second read is passed on, and nothing is judged.
		assert!(matches!(
			judge(&r, sums(2), || Err(ReadFail::Unstable)),
			Err(ReadFail::Unstable)
		));
	}

	#[test]
	fn each_record_is_checked() {
		let _id = test_id("ddy6k");
		let p = prior(1);
		// The database agrees, the attribute doesn't.
		let r = refs(Some(2), Some(&p));
		let kinds: Vec<_> = r.misses(&sums(1)).iter().map(|m| m.0.name()).collect();
		assert_eq!(kinds, ["b3-xattr-mismatch"]);
		let r = Refs {
			b2b: Some([7; 64]),
			..refs(None, None)
		};
		let s = Sums {
			b3: [1; 32],
			b2b: Some([8; 64]),
		};
		assert_eq!(r.misses(&s)[0].0.name(), "b2b-rmlint-mismatch");
	}

	#[test]
	fn exit_bits_add_up() {
		let _id = test_id("ddy6m");
		let c =
			|k: &[&str]| -> Vec<(String, i64)> { k.iter().map(|k| (k.to_string(), 1)).collect() };
		assert_eq!(exit_bits(&c(&[])), 0);
		assert_eq!(exit_bits(&c(&["unstable", "xattr-error"])), 0);
		assert_eq!(exit_bits(&c(&["cache-mismatch"])), 4);
		assert_eq!(exit_bits(&c(&["read-error", "b3-db-mismatch"])), 4);
		assert_eq!(exit_bits(&c(&["dir-error"])), 8);
		assert_eq!(exit_bits(&c(&["read-unsupported"])), 8);
		assert_eq!(exit_bits(&c(&["db-error", "b2b-rmlint-mismatch"])), 12);
		assert_eq!(exit_bits(&c(&["from-a-newer-version"])), 8);
		assert_eq!(exit_bits(&[("dir-error".into(), 0)]), 0);
		// Every kind has a name of its own, which is what's stored.
		let names: BTreeSet<_> = Kind::ALL.iter().map(|k| k.name()).collect();
		assert_eq!(names.len(), Kind::ALL.len());
	}

	fn test_shared(db: PathBuf) -> (Shared, Receiver<Msg>) {
		let (tx, rx) = sync_channel(64);
		let sh = Shared {
			stop: Arc::default(),
			faults: Arc::default(),
			run_id: 1,
			cutoff_us: 0,
			db,
			excludes: Vec::new(),
			no_xattr: Vec::new(),
			mount_points: BTreeMap::new(),
			no_write_devs: BTreeSet::new(),
			write_xattrs: false,
			rmlint: false,
			mode: Mode::Full,
			open_misses: HashSet::new(),
			tx,
		};
		(sh, rx)
	}

	// More files than the job queue holds, and no worker to take them. Workers
	// stopped opening the database in 2026102810135573, so a missing one now
	// stops the walk alone, and no workers is asked for outright.
	#[test]
	#[cfg_attr(miri, ignore = "SQLite is C, which Miri can't run")]
	fn a_group_with_no_workers_ends() {
		let _id = test_id("ddy8f");
		let dir = scratch("scan_noworkers");
		let tree = dir.join("tree");
		fs::create_dir(&tree).unwrap();
		for i in 0..1500 {
			File::create(tree.join(format!("f{i}"))).unwrap();
		}
		drop(db::open_rw(&dir.join("t.sqlite")).unwrap());
		let ends = |db: PathBuf, threads| {
			let (sh, _rx) = test_shared(db);
			let g = Group {
				name: "g".into(),
				roots: vec![tree.clone()],
				threads,
				stats: Stats::default(),
				done: AtomicBool::new(false),
			};
			let (dtx, drx) = std::sync::mpsc::channel();
			std::thread::spawn(move || {
				run_group(&g, &sh);
				let why = locked(&sh.faults.why).clone();
				dtx.send((g.done.load(Relaxed), sh.stop.load(Relaxed), why))
					.unwrap();
			});
			drx.recv_timeout(Duration::from_secs(20))
				.expect("the group never ended")
		};
		let (done, stopped, why) = ends(dir.join("t.sqlite"), 0);
		assert!(done && !stopped && why.is_empty(), "{why:?}");
		let (done, stopped, why) = ends(dir.join("not here/t.sqlite"), 2);
		assert!(done && stopped);
		assert_eq!(why.len(), 1, "{why:?}");
	}

	// ntfs3 answers EOPNOTSUPP for compressed and EFS files. That's not damage.
	#[test]
	fn unsupported_read_is_not_damage() {
		let _id = test_id("ddzxh");
		let (sh, rx) = test_shared(PathBuf::from("/nowhere"));
		let st = Stats::default();
		let p = Path::new("/x/vss_ps.dll");
		let kind = |fail| {
			report_fail(&sh, &st, p, fail);
			match rx.try_recv() {
				Ok(Msg::Event { kind, .. }) => kind,
				_ => panic!("no event"),
			}
		};
		let eio = io::Error::from_raw_os_error(libc::EIO);
		let nope = io::Error::from_raw_os_error(libc::EOPNOTSUPP);
		assert_eq!(kind(ReadFail::Io { err: eio, at: 4096 }), Kind::ReadError);
		assert_eq!(kind(ReadFail::Io { err: nope, at: 0 }), Kind::Unsupported);
		assert_eq!(
			(st.read_err.load(Relaxed), st.other_err.load(Relaxed)),
			(1, 1)
		);
	}

	#[test]
	fn a_panic_is_a_fault() {
		let _id = test_id("ddy8g");
		let (sh, _rx) = test_shared(PathBuf::from("/nowhere"));
		let done = AtomicBool::new(false);
		std::thread::scope(|s| {
			let _done = DoneOnDrop(&done);
			s.spawn(|| guarded(&sh, "a worker", || panic!("on purpose")));
		});
		assert!(done.load(Relaxed));
		assert!(sh.faults.any.load(Relaxed) && sh.stop.load(Relaxed));
		assert_eq!(*locked(&sh.faults.why), ["a worker panicked"]);
		// And a panic past the guard still marks the group done.
		let done = AtomicBool::new(false);
		let r = std::panic::catch_unwind(|| {
			let _done = DoneOnDrop(&done);
			panic!("on purpose");
		});
		assert!(r.is_err() && done.load(Relaxed));
	}

	// A worker that panics holding a lock poisons it. The claim it drops in
	// the unwind, the name waiting on that claim and the reason must all get
	// through, or the run aborts, hangs, or isn't marked failed.
	#[test]
	fn a_poisoned_lock_is_still_a_fault() {
		let _id = test_id("deawa");
		let (sh, _rx) = test_shared(PathBuf::from("/nowhere"));
		let (dtx, drx) = std::sync::mpsc::channel();
		std::thread::spawn(move || {
			let links = Links::default();
			let key = (1, 2);
			let waited = std::thread::scope(|s| {
				let Claim::Mine(mine) = links.claim(key, 2, 0, 0) else {
					panic!("not claimed");
				};
				let waiter = s.spawn(|| matches!(links.claim(key, 2, 0, 0), Claim::Mine(_)));
				std::thread::sleep(Duration::from_millis(50));
				s.spawn(|| {
					guarded(&sh, "a worker", || {
						let _claim = mine;
						let _held = (locked(&links.map), locked(&sh.faults.why));
						panic!("on purpose");
					});
				});
				waiter.join().is_ok_and(|mine| mine)
			});
			let poisoned = links.map.is_poisoned() && sh.faults.why.is_poisoned();
			let left = locked(&links.map).entries.len();
			let why = locked(&sh.faults.why).clone();
			dtx.send((waited, poisoned, left, why)).unwrap();
		});
		let (waited, poisoned, left, why) = drx
			.recv_timeout(Duration::from_secs(20))
			.expect("a poisoned lock hung");
		assert!(waited && poisoned);
		assert_eq!(left, 0);
		assert_eq!(why, ["a worker panicked"]);
	}

	#[test]
	fn roots_key_ignores_order() {
		let _id = test_id("ddy6n");
		let g = |rs: &[&str]| {
			vec![Planned {
				name: "g".into(),
				roots: rs.iter().map(PathBuf::from).collect(),
				threads: 1,
			}]
		};
		let a = roots_key(&[g(&["/b", "/a"]), g(&["/c"])].concat());
		let b = roots_key(&[g(&["/c"]), g(&["/a", "/b"])].concat());
		assert_eq!(a, b);
		assert_ne!(a, roots_key(&g(&["/a", "/b"])));
		assert_eq!(
			roots_diff(&a, &roots_key(&g(&["/a", "/d"]))),
			"not given now: /b, /c; not in that run: /d"
		);
	}

	fn test_group(root: &Path) -> Group {
		Group {
			name: "g".into(),
			roots: vec![root.to_path_buf()],
			threads: 1,
			stats: Stats::default(),
			done: AtomicBool::new(false),
		}
	}

	// A small buffer, so a read takes several passes.
	fn read_one(g: &Group, sh: &Shared, j: &Job, prior: Option<&Prior>, links: &Links) {
		let mut w = Worker {
			g,
			sh,
			links,
			buf: vec![0u8; 4096],
			xattr_fail_logged: 0,
		};
		w.one_file(j, prior);
	}

	fn job(root: &Arc<Root>, rel: &str) -> Job {
		Job {
			path: root.path.join(rel),
			in_git: false,
			root: root.clone(),
			prior: None,
		}
	}

	// The mount table is empty here, as it would be for a filesystem mounted
	// after the scan started. /dev/shm is its own mount on most boxes.
	#[test]
	fn the_walk_stays_on_the_root_device() {
		let _id = test_id("ddy94");
		let (Ok(dev), Ok(shm)) = (fs::metadata("/dev"), fs::metadata("/dev/shm")) else {
			return;
		};
		if dev.dev() == shm.dev() {
			eprintln!("/dev/shm isn't a mount here; skipped");
			return;
		}
		let mine = PathBuf::from(format!(
			"/dev/shm/test_tukfs-hash_walk_{}",
			std::process::id()
		));
		fs::write(&mine, "x").unwrap();
		let d = scratch("scan_walkdev");
		let look = db::open_rw(&d.join("t.sqlite")).unwrap();
		let (sh, rx) = test_shared(PathBuf::from("/nowhere/t.sqlite"));
		let drain = std::thread::spawn(move || rx.iter().count());
		let (jtx, jrx) = sync_channel(1 << 16);
		walk(Path::new("/dev"), &sh, &Stats::default(), &look, &jtx);
		drop((jtx, sh));
		drain.join().unwrap();
		let jobs: Vec<PathBuf> = jrx.iter().map(|j| j.path).collect();
		fs::remove_file(&mine).unwrap();
		assert!(!jobs.iter().any(|p| p.starts_with("/dev/shm")), "{jobs:?}");
	}

	// The walk looks each file up, a batch to a transaction, and a row it
	// can't read skips that file alone (2026102810135573).
	#[test]
	#[cfg_attr(miri, ignore = "SQLite is C, which Miri can't run")]
	fn the_walk_hands_each_job_its_row() {
		let _id = test_id("dej6m");
		let d = scratch("scan_walkrows");
		let tree = fs::canonicalize(&*d).unwrap().join("tree");
		fs::create_dir(&tree).unwrap();
		let n = LOOKUP_BATCH + 3;
		for i in 0..n {
			fs::write(tree.join(format!("f{i:04}")), "x").unwrap();
		}
		let look = db::open_rw(&d.join("t.sqlite")).unwrap();
		look.execute("INSERT INTO files (id, b3, bytes) VALUES (1, x'01', 1)", [])
			.unwrap();
		let mut put = look
			.prepare(
				"INSERT INTO paths (path, file_id, bytes, mtime_us, ino, hashed_us, seen_run)
				VALUES (?1, 1, ?2, 9, 1, 100, 1)",
			)
			.unwrap();
		let row = |i: usize| tree.join(format!("f{i:04}")).to_str().unwrap().to_owned();
		put.execute(rusqlite::params![row(1), 1]).unwrap();
		put.execute(rusqlite::params![row(n - 1), 1]).unwrap();
		put.execute(rusqlite::params![row(2), "junk"]).unwrap();
		drop(put);
		let (sh, rx) = test_shared(d.join("t.sqlite"));
		let drain = std::thread::spawn(move || {
			rx.iter()
				.filter_map(|m| match m {
					Msg::Event { kind, path, .. } => Some((kind, path)),
					_ => None,
				})
				.collect::<Vec<_>>()
		});
		let (jtx, jrx) = sync_channel(1 << 16);
		let stats = Stats::default();
		walk(&tree, &sh, &stats, &look, &jtx);
		drop((jtx, sh));
		let events = drain.join().unwrap();
		let jobs: BTreeMap<PathBuf, Option<i64>> = jrx
			.iter()
			.map(|j| (j.path, j.prior.map(|p| p.bytes)))
			.collect();
		assert_eq!(jobs.len(), n - 1, "the junk row's file is skipped");
		assert_eq!(jobs[&PathBuf::from(row(1))], Some(1));
		assert_eq!(
			jobs[&PathBuf::from(row(n - 1))],
			Some(1),
			"past the first batch"
		);
		assert_eq!(jobs[&PathBuf::from(row(0))], None);
		assert!(!jobs.contains_key(&PathBuf::from(row(2))));
		assert_eq!(events, vec![(Kind::DbError, row(2).into_bytes())]);
		assert_eq!(stats.other_err.load(Relaxed), 1);
		assert!(look.is_autocommit());
	}

	#[test]
	fn only_the_databases_own_names_are_left_out() {
		let _id = test_id("des63");
		let (sh, _rx) = test_shared(PathBuf::from("/x/tree/tuk"));
		let out = |name: &str| excluded(&sh, &Path::new("/x/tree").join(name));
		for name in ["tuk", "tuk-wal", "tuk-shm", "tuk-journal", "tuk.lock"] {
			assert!(out(name), "{name}");
		}
		for name in [
			"tuk-notes.txt",
			"tuk.d",
			"tukdir",
			"tuk.lock2",
			"tuk-wal.1",
			"tu",
			"Tuk",
		] {
			assert!(!out(name), "{name}");
		}
		assert!(
			!excluded(&sh, Path::new("/x/tree/sub/tuk")),
			"another folder"
		);
	}

	// design.md, Attributes: none in a git work tree, however deep the root.
	#[test]
	#[cfg_attr(miri, ignore = "SQLite is C, which Miri can't run")]
	fn a_root_below_a_git_folder_is_in_git() {
		let _id = test_id("des64");
		let d = scratch("scan_gitabove");
		let d = fs::canonicalize(&*d).unwrap();
		for top in ["repo", "wt", "plain"] {
			fs::create_dir_all(d.join(top).join("src/deep")).unwrap();
			fs::write(d.join(top).join("src/deep/a.c"), "x").unwrap();
			fs::write(d.join(top).join("src/b.c"), "x").unwrap();
		}
		fs::create_dir(d.join("repo/.git")).unwrap();
		// A linked work tree or a submodule has a .git file.
		fs::write(d.join("wt/.git"), "gitdir: elsewhere\n").unwrap();
		let look = db::open_rw(&d.join("t.sqlite")).unwrap();
		for (top, git) in [("repo", true), ("wt", true), ("plain", false)] {
			let root = d.join(top).join("src");
			let dev = fs::metadata(&root).unwrap().dev();
			assert_eq!(git_tree_above(&root, dev), git, "{top}");
			assert!(
				!git_tree_above(&root, dev + 1),
				"{top}: past the filesystem"
			);
			let (sh, _rx) = test_shared(d.join("t.sqlite"));
			let (jtx, jrx) = sync_channel(64);
			walk(&root, &sh, &Stats::default(), &look, &jtx);
			drop((jtx, sh));
			let jobs: Vec<(PathBuf, bool)> = jrx.iter().map(|j| (j.path, j.in_git)).collect();
			assert_eq!(jobs.len(), 2, "{top}");
			assert!(jobs.iter().all(|(_, g)| *g == git), "{top}: {jobs:?}");
		}
	}

	// A folder swapped for a symlink after the walk listed it.
	#[test]
	#[cfg_attr(miri, ignore = "Miri has no openat2")]
	fn a_swapped_folder_is_not_followed() {
		let _id = test_id("ddy95");
		let d = scratch("scan_swap");
		let (root, outside) = (d.join("root"), d.join("outside"));
		fs::create_dir_all(&root).unwrap();
		fs::create_dir_all(&outside).unwrap();
		fs::write(outside.join("f"), "not for the scan").unwrap();
		std::os::unix::fs::symlink(&outside, root.join("dir")).unwrap();
		let (sh, rx) = test_shared(d.join("t.sqlite"));
		let g = test_group(&root);
		let r = Arc::new(Root::open(&root).unwrap());
		read_one(&g, &sh, &job(&r, "dir/f"), None, &Links::default());
		assert_eq!(g.stats.files.load(Relaxed), 0);
		assert!(rx.try_recv().is_err());
	}

	// Names skipped by the database or the attributes count down too, so the
	// entry goes once all are seen.
	#[test]
	#[cfg_attr(miri, ignore = "Miri has no openat2")]
	fn skipped_links_count_down() {
		let _id = test_id("ddy96");
		let d = scratch("scan_links");
		fs::write(d.join("a"), "linked").unwrap();
		fs::hard_link(d.join("a"), d.join("b")).unwrap();
		fs::hard_link(d.join("a"), d.join("c")).unwrap();
		let md = fs::metadata(d.join("a")).unwrap();
		let fresh = Prior {
			id: 1,
			bytes: md.len() as i64,
			mtime_us: mtime_us(&md),
			ino: md.ino() as i64,
			hashed_us: now_us(),
			seen_run: 0,
			b3: blake3::hash(b"linked").as_bytes().to_vec(),
		};
		let (mut sh, rx) = test_shared(d.join("t.sqlite"));
		sh.write_xattrs = true;
		let drain = std::thread::spawn(move || rx.iter().count());
		let g = test_group(&d);
		let r = Arc::new(Root::open(&d).unwrap());
		let links = Links::default();
		read_one(&g, &sh, &job(&r, "a"), None, &links);
		let left = |l: &Links| locked(&l.map).entries.len();
		assert_eq!(left(&links), 1);
		read_one(&g, &sh, &job(&r, "b"), Some(&fresh), &links);
		assert_eq!(g.stats.skip_db.load(Relaxed), 1);
		read_one(&g, &sh, &job(&r, "c"), None, &links);
		if g.stats.xattr_set.load(Relaxed) == 1 {
			assert_eq!(g.stats.skip_xattr.load(Relaxed), 1);
		} else {
			eprintln!("no user xattrs here; c went through the claim");
		}
		assert_eq!(left(&links), 0);
		drop(sh);
		drain.join().unwrap();
	}

	// Whichever read of the mount table fails, no run is left running, and a
	// run reads it once (backlog ...852).
	#[test]
	#[cfg_attr(miri, ignore = "Miri has no openat2")]
	fn a_lost_mount_table_leaves_no_run_running() {
		let _id = test_id("dehzd");
		let d = scratch("scan_mountfail");
		let root = d.join("r");
		fs::create_dir(&root).unwrap();
		fs::write(root.join("a"), "x").unwrap();
		let db = d.join("t.sqlite");
		let o = Opts {
			db: db.clone(),
			roots: vec![root],
			excludes: Vec::new(),
			no_xattr: Vec::new(),
			threads: Vec::new(),
			since: None,
			resume: false,
			mode: Mode::Full,
			write_xattrs: false,
			rmlint: false,
			progress_secs: 3600,
			args: "test".into(),
		};
		// A container may not see the disk under its folders.
		if let Err(e) = run(&o, &Arc::new(AtomicBool::new(false))) {
			eprintln!("a plain scan fails here ({e}); skipped");
			return;
		}
		for n in 0..4 {
			mounts::READS_LEFT.set(Some(n));
			let r = run(&o, &Arc::new(AtomicBool::new(false)));
			mounts::READS_LEFT.set(None);
			assert_eq!(r.is_ok(), n > 0, "{n} good read(s): {r:?}");
			let c = rusqlite::Connection::open(&db).unwrap();
			let running: i64 = c
				.query_row(
					"SELECT count(*) FROM runs WHERE status = ?1",
					[RunStatus::Running],
					|r| r.get(0),
				)
				.unwrap();
			assert_eq!(running, 0, "{n} good read(s): {r:?}");
		}
	}

	// A panic in the database writer still closes the run (backlog ...002).
	#[test]
	#[cfg_attr(miri, ignore = "Miri has no openat2")]
	fn a_writer_panic_leaves_no_run_running() {
		let _id = test_id("dehzq");
		let d = scratch("scan_writerpanic");
		let root = d.join("r");
		fs::create_dir(&root).unwrap();
		fs::write(root.join("a"), "x").unwrap();
		let db = d.join("t.sqlite");
		let o = Opts {
			db: db.clone(),
			roots: vec![root.clone()],
			excludes: Vec::new(),
			no_xattr: Vec::new(),
			threads: Vec::new(),
			since: None,
			resume: false,
			mode: Mode::Full,
			write_xattrs: false,
			rmlint: false,
			progress_secs: 3600,
			args: "test".into(),
		};
		if let Err(e) = run(&o, &Arc::new(AtomicBool::new(false))) {
			eprintln!("a plain scan fails here ({e}); skipped");
			return;
		}
		// Something new, so the writer gets a batch.
		fs::write(root.join("b"), "y").unwrap();
		let key = canonical_db(&db).unwrap().to_str().unwrap().to_owned();
		db::PANIC_ON.lock().unwrap().push(key.clone());
		let r = run(&o, &Arc::new(AtomicBool::new(false)));
		db::PANIC_ON.lock().unwrap().retain(|k| *k != key);
		assert!(
			r.as_ref().is_err_and(|e| e.contains("writer panicked")),
			"{r:?}"
		);
		let c = rusqlite::Connection::open(&db).unwrap();
		let status: String = c
			.query_row(
				"SELECT status FROM runs ORDER BY id DESC LIMIT 1",
				[],
				|r| r.get(0),
			)
			.unwrap();
		assert_eq!(status, RunStatus::Failed.text());
	}

	// Progress counts a file as it's read, not all at the end (backlog ...779).
	#[test]
	#[cfg_attr(miri, ignore = "4096 reads")]
	fn bytes_count_as_they_are_read() {
		let _id = test_id("dehzr");
		let d = scratch("scan_readprogress");
		let p = d.join("big");
		let len = 16u64 << 20;
		fs::write(&p, vec![7u8; usize::try_from(len).unwrap()]).unwrap();
		let file = File::open(&p).unwrap();
		let before = file.metadata().unwrap();
		let stop = AtomicBool::new(false);
		let counted = AtomicU64::new(0);
		let mut buf = vec![0u8; 4096];
		let (r, seen) = std::thread::scope(|s| {
			let t = s.spawn(|| read_sums(&file, &before, false, &mut buf, &stop, &counted));
			let mut seen = 0;
			while !t.is_finished() {
				let n = counted.load(Relaxed);
				if n > 0 && n < len {
					seen = n;
					stop.store(true, Relaxed);
					break;
				}
			}
			(t.join().unwrap(), seen)
		});
		assert!(seen > 0, "nothing counted until the end");
		assert!(matches!(r, Err(ReadFail::Stopped)), "not stopped part way");
		// Only what was read, the stopped part included.
		assert!(counted.load(Relaxed) < len);
	}

	// Only a lock held elsewhere reads as another scan (backlog ...819).
	#[test]
	#[cfg_attr(miri, ignore = "Miri has no flock")]
	fn a_held_lock_says_so() {
		let _id = test_id("dehzf");
		let d = scratch("scan_heldlock");
		let db = d.join("t.sqlite");
		let mounts = mounts::read_mounts().unwrap();
		let held = lock(&db, &mounts).unwrap();
		let again = lock(&db, &mounts).unwrap_err();
		assert!(again.ends_with("is locked; another scan is using this database"));
		drop(held);
		lock(&db, &mounts).unwrap();
	}

	// A database left owned by root is named; a missing WAL file isn't
	// (backlog ...819).
	#[test]
	#[cfg_attr(miri, ignore = "Miri has no chown")]
	fn a_failed_hand_over_is_named() {
		let _id = test_id("dehze");
		// SAFETY: geteuid only reads.
		if unsafe { libc::geteuid() } == 0 {
			eprintln!("root can give anything away; skipped");
			return;
		}
		let d = scratch("scan_handover");
		let db = d.join("t.sqlite");
		fs::write(&db, "").unwrap();
		fs::write(lock_path(&db), "").unwrap();
		let me = fs::metadata(&db).unwrap();
		assert!(hand_over(&db, me.uid(), me.gid()).is_empty());
		let failed: Vec<PathBuf> = hand_over(&db, 0, 0).into_iter().map(|f| f.0).collect();
		assert_eq!(failed, [db.clone(), lock_path(&db)]);
	}

	// A link at a name is named, not followed (2026102814341403).
	#[test]
	#[cfg_attr(miri, ignore = "Miri has no chown")]
	fn a_link_is_not_handed_over() {
		let _id = test_id("dejdv");
		let d = scratch("scan_handover_link");
		let db = d.join("t.sqlite");
		fs::write(&db, "").unwrap();
		let mut wal = db.as_os_str().to_owned();
		wal.push("-wal");
		std::os::unix::fs::symlink(d.join("target"), &wal).unwrap();
		let me = fs::metadata(&db).unwrap();
		let failed: Vec<PathBuf> = hand_over(&db, me.uid(), me.gid())
			.into_iter()
			.map(|f| f.0)
			.collect();
		assert_eq!(failed, [PathBuf::from(wal)]);
		assert!(!d.join("target").exists());
	}

	#[test]
	#[cfg_attr(miri, ignore = "Miri has no openat2")]
	fn nothing_written_on_a_hands_off_device() {
		let _id = test_id("ddyas");
		let d = scratch("scan_handsoff");
		fs::write(d.join("a"), "win").unwrap();
		fs::write(d.join("b"), "mac").unwrap();
		let (mut sh, rx) = test_shared(d.join("t.sqlite"));
		sh.write_xattrs = true;
		let drain = std::thread::spawn(move || rx.iter().count());
		let g = test_group(&d);
		let r = Arc::new(Root::open(&d).unwrap());
		let links = Links::default();
		read_one(&g, &sh, &job(&r, "a"), None, &links);
		let control = g.stats.xattr_set.load(Relaxed);
		sh.no_write_devs.insert(fs::metadata(&d).unwrap().dev());
		read_one(&g, &sh, &job(&r, "b"), None, &links);
		assert_eq!(g.stats.xattr_set.load(Relaxed), control);
		assert_eq!(g.stats.xattr_fail.load(Relaxed), 0);
		let fd = File::open(d.join("b")).unwrap();
		assert!(OnFile::read(fd.as_raw_fd()).b3.is_none());
		if control == 0 {
			eprintln!("no user xattrs here; the control proves nothing");
		}
		drop(sh);
		drain.join().unwrap();
	}

	// Dropbox files get ours too (backlog ...929), and Dropbox's own is left be.
	#[test]
	#[cfg_attr(miri, ignore = "Miri can't set xattrs")]
	fn dropbox_files_get_attributes() {
		let _id = test_id("ddye5");
		let d = scratch("scan_dropbox");
		fs::write(d.join("a"), "synced").unwrap();
		let dbx = c"user.com.dropbox.attrs";
		let theirs = b"\x0a\x12opaque";
		let fd = File::open(d.join("a")).unwrap();
		if xattr::fset(fd.as_raw_fd(), dbx, theirs).is_err() {
			eprintln!("no user xattrs here; skipped");
			return;
		}
		let (mut sh, rx) = test_shared(d.join("t.sqlite"));
		sh.write_xattrs = true;
		let drain = std::thread::spawn(move || rx.iter().count());
		let g = test_group(&d);
		let r = Arc::new(Root::open(&d).unwrap());
		read_one(&g, &sh, &job(&r, "a"), None, &Links::default());
		assert_eq!(g.stats.xattr_set.load(Relaxed), 1);
		let on = OnFile::read(fd.as_raw_fd());
		assert_eq!(on.b3, Some(*blake3::hash(b"synced").as_bytes()));
		assert_eq!(
			xattr::fget(fd.as_raw_fd(), dbx).unwrap().as_deref(),
			Some(&theirs[..])
		);
		drop(sh);
		drain.join().unwrap();
	}

	// --rmlint leaves rmlint's set where none is current, and the blake2b goes
	// to the database either way.
	#[test]
	#[cfg_attr(miri, ignore = "Miri can't set xattrs")]
	fn rmlint_set_only_with_the_flag() {
		let _id = test_id("de5fz");
		let d = scratch("scan_rmlint");
		for f in ["plain", "flagged", "stale", "git"] {
			fs::write(d.join(f), f).unwrap();
		}
		let fd = |f: &str| File::open(d.join(f)).unwrap();
		if xattr::fset(fd("stale").as_raw_fd(), xattr::RM_B2B_MTIME, b"1000.5").is_err() {
			eprintln!("no user xattrs here; skipped");
			return;
		}
		xattr::fset(fd("stale").as_raw_fd(), xattr::RM_B2B_CKSUM, &[b'0'; 128]).unwrap();
		let (mut sh, rx) = test_shared(d.join("t.sqlite"));
		sh.write_xattrs = true;
		let g = test_group(&d);
		let r = Arc::new(Root::open(&d).unwrap());
		let go = |sh: &Shared, j: Job| {
			read_one(&g, sh, &j, None, &Links::default());
			match rx.try_recv() {
				Ok(Msg::Hashed(h)) => h.b2b,
				_ => panic!("nothing recorded"),
			}
		};
		let b2b = |f: &str| -> [u8; 64] { *blake2b_simd::blake2b(f.as_bytes()).as_array() };
		let now = |f: &str| {
			let file = fd(f);
			OnFile::read(file.as_raw_fd()).b2b_current(mtime_s(&file.metadata().unwrap()))
		};
		assert_eq!(go(&sh, job(&r, "plain")), None);
		assert_eq!(now("plain"), None);
		sh.rmlint = true;
		assert_eq!(go(&sh, job(&r, "flagged")), Some(b2b("flagged")));
		assert_eq!(now("flagged"), Some(b2b("flagged")));
		assert_eq!(go(&sh, job(&r, "stale")), Some(b2b("stale")));
		assert_eq!(now("stale"), Some(b2b("stale")));
		let in_git = Job {
			in_git: true,
			..job(&r, "git")
		};
		assert_eq!(go(&sh, in_git), Some(b2b("git")));
		assert_eq!(now("git"), None);
		assert_eq!(g.stats.rmlint_set.load(Relaxed), 2);
	}

	// rmlint takes plain unkeyed blake2b-512. The first two are RFC 7693's,
	// the last is 300000 bytes of i % 251, read in pieces that split blocks.
	#[test]
	fn b2b_matches_known_digests() {
		let _id = test_id("deav7");
		let d = scratch("scan_b2b_vectors");
		let long: Vec<u8> = (0..300_000u32).map(|i| (i % 251) as u8).collect();
		let cases: [(&[u8], &str); 3] = [
			(
				b"",
				"786a02f742015903c6c6fd852552d272912f4740e15847618a86e217f71f5419d25e1031afee585313896444934eb04b903a685b1448b755d56f701afe9be2ce",
			),
			(
				b"abc",
				"ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d17d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923",
			),
			(
				&long,
				"8ee2ab50e0b1be2f1c64692013dfe68e15e36d15c4d5ec703b725b5cf5c1ba07299284b7a9ddd0ca725b39105bda7b79fa85fc5defab5819dfa8fee27f79da78",
			),
		];
		let stop = AtomicBool::new(false);
		let counted = AtomicU64::new(0);
		// The long one takes Miri over 15 minutes. The short ones still go
		// through the hashers' unsafe code there.
		let n = if cfg!(miri) { 2 } else { cases.len() };
		for (i, (bytes, want)) in cases.iter().take(n).enumerate() {
			let p = d.join(format!("v{i}"));
			fs::write(&p, bytes).unwrap();
			let file = File::open(&p).unwrap();
			let before = file.metadata().unwrap();
			for piece in [1, 1000, 1 << 20] {
				let mut buf = vec![0u8; piece];
				let s = read_sums(&file, &before, true, &mut buf, &stop, &counted).unwrap();
				assert_eq!(
					crate::util::hex(&s.b2b.unwrap()),
					*want,
					"case {i}, buf {piece}"
				);
			}
		}
	}

	#[test]
	#[cfg_attr(miri, ignore = "O_DIRECT isn't modelled, and 1 MB reads")]
	fn direct_reads_hash_every_byte() {
		let _id = test_id("debte");
		let d = scratch("scan_direct_reads");
		let stop = AtomicBool::new(false);
		let counted = AtomicU64::new(0);
		let mut store = vec![0u8; (1 << 20) + 2 * DIRECT_ALIGN];
		let lead = store.as_ptr().align_offset(DIRECT_ALIGN);
		// On the block size, a byte off it, and too small to go direct.
		let bufs = [
			(lead, lead + (1 << 20)),
			(lead + 1, store.len()),
			(lead, lead + 1000),
		];
		let min = usize::try_from(DIRECT_MIN).unwrap();
		// Both sides of DIRECT_MIN, so each path gets odd tails.
		let sizes = [
			0,
			1,
			4095,
			4096,
			4097,
			3 * 4096 + 123,
			min - 1,
			min,
			min + 4097,
			(1 << 20) + 7,
		];
		for len in sizes {
			let bytes: Vec<u8> = (0..len).map(|i| (i % 253) as u8).collect();
			let p = d.join(format!("d{len}"));
			fs::write(&p, &bytes).unwrap();
			let file = File::open(&p).unwrap();
			let before = file.metadata().unwrap();
			for (from, to) in bufs {
				let s = read_sums(&file, &before, false, &mut store[from..to], &stop, &counted)
					.unwrap();
				assert_eq!(
					s.b3,
					*blake3::hash(&bytes).as_bytes(),
					"len {len}, buf {from}..{to}"
				);
				// SAFETY: the fd is open.
				let flags = unsafe { libc::fcntl(file.as_raw_fd(), libc::F_GETFL) };
				assert_eq!(flags & libc::O_DIRECT, 0, "O_DIRECT left on, len {len}");
			}
		}
	}

	#[test]
	#[cfg_attr(miri, ignore = "2^18 entries; over 15 min under Miri, and safe code")]
	fn the_link_map_is_capped() {
		let _id = test_id("ddy97");
		let mut m = LinkMap::default();
		let v = LinkVal {
			bytes: 1,
			mtime_us: 1,
			sums: sums(1),
		};
		for i in 0..LINKS_KEPT as u64 + 10 {
			m.fill((1, i), v, 5);
		}
		assert_eq!(m.entries.len(), LINKS_KEPT);
		assert!(!m.entries.contains_key(&(1, 9)) && m.entries.contains_key(&(1, 10)));
		// Counted down and filled again: the stale key doesn't grow the queue.
		for _ in 0..5 {
			m.count_down((1, 10));
		}
		m.fill((1, 10), v, 1);
		assert!(m.filled.len() <= LINKS_KEPT && m.entries.len() <= LINKS_KEPT);
		// One being read is never dropped.
		m.entries.insert((2, 0), None);
		for i in 0..LINKS_KEPT as u64 {
			m.fill((3, i), v, 5);
		}
		assert!(matches!(m.entries.get(&(2, 0)), Some(None)));
	}

	fn runs_with(status: &str) -> rusqlite::Connection {
		db::init();
		let c = rusqlite::Connection::open_in_memory().unwrap();
		c.execute_batch(
			"CREATE TABLE runs (id INTEGER PRIMARY KEY, started_us, cutoff_us, status, roots, summary, verify);",
		)
		.unwrap();
		c.execute(
			"INSERT INTO runs (started_us, cutoff_us, status, roots, verify) VALUES (1, 1, ?1, x'2f61', 0)",
			[status],
		)
		.unwrap();
		c
	}

	#[test]
	#[cfg_attr(miri, ignore = "SQLite is C, which Miri can't run")]
	fn resume_takes_only_the_statuses_it_knows() {
		let _id = test_id("deaw0");
		for s in ["stopped", "failed", "running", "killed"] {
			let r = pick_resume(&runs_with(s), b"/a", Mode::Full);
			assert!(r.is_ok(), "{s}: {:?}", r.err());
		}
		let r = pick_resume(&runs_with("done"), b"/a", Mode::Full);
		assert!(r.err().is_some_and(|m| m.contains("finished")));
		// One from a newer version, or a typo by hand.
		let r = pick_resume(&runs_with("paused"), b"/a", Mode::Full);
		assert!(
			r.err()
				.is_some_and(|m| m.contains("is paused; can't resume"))
		);
		// An accept is never the newest scan.
		let r = pick_resume(&runs_with("accept"), b"/a", Mode::Full);
		assert!(r.err().is_some_and(|m| m.contains("no scan to resume")));
	}
}
