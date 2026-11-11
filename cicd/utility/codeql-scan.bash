#!/usr/bin/env bash

##	Purpose:
##		CodeQL's Rust security-and-quality suite over a copy of the crate with
##		every dependency vendored into it (cargo vendor), so the crates are
##		inside the database's root and are reported on too, with their full
##		source extracted rather than their signatures. Any finding fails. One
##		that's wrong, or real and filed as a bug, is suppressed at its line,
##		with a comment alone on the line before it:
##			// codeql[rust/QUERY-ID] the reason, or the backlog item's ID
##		The pinned CodeQL has no alert-suppression query for Rust, so
##		cicd/codeql/rust-suppression is the one the other languages have, over
##		Rust's comments, and this matches them to the findings. A suppression
##		has to give its reason and still cover a finding. There's no baseline.
##		Vendored crates count only for findings tagged security or
##		correctness. Their style isn't ours to fix.
##		The copy gets a planted finding, which has to be reported, and the
##		database has to have every file of ours and the root of every crate
##		the Linux build takes, so an extractor that dropped code fails rather
##		than passing as clean. The Rust extractor reads source through
##		rust-analyzer and watches no build, so a warm build dir can't leave it
##		empty. Its cargo runs, for build scripts, get a fresh dir anyway.
##		It runs on the dated nightly, since rust-analyzer wants rust-src.
##		The SARIF and findings.txt go in cicd/artifacts/codeql/, and the
##		database goes with the scratch dir. CodeQL is the pinned one in the
##		leak check image, run with no network. With no docker, a noted skip,
##		which keeps a check-only run from recording its tree.
##		From shcl's cicd/utility/codeql-scan.bash.
##		--ours leaves the crates as the cargo home has them, so only their
##		signatures are extracted and only our code is reported on, the way
##		CodeQL's default setup reads a Rust project. About 3 minutes rather
##		than 10 to 15, for a worker's run. Its output goes in
##		cicd/artifacts/codeql-ours/, and cicd/codeql/vendored-reviewed.tsv
##		isn't read. A finding whose flow runs through a crate's own code can
##		show up only in the full run.
##	Syntax:
##		codeql-scan.bash [--ours]
##		CPU_CAP caps the threads (default a quarter of the cores).
##	Exit: 0 = clean, 1 = a finding, a missed bait, a dropped file or a bad
##	      suppression, 2 = could not run.
##	History: At bottom of script.

##	Copyright © 2026 t00mietum (CryptogID: ปʬϝღถɔ4რఠΔթะ9ƾǝu)
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


set -Eeuo pipefail

me="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${me}/include/leak-common.bash"
trap 'fStopDescendants; fScratchGone || true' EXIT

ours=0; modeArg=()
if [[ "${1:-}" == --ours ]]; then ours=1; modeArg=(--ours); shift; fi
if (($#)); then echo "codeql-scan: takes only --ours (see the header)" >&2; exit 2; fi
start="${SECONDS}"
art="${root}/cicd/artifacts/codeql"
((ours)) && art+="-ours"
mkdir -p -- "${art}" "${LEAK_DIR}"
leak_host_note=0
fLeakInImage codeql-scan "${me}/codeql-scan.bash" "${art}" "${modeArg[@]}"

missing=()
for t in codeql cargo rustup jq unzip; do
	if ! command -v "${t}" >/dev/null 2>&1; then missing+=("${t}"); fi
done
if command -v codeql >/dev/null 2>&1 && [[ "$(codeql version --format=terse 2>/dev/null)" != "${PIN_CODEQL}" ]]; then missing+=("codeql ${PIN_CODEQL}"); fi
if ((${#missing[@]})); then
	((in_image)) && { echo "codeql-scan: the leak check image has no ${missing[*]}" >&2; exit 2; }
	echo "note: codeql-scan: skipped, since ${leak_why:-the image is off}, and the host has no ${missing[*]}"
	fLeakHostSkip codeql
	exit 0
fi
export RUSTUP_TOOLCHAIN="${PIN_NIGHTLY}"

fScratchMake codeql || exit 2
work="${scratch}"; src="${work}/src"; db="${work}/db"
mkdir -p -- "${src}/tests" "${src}/.cargo" "${work}/rtarget" "${work}/tmp"
export TMPDIR="${work}/tmp"
cp -a -- Cargo.toml Cargo.lock build.rs src "${src}/"
## The profiling build isn't released, and uuid's Display, which comes in with
## pprof, reads to CodeQL as a secret that every format! in the tree could
## log. So the copy has no profiling feature, pprof or src/profiling.rs, and
## its lock loses their crates, which only removes lines.
sed -i -e '/^pprof = /d' -e '/^profiling = /d' "${src}/Cargo.toml"
rm -f -- "${src}/src/profiling.rs"
if grep -qE '^(pprof|profiling) = ' "${src}/Cargo.toml" || ! (cd "${src}" && cargo metadata --format-version 1 --offline >/dev/null 2>"${work}/relock.log"); then
	cat "${work}/relock.log" 2>/dev/null || true; echo "codeql-scan: could not leave the profiling crates out of the copy" >&2; exit 2
fi
if grep -q '^name = "pprof"$' "${src}/Cargo.lock"; then echo "codeql-scan: the copy's lock still has pprof" >&2; exit 2; fi
## A read through a null pointer, from shcl's bait. An integration test of
## its own, so it's in the crate's targets without touching ours.
bait="tests/codeql_bait.rs"
printf '%s\n' '#[test]' 'fn codeql_bait() {' '	let p: *const u8 = std::ptr::null();' '	let _v = unsafe { *p };' '}' > "${src}/${bait}"
## Versioned dirs, so a crate's dir names its version, and a reviewed line
## goes stale when the crate moves. --ours reads the crates from the cargo
## home instead, with only their signatures extracted.
asSource=false
if ((! ours)); then
	asSource=true
	if ! (cd "${src}" && cargo vendor --locked --quiet --versioned-dirs vendor > "${work}/vendor.log" 2>&1); then
		cat "${work}/vendor.log"; echo "codeql-scan: cargo vendor failed" >&2; exit 2
	fi
	printf '%s\n' '[source.crates-io]' 'replace-with = "vendored-sources"' '[source.vendored-sources]' 'directory = "vendor"' > "${src}/.cargo/config.toml"
fi
: > "${art}/findings.txt"
rm -f -- "${art}/rust.sarif"

log="${art}/rust-create.log"
echo "codeql-scan: building the database"
if ! codeql database create "${db}" --language=rust --source-root="${src}" --threads="${CPU_CAP}" --overwrite \
	-O "rust.cargo_target_dir=${work}/rtarget" -O "rust.extract_dependencies_as_source=${asSource}" >"${log}" 2>&1; then
	tail -n 20 "${log}"; echo "codeql-scan: the database didn't build, see ${log#"${root}/"}" >&2; exit 2
fi

## Every file of ours, and each crate root the Linux build takes, against
## what the database kept.
full=1
listed="$(unzip -Z1 "${db}/src.zip")"
declare -A inDb=()
while IFS= read -r f; do [[ -z "${f}" ]] || inDb["${f}"]=1; done <<<"${listed}"
while IFS= read -r -d '' f; do
	if [[ -z "${inDb["${f#/}"]:-}" ]]; then echo "codeql-scan: the database left out ${f#"${src}/"}"; full=0; fi
done < <(find "${src}/src" "${src}/tests" -name '*.rs' -print0)
roots="$(cd "${src}" && cargo metadata --format-version 1 --locked --offline --all-features --filter-platform x86_64-unknown-linux-gnu \
	| jq -r '[.resolve.nodes[].id] as $ids | .packages[] | select(.id as $i | $ids | index($i)) | select(.source != null)
		| .targets[] | select(.kind | index("lib") or index("proc-macro")) | .src_path')"
nRoots=0
while IFS= read -r f; do
	[[ -n "${f}" ]] || continue
	nRoots=$((nRoots + 1))
	if [[ -z "${inDb["${f#/}"]:-}" ]]; then echo "codeql-scan: the database left out the crate root ${f#"${src}/"}"; full=0; fi
done <<<"${roots}"
## A file outside every module tree says "semantic analyzer unavailable" too,
## which a crate's benches and Windows code do, so only ours count.
if grep -qF 'failed to load workspace' "${log}" || grep -qE "${src}/(src|tests)/[^ ]*: semantic analyzer unavailable" "${log}"; then
	grep -E "failed to load workspace|${src}/(src|tests)/[^ ]*: semantic analyzer unavailable" "${log}" | head -n 3 || true
	echo "codeql-scan: the workspace didn't load, so the extraction has no types or macros"; full=0
fi
echo "codeql-scan: the database has $(grep -c '\.rs$' <<<"${listed}") Rust files, ${nRoots} of them crate roots"

echo "codeql-scan: running the rust-security-and-quality suite"
if ! codeql database analyze "${db}" codeql/rust-queries:codeql-suites/rust-security-and-quality.qls \
	--format=sarif-latest --output="${art}/rust.sarif" --threads="${CPU_CAP}" --ram=8192 >"${art}/rust-analyze.log" 2>&1; then
	tail -n 20 "${art}/rust-analyze.log"; echo "codeql-scan: the analysis didn't finish" >&2; exit 2
fi

## The suppression comments. query run wants a file path; a pack's query name won't do.
cp -r -- cicd/codeql/rust-suppression "${work}/rust-suppression"
if ! (cd "${work}/rust-suppression" && codeql pack install >"${work}/pack.log" 2>&1); then
	cat "${work}/pack.log"; echo "codeql-scan: the Rust suppression query's pack didn't resolve" >&2; exit 2
fi
if ! codeql query run --database="${db}" --output="${work}/sup.bqrs" --threads="${CPU_CAP}" "${work}/rust-suppression/AlertSuppression.ql" >"${work}/sup.log" 2>&1 \
	|| ! codeql bqrs decode --format=json --entities=url "${work}/sup.bqrs" >"${work}/sup.json" 2>>"${work}/sup.log"; then
	tail -n 20 "${work}/sup.log"; echo "codeql-scan: the suppression query didn't run" >&2; exit 2
fi
## file, the line it covers, its own line, the query IDs, the reason.
jq -r --arg pre "file://${src}/" '.suppressions.tuples[] | select(.[1] | test("(?i)\\bcodeql\\s*\\[")) |
	[(.[3].url.uri | ltrimstr($pre)), (.[3].url.startLine | tostring), (.[0].url.startLine | tostring),
	(.[2] | sub("^lgtm\\["; "") | sub("\\]$"; "")), (.[1] | sub("^[^\\]]*\\]\\s*"; ""))] | @tsv' \
	"${work}/sup.json" > "${work}/sup.tsv"
## Of the crates, what the release binary builds: crates the Linux build
## takes, without dev-dependencies, so not the soak's dhat, and files in a
## module tree, so not a crate's benches or its Windows code.
for t in x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu; do
	(cd "${src}" && cargo tree --locked --offline -e normal,build --target "${t}" --prefix none -f '{p}') \
		|| { echo "codeql-scan: cargo tree failed for ${t}" >&2; exit 2; }
done | sed -E 's/^([^ ]+) v([^ ]+).*/\1-\2/' | sort -u > "${work}/shipped.txt"
SRCPRE="${src}/" awk 'index($0, ENVIRON["SRCPRE"] "vendor/") && /:1:1: semantic analyzer unavailable \(not included as a module\)/ {
	s = substr($0, index($0, ENVIRON["SRCPRE"]) + length(ENVIRON["SRCPRE"])); sub(/:1:1: .*/, "", s); print s }' "${log}" | sort -u > "${work}/notbuilt.txt"
## file, line, query, its tags, and the message's first line, for every
## finding. A crate's finding counts only when its query is tagged security
## or correctness. Their style isn't ours to fix.
jq -r '.runs[] | (.tool.driver.rules // [] | map({(.id): ((.properties.tags // []) | join(","))}) | add // {}) as $tags
	| .results[] | [(.locations[0].physicalLocation.artifactLocation.uri // "?"),
	(.locations[0].physicalLocation.region.startLine // 0 | tostring), .ruleId, ($tags[.ruleId] // ""),
	(.message.text | split("\n")[0])] | @tsv' "${art}/rust.sarif" \
	| awk -F'\t' -v OFS='\t' '$1 !~ /^vendor\// || $4 ~ /(^|,)(security|correctness)(,|$)/ { print $1, $2, $3, $5 }' > "${work}/found.tsv"
## The crates' code can't take a comment that would last past cargo vendor,
## so a finding there that was looked at and isn't a bug is a line of
## cicd/codeql/vendored-reviewed.tsv: path:line, query, why.
## --ours has no crate findings to match them to.
: > "${work}/reviewed.tsv"
((ours)) || grep -v '^#' cicd/codeql/vendored-reviewed.tsv 2>/dev/null | grep . > "${work}/reviewed.tsv" || true
## Ours is open unless a codeql[...] line covers it by its query ID. A
## crate's is left out when it isn't built, and otherwise open unless
## reviewed. A suppression or review that covers nothing is stale.
awk -F'\t' -v OFS='\t' '
	FILENAME == ARGV[1] {
		if ($5 == "") print "noreason", $1 ":" $3
		n = split($4, ids, /[ ,]+/)
		for (i = 1; i <= n; i++) if (ids[i] != "") { k = $1 SUBSEP $2 SUBSEP ids[i]; sup[k] = 1; at[k] = $1 ":" $3 }
		next
	}
	FILENAME == ARGV[2] { if ($3 == "") print "noreason", $1; rev[$1 SUBSEP $2] = 1; next }
	FILENAME == ARGV[3] { shipped[$0] = 1; next }
	FILENAME == ARGV[4] { notbuilt[$0] = 1; next }
	$1 ~ /^vendor\// {
		split($1, part, "/")
		if ($1 in notbuilt) { print "notbuilt", $0; next }
		if (!(part[2] in shipped)) { print "unshipped", $0; next }
		k = $1 ":" $2 SUBSEP $3
		if (k in rev) { revUsed[k] = 1; print "reviewed", $0 } else print "open", $0
		next
	}
	{ k = $1 SUBSEP $2 SUBSEP $3; if (k in sup) used[k] = 1; else print "open", $0 }
	END {
		for (k in sup) if (!(k in used)) { split(k, p, SUBSEP); print "stale", at[k], p[3] }
		for (k in rev) if (!(k in revUsed)) { split(k, p, SUBSEP); print "stalereview", p[1], p[2] }
	}
' "${work}/sup.tsv" "${work}/reviewed.tsv" "${work}/shipped.txt" "${work}/notbuilt.txt" "${work}/found.tsv" > "${work}/judged.tsv"
baitSeen=0; clean=1; suppressOk=1
nNotBuilt=0; nUnshipped=0; nReviewed=0
while IFS=$'\t' read -r state uri line rule msg; do
	case "${state}" in
		open)
			if [[ "${uri}" == "${bait}" ]]; then baitSeen=1; continue; fi
			echo "codeql: ${uri}:${line}: ${rule}: ${msg}" | tee -a "${art}/findings.txt"; clean=0 ;;
		notbuilt) nNotBuilt=$((nNotBuilt + 1)) ;;
		unshipped) nUnshipped=$((nUnshipped + 1)) ;;
		reviewed) nReviewed=$((nReviewed + 1)) ;;
		noreason) echo "codeql-scan: ${uri}: a suppression or review with no reason"; suppressOk=0 ;;
		stale) echo "codeql-scan: ${uri}: suppresses ${line}, and the line under it has no such finding"; suppressOk=0 ;;
		stalereview) echo "codeql-scan: cicd/codeql/vendored-reviewed.tsv: ${uri} ${line} has no such finding now"; suppressOk=0 ;;
	esac
done < "${work}/judged.tsv"
((ours)) || echo "codeql-scan: of the crates' findings, ${nReviewed} were reviewed, ${nNotBuilt} are in files the build leaves out, and ${nUnshipped} in crates the release binary doesn't link"
bad=0
if ((! baitSeen)); then echo "codeql-scan: nothing reported in the planted ${bait}"; bad=1; fi
if ((! full)); then bad=1; fi
if ((! clean)); then echo "codeql-scan: $(wc -l < "${art}/findings.txt") finding(s), listed in ${art#"${root}/"}/findings.txt"; bad=1; fi
if ((! suppressOk)); then bad=1; fi
((bad == 0)) || exit 1
what="our code or the crates"; ((ours)) && what="our code, with the crates' code left out"
echo "codeql-scan: OK: nothing found in ${what}, the bait was caught, and the SARIF is in ${art#"${root}/"}/ ($((SECONDS - start)) s)"


##	History:
##		- 2026-10-23: Copied from shcl's, for Rust alone, over the vendored tree.
##		- 2026-10-23: The profiling build's crates are left out of the copy.
##		- 2026-10-25: A quarter of the cores by default.
##		- 2026-11-10: --ours.
