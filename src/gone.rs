// Copyright © 2026 t00mietum (CryptogID: ปʬϝღถɔ4რఠΔթะ9ƾǝu)
// Licensed under GPL-2.0-only. No warranty.

// Names a finished scan didn't see. See design.md, Gone.

use crate::db;
use rusqlite::types::ValueRef;
use rusqlite::OptionalExtension;
use std::collections::{HashMap, HashSet};
use std::ffi::OsStr;
use std::os::unix::ffi::OsStrExt;
use std::path::Path;

fn split_roots(b: &[u8]) -> Vec<&Path> {
	b.split(|&c| c == 0)
		.filter(|r| !r.is_empty())
		.map(|r| Path::new(OsStr::from_bytes(r)))
		.collect()
}

fn deepest<'a>(roots: &[&'a Path], p: &Path) -> Option<&'a Path> {
	roots
		.iter()
		.copied()
		.filter(|r| p.starts_with(r))
		.max_by_key(|r| r.as_os_str().len())
}

// A scan stops at every mount, so a name that another run reached from a
// deeper root may sit on a filesystem this run never walked. Only a run at
// or below the root that last saw it would have reached it again. A run with
// no root list, such as accept's, can't say, so any root counts.
fn reachable(now: &[&Path], last: Option<&[&Path]>, p: &Path) -> bool {
	let Some(here) = deepest(now, p) else {
		return false;
	};
	match last.and_then(|rs| deepest(rs, p)) {
		Some(there) => here.starts_with(there),
		None => true,
	}
}

fn bytes_of(v: ValueRef<'_>) -> Vec<u8> {
	match v {
		ValueRef::Text(t) | ValueRef::Blob(t) => t.to_vec(),
		_ => Vec::new(),
	}
}

#[allow(clippy::too_many_lines, reason = "split by 2026101916404110")]
pub fn run(db_path: &Path, run: Option<i64>, limit: i64) -> Result<i32, String> {
	let conn = db::open_ro(db_path)?;
	let e = |e: rusqlite::Error| e.to_string();
	let none_yet = "no finished scan with a root list yet";
	if !db::has_column(&conn, "runs", "roots").map_err(e)? {
		return Err(none_yet.into());
	}
	let row = |r: &rusqlite::Row<'_>| {
		Ok((
			r.get::<_, i64>(0)?,
			r.get::<_, String>(1)?,
			r.get::<_, Option<Vec<u8>>>(2)?,
		))
	};
	let found = match run {
		Some(id) => conn
			.query_row(
				"SELECT id, status, roots FROM runs WHERE id = ?1",
				[id],
				row,
			)
			.optional(),
		None => conn
			.query_row(
				"SELECT id, status, roots FROM runs WHERE status = 'done' AND roots IS NOT NULL
				ORDER BY id DESC LIMIT 1",
				[],
				row,
			)
			.optional(),
	}
	.map_err(e)?;
	let Some((id, status, roots)) = found else {
		return Err(run.map_or_else(|| none_yet.into(), |id| format!("no run {id}")));
	};
	if status != "done" {
		return Err(format!(
			"run {id} is {status}; only a finished scan says what's gone"
		));
	}
	let Some(roots) = roots else {
		return Err(format!(
			"run {id} is from an older version, which kept no root list"
		));
	};
	let now = split_roots(&roots);

	let earlier: HashMap<i64, Option<Vec<u8>>> = conn
		.prepare("SELECT id, roots FROM runs WHERE id < ?1")
		.map_err(e)?
		.query_map([id], |r| Ok((r.get(0)?, r.get(1)?)))
		.map_err(e)?
		.collect::<Result<_, _>>()
		.map_err(e)?;
	let earlier: HashMap<i64, Vec<&Path>> = earlier
		.iter()
		.filter_map(|(k, v)| v.as_deref().map(|b| (*k, split_roots(b))))
		.collect();

	// A name with an event was reached, and the names under a folder that
	// couldn't be listed weren't looked for.
	let mut reached = HashSet::new();
	let mut unlisted = Vec::new();
	{
		let mut st = conn
			.prepare("SELECT kind, path FROM events WHERE run_id = ?1")
			.map_err(e)?;
		let mut rows = st.query([id]).map_err(e)?;
		while let Some(r) = rows.next().map_err(e)? {
			let path = bytes_of(r.get_ref(1).map_err(e)?);
			if r.get_ref(0).map_err(e)?.as_str().ok() == Some("dir-error") {
				unlisted.push(path.clone());
			}
			reached.insert(path);
		}
	}
	let unlisted: Vec<&Path> = unlisted
		.iter()
		.map(|b| Path::new(OsStr::from_bytes(b)))
		.collect();

	let mut st = conn
		.prepare("SELECT path, seen_run FROM paths WHERE seen_run < ?1 ORDER BY path")
		.map_err(e)?;
	let mut rows = st.query([id]).map_err(e)?;
	let mut count = 0u64;
	let mut shown = Vec::new();
	while let Some(r) = rows.next().map_err(e)? {
		let raw = r.get_ref(0).map_err(e)?;
		let last: i64 = r.get(1).map_err(e)?;
		let p = Path::new(OsStr::from_bytes(match raw {
			ValueRef::Text(t) | ValueRef::Blob(t) => t,
			_ => continue,
		}));
		if !reachable(&now, earlier.get(&last).map(Vec::as_slice), p)
			|| reached.contains(p.as_os_str().as_bytes())
			|| unlisted.iter().any(|d| p.starts_with(d))
		{
			continue;
		}
		count += 1;
		if (shown.len() as i64) < limit {
			shown.push(format!(
				"gone\t{}\tlast seen by run {last}",
				db::path_text(raw)
			));
		}
	}
	out!("run {id}");
	out!("\tgone: {count}");
	if !unlisted.is_empty() {
		out!(
			"\tnot counted: names under {} folder(s) it couldn't list",
			unlisted.len()
		);
	}
	for l in shown {
		out!("{l}");
	}
	Ok(0)
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn only_names_the_run_would_reach() {
		let p = Path::new;
		let now = [p("/a"), p("/z")];
		// Seen last from the same root, or from a shallower one.
		assert!(reachable(&now, Some(&[p("/a")]), p("/a/f")));
		assert!(reachable(&now, Some(&[p("/")]), p("/a/f")));
		// Seen from a deeper root, which may be its own mount.
		assert!(!reachable(&now, Some(&[p("/a/m")]), p("/a/m/f")));
		// Not under this run's roots at all, and a name that only shares a
		// prefix.
		assert!(!reachable(&now, Some(&[p("/b")]), p("/b/f")));
		assert!(!reachable(&now, None, p("/ab/f")));
		// No root list to go by.
		assert!(reachable(&now, None, p("/a/f")));
		// A deeper root of this run counts, not the shallow one.
		let now = [p("/a"), p("/a/m")];
		assert!(reachable(&now, Some(&[p("/a/m")]), p("/a/m/f")));
		assert_eq!(split_roots(b"/a\0/a/m"), now);
	}
}
