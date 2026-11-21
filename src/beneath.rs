// Copyright © 2026 t00mietum (CryptogID: ปʬϝღถɔ4რఠΔթะ9ƾǝu)
// Licensed under GPL-2.0-only. No warranty.

// Opening what the walk found, from the root's own folder, without following a symlink or crossing onto another filesystem anywhere on the way. The scan runs as root, and a folder swapped for a symlink after it was listed would otherwise send it somewhere else to read files and set attributes.

use crate::util::cpath;
use std::ffi::{CStr, CString, OsStr, OsString};
use std::fs::File;
use std::io;
use std::os::fd::{AsRawFd, FromRawFd, IntoRawFd, RawFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::MetadataExt;
use std::path::{Component, Path, PathBuf};
use std::ptr::NonNull;
use std::sync::atomic::{AtomicBool, Ordering::Relaxed};
use std::sync::{Mutex, PoisonError};
use std::thread::{self, ThreadId};

/// A scan root, held open so every path is opened beneath it.
#[derive(Debug)]
pub struct Root {
	pub path: PathBuf,
	pub dev: u64,
	dir: File,
	// Cleared on a kernel before 5.6, which has no openat2.
	openat2: AtomicBool,
	// Without openat2, the folder each thread last opened something in, so its next open there doesn't pay a lookup per level again.
	near: Mutex<Vec<Near>>,
}

#[derive(Debug)]
struct Near {
	thread: ThreadId,
	above: Vec<OsString>,
	dir: File,
	// Where it was and what it was, to tell whether its path still leads to it.
	at: CString,
	id: (u64, u64),
}

#[repr(C)]
struct OpenHow {
	flags: u64,
	mode: u64,
	resolve: u64,
}

/// Not where the walk saw it: gone, swapped for a symlink or a file, or under a mount made since. Nothing was there to check.
pub fn moved(e: &io::Error) -> bool {
	e.kind() == io::ErrorKind::NotFound || matches!(e.raw_os_error(), Some(libc::ELOOP | libc::ENOTDIR | libc::EXDEV))
}

fn retry(mut f: impl FnMut() -> libc::c_long) -> io::Result<File> {
	loop {
		let fd = f();
		if fd >= 0 {
			// SAFETY: the kernel returned fd, and nothing else owns it.
			return Ok(unsafe { File::from_raw_fd(fd as RawFd) });
		}
		let e = io::Error::last_os_error();
		if e.kind() != io::ErrorKind::Interrupted {
			return Err(e);
		}
	}
}

/// Opens a name in a folder without following a link at it. A file made by `O_CREAT` gets 0666 less the umask, as `File::create` gives.
pub fn openat(at: RawFd, name: &OsStr, flags: libc::c_int) -> io::Result<File> {
	let c = cpath(Path::new(name))?;
	let mode: libc::c_uint = 0o666;
	retry(|| {
		// SAFETY: c is NUL-terminated and outlives the call.
		unsafe { libc::openat(at, c.as_ptr(), flags | libc::O_NOFOLLOW | libc::O_CLOEXEC, mode) }.into()
	})
}

fn lstat_at(at: RawFd, c: &CStr) -> io::Result<libc::stat64> {
	let mut st = std::mem::MaybeUninit::<libc::stat64>::uninit();
	// SAFETY: c outlives the call, and st has room for a stat64.
	let r = unsafe { libc::fstatat64(at, c.as_ptr(), st.as_mut_ptr(), libc::AT_SYMLINK_NOFOLLOW) };
	if r != 0 {
		return Err(io::Error::last_os_error());
	}
	// SAFETY: fstatat64 returned 0, so st is filled in.
	Ok(unsafe { st.assume_init() })
}

impl AsRawFd for Root {
	fn as_raw_fd(&self) -> RawFd {
		self.dir.as_raw_fd()
	}
}

impl Root {
	/// Opens a root folder.
	pub fn open(path: &Path) -> io::Result<Root> {
		let dir = openat(libc::AT_FDCWD, path.as_os_str(), libc::O_RDONLY | libc::O_DIRECTORY)?;
		Ok(Root {
			path: path.to_path_buf(),
			dev: dir.metadata()?.dev(),
			dir,
			openat2: AtomicBool::new(true),
			near: Mutex::new(Vec::new()),
		})
	}

	/// A path made relative to the root, or as it was if it's outside.
	pub fn rel<'a>(&self, p: &'a Path) -> &'a Path {
		// An absolute path left over is refused by open_at.
		p.strip_prefix(&self.path).unwrap_or(p)
	}

	/// Opens a relative path without leaving the root or its filesystem.
	pub fn open_at(&self, rel: &Path, flags: libc::c_int) -> io::Result<File> {
		let rel = if rel.as_os_str().is_empty() { Path::new(".") } else { rel };
		if self.openat2.load(Relaxed) {
			match self.openat2(rel, flags) {
				Err(e) if e.raw_os_error() == Some(libc::ENOSYS) => {
					self.openat2.store(false, Relaxed);
				}
				r => return r,
			}
		}
		self.step_by_step(rel, flags)
	}

	fn openat2(&self, rel: &Path, flags: libc::c_int) -> io::Result<File> {
		let c = cpath(rel)?;
		let how = OpenHow {
			flags: (flags | libc::O_NOFOLLOW | libc::O_CLOEXEC) as u64,
			mode: 0,
			resolve: libc::RESOLVE_BENEATH | libc::RESOLVE_NO_SYMLINKS | libc::RESOLVE_NO_XDEV,
		};
		// SAFETY: c and how outlive the call, and OpenHow has the kernel's open_how layout.
		retry(|| unsafe { libc::syscall(libc::SYS_openat2, self.dir.as_raw_fd(), c.as_ptr(), &raw const how, std::mem::size_of::<OpenHow>()) })
	}

	// The same rules one folder at a time.
	fn step_by_step(&self, rel: &Path, flags: libc::c_int) -> io::Result<File> {
		let mut parts = Vec::new();
		for c in rel.components() {
			match c {
				Component::Normal(n) => parts.push(n),
				Component::CurDir => {}
				_ => return Err(io::Error::from_raw_os_error(libc::EXDEV)),
			}
		}
		let (last, above) = parts.split_last().map_or((OsStr::new("."), &[][..]), |(l, a)| (*l, a));
		// A kept folder moved out of the root, or replaced, would open what used to be there. One stat of its whole path is much cheaper than a walk.
		if let Some(near) = self.recall(above).filter(|n| lstat_at(self.dir.as_raw_fd(), &n.at).is_ok_and(|st| (st.st_dev, st.st_ino) == n.id)) {
			// It can still move between the check and the open, so a failure from it is tried again from the root.
			if let Ok(f) = self.descend(Some(near), above, last, flags) {
				return Ok(f);
			}
		}
		self.descend(None, above, last, flags)
	}

	// Opens the folders in above past the ones near already has open, then last in the deepest.
	fn descend(&self, near: Option<Near>, above: &[&OsStr], last: &OsStr, flags: libc::c_int) -> io::Result<File> {
		let (mut names, mut held, mut at) = near.map_or((Vec::new(), None, None), |n| (n.above, Some((n.dir, n.id)), Some(n.at)));
		for name in &above[names.len()..] {
			let from = held.as_ref().map_or(&self.dir, |(d, _)| d).as_raw_fd();
			let f = openat(from, name, libc::O_PATH | libc::O_DIRECTORY)?;
			let md = f.metadata()?;
			if md.dev() != self.dev {
				return Err(io::Error::from_raw_os_error(libc::EXDEV));
			}
			names.push(name.to_os_string());
			held = Some((f, (md.dev(), md.ino())));
			at = None;
		}
		let f = openat(held.as_ref().map_or(&self.dir, |(d, _)| d).as_raw_fd(), last, flags)?;
		// openat2's RESOLVE_NO_XDEV, for a mount on the last part, such as a file bind-mounted over one the the walk listed.
		if f.metadata()?.dev() != self.dev {
			return Err(io::Error::from_raw_os_error(libc::EXDEV));
		}
		if let Some((dir, id)) = held
			&& let Some(at) = at.or_else(|| cpath(&names.iter().collect::<PathBuf>()).ok())
		{
			let mut near = self.near.lock().unwrap_or_else(PoisonError::into_inner);
			near.push(Near { thread: thread::current().id(), above: names, dir, at, id });
		}
		Ok(f)
	}

	// Takes this thread's folder when it's above or one of the folders above.
	fn recall(&self, above: &[&OsStr]) -> Option<Near> {
		let me = thread::current().id();
		let mut near = self.near.lock().unwrap_or_else(PoisonError::into_inner);
		let i = near.iter().position(|n| n.thread == me)?;
		let n = near.swap_remove(i);
		(n.above.len() <= above.len() && n.above.iter().zip(above).all(|(a, b)| a == b)).then_some(n)
	}

	/// Opens a file to read without moving its atime, where allowed.
	pub fn open_read(&self, rel: &Path) -> io::Result<File> {
		let base = libc::O_RDONLY | libc::O_NONBLOCK;
		with_noatime(|extra| self.open_at(rel, base | extra))
	}
}

/// Calls `open` with `O_NOATIME`, and again without it if that's refused, since it needs ownership or root.
pub fn with_noatime(open: impl Fn(libc::c_int) -> io::Result<File>) -> io::Result<File> {
	match open(libc::O_NOATIME) {
		Err(e) if e.raw_os_error() == Some(libc::EPERM) => open(0),
		r => r,
	}
}

/// What a folder entry is, by its type.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Kind {
	Dir,
	File,
	Other,
}

/// One folder entry.
#[derive(Debug)]
pub struct Entry {
	pub name: Box<OsStr>,
	pub ino: u64,
	pub kind: io::Result<Kind>,
}

/// A folder's entries, read from an fd rather than by name.
#[derive(Debug)]
pub struct List {
	dir: NonNull<libc::DIR>,
}

impl List {
	/// Reads the entries of an open folder.
	pub fn new(f: File) -> io::Result<List> {
		let fd = f.into_raw_fd();
		// SAFETY: fd came from into_raw_fd, so it's ours. On success the DIR owns it.
		let Some(dir) = NonNull::new(unsafe { libc::fdopendir(fd) }) else {
			let e = io::Error::last_os_error();
			// SAFETY: fdopendir failed, so fd is still ours to close.
			unsafe { libc::close(fd) };
			return Err(e);
		};
		Ok(List { dir })
	}

	fn fd(&self) -> RawFd {
		// SAFETY: dir stays open until Drop.
		unsafe { libc::dirfd(self.dir.as_ptr()) }
	}

	fn lstat(&self, name: &[u8]) -> io::Result<libc::stat64> {
		lstat_at(self.fd(), &cpath(Path::new(OsStr::from_bytes(name)))?)
	}

	/// Whether the folder has an entry by that name.
	pub fn has(&self, name: &str) -> bool {
		self.lstat(name.as_bytes()).is_ok()
	}
}

impl Drop for List {
	fn drop(&mut self) {
		// SAFETY: dir is open, and Drop is the only close.
		unsafe { libc::closedir(self.dir.as_ptr()) };
	}
}

impl Iterator for List {
	type Item = io::Result<Entry>;

	fn next(&mut self) -> Option<io::Result<Entry>> {
		loop {
			// readdir says "the end" and "an error" both with null.
			// SAFETY: errno is per thread, and any value may be stored in it.
			unsafe { *libc::__errno_location() = 0 };
			// SAFETY: dir is open, and &mut self keeps other readers off it.
			let ent = unsafe { libc::readdir64(self.dir.as_ptr()) };
			// SAFETY: readdir64 gave null or an entry that's good until the next call on dir.
			let Some(ent) = (unsafe { ent.as_ref() }) else {
				let e = io::Error::last_os_error();
				return (e.raw_os_error() != Some(0)).then_some(Err(e));
			};
			// SAFETY: d_name is NUL-terminated within the entry.
			let name = unsafe { CStr::from_ptr(ent.d_name.as_ptr()) }.to_bytes();
			if name == b"." || name == b".." {
				continue;
			}
			let kind = match ent.d_type {
				libc::DT_DIR => Ok(Kind::Dir),
				libc::DT_REG => Ok(Kind::File),
				// Some filesystems don't say, so ask.
				libc::DT_UNKNOWN => self.lstat(name).map(|st| match st.st_mode & libc::S_IFMT {
					libc::S_IFDIR => Kind::Dir,
					libc::S_IFREG => Kind::File,
					_ => Kind::Other,
				}),
				_ => Ok(Kind::Other),
			};
			return Some(Ok(Entry { name: OsStr::from_bytes(name).into(), ino: ent.d_ino, kind }));
		}
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	use crate::testutil::{scratch, test_id};
	use std::fs;
	use std::io::Read;

	fn both(root: &Path) -> [Root; 2] {
		let slow = Root::open(root).unwrap();
		slow.openat2.store(false, Relaxed);
		[Root::open(root).unwrap(), slow]
	}

	// A folder swapped for a symlink after it was listed.
	#[test]
	#[cfg_attr(miri, ignore = "Miri has no openat2")]
	fn a_symlink_on_the_way_is_not_followed() {
		let _id = test_id("ddy91");
		let d = scratch("beneath_symlink");
		let (root, outside) = (d.join("root"), d.join("outside"));
		fs::create_dir_all(root.join("real")).unwrap();
		fs::create_dir_all(&outside).unwrap();
		fs::write(root.join("real/f"), "in").unwrap();
		fs::write(outside.join("f"), "secret").unwrap();
		std::os::unix::fs::symlink(&outside, root.join("swapped")).unwrap();
		std::os::unix::fs::symlink(outside.join("f"), root.join("real/link")).unwrap();
		for r in both(&root) {
			let mut s = String::new();
			r.open_read(Path::new("real/f")).unwrap().read_to_string(&mut s).unwrap();
			assert_eq!(s, "in");
			for p in ["swapped/f", "real/link", "/etc/hostname", "real/../swapped/f"] {
				let e = r.open_read(Path::new(p)).unwrap_err();
				assert!(moved(&e), "{p}: {e}");
			}
			let e = r.open_at(Path::new("swapped"), libc::O_RDONLY | libc::O_DIRECTORY).unwrap_err();
			assert!(moved(&e), "{e}");
		}
	}

	// /dev/shm is its own mount on most Linux boxes; skipped where it isn't.
	#[test]
	fn another_filesystem_is_not_entered() {
		let _id = test_id("ddy92");
		let (Ok(dev), Ok(shm)) = (fs::metadata("/dev"), fs::metadata("/dev/shm")) else {
			return;
		};
		if dev.dev() == shm.dev() {
			eprintln!("/dev/shm isn't a mount here; skipped");
			return;
		}
		for r in both(Path::new("/dev")) {
			// The mount on the last part too, as for a file mounted over after the walk listed it.
			let e = r.open_at(Path::new("shm"), libc::O_RDONLY | libc::O_DIRECTORY).unwrap_err();
			assert!(moved(&e), "{e}");
			let e = r.open_at(Path::new("shm/x"), libc::O_PATH).unwrap_err();
			assert!(moved(&e), "{e}");
		}
	}

	// Without openat2, a folder kept from an earlier open that's since been replaced, or swapped for a symlink.
	#[test]
	#[cfg_attr(miri, ignore = "Miri has no openat2")]
	fn a_kept_folder_is_checked_again() {
		let _id = test_id("dfh8m");
		let d = scratch("beneath_near");
		let (root, outside) = (d.join("root"), d.join("outside"));
		fs::create_dir_all(root.join("a/b/c")).unwrap();
		fs::create_dir_all(outside.join("c")).unwrap();
		fs::write(root.join("a/b/f"), "old").unwrap();
		fs::write(root.join("a/b/c/h"), "deep").unwrap();
		fs::write(outside.join("c/f"), "secret").unwrap();
		let [_, r] = both(&root);
		let read = |p: &str| -> io::Result<String> {
			let mut s = String::new();
			r.open_read(Path::new(p))?.read_to_string(&mut s)?;
			Ok(s)
		};
		let kept = || r.near.lock().unwrap().iter().map(|n| n.above.join(OsStr::new("/"))).collect::<Vec<_>>();
		assert_eq!(read("a/b/f").unwrap(), "old");
		assert_eq!(kept(), ["a/b"]);
		assert_eq!(read("a/b/c/h").unwrap(), "deep");
		assert_eq!(kept(), ["a/b/c"]);
		fs::rename(root.join("a/b"), root.join("a/gone")).unwrap();
		fs::create_dir_all(root.join("a/b/c")).unwrap();
		fs::write(root.join("a/b/c/g"), "new").unwrap();
		assert_eq!(read("a/b/c/g").unwrap(), "new");
		fs::rename(root.join("a/b"), root.join("a/gone2")).unwrap();
		fs::remove_dir_all(root.join("a/gone2")).unwrap();
		std::os::unix::fs::symlink(&outside, root.join("a/b")).unwrap();
		// The kept folder is deleted, and the path from the root now runs through the symlink.
		let e = read("a/b/c/f").unwrap_err();
		assert!(moved(&e), "{e}");
		assert!(kept().is_empty());
	}

	// Without openat2, a kept folder moved out of the root and another put in its place, as openat2 sees it.
	#[test]
	#[cfg_attr(miri, ignore = "Miri has no openat2")]
	fn a_kept_folder_moved_out_isnt_read_through() {
		let _id = test_id("dfjx2");
		let d = scratch("beneath_moved_out");
		let (root, outside) = (d.join("root"), d.join("outside"));
		fs::create_dir_all(root.join("d/sub")).unwrap();
		fs::create_dir_all(&outside).unwrap();
		fs::write(root.join("d/slow"), "x").unwrap();
		fs::write(root.join("d/f1"), "old only").unwrap();
		fs::write(root.join("d/sub/g"), "old").unwrap();
		for r in both(&root) {
			let read = |p: &str| -> io::Result<String> {
				let mut s = String::new();
				r.open_read(Path::new(p))?.read_to_string(&mut s)?;
				Ok(s)
			};
			assert_eq!(read("d/slow").unwrap(), "x");
			fs::rename(root.join("d"), outside.join("d_old")).unwrap();
			fs::create_dir_all(root.join("d/sub")).unwrap();
			fs::write(root.join("d/sub/g"), "new").unwrap();
			let e = read("d/f1").unwrap_err();
			assert!(moved(&e), "{e}");
			assert_eq!(read("d/sub/g").unwrap(), "new");
			fs::remove_dir_all(root.join("d")).unwrap();
			fs::rename(outside.join("d_old"), root.join("d")).unwrap();
		}
	}

	#[test]
	#[cfg_attr(miri, ignore = "Miri has no openat2")]
	fn a_listing_has_names_kinds_and_inodes() {
		let _id = test_id("ddy93");
		let d = scratch("beneath_list");
		fs::create_dir(d.join("sub")).unwrap();
		fs::write(d.join("f"), "x").unwrap();
		std::os::unix::fs::symlink("f", d.join("l")).unwrap();
		let r = Root::open(&d).unwrap();
		let list = List::new(r.open_at(Path::new(""), libc::O_RDONLY).unwrap()).unwrap();
		assert!(list.has("sub") && !list.has(".git"));
		let mut got: Vec<(String, u64, Kind)> = list
			.map(|e| {
				let e = e.unwrap();
				(e.name.to_string_lossy().into_owned(), e.ino, e.kind.unwrap())
			})
			.collect();
		got.sort();
		let ino = |n: &str| fs::symlink_metadata(d.join(n)).unwrap().ino();
		assert_eq!(got, [("f".into(), ino("f"), Kind::File), ("l".into(), ino("l"), Kind::Other), ("sub".into(), ino("sub"), Kind::Dir),]);
	}
}
