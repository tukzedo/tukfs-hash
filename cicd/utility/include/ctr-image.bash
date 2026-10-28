#!/usr/bin/env bash

#  shellcheck disable=2154  ## 'referenced but not assigned.' root, APP_NAME, CPU_CAP, the CTR_ settings, the PINs and stop_cidfile come from config.bash and stop-descendants.bash, sourced first.

##	Purpose:
##		The leak check image, or the release one, for the scripts that run
##		their tools in it. Source stop-descendants.bash and config.bash
##		first, with root set to the repo root.
##			fCtrUseRelease      the functions below work on the release image
##			                    from then on, not the leak check one.
##			fCtrWhyNot          nothing when the image can run here, else why
##			                    not: it's x86_64 only, and docker (or
##			                    TUKFS_DOCKER) counts once its daemon answers.
##			fCtrReady WORK      the image's tag into ctr_tag, building it
##			                    first if it isn't here. WORK is a scratch dir.
##			fCtrFetch WORK      fill CTR_CARGO_HOME, with network, with the
##			                    crates Cargo.lock names, and for the leak
##			                    checks the ones -Zbuild-std takes. Once per
##			                    lock file and image. Offline, a note, and
##			                    what's cached.
##			fCtrRunSelf WORK RW SCRIPT [ARG...]
##			                    run SCRIPT in the image, with no network, as
##			                    the caller's uid, on CPU_CAP cores, at nice 19
##			                    and idle I/O. The repo goes in read only at
##			                    its own path. WORK, CTR_CARGO_HOME and RW,
##			                    dirs joined by ':', are all it writes, each
##			                    at its own real path.
##			                    TMPDIR and HOME are in WORK, so on the host's
##			                    filesystem, with its user xattrs.
##			                    TUKFS_IN_IMAGE=1 tells the script where it is.
##			                    The build number, its release flag and
##			                    SOURCE_DATE_EPOCH go in when they're set.
##			                    Returns the script's exit, or 2.
##		Every container is named tukfs-hash-<run>-<step>-<n> and labeled
##		dev.project and dev.run, and every image dev.project and dev.run too.
##		<run> is TUKFS_RUN_NAME, the cicd run's folder name, and <step> is
##		ctr_step, which the caller sets. cicd.bash removes a run's
##		containers by that label at its end.
##		A build keeps the new tag and the one before it, once the new one has
##		answered, and then prunes build cache over a week old and any <none>
##		image of ours.
##		From shcl's cicd/utility/include/ctr-image.bash.
##	History: At bottom of script.

##	Copyright © 2026 t00mietum (CryptogID: ปʬϝღถɔ4რఠΔթะ9ƾǝu)
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


ctr_tag=""
ctr_kind="leak"
ctr_step="${ctr_step:-ctr}"
ctr_run=""; ctr_labels=()

## At first use, since cicd.bash names its run after this is sourced. A
## script run on its own, outside a cicd run, gets a name of its own.
fCtrLabels(){
	[[ -z "${ctr_run}" ]] || return 0
	ctr_run="${TUKFS_RUN_NAME:-}"
	[[ "${ctr_run}" =~ ^[A-Za-z0-9_.-]+$ ]] || printf -v ctr_run '%(%Y%m%d-%H%M%S)T_p%s' -1 "$$"
	ctr_labels=(--label "dev.project=${APP_NAME}" --label "dev.run=${ctr_run}")
}

fCtrUseRelease(){
	ctr_kind="release"
	CTR_DIR="${REL_CTR_DIR}"; CTR_IMAGE="${REL_CTR_IMAGE}"
	CTR_CONTEXT_EXTRA=("${REL_CTR_CONTEXT_EXTRA[@]}"); CTR_CARGO_HOME="${REL_CTR_CARGO_HOME}"
}

## An installed docker with no daemon behind it is no docker at all. The
## timeout is for a DOCKER_HOST that never replies.
fCtrWhyNot(){
	local engine="${TUKFS_DOCKER:-docker}"
	local -a limit=()
	if [[ -n "${TUKFS_NO_CONTAINER:-}" ]]; then echo "--no-container was given"; return 0; fi
	if [[ "$(uname -m)" != x86_64 ]]; then echo "the image is x86_64 only"; return 0; fi
	if ! command -v "${engine}" >/dev/null 2>&1; then echo "there's no ${engine} here"; return 0; fi
	if command -v timeout >/dev/null 2>&1; then limit=(timeout 30); fi
	if ! "${limit[@]}" "${engine}" info >/dev/null 2>&1; then echo "${engine} doesn't answer"; fi
	return 0
}

fCtrContext(){   ## fCtrContext DIR
	local ctx="$1" f
	cp -p -- "${root}/${CTR_DIR}"/* "${ctx}/" || return 1
	for f in "${CTR_CONTEXT_EXTRA[@]}"; do cp -p -- "${root}/${f}" "${ctx}/" || return 1; done
}

## A hash of the context, so an edit to any of it means a new image.
fCtrTag(){   ## fCtrTag DIR
	local ctx="$1" f
	local -a ctxFiles=()
	mapfile -t ctxFiles < <(cd "${ctx}" && find . -type f | LC_ALL=C sort)
	printf '%s:%s\n' "${CTR_IMAGE}" "$(cd "${ctx}" && for f in "${ctxFiles[@]}"; do echo "${f}"; cat "${f}"; done | git hash-object --stdin | cut -c1-12)"
}

fCtrSize(){ "${TUKFS_DOCKER:-docker}" image inspect --format '{{.Size}}' "$1" 2>/dev/null || echo 0; }

## docker run, with a cidfile a stop finds, for every container here. The
## cidfile goes in TUKFS_CID_DIR, else in DIR. nice on the client doesn't
## reach a container, so each gets CPU_CAP cores at a low share, and the ones
## that do real work run nice inside too.
## <n> is taken with a plain mkdir in the cid dir, which the whole run
## shares, so a name kept by --keep-temp can't come up twice.
fCtrRun(){   ## fCtrRun DIR STEP RUN_ARG...
	local engine="${TUKFS_DOCKER:-docker}" rc=0 cidfile="" f step="${2:-ctr}" n=1
	local -a kept=() args=()
	fStopCidfile "$1" || { echo "ctr-image: no dir for a cidfile" >&2; return 2; }
	cidfile="${stop_cidfile}"
	shift 2
	fCtrLabels
	step="${step//[^A-Za-z0-9_.-]/-}"
	while [[ "${step}" == *--* ]]; do step="${step//--/-}"; done
	while ! mkdir -- "${cidfile%/*}/name_${n}" 2>/dev/null; do
		n=$((n + 1)); ((n < 10000)) || { echo "ctr-image: no free container name" >&2; return 2; }
	done
	## --keep-temp keeps the container, stopped, for a look after.
	if [[ -n "${TUKFS_KEEP_TEMP:-}" ]]; then
		for f in "$@"; do [[ "${f}" == --rm ]] || args+=("${f}"); done
		set -- "${args[@]}"
	fi
	stop_cidfiles+=("${cidfile}")
	"${engine}" run --cidfile "${cidfile}" --name "${APP_NAME}-${ctr_run}-${step}-${n}" "${ctr_labels[@]}" \
		--cpus "${CPU_CAP:-1}" --cpu-shares 256 "$@" || rc=$?
	for f in "${stop_cidfiles[@]}"; do [[ "${f}" == "${cidfile}" ]] || kept+=("${f}"); done
	stop_cidfiles=("${kept[@]}")
	if [[ -n "${TUKFS_KEEP_TEMP:-}" && -s "${cidfile}" ]]; then echo "[ kept (--keep-temp): container $(head -c 12 -- "${cidfile}") ]" >&2; fi
	rm -f -- "${cidfile}"
	return "${rc}"
}
fCtrGB(){ awk -v b="${1:-0}" 'BEGIN { printf "%.1f GB", b / 1e9 }'; }

## The label is what finds a <none> image of ours, and only ours.
fCtrBuild(){   ## fCtrBuild TAG DIR
	local engine="${TUKFS_DOCKER:-docker}" tag="$1" ctx="$2" old="" prev="" id="" have="" bytes=0 freed=0 pruned=""
	local -a gone=() args=()
	fCtrLabels
	if [[ "${ctr_kind}" == leak ]]; then
		args=(--build-arg "NIGHTLY=${PIN_NIGHTLY}" --build-arg "CODEQL_VER=${PIN_CODEQL}"
			--build-arg "CODEQL_SHA256=${PIN_CODEQL_SHA256}" --build-arg "JOBS=${CPU_CAP:-1}")
	fi
	"${engine}" build -q --label "${CTR_IMAGE}" "${ctr_labels[@]}" -t "${tag}" "${args[@]}" "${ctx}" >/dev/null || return 1
	## It has to answer before the old one goes.
	if [[ "${ctr_kind}" == leak ]]; then
		have="$(fCtrRun "${ctx}" "${ctr_step}-probe" --rm --label "${CTR_IMAGE}" --network none "${tag}" codeql version --format=terse 2>/dev/null || true)"
		if [[ "${have}" != "${PIN_CODEQL}" ]]; then echo "ctr-image: ${tag} has CodeQL '${have}', not ${PIN_CODEQL}" >&2; return 1; fi
		have="$(fCtrRun "${ctx}" "${ctr_step}-probe" --rm --label "${CTR_IMAGE}" --network none "${tag}" rustup toolchain list 2>/dev/null || true)"
		if ! grep -q -- "^${PIN_NIGHTLY}-" <<<"${have}"; then
			echo "ctr-image: ${tag} has no ${PIN_NIGHTLY}" >&2; return 1
		fi
	else
		have="$(fCtrRun "${ctx}" "${ctr_step}-probe" --rm --label "${CTR_IMAGE}" --network none "${tag}" ldd --version 2>/dev/null | head -n 1 || true)"
		if [[ "${have}" != *" ${GLIBC_FLOOR}" ]]; then echo "ctr-image: ${tag} has '${have}', not glibc ${GLIBC_FLOOR}" >&2; return 1; fi
		have="$(fCtrRun "${ctx}" "${ctr_step}-probe" --rm --label "${CTR_IMAGE}" --network none "${tag}" rustup toolchain list 2>/dev/null || true)"
		if ! grep -q -- "^${RUST_PIN}-" <<<"${have}"; then
			echo "ctr-image: ${tag} has no ${RUST_PIN}" >&2; return 1
		fi
	fi
	## The newest other tag stays too, to go back to. Not -f, so an image a
	## container still has stays.
	while IFS=$'\t' read -r _ old; do
		[[ -n "${old}" && "${old}" != "${tag}" ]] || continue
		if [[ -z "${prev}" ]]; then prev="${old}"; continue; fi
		bytes="$(fCtrSize "${old}")"
		if "${engine}" rmi "${old}" >/dev/null 2>&1; then gone+=("${old}"); freed=$((freed + bytes)); else echo "ctr-image: kept ${old}, which is in use"; fi
	done < <("${engine}" image ls "${CTR_IMAGE}" --format '{{.CreatedAt}}\t{{.Repository}}:{{.Tag}}' 2>/dev/null | LC_ALL=C sort -r || true)
	## A week of every project's cache stays, since a cold one costs minutes.
	pruned="$("${engine}" builder prune -f --filter until=168h 2>/dev/null | sed -n 's/^Total\( reclaimed space\)\{0,1\}:[[:space:]]*//p' || true)"
	while IFS= read -r id; do
		[[ -n "${id}" ]] || continue
		bytes="$(fCtrSize "${id}")"
		if "${engine}" rmi "${id}" >/dev/null 2>&1; then gone+=("<none> ${id:0:12}"); freed=$((freed + bytes)); fi
	done < <("${engine}" image ls -q --filter dangling=true --filter "label=${CTR_IMAGE}" 2>/dev/null || true)
	echo "ctr-image: built ${tag} ($(fCtrGB "$(fCtrSize "${tag}")")); kept ${prev:-no older tag}; removed ${gone[*]:-no old image}, freeing $(fCtrGB "${freed}"), and ${pruned:-0B} of build cache"
	return 0
}

fCtrReady(){   ## fCtrReady WORK
	local engine="${TUKFS_DOCKER:-docker}" ctx="$1/ctx"
	mkdir -p -- "${ctx}" || return 1
	fCtrContext "${ctx}" || { echo "ctr-image: could not copy the image's context" >&2; return 1; }
	ctr_tag="$(fCtrTag "${ctx}")"
	"${engine}" image inspect "${ctr_tag}" >/dev/null 2>&1 && return 0
	echo "ctr-image: building ${ctr_tag}, which takes several minutes the first time"
	fCtrBuild "${ctr_tag}" "${ctx}" || { echo "ctr-image: could not build ${ctr_tag}" >&2; return 1; }
}

## The crates for an offline run. Most runs find the stamp current and skip it.
fCtrFetch(){   ## fCtrFetch WORK
	local work="$1" want="" got="" ch=""
	mkdir -p -- "${CTR_CARGO_HOME}" "${work}/home" "${work}/tmp" || return 1
	ch="$(realpath -e -- "${CTR_CARGO_HOME}")" || return 1
	local -a nightly=()
	if [[ "${ctr_kind}" == leak ]]; then nightly=("${PIN_NIGHTLY}"); fi
	want="$(sha256sum < "${root}/Cargo.lock" | cut -c1-16) ${ctr_tag}"
	{ read -r got < "${ch}/.fetched"; } 2>/dev/null || true
	[[ "${got}" != "${want}" ]] || return 0
	if fCtrRun "${work}" "${ctr_step}-fetch" --rm --init --label "${CTR_IMAGE}" --user "$(id -u):$(id -g)" \
		-v "${root}:${root}:ro" -v "${work}:${work}" -v "${ch}:${ch}" -w "${root}" \
		-e "TMPDIR=${work}/tmp" -e "HOME=${work}/home" -e "CARGO_HOME=${ch}" \
		"${ctr_tag}" nice -n 19 ionice -c 3 bash "${root}/cicd/utility/include/ctr-fetch.bash" "${nightly[@]}"; then
		printf '%s\n' "${want}" > "${ch}/.fetched"
	else
		echo "note: could not fetch crates for the image (offline?); going on with what's cached"
	fi
	return 0
}

fCtrRunSelf(){   ## fCtrRunSelf WORK RW SCRIPT [ARG...]
	local work="$1" rw="$2" rc=0 d ch=""
	local -a rwMount=() rwDirs=()
	shift 2
	mkdir -p -- "${work}/home" "${work}/tmp" "${CTR_CARGO_HOME}" || return 2
	ch="$(realpath -e -- "${CTR_CARGO_HOME}")" || return 2
	## Docker would make a missing mount point as root, inside a read-only mount.
	IFS=: read -r -a rwDirs <<<"${rw}"
	for d in "${rwDirs[@]}"; do
		[[ -n "${d}" ]] || continue
		mkdir -p -- "${d}" || return 2
		d="$(realpath -e -- "${d}")" || return 2
		rwMount+=(-v "${d}:${d}")
	done
	## A stop takes the container down too, even when its client won't go.
	fCtrRun "${work}" "${ctr_step}" --rm --init --label "${CTR_IMAGE}" --network none \
		--user "$(id -u):$(id -g)" -v "${root}:${root}:ro" -v "${work}:${work}" -v "${ch}:${ch}" \
		"${rwMount[@]}" -w "${root}" \
		-e TUKFS_IN_IMAGE=1 -e TINI_KILL_PROCESS_GROUP=1 -e "CPU_CAP=${CPU_CAP:-1}" -e "TMPDIR=${work}/tmp" \
		-e "HOME=${work}/home" -e "CARGO_HOME=${ch}" -e CARGO_NET_OFFLINE=true -e "TUKFS_GATE_STRICT=${TUKFS_GATE_STRICT:-}" \
		-e "${BUILD_ENV_NAME}" -e "${BUILD_RELEASE_ENV_NAME}" -e SOURCE_DATE_EPOCH -e CARGO_TERM_QUIET \
		"${ctr_tag}" nice -n 19 ionice -c 3 bash "$@" || rc=$?
	return "${rc}"
}


##	History:
##		- 2026-10-23: Copied from shcl's, for the leak checks only: one image,
##		  the nightly and CodeQL from tool-pins.env, a fetch run for the
##		  crates, and the old image and build cache cleared after a build.
##		- 2026-10-23: Every container through fCtrRun, with a cidfile in the
##		  run's cid dir, so a stop of the whole run finds it.
##		- 2026-10-23: The release image too, through fCtrUseRelease.
##		- 2026-10-23: The release flag goes in with the build number.
##		- 2026-10-25: --cpus and --cpu-shares 256 on every container, and nice
##		  and idle I/O inside the ones that build or test.
##		- 2026-10-25: Container names and dev.project and dev.run labels. A
##		  build keeps the tag before the new one, and the cache prune keeps a
##		  week.
