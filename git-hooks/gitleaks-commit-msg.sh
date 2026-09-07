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
# Note: gitleaks resolves a config's RELATIVE `[extend] path` against the
# PROCESS cwd, so this hook cd's to the repo root and passes gl_preflight's
# effective config (see gitleaks-common.sh). The message file is resolved to
# an absolute path first, so the cd doesn't break a relative $1.
#
# GL_TEXT_FILE: a named-env-var alternative source, for CI callers
# that reuse this same scan (a single arbitrary text file — a commit message
# in the PR range, a branch name, a PR title, a PR body) outside the
# pre-commit framework, which has no hook argument for those surfaces.
# Positional $1 (pre-commit's own commit-msg stage contract) is UNCHANGED and
# still takes priority when both would resolve — this hook's local behavior
# is identical whether or not GL_TEXT_FILE happens to be set in the caller's
# environment.
#
# Spec: {workspace_root}/System/Knowledge/leak-prevention-architecture.md

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/gitleaks-common.sh"
# The effective config may be a temp file (see gl_preflight); always remove it.
trap 'rm -f "$GL_TMP_CONFIG" 2>/dev/null || true' EXIT INT TERM

# GL_CONFIG_PATH: the trusted lane's override (see gitleaks-pre-push.sh for
# the full rationale — never write a base-ref-pinned config into the PR
# checkout; this script must honor the same override or the pin is a no-op
# for every text surface it scans). A pressure-test finding: this hardcode
# survived the critical fix that introduced GL_CONFIG_PATH because only
# gitleaks-pre-push.sh consumed it — a PR could widen its OWN .gitleaks.toml
# and this script would load it unpinned, silently un-pinning the base-rules
# pass over commit messages, branch name, PR title, and PR body in the
# trusted lane (live-verified: identical canary, clean vs PR-widened
# allowlist -- clean blocked, widened passed green). Unset (every
# local/native use), this resolves exactly as before.
CONFIG="${GL_CONFIG_PATH:-.gitleaks.toml}"   # relative default — resolved from cwd (= repo root, see below)
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
    --config="$GL_EFFECTIVE_CONFIG" \
    --no-banner --redact=100 --ignore-gitleaks-allow \
    --report-format json --report-path "$report" \
    </dev/null >/dev/null 2>"$errf"
gl_exit=$?

if grep -qE 'FTL|Failed to load config' "$errf"; then
    gl_block "Commit-msg BLOCKED: gitleaks config failed to load" \
        "Config: $repo_root/$CONFIG (operator rules: $GL_RULES_SOURCE)" \
        "Install the operator ruleset via the blueprint (gitleaks-rules apply)."
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
