#!/usr/bin/env bash
# gitleaks-commit-msg.sh — FAIL-CLOSED scan of the commit MESSAGE text.
#
# Why a dedicated hook: gitleaks NEVER scans commit-message text in any git
# mode (`git`, `git --staged`) — it only scans diffs/blobs. A secret pasted
# into a commit message would therefore sail past both the staged scan and the
# pre-push range scan. `gitleaks dir <path>` scans a plain filesystem path
# (verified: it scans a single file, including one located under .git/), which
# is the right mechanism here — pre-commit's commit-msg stage passes the commit
# message file path as $1.
#
# Note: gitleaks resolves a config's `[extend] path` relative to the PROCESS
# cwd, so this hook cd's to the repo root and uses a relative --config. The
# message file is resolved to an absolute path first, so the cd doesn't break
# a relative $1.
#
# Spec: {workspace_root}/System/Knowledge/leak-prevention-architecture.md

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/gitleaks-common.sh"

CONFIG=".gitleaks.toml"   # relative — resolved from cwd (= repo root, see below)
msg_file="${1:-}"

# Fail-closed: without a readable message file we cannot scan it.
if [[ -z "$msg_file" || ! -f "$msg_file" ]]; then
    gl_block "Commit-msg BLOCKED: message file not provided" \
        "Expected the commit message file path as the first argument." \
        "This hook must run in pre-commit's commit-msg stage." \
        "(Fail-closed: no message file means no scan means no pass.)"
    exit 1
fi
# Resolve to absolute BEFORE the cd below, so a relative $1 still points home.
msg_abs="$(cd "$(dirname "$msg_file")" && pwd)/$(basename "$msg_file")"

repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    gl_block "Commit-msg BLOCKED: not inside a git work tree" \
        "Could not determine the repository root."
    exit 1
}
cd "$repo_root" || {
    gl_block "Commit-msg BLOCKED: cannot enter the repository root" \
        "cd '$repo_root' failed."
    exit 1
}

gl_preflight "$CONFIG" || exit 1

report="$(mktemp)"
errf="$(mktemp)"
gitleaks dir "$msg_abs" \
    --config="$CONFIG" \
    --no-banner --redact --ignore-gitleaks-allow \
    --report-format json --report-path "$report" \
    </dev/null >/dev/null 2>"$errf"
gl_exit=$?

if grep -qE 'FTL|Failed to load config' "$errf"; then
    gl_block "Commit-msg BLOCKED: gitleaks config failed to load" \
        "Config: $repo_root/$CONFIG" \
        "Provision the operator ruleset symlink via: setup-claude-profiles.sh"
    rm -f "$report" "$errf"
    exit 1
fi

if [[ "$gl_exit" -ne 0 ]]; then
    gl_block "Commit-msg BLOCKED: sensitive content in the commit message" \
        "Findings (rule / file:line — matched values withheld):"
    gl_summarize_report "$report" >&2
    {
        echo "  Remediation: remove the flagged content from the commit message,"
        echo "  then re-commit. (Secrets belong in neither code nor message text.)"
        echo ""
    } >&2
    rm -f "$report" "$errf"
    exit 1
fi

rm -f "$report" "$errf"
exit 0
