#!/usr/bin/env bash
# gitleaks-pre-push.sh — THIN, best-effort, ADVISORY local pre-push heads-up.
#
# DEMOTED (was ~554 lines of hand-rolled range/history/widen/whole-tree logic).
# The authoritative, merge-blocking secret/PII scan is now the diff-scoped CI
# check — gitleaks-range-scan.sh over the PR's own `base..head`, required in the
# reusable workflow (estate-ci.yml routine lane + estate-gate.yml trusted lane).
#
# This hook is now a FAST LOCAL HEADS-UP ONLY. Deliberate posture inversion:
#   * it does NOT reconstruct whole-history ranges, resolve a target remote, or
#     scan whole trees — the empty-remote / all-zeros / target-remote /
#     force-push OVER-SCAN traps that false-blocked clean pushes on legit deep
#     history (incident #1) are GONE with that logic.
#   * it FAILS OPEN. Any inability to resolve a clean local range, any scanner
#     error, and even a local finding, results in the push PROCEEDING with a
#     printed notice — it never blocks. The required CI check is the gate; a
#     local hook must not be able to false-block a push, which is the exact
#     failure this demotion removes.
#
# Kept present (not deleted) so the pre-commit pre-push shim is non-empty and
# the estate-identity-guard's "a pre-push hook is installed" check still holds.
# NOTE (tracked follow-up, estate-hooks): that guard's comment still says the
# hook makes "the push was scanned" a real invariant — now it means "a
# best-effort local scan ran; the authoritative scan is the required CI check."
#
# Invocation: under pre-commit (stages: [pre-push]) PRE_COMMIT_FROM_REF/TO_REF
# are exported; as a native hook the ref protocol is on stdin. Either way, this
# hook only ever RECOMMENDS — see gitleaks-range-scan.sh for the real gate.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RANGE_SCAN="$HERE/gitleaks-range-scan.sh"
ZERO="0000000000000000000000000000000000000000"

note() { echo "gitleaks-pre-push (advisory — CI is the authoritative gate): $*" >&2; }

# Best-effort base..head. Prefer pre-commit's exported refs; else the upstream
# tracking ref; else the default-branch merge-base. Any gap => pass with a note.
head_ref=""; base=""
if [[ -n "${PRE_COMMIT_TO_REF:-}" ]]; then
    head_ref="$PRE_COMMIT_TO_REF"; base="${PRE_COMMIT_FROM_REF:-}"
    [[ "$head_ref" == "$ZERO" ]] && exit 0   # branch deletion
fi
[[ -z "$head_ref" ]] && head_ref="$(git rev-parse --verify --quiet HEAD 2>/dev/null || true)"
[[ -z "$head_ref" ]] && { note "no HEAD to scan; skipping."; exit 0; }
if [[ -z "$base" || "$base" == "$ZERO" ]]; then
    base="$(git rev-parse --verify --quiet '@{upstream}' 2>/dev/null || true)"
fi
if [[ -z "$base" ]]; then
    def="$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || true)"
    [[ -n "$def" ]] && base="$(git merge-base "$def" "$head_ref" 2>/dev/null || true)"
fi
if [[ -z "$base" ]]; then
    note "could not resolve a local base to diff against; skipping. The required CI check will scan the PR's base..head."
    exit 0
fi

# Advisory scan. A finding prints a loud heads-up; the push still proceeds
# (fail-open) — the required CI check is the gate and will block the MERGE.
if GL_RANGE_BASE="$base" GL_RANGE_HEAD="$head_ref" bash "$RANGE_SCAN" >&2; then
    exit 0
fi
note "the local best-effort scan above flagged something. This is ADVISORY — fix it"
note "before the PR to save a round-trip, but the push is not blocked here; the"
note "required CI check is authoritative. (A false local resolution? push and let CI decide.)"
exit 0
