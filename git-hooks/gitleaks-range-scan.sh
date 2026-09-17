#!/usr/bin/env bash
# gitleaks-range-scan.sh — the estate's AUTHORITATIVE diff-scoped secret/PII scan.
#
# ONE guarded `gitleaks git --log-opts=<base>..<head>` over an EXPLICIT commit
# range (a CI/PR fact — never reconstructed). This replaces the hand-rolled
# range/history/widen/whole-tree logic that used to live in
# gitleaks-pre-push.sh: the empty-remote, all-zeros, target-remote and
# force-push OVER-SCAN traps are GONE, because the authoritative scan now runs
# as a required CI check on the PR's own `base..head` (supplied by GitHub), not
# on a client trying to reconstruct what git is about to push.
#
# `--log-opts="base..head"` scans EACH commit's patch in the range, so a secret
# added in an intermediate commit and later removed is still caught — the one
# real coverage class the old differential scan had, kept.
#
# CONFIG RESOLUTION IS UNCHANGED IN CONTRACT. gl_resolve answers the SAME env
# modes the lanes already set:
#   GL_NO_OVERLAY   — base rules only (routine lane; private-repo overlay skip)
#   GL_OVERLAY_ONLY — operator overlay standalone (trusted lane's identity pass)
#   GL_CONFIG_PATH  — a pinned base-ref config (trusted lane), GL_IGNORE_PATH its
#                     pinned .gitleaksignore
# What changed is HOW it gets there: gitleaks now runs from gl_resolve's
# resolution directory, so the scan target and the ignore path are passed
# explicitly rather than inherited from cwd. See git-hooks/gitleaks-common.sh.
#
# INPUTS (explicit, never guessed): GL_RANGE_BASE, GL_RANGE_HEAD (sha or ref).
#
# RETAINED CONTROLS (finding-driven, NOT the old range machinery):
#   * identity guard — outgoing commits carry noreply author/committer only
#     (ported verbatim from the old scan_logopts; a scrubbed-email-resurfacing
#     PII control, eval-tested for the tab/space column-shift bypass).
#   * #2129 guard — a git error on gitleaks stderr => BLOCK regardless of exit 0
#     (gitleaks exits 0 on an unresolvable range and prints "no leaks found").
#   * #1729 guard — assert the scanned-commit count is sane vs `git rev-list
#     --count`: BLOCK on a silent 0-scan (range did not apply) or a silent
#     over-scan (N > expected — the range widened, would re-trip out-of-range
#     history). N < expected is LEGITIMATE (merge/empty/binary-only commits emit
#     no diff fragment and are not counted — verified against gitleaks 8.30.1
#     detect/detect.go + sources/git.go), so it is never blocked.
#
# Exit 0 = clean, 1 = a finding or a fail-closed guard tripped.
# Spec: {workspace_root}/System/Knowledge/leak-prevention-architecture.md

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/gitleaks-common.sh"

REPORT=""; ERRF=""
trap 'rm -f "$REPORT" "$ERRF" 2>/dev/null; [[ -n "${GL_SCRATCH:-}" ]] && rm -rf "$GL_SCRATCH" 2>/dev/null; true' EXIT INT TERM

ZERO="0000000000000000000000000000000000000000"
CONFIG="${GL_CONFIG_PATH:-.gitleaks.toml}"   # relative default resolved against the repo root, below
BASE="${GL_RANGE_BASE:-}"
HEAD_REF="${GL_RANGE_HEAD:-}"

if [[ -z "$BASE" || -z "$HEAD_REF" ]]; then
    gl_block "Range scan BLOCKED: base/head not supplied" \
        "GL_RANGE_BASE and GL_RANGE_HEAD are both required — an explicit range," \
        "never reconstructed. (This scan does not guess what is being pushed.)"
    exit 1
fi
[[ "$HEAD_REF" == "$ZERO" ]] && exit 0   # branch deletion — nothing to scan

repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    gl_block "Range scan BLOCKED: not inside a git work tree" \
        "Could not determine the repository root — refusing to scan."
    exit 1
}
cd "$repo_root" || {
    gl_block "Range scan BLOCKED: cannot enter the repository root" "cd '$repo_root' failed."
    exit 1
}

# Config composition. Absolutise BEFORE resolving: gitleaks runs from the
# resolution directory, not the repo, so a relative --config would break.
[[ "$CONFIG" == /* ]] || CONFIG="$repo_root/$CONFIG"
gl_resolve "$CONFIG" "$repo_root" || exit 1

# Size the range ourselves BEFORE scanning (fail-closed on an unresolvable
# range; the #1729 backstop below asserts gitleaks actually scanned it).
expected="$(git rev-list --count "$BASE..$HEAD_REF" </dev/null 2>/dev/null)" || {
    gl_block "Range scan BLOCKED: unresolvable commit range" \
        "Range: $BASE..$HEAD_REF" \
        "git rev-list could not resolve it — refusing to pass an unverifiable range."
    exit 1
}
if ! [[ "$expected" =~ ^[0-9]+$ ]]; then
    gl_block "Range scan BLOCKED: commit count unreadable" "Range: $BASE..$HEAD_REF"
    exit 1
fi
# A legitimately empty range (head == base, nothing new) is clean, not a failure.
[[ "$expected" -eq 0 ]] && exit 0

blocked=0

# --- Identity guard (ported from gitleaks-pre-push.sh scan_logopts) ----------
# Public commits carry noreply identity only. gitleaks never sees author/
# committer metadata, so a stale pre-rewrite clone can resurrect scrubbed emails
# through an otherwise-clean scan. Substring test (the estate identity is a
# users.noreply address; the squash committer is noreply@github.com — the threat
# is accidental leakage, not evasion). Tab-delimited: git accepts a SPACE inside
# an env-supplied email, which under space-splitting shifts columns and lets a
# bad committer email inherit a noreply substring; emails cannot contain tabs.
# Fail-closed: a non-empty range whose identities cannot be read is a BLOCK.
idlog=""
if ! idlog="$(git log --format='%H%x09%ae%x09%ce' "$BASE..$HEAD_REF" </dev/null 2>/dev/null)" \
        || [[ -z "$idlog" ]]; then
    gl_block "Range scan BLOCKED: cannot read commit identities" \
        "Range: $BASE..$HEAD_REF — refusing to pass commits whose author/committer" \
        "emails cannot be verified. (Fail-closed.)"
    blocked=1
else
    while IFS=$'\t' read -r sha ae ce; do
        [[ -z "$sha" ]] && continue
        for f in "author:$ae" "committer:$ce"; do
            [[ "${f#*:}" == *noreply* ]] && continue
            gl_block "Range scan BLOCKED: non-noreply ${f%%:*} email in outgoing commits" \
                "Commit: $sha (${f%%:*} email; value withheld)" \
                "Estate policy: public commits carry noreply identity only." \
                "A non-noreply email usually means a stale pre-rewrite clone — re-point" \
                "the checkout before pushing/opening the PR."
            blocked=1
        done
    done <<< "$idlog"
fi

# --- The one range scan ------------------------------------------------------
REPORT="$(mktemp)"; ERRF="$(mktemp)"
# Run from the resolution directory so the config's relative [extend] token
# resolves (see gitleaks-common.sh). The repo is therefore the explicit scan
# target, and the ignore path explicit too — gitleaks' own default for
# --gitleaks-ignore-path is ".", which from here is the resolution directory.
( cd "$GL_CWD" && gitleaks git "$repo_root" \
    --log-opts="$BASE..$HEAD_REF" \
    --config="$GL_CONFIG" \
    --no-banner --redact=100 --ignore-gitleaks-allow \
    --gitleaks-ignore-path "${GL_IGNORE_PATH:-$repo_root}" \
    --report-format json --report-path "$REPORT" \
    </dev/null >/dev/null 2>"$ERRF" )
rc=$?

if grep -qE 'fatal:|stderr is not empty' "$ERRF"; then
    # #2129: gitleaks hit a git range error and would otherwise exit 0.
    gl_block "Range scan BLOCKED: scanner could not resolve the range" \
        "Range: $BASE..$HEAD_REF" \
        "gitleaks reported a git error; its exit code is untrustworthy here." \
        "(Fail-closed backstop against the known log-opts fail-open, gitleaks #2129.)"
    blocked=1
elif grep -qE 'FTL|Failed to load config' "$ERRF"; then
    gl_block "Range scan BLOCKED: gitleaks config failed to load" \
        "Config: $CONFIG (operator rules: $GL_RULES_SOURCE)" \
        "Install the operator ruleset via the blueprint (gitleaks-rules apply)."
    blocked=1
else
    # #1729 over-scan backstop: gitleaks 8.30.1 logs "<N> commits scanned." on
    # stderr. The dangerous #1729 shape this catches is a SILENT WIDEN — gitleaks
    # ignoring --log-opts and scanning MORE than the range (which would re-trip on
    # out-of-range history, i.e. incident #1 returning). `N > expected` is never
    # legitimate for a real `base..head` (gitleaks walks the same DAG as
    # `git rev-list --count`), so this has no false-positive.
    #
    # We deliberately do NOT block on `N == 0` / `N < expected`: a range whose
    # commits are all merge/empty/binary-only legitimately produces N < expected
    # (those commits emit no diff fragment — verified vs 8.30.1 detect/detect.go
    # + sources/git.go), and a range of ONLY such commits legitimately yields
    # N == 0. The OTHER #1729/#2129 fail-open shape — an INVALID range that
    # gitleaks accepts and scans nothing — is already caught above by the
    # `fatal:` / `stderr is not empty` check (the same structural defense the
    # current pre-push hook relies on), plus the pre-scan `git rev-list --count`
    # validation that an unresolvable range never reaches gitleaks at all. An
    # unparseable count is treated as non-blocking rather than a brittle
    # log-format false-block; the stderr-fatal check remains the primary guard.
    scanned="$(grep -oE '[0-9]+ commits scanned' "$ERRF" | grep -oE '^[0-9]+' | tail -1)"
    if [[ -n "$scanned" && "$scanned" -gt "$expected" ]]; then
        gl_block "Range scan BLOCKED: gitleaks scanned $scanned commits, > the $expected in range" \
            "Range: $BASE..$HEAD_REF — the range silently widened (would re-trip on" \
            "out-of-range history). (Fail-closed backstop against gitleaks #1729.)"
        blocked=1
    fi

    if [[ "$rc" -ne 0 ]]; then
        gl_block "Range scan BLOCKED: sensitive content in outgoing commits" \
            "Range: $BASE..$HEAD_REF" \
            "Findings (rule / commit / file:line — matched values withheld):"
        gl_summarize_report "$REPORT" >&2
        {
            echo "  Remediation:"
            echo "    * Rewrite the offending commit(s): git rebase -i / git commit --amend"
            echo "    * If already in history, purge it: git filter-repo"
            echo "    * The value must be gone from EVERY commit in the range, not just HEAD."
            echo ""
        } >&2
        blocked=1
    fi
fi

[[ "$blocked" -ne 0 ]] && exit 1
exit 0
