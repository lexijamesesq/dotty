#!/usr/bin/env bash
# gitleaks-pre-push.sh — FAIL-CLOSED scan of the outgoing commit range.
#
# One range scan, delegated to gitleaks-range-scan.sh (the estate's single
# diff-scoped scan implementation, with its identity guard and its #2129 /
# #1729 fail-open backstops). This hook's only job is to resolve WHICH range is
# outgoing, and to block when it cannot.
#
# FAIL-CLOSED, restored. An earlier revision demoted this hook to advisory:
# it failed open on an unresolvable range, on a scanner error, and even on a
# finding, on the reasoning that the required CI check is the real gate. That
# is wrong on the operator's standard — a test that does not gate is not a
# useful test — and it left `.pre-commit-hooks.yaml` describing a fail-closed
# hook that did not exist. Every path below now ends in a block with a stated
# reason; the only exits with 0 are a branch deletion, an empty range, and a
# clean scan.
#
# It does NOT bring back the 554-line range/history/widen/whole-tree resolver
# that preceded the demotion. Those over-scan traps (empty remote, all-zeros,
# target-remote resolution, force-push) were real, and the fix for them is to
# stop reconstructing what git is about to push, not to stop gating. The range
# comes from pre-commit's own pre-push contract — PRE_COMMIT_FROM_REF /
# PRE_COMMIT_TO_REF, exported at the pre-push stage — with a merge-base against
# the default branch for a branch that has no remote counterpart yet.
#
# Spec: {workspace_root}/System/Knowledge/leak-prevention-architecture.md

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/gitleaks-common.sh"
RANGE_SCAN="$HERE/gitleaks-range-scan.sh"
ZERO="0000000000000000000000000000000000000000"

head_ref="${PRE_COMMIT_TO_REF:-}"
# A branch deletion pushes the all-zeros object as the new value: there are no
# outgoing commits to scan, so this is a clean pass, not an unresolved range.
[[ "$head_ref" == "$ZERO" ]] && exit 0
[[ -n "$head_ref" ]] || head_ref="$(git rev-parse --verify --quiet HEAD 2>/dev/null || true)"
if [[ -z "$head_ref" ]]; then
	gl_block "Pre-push BLOCKED: no outgoing head to scan" \
		"Neither PRE_COMMIT_TO_REF nor HEAD resolves to a commit." \
		"(Fail-closed: an unscannable push is refused, never waved through.)"
	exit 1
fi

# Base, in order: pre-commit's own exported from-ref; the branch's upstream;
# the merge-base with the default branch (the new-branch case, where no remote
# counterpart exists yet and the outgoing commits are exactly those not on the
# default branch).
base="${PRE_COMMIT_FROM_REF:-}"
[[ "$base" == "$ZERO" ]] && base=""
if [[ -z "$base" ]]; then
	base="$(git rev-parse --verify --quiet '@{upstream}' 2>/dev/null || true)"
fi
if [[ -z "$base" ]]; then
	for ref in "$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || true)" \
		origin/main origin/master; do
		[[ -n "$ref" ]] || continue
		git rev-parse --verify --quiet "$ref" >/dev/null 2>&1 || continue
		base="$(git merge-base "$ref" "$head_ref" 2>/dev/null || true)"
		[[ -n "$base" ]] && break
	done
fi
if [[ -z "$base" ]]; then
	gl_block "Pre-push BLOCKED: cannot resolve the outgoing commit range" \
		"Head: $head_ref" \
		"No PRE_COMMIT_FROM_REF, no upstream tracking ref, and no default-branch" \
		"remote ref (origin/HEAD, origin/main, origin/master) to take a merge-base" \
		"against — so which commits are outgoing is unknown." \
		"Fix: fetch the remote, or set the branch's upstream, then push again." \
		"(Fail-closed: an unverifiable range is refused, never scanned partially" \
		"and passed.)"
	exit 1
fi

if GL_RANGE_BASE="$base" GL_RANGE_HEAD="$head_ref" bash "$RANGE_SCAN" >&2; then
	exit 0
fi
gl_block "Pre-push BLOCKED: the outgoing commit range did not pass the scan" \
	"Range: $base..$head_ref" \
	"The scan's own report is above (rule ids and locations; matched values" \
	"withheld). The push is refused here, before the content reaches the remote."
exit 1
