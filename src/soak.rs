// Copyright © 2026 t00mietum (CryptogID: ปʬϝღถɔ4რఠΔթะ9ƾǝu)
// Licensed under GPL-2.0-only. No warranty.

// The soak test: scan, change a file, scan again, then status and accept, in
// a loop in this process, with the heap at round 2N held to round N. Only
// with --features soak, since dhat then counts every allocation in the test
// binary and only one profiler can run at once. cicd/utility/soak.bash runs
// it alone. SQLite allocates through libc, which dhat doesn't see, so its own
// counter is held to the same margin.

#[global_allocator]
static ALLOC: dhat::Alloc = dhat::Alloc;

use crate::util::{local_midnight_us, now_us};
use crate::{accept, gone, scan};
use std::fmt::Write as _;
use std::fs::{self, File, FileTimes};
use std::os::unix::fs::FileExt;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::AtomicBool;

// Round N is half of these. The first rounds fill what fills once, such as
// SQLite's globals and stdout's buffer, so it's N against 2N, never 0 against N.
const ROUNDS: usize = 20;
// What either heap may grow by from round N to 2N, in bytes.
const MARGIN: usize = 4096;

struct Tree {
	dir: PathBuf,
	root: PathBuf,
	db: PathBuf,
	flipped: [PathBuf; 2],
	edited: PathBuf,
}

fn tree() -> Tree {
	let dir = std::env::temp_dir().join(format!("test_tukfs-hash_soak_{}", std::process::id()));
	_ = fs::remove_dir_all(&dir);
	let root = dir.join("tree");
	fs::create_dir_all(root.join("sub dir")).unwrap();
	fs::create_dir_all(dir.join("db")).unwrap();
	let big: Vec<u8> = (0..1_500_000u32).map(|i| (i % 251) as u8).collect();
	fs::write(root.join("big.bin"), big).unwrap();
	fs::hard_link(root.join("big.bin"), root.join("sub dir/big-link.bin")).unwrap();
	for i in 0..30 {
		fs::write(root.join(format!("sub dir/f{i}")), format!("file {i}\n")).unwrap();
	}
	fs::write(root.join("edited.txt"), "0").unwrap();
	Tree {
		db: dir.join("db/t.sqlite"),
		flipped: [root.join("big.bin"), root.join("sub dir/big-link.bin")],
		edited: root.join("edited.txt"),
		root,
		dir,
	}
}

// A byte changed with the time put back, as bad RAM leaves a file.
fn flip(p: &Path, at: u64) {
	let f = File::options().read(true).write(true).open(p).unwrap();
	let mtime = f.metadata().unwrap().modified().unwrap();
	let mut b = [0u8; 1];
	f.read_exact_at(&mut b, at).unwrap();
	f.write_all_at(&[b[0] ^ 0x5a], at).unwrap();
	f.set_times(FileTimes::new().set_modified(mtime)).unwrap();
}

fn scan(t: &Tree, since: Option<i64>) -> i32 {
	let o = scan::Opts {
		db: t.db.clone(),
		roots: vec![t.root.clone()],
		excludes: Vec::new(),
		no_xattr: Vec::new(),
		threads: Vec::new(),
		since,
		resume: false,
		mode: scan::Mode::Full,
		write_xattrs: true,
		rmlint: true,
		progress_secs: 3600,
		args: "soak".into(),
	};
	scan::run(&o, &Arc::new(AtomicBool::new(false))).unwrap()
}

#[derive(Clone, Copy, Default)]
struct Heap {
	rust: usize,
	blocks: usize,
	rust_total: u64,
	sqlite: i64,
	sqlite_peak: i64,
}

fn heap() -> Heap {
	let s = dhat::HeapStats::get();
	// SAFETY: these read and reset SQLite's own counts of what it has
	// allocated, and take nothing that could dangle.
	let (sqlite, sqlite_peak) = unsafe {
		(
			rusqlite::ffi::sqlite3_memory_used(),
			rusqlite::ffi::sqlite3_memory_highwater(1),
		)
	};
	Heap {
		rust: s.curr_bytes,
		blocks: s.curr_blocks,
		rust_total: s.total_bytes,
		sqlite,
		sqlite_peak,
	}
}

#[test]
fn the_heap_holds_steady() {
	let out = std::env::var_os("TUKFS_SOAK_OUT").map_or_else(std::env::temp_dir, PathBuf::from);
	let t = tree();
	// On the stack, so the table itself isn't growth.
	let mut rows = [Heap::default(); ROUNDS];
	let prof = dhat::Profiler::builder()
		.testing()
		.file_name(out.join("dhat-heap.json"))
		.build();
	// Past tomorrow's midnight, so every file is read again.
	let tomorrow = local_midnight_us(now_us()) + 36 * 3_600_000_000;
	for (i, row) in rows.iter_mut().enumerate() {
		// An edit that changes the time, which is no event.
		fs::write(&t.edited, i.to_string()).unwrap();
		assert_eq!(scan(&t, None), 0, "round {}", i + 1);
		flip(&t.flipped[0], i as u64 * 4096);
		assert_eq!(scan(&t, Some(tomorrow)), 4, "round {}", i + 1);
		assert_eq!(crate::runs(&t.db), Ok(0));
		assert_eq!(crate::report(&t.db, None, None, 200), Ok(0));
		assert_eq!(gone::run(&t.db, None, 200), Ok(0));
		assert_eq!(accept::run(&t.db, &t.flipped, "soak"), Ok(0));
		*row = heap();
	}

	let (n, n2) = (rows[ROUNDS / 2 - 1], rows[ROUNDS - 1]);
	let mut table = String::from(
		"round\trust live bytes\trust live blocks\trust allocated\tsqlite live bytes\tsqlite peak\n",
	);
	for (i, r) in rows.iter().enumerate() {
		_ = writeln!(
			table,
			"{}\t{}\t{}\t{}\t{}\t{}",
			i + 1,
			r.rust,
			r.blocks,
			r.rust_total,
			r.sqlite,
			r.sqlite_peak
		);
	}
	_ = writeln!(
		table,
		"round {} to {}: rust {:+} bytes, sqlite {:+} bytes, margin {MARGIN}",
		ROUNDS / 2,
		ROUNDS,
		n2.rust as i64 - n.rust as i64,
		n2.sqlite - n.sqlite
	);
	fs::write(out.join("soak.txt"), &table).unwrap();
	// Counters that saw nothing would pass any leak.
	assert!(
		n2.rust_total > rows[0].rust_total && rows.iter().all(|r| r.sqlite_peak > 0),
		"a heap counter saw nothing; see {}",
		out.join("soak.txt").display()
	);
	dhat::assert!(
		n2.rust <= n.rust + MARGIN,
		"the Rust heap grew from {} to {} bytes between rounds {} and {ROUNDS}",
		n.rust,
		n2.rust,
		ROUNDS / 2
	);
	dhat::assert!(
		n2.sqlite <= n.sqlite + MARGIN as i64,
		"SQLite's heap grew from {} to {} bytes between rounds {} and {ROUNDS}",
		n.sqlite,
		n2.sqlite,
		ROUNDS / 2
	);
	drop(prof);
	fs::remove_dir_all(&t.dir).unwrap();
}
