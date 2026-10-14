// Copyright © 2026 t00mietum (CryptogID: ปʬϝღถɔ4რఠΔթะ9ƾǝu)
// Licensed under GPL-2.0-only. No warranty.

// Walks each root, checksums every regular file, and compares the result with
// whatever was known before: the blake3 on the file, rmlint's blake2b on the
// file, and the database. A file whose size and time didn't change but whose
// contents did is the thing this is looking for.

use crate::db::{self, Hashed, Msg, Prior};
use crate::mounts;
use crate::util::{b64u_encode, fmt_local, hex, human_bytes, local_midnight_us, now_us};
use crate::xattr::{self, OnFile};
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read};
use std::os::fd::AsRawFd;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{DirEntryExt, MetadataExt, OpenOptionsExt};
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

fn lock(db: &Path) -> Result<File, String> {
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

fn host() -> String {
	fs::read_to_string("/proc/sys/kernel/hostname")
		.map(|s| s.trim().to_string())
		.unwrap_or_default()
}

// Hand the files back to whoever ran this through sudo, so reports and
// queries need no root.
fn give_back(paths: &[PathBuf]) {
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
	let (run_id, cutoff_us, run_started) = if o.resume {
		conn.query_row(
			"SELECT id, cutoff_us, started_us FROM runs WHERE status != 'done' ORDER BY id DESC LIMIT 1",
			[],
			|r| Ok((r.get::<_, i64>(0)?, r.get::<_, i64>(1)?, r.get::<_, i64>(2)?)),
		)
		.map_err(|_| "no unfinished run to resume".to_string())?
	} else {
		let cutoff = o.since.unwrap_or_else(|| local_midnight_us(started));
		conn.execute(
			"INSERT INTO runs (started_us, cutoff_us, status, host, args) VALUES (?1, ?2, 'running', ?3, ?4)",
			rusqlite::params![started, cutoff, host(), o.args],
		)
		.map_err(e)?;
		(conn.last_insert_rowid(), cutoff, started)
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
	let mut summary = String::new();
	let mut bad = 0;
	for g in &groups {
		summary.push_str(&format!("{}: {}\n", g.name, g.stats.line()));
		bad += g.stats.mismatch.load(Relaxed) + g.stats.read_err.load(Relaxed);
	}
	let status = if stopped { "stopped" } else { "done" };
	conn.execute(
		"UPDATE runs SET status = ?1, finished_us = ?2, summary = ?3 WHERE id = ?4",
		rusqlite::params![status, now_us(), summary, run_id],
	)
	.map_err(e)?;
	db::close_rw(conn).map_err(e)?;
	give_back(&[db_path.clone(), lock_path(&db_path)]);

	out!(
		"run {run_id} {status} after {}s\n{summary}",
		t0.elapsed().as_secs()
	);
	if stopped {
		out!("Continue it with the same command plus --resume.");
		return Ok(2);
	}
	Ok(if bad > 0 { 4 } else { 0 })
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

fn event(sh: &Shared, kind: &'static str, path: &Path, detail: String) {
	send(
		sh,
		Msg::Event {
			kind,
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
	let parent = db
		.parent()
		.filter(|p| !p.as_os_str().is_empty())
		.unwrap_or(Path::new("."));
	let dir = fs::canonicalize(parent).map_err(|e| format!("{}: {e}", parent.display()))?;
	let name = db
		.file_name()
		.ok_or_else(|| format!("{}: not a file name", db.display()))?;
	Ok(dir.join(name))
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
			Err(e) => {
				stats.other_err.fetch_add(1, Relaxed);
				event(sh, "dir-error", &dir, e.to_string());
				continue;
			}
		};
		let mut files: Vec<(u64, PathBuf)> = Vec::new();
		let mut dirs: Vec<PathBuf> = Vec::new();
		let mut in_git = git_above;
		for ent in rd.flatten() {
			let name = ent.file_name();
			if name == ".git" {
				in_git = true;
			}
			let Ok(ft) = ent.file_type() else { continue };
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

type LinkVal = (i64, i64, [u8; 32], Option<[u8; 64]>);

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
		let prior = db::lookup(&mut stmt, job.path.as_os_str().as_bytes());
		one_file(g, sh, &job, prior, &mut buf, links, &mut xattr_fail_logged);
	}
}

fn mtime_us(md: &fs::Metadata) -> i64 {
	md.mtime() * 1_000_000 + md.mtime_nsec() / 1000
}

fn open_noatime(p: &Path) -> io::Result<File> {
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
			event(sh, "stat-error", path, e.to_string());
			return;
		}
	};
	st.files.fetch_add(1, Relaxed);
	let (bytes, mt) = (md.len() as i64, mtime_us(&md));

	if let Some(p) = &prior {
		if p.hashed_us >= sh.cutoff_us
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
			event(sh, "open-error", path, e.to_string());
			return;
		}
	};
	let fd = file.as_raw_fd();
	let before = match file.metadata() {
		Ok(m) if m.file_type().is_file() => m,
		_ => return,
	};
	let (bytes, mt, ino) = (before.len() as i64, mtime_us(&before), before.ino() as i64);
	let onfile = OnFile::read(fd);

	if let Some((d, date)) = onfile.b3_fresh(
		bytes,
		mt,
		before.dev(),
		before.ino(),
		sh.cutoff_us,
		now_us(),
	) {
		st.skip_xattr.fetch_add(1, Relaxed);
		send(
			sh,
			Msg::Hashed(Box::new(Hashed {
				path: pbytes.to_vec(),
				b3: d,
				b2: None,
				bytes,
				mtime_us: mt,
				ino,
				hashed_us: date,
			})),
		);
		return;
	}

	let mut claim = None;
	if before.nlink() > 1 {
		match links.claim((before.dev(), before.ino()), before.nlink(), bytes, mt) {
			Claim::Done((_, _, d, b2)) => {
				st.links.fetch_add(1, Relaxed);
				send(
					sh,
					Msg::Hashed(Box::new(Hashed {
						path: pbytes.to_vec(),
						b3: d,
						b2,
						bytes,
						mtime_us: mt,
						ino,
						hashed_us: now_us(),
					})),
				);
				return;
			}
			Claim::Mine(g) => claim = Some(g),
		}
	}

	let mtime_s = before.mtime() as f64 + before.mtime_nsec() as f64 / 1e9;
	let want_b2 = onfile.b2_current(mtime_s);
	unsafe { libc::posix_fadvise(fd, 0, 0, libc::POSIX_FADV_SEQUENTIAL) };
	let mut b3 = blake3::Hasher::new();
	let mut b2 = want_b2.map(|_| <blake2::Blake2b512 as blake2::Digest>::new());
	let mut f = &file;
	let mut total: u64 = 0;
	loop {
		if sh.stop.load(Relaxed) {
			return;
		}
		match f.read(buf) {
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
				// On ZFS an EIO here is a block that failed its checksum
				// with no good copy left. That is the same news as a
				// mismatch.
				st.read_err.fetch_add(1, Relaxed);
				event(sh, "read-error", path, format!("{e} at byte {total}"));
				return;
			}
		}
	}
	unsafe { libc::posix_fadvise(fd, 0, 0, libc::POSIX_FADV_DONTNEED) };
	st.bytes.fetch_add(total, Relaxed);

	let after = match file.metadata() {
		Ok(m) => m,
		Err(_) => return,
	};
	if after.len() != before.len()
		|| mtime_us(&after) != mt
		|| after.ctime() != before.ctime()
		|| after.ctime_nsec() != before.ctime_nsec()
		|| total != before.len()
	{
		st.unstable.fetch_add(1, Relaxed);
		event(sh, "unstable", path, "changed while being read".into());
		return;
	}
	st.hashed.fetch_add(1, Relaxed);
	let digest: [u8; 32] = *b3.finalize().as_bytes();
	let b2_digest: Option<[u8; 64]> = b2.map(|h| blake2::Digest::finalize(h).into());

	if let Some(stored) = onfile.b3_current(bytes, mt) {
		if stored == digest {
			st.b3_ok.fetch_add(1, Relaxed);
		} else {
			st.mismatch.fetch_add(1, Relaxed);
			let when = onfile
				.b3_date_us
				.map(fmt_local)
				.unwrap_or_else(|| "unknown".into());
			event(
				sh,
				"b3-xattr-mismatch",
				path,
				format!(
					"on file {} (taken {when}), read now {}",
					b64u_encode(&stored),
					b64u_encode(&digest)
				),
			);
		}
	}
	if let (Some(stored), Some(now)) = (want_b2, b2_digest) {
		if stored == now {
			st.b2_ok.fetch_add(1, Relaxed);
		} else {
			st.mismatch.fetch_add(1, Relaxed);
			event(
				sh,
				"b2-rmlint-mismatch",
				path,
				format!("on file {}, read now {}", hex(&stored), hex(&now)),
			);
		}
	}
	if let Some(p) = &prior {
		if p.bytes == bytes && p.mtime_us == mt {
			if p.b3 == digest {
				st.db_ok.fetch_add(1, Relaxed);
			} else {
				st.mismatch.fetch_add(1, Relaxed);
				event(
					sh,
					"b3-db-mismatch",
					path,
					format!(
						"database {} (taken {}), read now {}",
						b64u_encode(&p.b3),
						fmt_local(p.hashed_us),
						b64u_encode(&digest)
					),
				);
			}
		}
	}

	let hashed_us = now_us();
	if let Some(c) = claim {
		c.fill((bytes, mt, digest, b2_digest));
	}
	send(
		sh,
		Msg::Hashed(Box::new(Hashed {
			path: pbytes.to_vec(),
			b3: digest,
			b2: b2_digest,
			bytes,
			mtime_us: mt,
			ino,
			hashed_us,
		})),
	);

	// Not inside a git checkout: the files come and go with every checkout,
	// git already checksums what it keeps, and a ctime change makes git
	// look at each file again.
	if sh.write_xattrs && !job.in_git && !sh.no_xattr.iter().any(|x| path.starts_with(x)) {
		let only_date = onfile.b3_current(bytes, mt) == Some(digest);
		let id = (before.dev(), before.ino());
		match xattr::write_b3(fd, &digest, bytes, mt, hashed_us, id, only_date) {
			Ok(()) => {
				st.xattr_set.fetch_add(1, Relaxed);
			}
			Err(e) => {
				st.xattr_fail.fetch_add(1, Relaxed);
				// A read-only or xattr-less filesystem fails for every
				// file. A few events are enough to say so.
				if *xattr_fail_logged < 20 {
					*xattr_fail_logged += 1;
					event(sh, "xattr-error", path, e.to_string());
				}
			}
		}
	}
}
