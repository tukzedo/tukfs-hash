// Copyright © 2026 t00mietum (CryptogID: ปʬϝღถɔ4რఠΔթะ9ƾǝu)
// Licensed under GPL-2.0-only. No warranty.

// cicd.bash passes the build number in, worked out from the commit time, so
// a rebuild of one commit gets the same one. A plain `cargo build` has none,
// and --version leaves it off. A bad value is a pipeline bug, and a wrong
// number in a release would be worse than a failed build.
const DIGITS: &str = "0123456789abcdefghjkmnpqrstvwxyz";

fn main() {
	println!("cargo:rerun-if-changed=build.rs");
	println!("cargo:rerun-if-env-changed=TUKFS_HASH_BUILD");
	println!("cargo:rerun-if-env-changed=TUKFS_HASH_RELEASE");
	println!("cargo:rerun-if-env-changed=TUKFS_HASH_DIRTY");
	let build = std::env::var("TUKFS_HASH_BUILD").unwrap_or_default();
	assert!(
		build.chars().all(|c| DIGITS.contains(c)),
		"TUKFS_HASH_BUILD must be lower-case Crockford base32, got {build:?}"
	);
	let release = std::env::var("TUKFS_HASH_RELEASE").unwrap_or_default();
	assert!(
		release.is_empty() || release == "1",
		"TUKFS_HASH_RELEASE must be empty or 1, got {release:?}"
	);
	// Set when the tree built isn't the commit's, so the number names a commit
	// that isn't what was built. Such a build is never a release.
	let dirty = std::env::var("TUKFS_HASH_DIRTY").unwrap_or_default();
	assert!(
		dirty.is_empty() || dirty == "1",
		"TUKFS_HASH_DIRTY must be empty or 1, got {dirty:?}"
	);
	assert!(
		dirty.is_empty() || release.is_empty(),
		"TUKFS_HASH_DIRTY and TUKFS_HASH_RELEASE can't both be set"
	);
	let suffix = match (build.is_empty(), dirty.is_empty()) {
		(true, _) => String::new(),
		(false, true) => format!(" build {build}"),
		(false, false) => format!(" build {build}-dirty"),
	};
	// Builds between releases also show their day, which main.rs works out
	// when it runs, in the time zone of whoever looks.
	let minutes = if build.is_empty() || !release.is_empty() {
		String::new()
	} else {
		// The assert above let only DIGITS through.
		build
			.chars()
			.fold(0u64, |n, c| n * 32 + DIGITS.find(c).unwrap() as u64)
			.to_string()
	};
	println!("cargo:rustc-env=TUKFS_HASH_BUILD_SUFFIX={suffix}");
	println!("cargo:rustc-env=TUKFS_HASH_BUILD_MINUTES={minutes}");
}
