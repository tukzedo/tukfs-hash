#!/usr/bin/env bash

##	Purpose:
##		- Puts a release set on the git host as release vVERSION: pushes the
##		  tag, then makes the release with every file the sums file names and
##		  the sums file, under the same names. A version with a "-" in it is a
##		  pre-release. The git host marks the newest other one the latest, by
##		  version, so a fix release for an older line doesn't take it.
##		- The tag has to be on BRANCH at the remote, so a release is always of
##		  a pushed commit. A tag of that name already there has to be the same.
##		- A release that's already there gets only the files it lacks. One
##		  it has with another size, or another sums file, fails the run, since
##		  a download link must never change what it gives.
##		- The notes are the version's section of changelog.md, a downloads
##		  table, then BUILD_LINE. A rerun on a release that's already there
##		  rewrites its notes.
##		- Called by the release upload stage of cicd.bash, and by hand after a
##		  run that stopped there.
##	Syntax:
##		release-upload.bash REPO VERSION SET_DIR BUILD_LINE BRANCH
##	Exit: 0 = uploaded or already there, 1 = refused or failed, 2 = usage.
##	History: At bottom of script.

##	Copyright © 2026 t00mietum (CryptogID: ปʬϝღถɔ4რఠΔթะ9ƾǝu)
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


set -Eeuo pipefail

(($# == 5)) || { echo "usage: release-upload.bash REPO VERSION SET_DIR BUILD_LINE BRANCH" >&2; exit 2; }
repo="$1"; ver="$2"; setDir="$3"; buildLine="$4"; branch="$5"
tag="v${ver}"
exeName="${buildLine%% *}"
sums="${exeName}-${ver}-sha256sums.txt"
export GH_PROMPT_DISABLED=1

fDie(){ echo "release-upload: $*" >&2; exit 1; }
## Through gitsby where it's installed, so the repo's own account is used.
fGitRemote(){ if command -v gitsby >/dev/null 2>&1; then gitsby raw git "$@"; else git "$@"; fi; }
fGh(){ if command -v gitsby >/dev/null 2>&1; then gitsby raw gh "$@"; else gh "$@"; fi; }

cd -- "${repo}" || fDie "no repo at ${repo}"
## No date and no -dirty, which only a release build leaves off.
build="${buildLine#"${exeName} ${tag} build "}"
[[ -n "${exeName}" && "${build}" != "${buildLine}" ]] || fDie "the build line doesn't name ${tag}: ${buildLine}"
[[ "${build}" =~ ^[0-9a-z]+$ ]] || fDie "the build line isn't a release build's: ${buildLine}"

## The set is what its sums file names, all of it there and whole.
[[ -f "${setDir}/${sums}" ]] || fDie "no ${sums} in ${setDir}"
declare -a files=()
while read -r _sum name; do
	[[ "${name}" == "${exeName}-${ver}-"* && "${name}" != */* ]] || fDie "${sums} names ${name}, which isn't in the ${ver} set"
	files+=("${name}")
done < "${setDir}/${sums}"
((${#files[@]})) || fDie "${sums} is empty"
( cd -- "${setDir}" && sha256sum --check --quiet --strict -- "${sums}" ) || fDie "the set in ${setDir} doesn't match ${sums}"
files+=("${sums}")

remote="$(git config --get "branch.${branch}.remote" || echo origin)"
commit="$(git rev-parse -q --verify "refs/tags/${tag}^{commit}")" || fDie "no tag ${tag} here"
tagObj="$(git rev-parse "refs/tags/${tag}")"
fGitRemote fetch --quiet "${remote}" "refs/heads/${branch}" || fDie "couldn't fetch ${branch} from ${remote}"
git merge-base --is-ancestor "${commit}" FETCH_HEAD || fDie "${tag} (${commit:0:12}) isn't on ${remote}'s ${branch} yet. Push ${branch} first."

out="$(fGitRemote ls-remote --tags "${remote}" "refs/tags/${tag}")" || fDie "couldn't list the tags on ${remote}"
if [[ -z "${out}" ]]; then
	fGitRemote push --quiet "${remote}" "refs/tags/${tag}" || fDie "couldn't push ${tag} to ${remote}"
	echo "pushed tag ${tag} (${commit:0:12}) to ${remote}"
elif [[ "${out%%[[:space:]]*}" != "${tagObj}" ]]; then
	fDie "${remote} has another ${tag}. Bump the version, or sort the tag out by hand."
fi

## Rank for the table's order, then the name. Unknown ones go last.
fRank(){ local i=0 w; for w in ${2}; do [[ "${w}" == "$1" ]] && { echo "${i}"; return; }; i=$((i + 1)); done; echo 99; }
## OS rows, CPU columns, same as the sister projects. Our names never need GitHub's renaming, so links are built from them.
fTable(){
	local base="$1" name rest os tail arch ext k label raw line c i
	local -a ents=() oses=() arches=() rows=() w=() sumLinks=() otherLinks=()
	local -A cell=()
	for name in "${files[@]}"; do
		if [[ "${name}" == "${sums}" ]]; then sumLinks+=("[${name}](${base}/${name})"); continue; fi
		rest="${name#"${exeName}-${ver}-"}"; os="${rest%%-*}"; tail="${rest#*-}"; arch="${tail%%.*}"; ext="${tail#"${arch}"}"; ext="${ext#.}"
		if [[ "${rest}" != *-* || -z "${arch}" ]]; then otherLinks+=("[${name}](${base}/${name})"); continue; fi
		case "${ext}" in "") k=0; label=binary ;; deb) k=1; label=deb ;; rpm) k=2; label=rpm ;; *) k=3; label="${ext}" ;; esac
		ents+=("$(fRank "${os}" "linux windows freebsd macos")"$'\t'"${os}"$'\t'"$(fRank "${arch}" "x86_64 arm64")"$'\t'"${arch}"$'\t'"${k}"$'\t'"${label}"$'\t'"${name}")
	done
	if ((${#ents[@]})); then
		mapfile -t oses < <(printf '%s\n' "${ents[@]}" | sort -t$'\t' -k1,1n -k2,2 | cut -f2 | uniq)
		mapfile -t arches < <(printf '%s\n' "${ents[@]}" | sort -t$'\t' -k3,3n -k4,4 | cut -f4 | uniq)
		while IFS=$'\t' read -r _ os _ arch _ label name; do
			cell["${os}/${arch}"]+="${cell["${os}/${arch}"]:+, }[${label}](${base}/${name})"
		done < <(printf '%s\n' "${ents[@]}" | sort -t$'\t' -k1,1n -k2,2 -k3,3n -k4,4 -k5,5n -k6,6)
		line="OS"; for arch in "${arches[@]}"; do line+=$'\t'"${arch}"; done; rows+=("${line}")
		line=":---"; for arch in "${arches[@]}"; do line+=$'\t'":---"; done; rows+=("${line}")
		for os in "${oses[@]}"; do
			case "${os}" in linux) line=Linux ;; windows) line=Windows ;; freebsd) line=FreeBSD ;; macos) line=macOS ;; *) line="${os}" ;; esac
			for arch in "${arches[@]}"; do line+=$'\t'"${cell["${os}/${arch}"]:--}"; done
			rows+=("${line}")
		done
		for line in "${rows[@]}"; do IFS=$'\t' read -ra c <<< "${line}"; for i in "${!c[@]}"; do ((${#c[i]} <= ${w[i]:-0})) || w[i]=${#c[i]}; done; done
		printf '### Downloads\n\n'
		for line in "${rows[@]}"; do
			IFS=$'\t' read -ra c <<< "${line}"; raw="|"
			for i in "${!c[@]}"; do raw+="$(printf ' %-*s |' "${w[i]}" "${c[i]}")"; done
			raw="${raw% |}"; printf '%s\n' "${raw%"${raw##*[![:space:]]}"}"
		done
	fi
	line=""
	if ((${#sumLinks[@]})); then printf -v raw '%s, ' "${sumLinks[@]}"; line+="Checksums: ${raw%, }."; fi
	if ((${#otherLinks[@]})); then printf -v raw '%s, ' "${otherLinks[@]}"; line+="${line:+ }Other files: ${raw%, }."; fi
	if git cat-file -e "${tag}:install.bash" 2>/dev/null; then
		raw="${base%/releases/download/*}"; raw="https://raw.githubusercontent.com/${raw#https://github.com/}"
		line+="${line:+ }Installer: [install.bash](${raw}/${tag}/install.bash)."
	fi
	[[ -z "${line}" ]] || printf '\n%s\n' "${line}"
}

## The version's changelog section, the table, then the build line, as gitsby and nemo-anywhere do.
notes=""
if [[ -f changelog.md ]]; then
	## The lines under "## VERSION", up to the next heading of that level.
	section="$(awk -v h="## ${ver}" '$0 == h {on = 1; next} on && /^## / {exit} on' changelog.md | sed '/./,$!d')"
	if [[ -n "${section//[[:space:]]/}" ]]; then notes="${section}"$'\n\n'; else echo "note: changelog.md has no section for ${ver}"; fi
fi
repoUrl="$(fGh repo view --json url --jq .url)" && [[ "${repoUrl}" == https://github.com/?*/?* ]] || fDie "couldn't read the repo's URL from the git host"
notes+="$(fTable "${repoUrl%/}/releases/download/${tag}")"$'\n\n---\n\n'"${buildLine}"

## name<TAB>size per asset, for a release that's already there.
declare -A hostSize=()
if have="$(fGh release view "${tag}" --json assets --jq '.assets[] | "\(.name)\t\(.size)"' 2>/dev/null)"; then
	if [[ -n "${have}" ]]; then while IFS=$'\t' read -r name size; do hostSize["${name}"]="${size}"; done <<< "${have}"; fi
	if [[ -n "${hostSize["${sums}"]:-}" ]]; then
		hostSums="$(fGh release download "${tag}" --pattern "${sums}" --output -)" || fDie "couldn't read ${sums} from release ${tag}"
		[[ "${hostSums}" == "$(< "${setDir}/${sums}")" ]] || fDie "release ${tag} has other files than this set. Bump the version."
	fi
	declare -a missing=()
	for name in "${files[@]}"; do
		if [[ -z "${hostSize["${name}"]:-}" ]]; then missing+=("${setDir}/${name}"); continue; fi
		[[ "${hostSize["${name}"]}" == "$(stat -c %s -- "${setDir}/${name}")" ]] || fDie "release ${tag} has another ${name}. Bump the version."
	done
	if ((${#missing[@]} == 0)); then
		echo "release ${tag} already has all ${#files[@]} files"
	else
		fGh release upload "${tag}" "${missing[@]}" || fDie "couldn't upload to release ${tag}"
		echo "uploaded ${#missing[@]} file(s) to release ${tag}, which had the rest"
	fi
	## Notes come from the changelog, so a rerun brings an old release's up to date.
	fGh release edit "${tag}" --notes "${notes}" >/dev/null || fDie "couldn't update the notes of release ${tag}"
	echo "updated the notes of release ${tag}"
	exit 0
fi

kind=()
if [[ "${ver}" == *-* ]]; then kind=(--prerelease); fi
declare -a paths=()
for name in "${files[@]}"; do paths+=("${setDir}/${name}"); done
fGh release create "${tag}" --verify-tag --title "${tag}" --notes "${notes}" ${kind[@]+"${kind[@]}"} "${paths[@]}" || fDie "couldn't make release ${tag}"
echo "made release ${tag} with ${#files[@]} files"


##	History:
##		- 2026-11-08: Created.
##		- 2026-11-27: Downloads table in the notes, and a rerun rewrites them.
