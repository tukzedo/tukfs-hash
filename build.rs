// Copyright © 2026 t00mietum (CryptogID: ปʬϝღถɔ4რఠΔթะ9ƾǝu)
// Licensed under GPL-2.0-only. No warranty.

// cicd.bash passes the build number in, worked out from the commit time, so
// a rebuild of one commit gets the same one. A plain `cargo build` has none,
// and --version leaves it off. A bad value is a pipeline bug, and a wrong
// number in a release would be worse than a failed build.
fn main() {
	println!("cargo:rerun-if-changed=build.rs");
	println!("cargo:rerun-if-env-changed=TUKFS_HASH_BUILD");
	let build = std::env::var("TUKFS_HASH_BUILD").unwrap_or_default();
	assert!(
		build
			.chars()
			.all(|c| "0123456789abcdefghjkmnpqrstvwxyz".contains(c)),
		"TUKFS_HASH_BUILD must be lower-case Crockford base32, got {build:?}"
	);
	let suffix = if build.is_empty() {
		String::new()
	} else {
		format!(" build {build}")
	};
	println!("cargo:rustc-env=TUKFS_HASH_BUILD_SUFFIX={suffix}");
}
