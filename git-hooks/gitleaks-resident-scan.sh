#!/usr/bin/env bash
# gitleaks-resident-scan.sh — the estate's SCHEDULED default-branch resident
# secret/PII backstop (the whole-tree coverage a diff-scoped PR gate cannot give).
#
# WHY THIS EXISTS. The authoritative merge gate is now diff-scoped
# (gitleaks-range-scan.sh over base..head). Diff-scoping structurally cannot
# catch: (a) content resident in the tree from before range-scanning existed,
# and (b) already-merged content that a NEWLY-ADDED operator pattern would now
# flag — no diff ever re-touches it. This backstop is the relocation of the old
# per-push whole-tree scan OFF the push path onto a schedule, so it keeps that
# resident coverage WITHOUT the per-push re-report that was incident #2's noise
# and WITHOUT any range/history logic (it scans one tree-ish: HEAD).
#
# PROFILE (reuses gate-resolve-profile.sh — the trusted lane's own mechanism):
#   verified-private (GATE_SKIP_OVERLAY=1) -> GL_NO_OVERLAY=1, BASE RULES ONLY.
#     The operator overlay (identity/roster rules) is never loaded, so a repo
#     that LEGITIMATELY holds the operator patterns (dotty-private's
#     gitleaks-registry) is never re-flagged — the false-positive half of
#     incident #2, closed by the same posture the estate already ships for the
#     PR trusted lane. Base rules still catch a resident CREDENTIAL.
#   public/other -> base + operator overlay: catches resident operator-PII that
#     does NOT belong on a public repo (the backstop's real purpose).
#
# OUTPUT. On findings, a MACHINE-PARSEABLE, de-duped list to stdout — one
# `<rule-id>\t<file>:<line>` per finding, matched VALUES WITHHELD (redacted by
# gl_scan_tree_at) — shaped so the caller can drop it verbatim into an operator
# issue body that a human, OR later an autonomous fixer, can act on directly.
#
# Exit 0 = clean, 1 = findings (list on stdout), 2 = scan error (fail-closed).
#
# Inputs: GATE_SKIP_OVERLAY (0|1, from gate-resolve-profile.sh; default 0).
#         GL_RESIDENT_REPO (default: the git toplevel of cwd).
# Spec: {workspace_root}/System/Knowledge/leak-prevention-architecture.md
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/gitleaks-common.sh"

repo="${GL_RESIDENT_REPO:-$(git rev-parse --show-toplevel 2>/dev/null)}" || {
    echo "resident scan: not inside a git work tree (fail-closed)" >&2; exit 2; }
cd "$repo" || { echo "resident scan: cannot enter $repo (fail-closed)" >&2; exit 2; }

# Profile toggle: verified-private -> base-only (no overlay -> no registry
# re-flag). Public/other -> base+overlay (default gl_mandatory_preflight).
if [[ "${GATE_SKIP_OVERLAY:-0}" == "1" ]]; then
    export GL_NO_OVERLAY=1
fi

# The single shared whole-tree scan (gl_scan_tree_at) requires GL_MANDATORY_CONFIG
# from gl_mandatory_preflight — the exact sequence gate-mechanical.sh uses.
gl_mandatory_preflight || { echo "resident scan: overlay/config unavailable (fail-closed)" >&2; exit 2; }

report="$(mktemp)"; rc=0
gl_scan_tree_at "$repo" "$report" HEAD || rc=$?
rm -f "${GL_MANDATORY_TMP:-}" 2>/dev/null || true

if [[ "$rc" -eq 2 ]]; then
    echo "resident scan: gitleaks scanner error (fail-closed)" >&2
    rm -f "$report"; exit 2
fi
if [[ "$rc" -eq 1 ]]; then
    # Machine-parseable, de-duped: "<rule-id>\t<repo-relative-file>:<line>".
    # Values withheld (the report is already --redact=100). gl_scan_tree_at
    # materializes each blob at "<scratch>/<40-hex-blob-sha>/<repo-relative-path>",
    # so the report's File carries that scratch prefix; strip everything up to
    # and including the blob-sha segment to recover the repo-relative path the
    # operator (or a later autonomous fixer) actually needs. jq when present; a
    # safe rule-id-only fallback otherwise (never prints a matched literal).
    if command -v jq >/dev/null 2>&1; then
        jq -r '.[] | .RuleID + "\t" + .File + ":" + (.StartLine|tostring)' "$report" 2>/dev/null \
            | sed -E 's#\t.*/[0-9a-f]{40}/#\t#' \
            | sort -u
    else
        echo "(jq not installed — rule ids only; file:line and values withheld)"
        grep -oE '"RuleID":[[:space:]]*"[^"]*"' "$report" 2>/dev/null \
            | sed -E 's/.*"([^"]*)"$/\1/' | sort -u
    fi
    rm -f "$report"; exit 1
fi
rm -f "$report"; exit 0
