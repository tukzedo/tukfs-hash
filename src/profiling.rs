// Copyright © 2026 t00mietum (CryptogID: ปʬϝღถɔ4რఠΔթะ9ƾǝu)
// Licensed under GPL-2.0-only. No warranty.

// The cicd profiler stage's sampler, only with --features profiling. It
// samples on SIGPROF in this process, since perf can't record on b23. A run
// with TUKFS_PROFILE_DIR set adds its stacks there under TUKFS_PROFILE_LABEL,
// then draws everything in the dir as one flamegraph, so a first scan and a
// rescan end up side by side. TUKFS_PROFILE_CHECK runs the attribution check
// instead of the command. See design.md, Profiling.

use std::fmt::Write as _;
use std::fs::{self, File, OpenOptions};
use std::hint::black_box;
use std::io::Write as _;
use std::os::unix::fs::FileExt;
use std::path::Path;
use std::time::{Duration, Instant};

// Under the kernel's 250 Hz tick, so each busy thread's samples keep up.
const FREQ: i32 = 199;
// Not libc. A scan's reads and attribute calls end there, and dropping those
// samples would leave the I/O out of the graph. The unwinder itself, the vdso
// and the loader stay out, since unwinding from inside them isn't safe.
const BLOCKLIST: [&str; 3] = ["libgcc", "vdso", "ld-linux"];

/// pprof files a sample under the start address of each function on its stack,
/// then names the whole bucket from the inline frames of whichever sample
/// opened it. LTO folds most of a scan into a few functions, so one name took
/// all of each. It asks libgcc for that start address through this symbol, and
/// one defined in the binary wins over the shared library's, so answering with
/// the address itself files each instruction on its own. From shcl's.
#[unsafe(no_mangle)]
pub extern "C" fn _Unwind_FindEnclosingFunction(
	pc: *mut std::ffi::c_void,
) -> *mut std::ffi::c_void {
	pc
}

fn sampler() -> Result<pprof::ProfilerGuard<'static>, String> {
	pprof::ProfilerGuardBuilder::default()
		.frequency(FREQ)
		.blocklist(&BLOCKLIST)
		.build()
		.map_err(|e| format!("profiler: {e}"))
}

// User and system time, apart. SIGPROF counts both, but a thread in the
// kernel gets fewer of them, so the graph alone undercounts system time.
fn cpu_us() -> (i64, i64) {
	// SAFETY: getrusage only writes the struct it's given.
	let ru = unsafe {
		let mut ru: libc::rusage = std::mem::zeroed();
		libc::getrusage(libc::RUSAGE_SELF, &raw mut ru);
		ru
	};
	let us = |t: libc::timeval| t.tv_sec * 1_000_000 + t.tv_usec;
	(us(ru.ru_utime), us(ru.ru_stime))
}

/// Runs the command as it is, sampled when `TUKFS_PROFILE_DIR` is set.
pub fn sampled(f: impl FnOnce() -> Result<i32, String>) -> Result<i32, String> {
	if std::env::var_os("TUKFS_PROFILE_CHECK").is_some() {
		return Ok(check());
	}
	let Some(dir) = std::env::var_os("TUKFS_PROFILE_DIR") else {
		return f();
	};
	let label = std::env::var("TUKFS_PROFILE_LABEL")
		.unwrap_or_else(|_| "run".into())
		.replace(|c: char| c == ';' || c.is_whitespace(), "-");
	let (wall0, cpu0) = (Instant::now(), cpu_us());
	let guard = sampler()?;
	let code = f();
	let report = guard
		.report()
		.build_unresolved()
		.map_err(|e| format!("profiler: {e}"))?;
	drop(guard);
	let ((user, sys), wall) = (cpu_us(), wall0.elapsed().as_micros());
	let (user, sys) = (user - cpu0.0, sys - cpu0.1);
	let dir = Path::new(&dir);
	let mut folded = String::new();
	let mut kept: isize = 0;
	for (raw, n) in report.data {
		let asm = raw.frames.iter().find_map(|f| asm_name(f.ip() as usize));
		let frames = pprof::Frames::from(raw);
		folded.push_str(&label);
		for frame in frames.frames.iter().rev() {
			for sym in frame.iter().rev() {
				let name = match (sym.name.is_none(), asm) {
					(true, Some(a)) => a.to_string(),
					// A name like <[u8; 32] as T>::f would split the stack.
					_ => sym.name().replace(';', ","),
				};
				_ = write!(folded, ";{name}");
			}
		}
		_ = writeln!(folded, " {n}");
		kept += n;
	}
	let add = |name: &str, text: &str| -> Result<(), String> {
		let p = dir.join(name);
		OpenOptions::new()
			.create(true)
			.append(true)
			.open(&p)
			.and_then(|mut f| f.write_all(text.as_bytes()))
			.map_err(|e| format!("{}: {e}", p.display()))
	};
	add("stacks.folded", &folded)?;
	add(
		"runs.tsv",
		&format!("{label}\t{kept}\t{user}\t{sys}\t{wall}\n"),
	)?;
	draw(dir)?;
	code
}

// blake3's assembly has no unwind info and no symbol sizes, so a sample in it
// comes back as one frame with no name and no callers. It's named here by
// where its functions start, which the linker gives us.
#[cfg(target_arch = "x86_64")]
fn asm_name(ip: usize) -> Option<&'static str> {
	macro_rules! starts {
		($($f:ident),*) => {{
			unsafe extern "C" {
				$(fn $f();)*
			}
			[$(($f as unsafe extern "C" fn() as usize, stringify!($f))),*]
		}};
	}
	let mut starts = starts!(
		blake3_hash_many_sse2,
		blake3_compress_in_place_sse2,
		blake3_compress_xof_sse2,
		blake3_hash_many_sse41,
		blake3_compress_in_place_sse41,
		blake3_compress_xof_sse41,
		blake3_hash_many_avx2,
		blake3_hash_many_avx512,
		blake3_compress_in_place_avx512,
		blake3_compress_xof_avx512
	);
	starts.sort_unstable();
	let i = starts.partition_point(|s| s.0 <= ip).checked_sub(1)?;
	// The last one's end isn't known, and none of them is 16 KB long.
	let end = starts.get(i + 1).map_or(starts[i].0 + 16384, |s| s.0);
	(ip < end).then_some(starts[i].1)
}
#[cfg(not(target_arch = "x86_64"))]
fn asm_name(_: usize) -> Option<&'static str> {
	None
}

// Everything in the dir, into flame.svg beside it. The subtitle has each run's
// user and system CPU against its wall time, which is where waiting on the
// disk shows, and how many samples were kept. flame-report.py reads it.
fn draw(dir: &Path) -> Result<(), String> {
	let read = |name: &str| {
		let p = dir.join(name);
		fs::read_to_string(&p).map_err(|e| format!("{}: {e}", p.display()))
	};
	let (folded, runs) = (read("stacks.folded")?, read("runs.tsv")?);
	let (mut kept, mut cpu_total) = (0i64, 0i64);
	let mut parts = Vec::new();
	for l in runs.lines() {
		let f: Vec<&str> = l.split('\t').collect();
		let num = |i: usize| f.get(i).and_then(|v| v.parse::<i64>().ok()).unwrap_or(0);
		let (user, sys, wall) = (num(2), num(3), num(4));
		kept += num(1);
		cpu_total += user + sys;
		let s = |us: i64| us as f64 / 1e6;
		parts.push(format!(
			"{} {:.2} s user + {:.2} s system in {:.2} s",
			f[0],
			s(user),
			s(sys),
			s(wall)
		));
	}
	let mut opt = pprof::flamegraph::Options::default();
	opt.title = "tukfs-hash scan".into();
	opt.subtitle = Some(format!(
		"{}; {kept} of about {} samples kept",
		parts.join(", "),
		cpu_total * i64::from(FREQ) / 1_000_000
	));
	// Colors by name, so 2 graphs of the same code look alike.
	opt.hash = true;
	let tmp = dir.join("flame.svg.tmp");
	let out = File::create(&tmp).map_err(|e| format!("{}: {e}", tmp.display()))?;
	pprof::flamegraph::from_lines(&mut opt, folded.lines(), out)
		.map_err(|e| format!("flamegraph: {e}"))?;
	fs::rename(&tmp, dir.join("flame.svg")).map_err(|e| format!("{}: {e}", tmp.display()))
}

/// The sampler's attribution against a workload whose answer is known, so a
/// graph isn't trusted on faith. 2 threads busy for the same time: one runs
/// two loops inlined into one function at 3 to 1, and the other reads a file
/// that's in the page cache, so its samples end inside libc. The loops have
/// to split about 3 to 1, which they don't when one name takes a whole
/// function. The reader would get half in fairness, but a thread in the
/// kernel gets fewer signals, about 35% at this rate. With libc dropped it
/// gets none.
fn check() -> i32 {
	let exe = std::env::current_exe().and_then(File::open);
	let Ok(exe) = exe else {
		err!("profiler check: can't open its own binary to read");
		return 1;
	};
	let Ok(guard) = sampler() else {
		err!("profiler check: the sampler didn't start");
		return 1;
	};
	let cpu0 = cpu_us();
	let deadline = Instant::now() + Duration::from_secs(3);
	std::thread::scope(|s| {
		s.spawn(|| {
			let mut x = 0u64;
			while Instant::now() < deadline {
				x ^= calibrate_both(black_box(20_000));
			}
			black_box(x);
		});
		s.spawn(|| {
			let mut buf = vec![0u8; 1 << 16];
			while Instant::now() < deadline {
				calibrate_reads(&exe, &mut buf);
			}
		});
	});
	let cpu1 = cpu_us();
	let expected = (cpu1.0 + cpu1.1 - cpu0.0 - cpu0.1) * i64::from(FREQ) / 1_000_000;
	let Ok(report) = guard.report().build() else {
		err!("profiler check: no report");
		return 1;
	};
	let (mut three, mut one, mut reads, mut kept) = (0isize, 0isize, 0isize, 0isize);
	for (frames, n) in &report.data {
		kept += n;
		let has = |want: &str| {
			frames
				.frames
				.iter()
				.flatten()
				.any(|s| s.name().contains(want))
		};
		if has("calibrate_three") {
			three += n;
		} else if has("calibrate_one") {
			one += n;
		} else if has("calibrate_reads") {
			reads += n;
		}
	}
	let loops = three + one;
	let split = 100 * three / loops.max(1);
	let read_share = 100 * reads / (loops + reads).max(1);
	let kept_share = 100 * kept as i64 / expected.max(1);
	let ok = loops + reads >= 300
		&& (65..=85).contains(&split)
		&& (15..=70).contains(&read_share)
		&& kept_share >= 40;
	err!(
		"profiler attribution {}: the 3-to-1 loops split {split}% where 75% is right, the reading thread had {read_share}% where about 35% is usual, and {kept} of about {expected} samples were kept ({kept_share}%)",
		if ok { "ok" } else { "WRONG" },
	);
	i32::from(!ok)
}

#[inline(never)]
fn calibrate_both(n: u64) -> u64 {
	calibrate_three(black_box(3 * n)) ^ calibrate_one(black_box(n))
}

#[allow(
	clippy::inline_always,
	reason = "the check needs both loops in one function"
)]
#[inline(always)]
fn calibrate_three(n: u64) -> u64 {
	let mut x = 0x9e37u64;
	for k in 0..n {
		x = x.rotate_left(5) ^ k.wrapping_mul(0x9e37_79b9_7f4a_7c15);
	}
	x
}

#[allow(
	clippy::inline_always,
	reason = "the check needs both loops in one function"
)]
#[inline(always)]
fn calibrate_one(n: u64) -> u64 {
	let mut x = 0x7f4au64;
	for k in 0..n {
		x = x.rotate_left(7) ^ k.wrapping_mul(0xc2b2_ae3d_27d4_eb4f);
	}
	x
}

#[inline(never)]
fn calibrate_reads(f: &File, buf: &mut [u8]) {
	_ = black_box(f.read_at(buf, 0));
}
