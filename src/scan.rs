// Copyright © 2026 t00mietum (CryptogID: ปʬϝღถɔ4რఠΔթะ9ƾǝu)
// Licensed under GPL-2.0-only. No warranty.

// Walks each root, checksums every regular file, and compares the result with
// whatever was known before: the blake3 on the file, rmlint's blake2b on the
// file, and the database. A file whose size and time didn't change but whose
// contents did is the thing this is looking for.

use crate::db::{self, Hashed, Msg, Prior};
use crate::mounts;
use crate::util::{
	b64u_encode, escape_name, fmt_local, hex, human_bytes, local_midnight_us, now_us,
};
use crate::xattr::{self, OnFile};
use rusqlite::OptionalExtension;
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::fs::{self, File, OpenOptions};
use std::io;
use std::os::fd::AsRawFd;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{DirEntryExt, FileExt, MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering::Relaxed};
use std::sync::mpsc::{sync_channel, Receiver, SyncSender};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

pub struct Opts {
	pub db: PathBuf,
	pub roots: Vec<PathBuf>,
	pub excludes: Vec<PathBuf>,
	pub no_xattr: Vec<PathBuf>,
	pub threads: Vec<(PathBuf, usize)>,
	pub since: Option<i64>,
	pub resume: bool,
	pub write_xattrs: bool,
	pub progress_secs: u64,
	pub args: String,
}

/// What an event says about a file.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
	XattrMismatch,
	RmlintMismatch,
	DbMismatch,
	CacheMismatch,
	ReadError,
	Unstable,
	DirError,
	StatError,
	OpenError,
	DbError,
	XattrError,
}

impl Kind {
	const ALL: [Kind; 11] = [
		Kind::XattrMismatch,
		Kind::RmlintMismatch,
		Kind::DbMismatch,
		Kind::CacheMismatch,
		Kind::ReadError,
		Kind::Unstable,
		Kind::DirError,
		Kind::StatError,
		Kind::OpenError,
		Kind::DbError,
		Kind::XattrError,
	];

	pub fn name(self) -> &'static str {
		match self {
			Kind::XattrMismatch => "b3-xattr-mismatch",
			Kind::RmlintMismatch => "b2-rmlint-mismatch",
			Kind::DbMismatch => "b3-db-mismatch",
			Kind::CacheMismatch => "cache-mismatch",
			Kind::ReadError => "read-error",
			Kind::Unstable => "unstable",
			Kind::DirError => "dir-error",
			Kind::StatError => "stat-error",
			Kind::OpenError => "open-error",
			Kind::DbError => "db-error",
			Kind::XattrError => "xattr-error",
		}
	}

	// 4 is something flagged, 8 is something left unchecked. Unstable files
	// are live ones, like a running VM's disk, and would set 8 on every run.
	// A failed attribute write comes after the check.
	fn exit_bits(self) -> i32 {
		match self {
			Kind::XattrMismatch
			| Kind::RmlintMismatch
			| Kind::DbMismatch
			| Kind::CacheMismatch
			| Kind::ReadError => 4,
			Kind::DirError | Kind::StatError | Kind::OpenError | Kind::DbError => 8,
			Kind::Unstable | Kind::XattrError => 0,
		}
	}
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
		.map(|(k, _)| {
			Kind::ALL
				.iter()
				.find(|x| x.name() == k)
				.map_or(8, |x| x.exit_bits())
		})
		.fold(0, |a, b| a | b)
}

const EVENTS_LINE: &str = "events in the whole run:";

fn events_line(counts: &[(String, i64)]) -> String {
	if counts.is_empty() {
		return format!("{EVENTS_LINE} none");
	}
	let each: Vec<String> = counts.iter().map(|(k, n)| format!("{k} {n}")).collect();
	format!("{EVENTS_LINE} {}", each.join(", "))
}

// Roots as plan() kept them, sorted, so 2 runs over the same folders match.
fn roots_key(groups: &[(String, Vec<PathBuf>, usize)]) -> Vec<u8> {
	let mut roots: Vec<&[u8]> = groups
		.iter()
		.flat_map(|(_, rs, _)| rs.iter().map(|r| r.as_os_str().as_bytes()))
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

// Only the newest scan, only if it didn't finish, and only over the same
// roots. An older stopped run would bring back an old skip date, and the
// other wrapper's run would be finished over the wrong roots.
fn pick_resume(conn: &rusqlite::Connection, roots: &[u8]) -> Result<Resumed, String> {
	let row = conn
		.query_row(
			"SELECT id, status, cutoff_us, started_us, roots, summary FROM runs
			WHERE status != 'accept' ORDER BY id DESC LIMIT 1",
			[],
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
				))
			},
		)
		.optional()
		.map_err(|e| format!("database: {e}"))?;
	let Some((run, status, was)) = row else {
		return Err("--resume: no scan to resume".into());
	};
	let id = run.id;
	match status.as_str() {
		"stopped" | "running" | "killed" => {}
		"done" => {
			return Err(format!(
				"--resume: the last scan, run {id}, finished. Start a new one without --resume."
			))
		}
		other => return Err(format!("--resume: run {id} is {other}; can't resume it")),
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
	if status != "stopped" {
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
	links: AtomicU64,
	bytes: AtomicU64,
	b3_ok: AtomicU64,
	b2_ok: AtomicU64,
	db_ok: AtomicU64,
	mismatch: AtomicU64,
	read_err: AtomicU64,
	other_err: AtomicU64,
	unstable: AtomicU64,
	xattr_set: AtomicU64,
	xattr_fail: AtomicU64,
}

impl Stats {
	fn line(&self) -> String {
		let g = |a: &AtomicU64| a.load(Relaxed);
		format!(
			"files {} hashed {} ({}) skipped {} links {} | verified b3 {} b2 {} db {} | MISMATCH {} read-err {} other-err {} unstable {} | xattr set {} fail {}",
			g(&self.files),
			g(&self.hashed),
			human_bytes(g(&self.bytes)),
			g(&self.skip_db) + g(&self.skip_xattr),
			g(&self.links),
			g(&self.b3_ok),
			g(&self.b2_ok),
			g(&self.db_ok),
			g(&self.mismatch),
			g(&self.read_err),
			g(&self.other_err),
			g(&self.unstable),
			g(&self.xattr_set),
			g(&self.xattr_fail),
		)
	}
}

struct Shared {
	stop: Arc<AtomicBool>,
	run_id: i64,
	cutoff_us: i64,
	db: PathBuf,
	excludes: Vec<PathBuf>,
	no_xattr: Vec<PathBuf>,
	mount_points: BTreeMap<PathBuf, String>,
	write_xattrs: bool,
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
}

pub struct Plan {
	pub groups: Vec<(String, Vec<PathBuf>, usize)>,
	pub dropped: Vec<String>,
}

// Roots that resolve to the same place, or sit inside another root on the same
// filesystem, are dropped, so nothing is read twice. Bind mounts are the usual
// cause here.
pub fn plan(roots: &[PathBuf], threads: &[(PathBuf, usize)]) -> Result<Plan, String> {
	let mounts = mounts::read_mounts()?;
	let mut dropped = Vec::new();
	let mut kept: Vec<(PathBuf, BTreeSet<String>)> = Vec::new();
	let mut seen_ids: HashMap<(u64, u64), PathBuf> = HashMap::new();
	let mut canon = Vec::new();
	for r in roots {
		match fs::canonicalize(r) {
			Ok(c) => canon.push(c),
			Err(_) => dropped.push(format!("{}: missing", r.display())),
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
		if let Some((other, _)) = kept.iter().find(|(k, _)| {
			c.starts_with(k) && mounts::mount_for(&mounts, k).is_some_and(|km| km.point == m.point)
		}) {
			dropped.push(format!("{}: inside {}", c.display(), other.display()));
			continue;
		}
		let disks = mounts::disks_for(m, &mounts)?;
		seen_ids.insert((md.dev(), md.ino()), c.clone());
		kept.push((c, disks));
	}
	let mut groups = Vec::new();
	for (disks, rs) in mounts::group_roots(&kept) {
		let mut n = mounts::default_threads(&disks);
		for (p, t) in threads {
			if let Ok(c) = fs::canonicalize(p) {
				if rs.iter().any(|r| c.starts_with(r) || r.starts_with(&c)) {
					n = *t;
				}
			}
		}
		groups.push((mounts::group_name(&disks), rs, n.max(1)));
	}
	Ok(Plan { groups, dropped })
}

pub fn lock(db: &Path) -> Result<File, String> {
	let p = lock_path(db);
	let f = OpenOptions::new()
		.create(true)
		.truncate(false)
		.write(true)
		.open(&p)
		.map_err(|e| format!("{}: {e}", p.display()))?;
	if unsafe { libc::flock(f.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
		return Err(format!(
			"{} is locked; another scan is using this database",
			p.display()
		));
	}
	Ok(f)
}

pub fn host() -> String {
	fs::read_to_string("/proc/sys/kernel/hostname")
		.map(|s| s.trim().to_string())
		.unwrap_or_default()
}

// Hand the files back to whoever ran this through sudo, so reports and
// queries need no root.
pub fn give_back(paths: &[PathBuf]) {
	let id = |k| std::env::var(k).ok().and_then(|v| v.parse::<u32>().ok());
	if let (Some(uid), Some(gid)) = (id("SUDO_UID"), id("SUDO_GID")) {
		for p in paths {
			if let Ok(c) = crate::util::cpath(p) {
				unsafe { libc::chown(c.as_ptr(), uid, gid) };
			}
		}
	}
}

pub fn run(o: Opts, stop: Arc<AtomicBool>) -> Result<i32, String> {
	let plan = plan(&o.roots, &o.threads)?;
	for d in &plan.dropped {
		err!("skipping root {d}");
	}
	if plan.groups.is_empty() {
		return Err("nothing to scan".into());
	}
	let db_path = canonical_db(&o.db)?;
	let _lock = lock(&db_path)?;
	let conn = db::open_rw(&db_path)?;
	let e = |e: rusqlite::Error| format!("database: {e}");

	let started = now_us();
	let roots = roots_key(&plan.groups);
	let (run_id, cutoff_us, run_started, earlier) = if o.resume {
		let r = pick_resume(&conn, &roots)?;
		(r.id, r.cutoff_us, r.started_us, r.summary)
	} else {
		// The lock is held, so a run still marked running died without a
		// word. A new run means it won't be resumed.
		conn.execute(
			"UPDATE runs SET status = 'killed' WHERE status = 'running'",
			[],
		)
		.map_err(e)?;
		let cutoff = o.since.unwrap_or_else(|| local_midnight_us(started));
		conn.execute(
			"INSERT INTO runs (started_us, cutoff_us, status, host, args, roots) VALUES (?1, ?2, 'running', ?3, ?4, ?5)",
			rusqlite::params![started, cutoff, host(), o.args, roots],
		)
		.map_err(e)?;
		(conn.last_insert_rowid(), cutoff, started, None)
	};
	conn.execute("UPDATE runs SET status = 'running' WHERE id = ?1", [run_id])
		.map_err(e)?;
	out!(
		"run {run_id}: files checksummed since {} are skipped",
		fmt_local(cutoff_us)
	);

	let (tx, rx) = sync_channel::<Msg>(65536);
	let writer = std::thread::spawn(move || db::writer(conn, run_id, rx));

	let mounts = mounts::read_mounts()?;
	let shared = Arc::new(Shared {
		stop: stop.clone(),
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
		mount_points: mounts::mount_points(&mounts),
		write_xattrs: o.write_xattrs,
		tx,
	});

	let groups: Vec<Arc<Group>> = plan
		.groups
		.into_iter()
		.map(|(name, roots, threads)| {
			Arc::new(Group {
				name,
				roots,
				threads,
				stats: Stats::default(),
				done: AtomicBool::new(false),
			})
		})
		.collect();
	for g in &groups {
		out!("group {} with {} worker(s):", g.name, g.threads);
		for r in &g.roots {
			out!("\t{}", r.display());
		}
	}

	let mut handles = Vec::new();
	for g in &groups {
		let g = g.clone();
		let sh = shared.clone();
		handles.push(std::thread::spawn(move || run_group(&g, &sh)));
	}
	drop(shared);

	let t0 = Instant::now();
	let mut last = Instant::now();
	while !groups.iter().all(|g| g.done.load(Relaxed)) {
		std::thread::sleep(Duration::from_millis(200));
		if last.elapsed() >= Duration::from_secs(o.progress_secs.max(1)) {
			last = Instant::now();
			let secs = t0.elapsed().as_secs_f64().max(1.0);
			for g in &groups {
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
	for h in handles {
		h.join().map_err(|_| "a worker panicked".to_string())?;
	}
	let conn = writer
		.join()
		.map_err(|_| "the database writer panicked".to_string())??;

	let stopped = stop.load(Relaxed);
	// The stored summary keeps every part's lines; the output shows this
	// part's. The events line is the whole run's either way.
	let mut part = String::new();
	for g in &groups {
		part.push_str(&format!("{}: {}\n", g.name, g.stats.line()));
	}
	let counts = run_events(&conn, run_id).map_err(e)?;
	part.push_str(&events_line(&counts));
	let mut summary = String::new();
	if let Some(prev) = earlier {
		for l in prev.lines().filter(|l| !l.starts_with(EVENTS_LINE)) {
			summary.push_str(l);
			summary.push('\n');
		}
		summary.push_str(&format!("resumed {}\n", fmt_local(started)));
	}
	summary.push_str(&part);
	let status = if stopped { "stopped" } else { "done" };
	conn.execute(
		"UPDATE runs SET status = ?1, finished_us = ?2, summary = ?3 WHERE id = ?4",
		rusqlite::params![status, now_us(), summary, run_id],
	)
	.map_err(e)?;
	db::close_rw(conn).map_err(e)?;
	give_back(&[db_path.clone(), lock_path(&db_path)]);

	out!(
		"run {run_id} {status} after {}s\n{part}",
		t0.elapsed().as_secs()
	);
	if stopped {
		out!("Continue it with the same command plus --resume.");
	}
	// 2 adds to the others, so a stop says what was found before it.
	Ok(exit_bits(&counts) | if stopped { 2 } else { 0 })
}

fn run_group(g: &Group, sh: &Shared) {
	let (jtx, jrx) = sync_channel::<Job>(1024);
	let jrx = Arc::new(Mutex::new(jrx));
	let links = Arc::new(Links::default());
	std::thread::scope(|s| {
		for _ in 0..g.threads {
			let jrx = jrx.clone();
			let links = links.clone();
			s.spawn(move || hasher(g, sh, &jrx, &links));
		}
		for r in &g.roots {
			if sh.stop.load(Relaxed) {
				break;
			}
			walk(r, sh, &g.stats, &jtx);
		}
		drop(jtx);
	});
	g.done.store(true, Relaxed);
}

fn event(sh: &Shared, kind: Kind, path: &Path, detail: String) {
	send(
		sh,
		Msg::Event {
			kind: kind.name(),
			path: path.as_os_str().as_bytes().to_vec(),
			detail,
		},
	);
}

// The database, its journal files and its lock all start with its name.
fn excluded(sh: &Shared, p: &Path) -> bool {
	let own = p.parent() == sh.db.parent()
		&& p.file_name()
			.zip(sh.db.file_name())
			.is_some_and(|(n, d)| n.as_bytes().starts_with(d.as_bytes()));
	own || sh.excludes.iter().any(|x| p.starts_with(x))
}

// A dead writer means nothing more can be recorded, so stop rather than read
// files for nothing.
fn send(sh: &Shared, m: Msg) {
	if sh.tx.send(m).is_err() {
		sh.stop.store(true, Relaxed);
	}
}

pub fn lock_path(db: &Path) -> PathBuf {
	let mut s = db.as_os_str().to_owned();
	s.push(".lock");
	PathBuf::from(s)
}

// The database may not exist yet, so only its folder can be resolved.
pub fn canonical_db(db: &Path) -> Result<PathBuf, String> {
	crate::util::canonical_name(db)
}

// Depth first, files before folders. Folders go in name order; files go in
// inode order, which on most filesystems is close to the order on disk.
fn walk(root: &Path, sh: &Shared, stats: &Stats, jobs: &SyncSender<Job>) {
	let mut stack: Vec<(PathBuf, bool)> = vec![(root.to_path_buf(), false)];
	while let Some((dir, git_above)) = stack.pop() {
		if sh.stop.load(Relaxed) {
			return;
		}
		let rd = match fs::read_dir(&dir) {
			Ok(rd) => rd,
			// Gone since it was listed, like a file that goes before it's
			// opened.
			Err(e) if e.kind() == io::ErrorKind::NotFound => continue,
			Err(e) => {
				stats.other_err.fetch_add(1, Relaxed);
				event(sh, Kind::DirError, &dir, e.to_string());
				continue;
			}
		};
		let mut files: Vec<(u64, PathBuf)> = Vec::new();
		let mut dirs: Vec<PathBuf> = Vec::new();
		let mut in_git = git_above;
		for ent in rd {
			// std ends the listing at an error, so the rest of the folder
			// goes unread. An EIO in a damaged folder block is the case.
			let ent = match ent {
				Ok(ent) => ent,
				Err(e) => {
					stats.other_err.fetch_add(1, Relaxed);
					let n = files.len() + dirs.len();
					event(
						sh,
						Kind::DirError,
						&dir,
						format!("{e}, after {n} entries; the rest weren't read"),
					);
					break;
				}
			};
			let name = ent.file_name();
			if name == ".git" {
				in_git = true;
			}
			let ft = match ent.file_type() {
				Ok(ft) => ft,
				Err(e) if e.kind() == io::ErrorKind::NotFound => continue,
				Err(e) => {
					stats.other_err.fetch_add(1, Relaxed);
					event(sh, Kind::StatError, &ent.path(), e.to_string());
					continue;
				}
			};
			let p = ent.path();
			if ft.is_dir() {
				if name == ".zfs" && sh.mount_points.get(&dir).is_some_and(|t| t == "zfs") {
					continue;
				}
				if sh.mount_points.contains_key(&p) || excluded(sh, &p) {
					continue;
				}
				dirs.push(p);
			} else if ft.is_file() && !excluded(sh, &p) {
				files.push((ent.ino(), p));
			}
		}
		files.sort_unstable();
		for (_, p) in files {
			if jobs.send(Job { path: p, in_git }).is_err() {
				return;
			}
		}
		dirs.sort_unstable();
		for d in dirs.into_iter().rev() {
			stack.push((d, in_git));
		}
	}
}

type LinkVal = (i64, i64, Sums);

// Each entry counts down the names still to come and goes when it hits zero,
// so a backup tree full of hard links doesn't keep every inode in memory.
type LinkEntry = Option<(LinkVal, u64)>;

// Hard links to one file. The first worker to reach an inode claims it, and
// any other name for it waits for that result rather than reading the file a
// second time. Reading it alongside would also see the first worker's xattr
// write move the ctime, and call the file unstable.
#[derive(Default)]
struct Links {
	map: Mutex<HashMap<(u64, u64), LinkEntry>>,
	cv: Condvar,
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
		self.links
			.map
			.lock()
			.unwrap()
			.insert(self.key, Some((v, self.others)));
	}
}

impl Drop for ClaimGuard<'_> {
	// Unfilled means the read failed or was stopped; let the next name try.
	fn drop(&mut self) {
		let mut m = self.links.map.lock().unwrap();
		if matches!(m.get(&self.key), Some(None)) {
			m.remove(&self.key);
		}
		self.links.cv.notify_all();
	}
}

impl Links {
	fn claim(&self, key: (u64, u64), nlink: u64, bytes: i64, mt: i64) -> Claim<'_> {
		let mut m = self.map.lock().unwrap();
		loop {
			match m.get_mut(&key) {
				Some(Some((v, left))) if v.0 == bytes && v.1 == mt => {
					let v = *v;
					*left = left.saturating_sub(1);
					if *left == 0 {
						m.remove(&key);
					}
					return Claim::Done(v);
				}
				Some(None) => m = self.cv.wait(m).unwrap(),
				_ => {
					m.insert(key, None);
					return Claim::Mine(ClaimGuard {
						links: self,
						key,
						others: nlink.saturating_sub(1),
					});
				}
			}
		}
	}
}

fn hasher(g: &Group, sh: &Shared, jobs: &Mutex<Receiver<Job>>, links: &Links) {
	let conn = match db::open_ro(&sh.db) {
		Ok(c) => c,
		Err(e) => {
			err!("{e}");
			sh.stop.store(true, Relaxed);
			return;
		}
	};
	let mut stmt = conn.prepare(db::LOOKUP).expect("lookup statement");
	let mut buf = vec![0u8; 1 << 20];
	let mut xattr_fail_logged = 0;
	loop {
		let job = match jobs.lock().unwrap().recv() {
			Ok(j) => j,
			Err(_) => return,
		};
		if sh.stop.load(Relaxed) {
			continue;
		}
		let prior = match db::lookup(&mut stmt, job.path.as_os_str().as_bytes()) {
			Ok(p) => p,
			Err(e) => {
				g.stats.other_err.fetch_add(1, Relaxed);
				event(sh, Kind::DbError, &job.path, e.to_string());
				continue;
			}
		};
		one_file(g, sh, &job, prior, &mut buf, links, &mut xattr_fail_logged);
	}
}

pub fn mtime_us(md: &fs::Metadata) -> i64 {
	md.mtime() * 1_000_000 + md.mtime_nsec() / 1000
}

pub fn open_noatime(p: &Path) -> io::Result<File> {
	let base = libc::O_NOFOLLOW | libc::O_NONBLOCK;
	match OpenOptions::new()
		.read(true)
		.custom_flags(base | libc::O_NOATIME)
		.open(p)
	{
		// O_NOATIME needs ownership or root.
		Err(e) if e.raw_os_error() == Some(libc::EPERM) => {
			OpenOptions::new().read(true).custom_flags(base).open(p)
		}
		r => r,
	}
}

/// What one read of a file came to.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Sums {
	pub b3: [u8; 32],
	pub b2: Option<[u8; 64]>,
}

#[derive(Debug)]
pub enum ReadFail {
	Stopped,
	Io(io::Error, u64),
	Unstable,
}

// Reads the whole file from the start. Its cached pages are dropped first, so
// a scribble in the page cache isn't taken for what's on disk. ZFS ignores the
// advice; see design.md, Reading files.
pub fn read_sums(
	file: &File,
	before: &fs::Metadata,
	want_b2: bool,
	buf: &mut [u8],
	stop: &AtomicBool,
	read_bytes: &AtomicU64,
) -> Result<Sums, ReadFail> {
	let fd = file.as_raw_fd();
	unsafe {
		libc::posix_fadvise(fd, 0, 0, libc::POSIX_FADV_DONTNEED);
		libc::posix_fadvise(fd, 0, 0, libc::POSIX_FADV_SEQUENTIAL);
	}
	let mut b3 = blake3::Hasher::new();
	let mut b2 = want_b2.then(<blake2::Blake2b512 as blake2::Digest>::new);
	let mut total: u64 = 0;
	loop {
		if stop.load(Relaxed) {
			return Err(ReadFail::Stopped);
		}
		match file.read_at(buf, total) {
			Ok(0) => break,
			Ok(n) => {
				b3.update(&buf[..n]);
				if let Some(h) = b2.as_mut() {
					blake2::Digest::update(h, &buf[..n]);
				}
				total += n as u64;
			}
			Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
			Err(e) => {
				read_bytes.fetch_add(total, Relaxed);
				return Err(ReadFail::Io(e, total));
			}
		}
	}
	unsafe { libc::posix_fadvise(fd, 0, 0, libc::POSIX_FADV_DONTNEED) };
	read_bytes.fetch_add(total, Relaxed);
	let after = file.metadata().map_err(|e| ReadFail::Io(e, total))?;
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
		b2: b2.map(|h| blake2::Digest::finalize(h).into()),
	})
}

fn report_fail(sh: &Shared, st: &Stats, path: &Path, fail: ReadFail) {
	match fail {
		ReadFail::Stopped => {}
		// On ZFS an EIO here is a block that failed its checksum with no
		// good copy left. That is the same news as a mismatch.
		ReadFail::Io(e, at) => {
			st.read_err.fetch_add(1, Relaxed);
			event(sh, Kind::ReadError, path, format!("{e} at byte {at}"));
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
	b2: Option<[u8; 64]>,
	db: Option<&'a Prior>,
}

type Miss = (Kind, String);

impl<'a> Refs<'a> {
	fn new(onfile: &OnFile, prior: Option<&'a Prior>, md: &fs::Metadata) -> Refs<'a> {
		let (bytes, mt) = (md.len() as i64, mtime_us(md));
		let mtime_s = md.mtime() as f64 + md.mtime_nsec() as f64 / 1e9;
		Refs {
			xattr: onfile.b3_current(bytes, mt),
			xattr_date: onfile.b3_date_us,
			b2: onfile.b2_current(mtime_s),
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
		if let (Some(stored), Some(now)) = (self.b2, s.b2) {
			if stored != now {
				out.push((
					Kind::RmlintMismatch,
					format!("on file {}, read now {}", hex(&stored), hex(&now)),
				));
			}
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
		if self.b2.is_some() && s.b2.is_some() {
			st.b2_ok.fetch_add(1, Relaxed);
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
	if prior.is_some_and(|p| p.seen_run != sh.run_id) {
		send(sh, Msg::Seen(path.as_os_str().as_bytes().to_vec()));
	}
}

fn hashed_msg(path: &[u8], s: &Sums, md: &fs::Metadata, hashed_us: i64) -> Msg {
	Msg::Hashed(Box::new(Hashed {
		path: path.to_vec(),
		b3: s.b3,
		b2: s.b2,
		bytes: md.len() as i64,
		mtime_us: mtime_us(md),
		ino: md.ino() as i64,
		hashed_us,
	}))
}

fn one_file(
	g: &Group,
	sh: &Shared,
	job: &Job,
	prior: Option<Prior>,
	buf: &mut [u8],
	links: &Links,
	xattr_fail_logged: &mut u32,
) {
	let st = &g.stats;
	let path = &job.path;
	let pbytes = path.as_os_str().as_bytes();
	let md = match fs::symlink_metadata(path) {
		Ok(m) if m.file_type().is_file() => m,
		Ok(_) => return,
		Err(e) if e.kind() == io::ErrorKind::NotFound => return,
		Err(e) => {
			st.other_err.fetch_add(1, Relaxed);
			event(sh, Kind::StatError, path, e.to_string());
			return;
		}
	};
	st.files.fetch_add(1, Relaxed);
	let (bytes, mt) = (md.len() as i64, mtime_us(&md));

	if let Some(p) = &prior {
		// An earlier part of this run already judged it, mismatch or not, so
		// a resumed run doesn't read and report it twice.
		if (p.hashed_us >= sh.cutoff_us || p.seen_run == sh.run_id)
			&& p.bytes == bytes
			&& p.mtime_us == mt
			&& p.ino == md.ino() as i64
		{
			if p.seen_run != sh.run_id {
				send(sh, Msg::Seen(pbytes.to_vec()));
			}
			st.skip_db.fetch_add(1, Relaxed);
			return;
		}
	}

	let file = match open_noatime(path) {
		Ok(f) => f,
		Err(e) if e.kind() == io::ErrorKind::NotFound => return,
		Err(e) => {
			st.other_err.fetch_add(1, Relaxed);
			event(sh, Kind::OpenError, path, e.to_string());
			return;
		}
	};
	let fd = file.as_raw_fd();
	let before = match file.metadata() {
		Ok(m) if m.file_type().is_file() => m,
		Ok(_) => return,
		Err(e) => {
			st.other_err.fetch_add(1, Relaxed);
			event(sh, Kind::StatError, path, e.to_string());
			return;
		}
	};
	let (bytes, mt) = (before.len() as i64, mtime_us(&before));
	let onfile = OnFile::read(fd);
	let refs = Refs::new(&onfile, prior.as_ref(), &before);

	// Another name for this inode may have left a fresh set without ever
	// seeing this name's row, so the row gets a say.
	if let Some((d, date)) = onfile
		.b3_fresh(
			bytes,
			mt,
			before.dev(),
			before.ino(),
			sh.cutoff_us,
			now_us(),
		)
		.filter(|(d, _)| refs.db.is_none_or(|p| p.b3 == d))
	{
		st.skip_xattr.fetch_add(1, Relaxed);
		send(
			sh,
			hashed_msg(pbytes, &Sums { b3: d, b2: None }, &before, date),
		);
		return;
	}

	let mut claim = None;
	if before.nlink() > 1 {
		match links.claim((before.dev(), before.ino()), before.nlink(), bytes, mt) {
			// Read once, but each name is held to its own records.
			Claim::Done((_, _, sums)) => {
				st.links.fetch_add(1, Relaxed);
				let misses = refs.misses(&sums);
				if !misses.is_empty() {
					keep(sh, st, path, prior.as_ref(), misses, "");
					return;
				}
				refs.tally(&sums, st);
				send(sh, hashed_msg(pbytes, &sums, &before, now_us()));
				return;
			}
			Claim::Mine(g) => claim = Some(g),
		}
	}

	let want_b2 = refs.b2.is_some();
	let first = match read_sums(&file, &before, want_b2, buf, &sh.stop, &st.bytes) {
		Ok(s) => s,
		Err(f) => return report_fail(sh, st, path, f),
	};
	st.hashed.fetch_add(1, Relaxed);
	let verdict = judge(&refs, first, || {
		read_sums(&file, &before, want_b2, buf, &sh.stop, &st.bytes)
	});
	let sums = match verdict {
		Err(f) => return report_fail(sh, st, path, f),
		Ok(Verdict::Clean(s)) => s,
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
			second
		}
		Ok(Verdict::Changed { sums, misses, note }) => {
			if let Some(c) = claim {
				c.fill((bytes, mt, sums));
			}
			keep(sh, st, path, prior.as_ref(), misses, &note);
			return;
		}
	};
	refs.tally(&sums, st);

	let hashed_us = now_us();
	if let Some(c) = claim {
		c.fill((bytes, mt, sums));
	}
	send(sh, hashed_msg(pbytes, &sums, &before, hashed_us));

	// Not inside a git checkout: the files come and go with every checkout,
	// git already checksums what it keeps, and a ctime change makes git
	// look at each file again.
	if sh.write_xattrs && !job.in_git && !sh.no_xattr.iter().any(|x| path.starts_with(x)) {
		let only_date = refs.xattr == Some(sums.b3);
		let id = (before.dev(), before.ino());
		match xattr::write_b3(fd, &sums.b3, bytes, mt, hashed_us, id, only_date) {
			Ok(()) => {
				st.xattr_set.fetch_add(1, Relaxed);
			}
			Err(e) => {
				st.xattr_fail.fetch_add(1, Relaxed);
				// A read-only or xattr-less filesystem fails for every
				// file. A few events are enough to say so.
				if *xattr_fail_logged < 20 {
					*xattr_fail_logged += 1;
					event(sh, Kind::XattrError, path, e.to_string());
				}
			}
		}
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	fn sums(b: u8) -> Sums {
		Sums {
			b3: [b; 32],
			b2: None,
		}
	}

	fn refs(xattr: Option<u8>, db: Option<&Prior>) -> Refs<'_> {
		Refs {
			xattr: xattr.map(|b| [b; 32]),
			xattr_date: None,
			b2: None,
			db,
		}
	}

	fn prior(b: u8) -> Prior {
		Prior {
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
		let p = prior(1);
		let v = judge(&refs(Some(1), Some(&p)), sums(1), || panic!("read again")).unwrap();
		assert!(matches!(v, Verdict::Clean(s) if s == sums(1)));
		// Nothing stored to disagree with.
		let v = judge(&refs(None, None), sums(5), || panic!("read again")).unwrap();
		assert!(matches!(v, Verdict::Clean(_)));
	}

	#[test]
	fn a_second_read_tells_cache_from_disk() {
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
		let p = prior(1);
		// The database agrees, the attribute doesn't.
		let r = refs(Some(2), Some(&p));
		let kinds: Vec<_> = r.misses(&sums(1)).iter().map(|m| m.0.name()).collect();
		assert_eq!(kinds, ["b3-xattr-mismatch"]);
		let r = Refs {
			b2: Some([7; 64]),
			..refs(None, None)
		};
		let s = Sums {
			b3: [1; 32],
			b2: Some([8; 64]),
		};
		assert_eq!(r.misses(&s)[0].0.name(), "b2-rmlint-mismatch");
	}

	#[test]
	fn exit_bits_add_up() {
		let c =
			|k: &[&str]| -> Vec<(String, i64)> { k.iter().map(|k| (k.to_string(), 1)).collect() };
		assert_eq!(exit_bits(&c(&[])), 0);
		assert_eq!(exit_bits(&c(&["unstable", "xattr-error"])), 0);
		assert_eq!(exit_bits(&c(&["cache-mismatch"])), 4);
		assert_eq!(exit_bits(&c(&["read-error", "b3-db-mismatch"])), 4);
		assert_eq!(exit_bits(&c(&["dir-error"])), 8);
		assert_eq!(exit_bits(&c(&["db-error", "b2-rmlint-mismatch"])), 12);
		assert_eq!(exit_bits(&c(&["from-a-newer-version"])), 8);
		assert_eq!(exit_bits(&[("dir-error".into(), 0)]), 0);
		// Every kind has a name of its own, which is what's stored.
		let names: BTreeSet<_> = Kind::ALL.iter().map(|k| k.name()).collect();
		assert_eq!(names.len(), Kind::ALL.len());
	}

	#[test]
	fn roots_key_ignores_order() {
		let g = |rs: &[&str]| vec![("g".to_string(), rs.iter().map(PathBuf::from).collect(), 1)];
		let a = roots_key(&[g(&["/b", "/a"]), g(&["/c"])].concat());
		let b = roots_key(&[g(&["/c"]), g(&["/a", "/b"])].concat());
		assert_eq!(a, b);
		assert_ne!(a, roots_key(&g(&["/a", "/b"])));
		assert_eq!(
			roots_diff(&a, &roots_key(&g(&["/a", "/d"]))),
			"not given now: /b, /c; not in that run: /d"
		);
	}
}
