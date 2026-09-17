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
# The message file is resolved to an absolute path first, because gitleaks runs
# from gl_resolve's resolution directory (see gitleaks-common.sh), not the repo.
#
# GL_TEXT_FILE: a named-env-var alternative source, for CI callers that reuse
# this same scan (a single arbitrary text file — a commit message in the PR
# range, a branch name, a PR title, a PR body) outside the pre-commit
# framework, which has no hook argument for those surfaces. Positional $1
# (pre-commit's own commit-msg stage contract) is UNCHANGED and still takes
# priority when both would resolve.
#
# Spec: {workspace_root}/System/Knowledge/leak-prevention-architecture.md

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/gitleaks-common.sh"

report=""; errf=""
trap 'rm -f "$report" "$errf" 2>/dev/null; [[ -n "${GL_SCRATCH:-}" ]] && rm -rf "$GL_SCRATCH" 2>/dev/null; true' EXIT INT TERM

msg_file="${1:-${GL_TEXT_FILE:-}}"

# Fail-closed: without a readable message file we cannot scan it.
if [[ -z "$msg_file" || ! -f "$msg_file" ]]; then
    gl_block "Commit-msg BLOCKED: message file not provided" \
        "Expected the commit message file path as the first argument," \
        "or GL_TEXT_FILE in the environment (CI callers)." \
        "This hook must run in pre-commit's commit-msg stage, or be invoked" \
        "directly with GL_TEXT_FILE set." \
        "(Fail-closed: no message file means no scan means no pass.)"
    exit 1
fi
msg_abs="$(cd "$(dirname "$msg_file")" && pwd)/$(basename "$msg_file")"

repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    gl_block "Commit-msg BLOCKED: not inside a git work tree" \
        "Could not determine the repository root."
    exit 1
}

# GL_CONFIG_PATH: the trusted lane's base-ref pin. A PR could otherwise widen
# its OWN .gitleaks.toml and this script would load it unpinned, silently
# un-pinning the base-rules pass over commit messages, branch name, PR title
# and PR body (live-verified: identical canary, clean blocked, PR-widened
# allowlist passed green). Unset — every local/native use — this resolves to
# the repo's own config exactly as before.
CONFIG="${GL_CONFIG_PATH:-$repo_root/.gitleaks.toml}"
[[ "$CONFIG" == /* ]] || CONFIG="$repo_root/$CONFIG"

gl_resolve "$CONFIG" "$repo_root" || exit 1

report="$(mktemp)"
errf="$(mktemp)"
( cd "$GL_CWD" && gitleaks dir "$msg_abs" \
    --config="$GL_CONFIG" \
    --gitleaks-ignore-path "${GL_IGNORE_PATH:-$repo_root}" \
    --no-banner --redact=100 --ignore-gitleaks-allow \
    --report-format json --report-path "$report" \
    </dev/null >/dev/null 2>"$errf" )
gl_exit=$?

if grep -qE 'FTL|Failed to load config' "$errf"; then
    gl_block "Commit-msg BLOCKED: gitleaks config failed to load" \
        "Config: $CONFIG (operator rules: $GL_RULES_SOURCE)" \
        "Install the operator ruleset via the blueprint (gitleaks-rules apply)."
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
    exit 1
fi

exit 0
