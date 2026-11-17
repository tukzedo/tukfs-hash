#!/usr/bin/env bash

##	Purpose:
##		Remember the trees a gate passed, so the pre-push hook can let through a
##		commit with the same tree instead of running the gate on it again. A tree
##		hash covers every tracked byte and file mode, so 2 commits that share
##		one can't differ in anything the gate reads from the repo.
##	Syntax:
##		green-tree.bash tree DIR          the tree `git add --all` would commit in DIR
##		green-tree.bash record DIR TREE   remember TREE, if DIR still has it
##		green-tree.bash passed DIR TREE   is TREE remembered?
##	Exit: 0 = done or remembered, 1 = not recorded or not remembered, 2 = usage or git failure.
##	History: At bottom of script.

##	Copyright (c) 2026 Bubbles
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


set -Eeuo pipefail

fUsage(){ echo "usage: green-tree.bash tree DIR | record DIR TREE | passed DIR TREE" >&2; exit 2 ;}
(($# >= 2)) || fUsage
cmd="$1"; dir="$2"
if [[ "${cmd}" != tree ]]; then
	(($# == 3)) || fUsage
	[[ "$3" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] || fUsage
fi

## In the common dir, so every worktree of a clone shares one list, and nothing
## commits it or cleans it away.
fList(){
	local common
	common="$(git -C "${dir}" rev-parse --path-format=absolute --git-common-dir)" || exit 2
	echo "${common}/tukfs-hash-green-trees"
}

## A scratch index seeded from HEAD rather than copied from the real one, so
## every file is hashed from disk: a copied index would keep assume-unchanged
## and skip-worktree bits, and a file with one would be tested as it sits on
## disk and committed as the index has it.
fTree(){
	local tree
	scratchIdx="$(mktemp -u)"
	## Global, since the trap runs after the function returns. A stopped run left
	## the index, and its lock, behind.
	trap 'rm -f -- "${scratchIdx}" "${scratchIdx}.lock"' EXIT
	if { ! git -C "${dir}" rev-parse -q --verify HEAD >/dev/null || GIT_INDEX_FILE="${scratchIdx}" git -C "${dir}" read-tree HEAD; } \
		&& GIT_INDEX_FILE="${scratchIdx}" git -C "${dir}" add --all \
		&& tree="$(GIT_INDEX_FILE="${scratchIdx}" git -C "${dir}" write-tree)"; then
		rm -f "${scratchIdx}"; echo "${tree}"
	else
		rm -f "${scratchIdx}"; exit 2
	fi
}

case "${cmd}" in
	tree)
		fTree ;;
	record)
		now="$(fTree)" || exit 2
		if [[ "${now}" != "$3" ]]; then
			echo "green-tree: the files changed during the run, so it is not recorded" >&2
			exit 1
		fi
		list="$(fList)"
		printf '%s %s\n' "$3" "$(date +%Y%m%d-%H%M%S)" >> "${list}"
		if (($(wc -l < "${list}") > 200)); then
			tail -n 100 "${list}" > "${list}.tmp" && mv -f "${list}.tmp" "${list}"
		fi ;;
	passed)
		list="$(fList)"
		[[ -f "${list}" ]] || exit 1
		grep -q "^$3 " "${list}" ;;
	*)
		fUsage ;;
esac


##	History:
##		- 2026-09-14: Created.
##		- 2026-10-19: The scratch index goes on any exit.
##		- 2026-10-23: Copied into tukfs-hash from shcl's cicd, with its own list name.
