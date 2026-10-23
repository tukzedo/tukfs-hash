#!/usr/bin/env bash

#  shellcheck disable=1091  ## 'Not following.' The includes are checked on their own.
#  shellcheck disable=2154  ## 'referenced but not assigned.' PIN_NIGHTLY and LEAK_DIR come from config.bash, through leak-common.bash.

##	Purpose:
##		The unit tests again under a sanitizer or Miri, on the dated nightly
##		in cicd/tool-pins.env, each in a build dir of its own under
##		target/leakcheck. The plain cargo test proves the output; these prove
##		the memory behind it.
##		- --asan: AddressSanitizer and LeakSanitizer. std is built too
##		  (-Zbuild-std), and the target is named, or the flags would reach the
##		  build scripts. clang builds the bundled SQLite with the same
##		  sanitizer, with its lookaside and page cache pools off so each block
##		  is a malloc of its own, and its objects have to show the
##		  instrumentation. LSan reports at exit, so a leak fails the whole
##		  test binary. To find the test, rerun it with --test-threads=1 and a
##		  name filter.
##		- --tsan: ThreadSanitizer, the same way.
##		- --miri: each test in a Miri process of its own, CPU_CAP at a time.
##		  Miri also fails on memory still allocated when a test ends. A test
##		  that calls what Miri can't run has #[cfg_attr(miri, ignore = "why")],
##		  and the count of those is printed.
##		Runs in the leak check image when docker answers, else on the host,
##		with a note.
##		From shcl's cicd/utility/sanitize-rust.bash.
##	Syntax:
##		sanitize-rust.bash --asan|--tsan|--miri
##		CPU_CAP sets the jobs and test threads (default half the cores).
##		TUKFS_MIRI_TEST_SECS stops a Miri test that runs longer (default 1800).
##	Exit: 0 = clean, 1 = a test failed or a sanitizer or Miri reported, 2 = can't run.
##	History: At bottom of script.

##	Copyright © 2026 t00mietum (CryptogID: ปʬϝღถɔ4რఠΔթะ9ƾǝu)
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


set -Eeuo pipefail

me="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${me}/include/leak-common.bash"
trap 'fStopDescendants; fScratchGone || true' EXIT

mode=""
case "${1:-}" in
	--asan) mode=asan ;;
	--tsan) mode=tsan ;;
	--miri) mode=miri ;;
	*) echo "usage: sanitize-rust.bash --asan|--tsan|--miri" >&2; exit 2 ;;
esac
start="${SECONDS}"
fLeakInImage "sanitize-rust ${mode}" "${me}/sanitize-rust.bash" "${LEAK_DIR}" "$@"

## Asking cargo through rustup would install a missing toolchain on the
## spot, so the list says whether it's here.
if ! rustup toolchain list 2>/dev/null | grep -q -- "^${PIN_NIGHTLY}-"; then
	echo "note: sanitize-rust ${mode}: skipped, since ${PIN_NIGHTLY} isn't installed (rustup toolchain install ${PIN_NIGHTLY} --component rust-src,miri)"
	exit 0
fi
fScratchMake "${mode}" || exit 2
mkdir -p -- "${scratch}/tmp" "${LEAK_DIR}"
export TMPDIR="${scratch}/tmp"

## The suite's own pass lines were shown by the tests stage, so only what
## failed, and what a sanitizer or Miri said.
fShow(){ grep -vE '^test .+ \.\.\. (ok|ignored.*)$|^ +(Compiling|Finished|Running) ' "$1" || true; }

## The SQLite build has to be one of the the sanitizer's, or its C goes unchecked.
## nm -u lists the runtime calls the instrumentation added.
fInstrumented(){   ## fInstrumented DIR SAN
	local lib="" syms=""
	lib="$(find "$1" -name libsqlite3.a -path '*libsqlite3-sys*' -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -n 1)"
	lib="${lib#* }"
	[[ -f "${lib}" ]] || { echo "sanitize-rust: no libsqlite3.a under ${1#"${root}/"}"; return 1; }
	syms="$(nm -u -- "${lib}" 2>/dev/null || true)"
	if [[ "${syms}" != *"__$2_init"* ]]; then echo "sanitize-rust: ${lib#"${root}/"} wasn't built with -fsanitize, so SQLite went unchecked"; return 1; fi
	echo "sanitize-rust: SQLite built with the sanitizer ($(grep -c "__$2_" <<<"${syms}") __$2_ symbols in ${lib##*/})"
}

fSanitizer(){   ## fSanitizer address|thread
	local san="$1" short="${mode}" dir="${LEAK_DIR}/${mode}" log="${scratch}/${mode}.log" rc=0 cc="" sym="" n=""
	for cc in clang-{24..14} clang; do command -v "${cc}" >/dev/null 2>&1 && break; done
	command -v "${cc}" >/dev/null 2>&1 || { echo "sanitize-rust: no clang to build the bundled SQLite with" >&2; exit 2; }
	## LLVM's runtime prints bare addresses unless it finds a symbolizer.
	for sym in llvm-symbolizer llvm-symbolizer-{24..14}; do command -v "${sym}" >/dev/null 2>&1 && break; done
	sym="$(command -v "${sym}" 2>/dev/null || true)"
	## exitcode 77 is no exit a test binary uses, so a report can't pass for
	## a test's own failure. The suppressions file is loaded even though
	## it's empty, so a planted leak shows it hides nothing of ours.
	env RUSTFLAGS="-Zsanitizer=${san} -Cforce-frame-pointers=yes" \
		"CC_x86_64_unknown_linux_gnu=${cc}" "CFLAGS_x86_64_unknown_linux_gnu=-fsanitize=${san} -fno-omit-frame-pointer -g" \
		LIBSQLITE3_FLAGS="-DSQLITE_DEFAULT_LOOKASIDE=0,0 -DSQLITE_DEFAULT_PCACHE_INITSZ=0" \
		ASAN_OPTIONS="exitcode=77:detect_leaks=1:strict_string_checks=1:check_initialization_order=1${sym:+:external_symbolizer_path=${sym}}" \
		LSAN_OPTIONS="exitcode=77:suppressions=${here}/utility/lsan.supp:print_suppressions=0" \
		TSAN_OPTIONS="exitcode=77:halt_on_error=0:second_deadlock_stack=1${sym:+:external_symbolizer_path=${sym}}" \
		RUST_TEST_THREADS="${CPU_CAP}" \
		cargo "+${PIN_NIGHTLY}" test -j "${CPU_CAP}" --locked -Zbuild-std --target x86_64-unknown-linux-gnu \
		--target-dir "${dir}" -- --test-threads "${CPU_CAP}" >"${log}" 2>&1 || rc=$?
	if ((rc != 0)); then
		fShow "${log}"
		echo "sanitize-rust: the tests under ${short} exited ${rc}" >&2
		exit 1
	fi
	fInstrumented "${dir}" "${san:0:1}san" || exit 1
	n="$(sed -n 's/^test result: ok\. \([0-9]*\) passed.*/\1/p' "${log}")"
	echo "sanitize-rust: OK: ${n:-?} tests under ${short}, nothing reported ($((SECONDS - start)) s)"
}

fMiri(){
	local log="${scratch}/miri-build.log" rc=0 t i n=0 live=0 jrc="" limit="${TUKFS_MIRI_TEST_SECS:-1800}" bad=0
	local -a tests=() skipped=() cmd=()
	local -A ignored=()
	[[ "${limit}" =~ ^[1-9][0-9]*$ ]] || { echo "sanitize-rust: TUKFS_MIRI_TEST_SECS must be whole seconds" >&2; exit 2; }
	command -v timeout >/dev/null 2>&1 || { echo "sanitize-rust: no timeout, so a stuck Miri test would never end" >&2; exit 2; }
	## Isolation off, since the tests use real files and the clock.
	export MIRIFLAGS="-Zmiri-disable-isolation ${MIRIFLAGS:-}" RUST_TEST_THREADS=1
	cmd=(cargo "+${PIN_NIGHTLY}" miri test --locked --target-dir "${LEAK_DIR}/miri")
	env -u RUSTFLAGS "${cmd[@]}" -j "${CPU_CAP}" --no-run >"${log}" 2>&1 || rc=$?
	if ((rc != 0)); then cat "${log}"; echo "sanitize-rust: the tests didn't build for Miri" >&2; exit 1; fi
	mapfile -t tests < <(env -u RUSTFLAGS "${cmd[@]}" -- --list 2>/dev/null | sed -n 's/: test$//p')
	while IFS= read -r t; do ignored["${t}"]=1; done < <(env -u RUSTFLAGS "${cmd[@]}" -- --list --ignored 2>/dev/null | sed -n 's/: test$//p')
	((${#tests[@]})) || { echo "sanitize-rust: Miri listed no tests" >&2; exit 1; }
	for t in "${tests[@]}"; do if [[ -n "${ignored[${t}]:-}" ]]; then skipped+=("${t}"); fi; done
	## GNU timeout signals its whole process group, so the test cargo
	## started goes too.
	for i in "${!tests[@]}"; do
		[[ -z "${ignored[${tests[i]}]:-}" ]] || continue
		if ((live >= CPU_CAP)); then wait -n || true; live=$((live - 1)); fi
		{ jrc=0; timeout -k 60 "${limit}" env -u RUSTFLAGS "${cmd[@]}" -- --exact "${tests[i]}" >"${scratch}/miri-${i}.log" 2>&1 || jrc=$?
			echo "${jrc}" >"${scratch}/miri-${i}.rc"; } &
		live=$((live + 1)); n=$((n + 1))
	done
	wait
	for i in "${!tests[@]}"; do
		[[ -z "${ignored[${tests[i]}]:-}" ]] || continue
		jrc=""; { read -r jrc <"${scratch}/miri-${i}.rc"; } 2>/dev/null || true
		[[ "${jrc}" == 0 ]] && continue
		bad=$((bad + 1))
		if [[ "${jrc}" == 124 || "${jrc}" == 137 ]]; then echo "sanitize-rust: ${tests[i]} ran past ${limit} s under Miri and was stopped" >&2; continue; fi
		fShow "${scratch}/miri-${i}.log"
		echo "sanitize-rust: ${tests[i]} under Miri exited ${jrc:-without a result}" >&2
	done
	echo "sanitize-rust: Miri ran ${n} of ${#tests[@]} tests; ${#skipped[@]} are marked to skip it"
	((bad == 0)) || exit 1
	echo "sanitize-rust: OK: nothing reported under Miri ($((SECONDS - start)) s)"
}

case "${mode}" in
	asan) fSanitizer address ;;
	tsan) fSanitizer thread ;;
	miri) fMiri ;;
esac


##	History:
##		- 2026-10-23: Copied from shcl's, with TSan, clang's SQLite build, and
##		  the leak check image.
