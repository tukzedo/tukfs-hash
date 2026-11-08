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
##		- The notes are BUILD_LINE, then the version's section of changelog.md.
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
fGitRemote fetch --quiet "${remote}" "refs/heads/${branch}" || fDie "could not fetch ${branch} from ${remote}"
git merge-base --is-ancestor "${commit}" FETCH_HEAD || fDie "${tag} (${commit:0:12}) isn't on ${remote}'s ${branch} yet. Push ${branch} first."

out="$(fGitRemote ls-remote --tags "${remote}" "refs/tags/${tag}")" || fDie "could not list the tags on ${remote}"
if [[ -z "${out}" ]]; then
	fGitRemote push --quiet "${remote}" "refs/tags/${tag}" || fDie "could not push ${tag} to ${remote}"
	echo "pushed tag ${tag} (${commit:0:12}) to ${remote}"
elif [[ "${out%%[[:space:]]*}" != "${tagObj}" ]]; then
	fDie "${remote} has another ${tag}. Bump the version, or sort the tag out by hand."
fi

## name<TAB>size per asset, for a release that's already there.
declare -A hostSize=()
if have="$(fGh release view "${tag}" --json assets --jq '.assets[] | "\(.name)\t\(.size)"' 2>/dev/null)"; then
	if [[ -n "${have}" ]]; then while IFS=$'\t' read -r name size; do hostSize["${name}"]="${size}"; done <<< "${have}"; fi
	if [[ -n "${hostSize["${sums}"]:-}" ]]; then
		hostSums="$(fGh release download "${tag}" --pattern "${sums}" --output -)" || fDie "could not read ${sums} from release ${tag}"
		[[ "${hostSums}" == "$(< "${setDir}/${sums}")" ]] || fDie "release ${tag} has other files than this set. Bump the version."
	fi
	declare -a missing=()
	for name in "${files[@]}"; do
		if [[ -z "${hostSize["${name}"]:-}" ]]; then missing+=("${setDir}/${name}"); continue; fi
		[[ "${hostSize["${name}"]}" == "$(stat -c %s -- "${setDir}/${name}")" ]] || fDie "release ${tag} has another ${name}. Bump the version."
	done
	if ((${#missing[@]} == 0)); then echo "release ${tag} already has all ${#files[@]} files"; exit 0; fi
	fGh release upload "${tag}" "${missing[@]}" || fDie "could not upload to release ${tag}"
	echo "uploaded ${#missing[@]} file(s) to release ${tag}, which had the rest"
	exit 0
fi

notes="${buildLine}"
if [[ -f changelog.md ]]; then
	## The lines under "## VERSION", up to the next heading of that level.
	section="$(awk -v h="## ${ver}" '$0 == h {on = 1; next} on && /^## / {exit} on' changelog.md)"
	if [[ -n "${section//[[:space:]]/}" ]]; then notes+=$'\n'"${section}"; else echo "note: changelog.md has no section for ${ver}"; fi
fi
kind=()
if [[ "${ver}" == *-* ]]; then kind=(--prerelease); fi
declare -a paths=()
for name in "${files[@]}"; do paths+=("${setDir}/${name}"); done
fGh release create "${tag}" --verify-tag --title "${tag}" --notes "${notes}" ${kind[@]+"${kind[@]}"} "${paths[@]}" || fDie "could not make release ${tag}"
echo "made release ${tag} with ${#files[@]} files"


##	History:
##		- 2026-11-08: Created.
