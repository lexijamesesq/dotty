#!/usr/bin/env bash
# gitleaks-staged.sh — FAIL-CLOSED scan of the STAGED diff before a commit is
# created (the pre-commit stage). A thin wrapper around `gitleaks git --staged`
# so the operator ruleset is resolved by gl_preflight like every other hook's
# (see gitleaks-common.sh). Why a wrapper and not a bare gitleaks entry: a
# checkout with no operator-rules symlink could push (pre-push resolves the
# installed ruleset) but never commit — the staged scan FTL'd on the relative
# extend.
#
# Output: gitleaks' own --verbose finding log (already --redact'ed) is replayed
# to stderr so pre-commit shows it on failure. Exit code is gitleaks' own
# (1 = findings), except that a config-load failure is named as such and blocks.
#
# Spec: {workspace_root}/System/Knowledge/leak-prevention-architecture.md

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/gitleaks-common.sh"

CONFIG=".gitleaks.toml"   # relative — resolved from cwd (= repo root, see below)

repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    gl_block "Staged scan BLOCKED: not inside a git work tree" \
        "Could not determine the repository root — refusing to commit unscanned."
    exit 1
}
cd "$repo_root" || {
    gl_block "Staged scan BLOCKED: cannot enter the repository root" \
        "cd '$repo_root' failed — refusing to commit unscanned."
    exit 1
}

errf=""
trap 'rm -f "$errf" "$GL_TMP_CONFIG" 2>/dev/null || true' EXIT INT TERM

gl_preflight "$CONFIG" || exit 1

errf="$(mktemp)"
gitleaks git --staged . \
    --config="$GL_EFFECTIVE_CONFIG" \
    --verbose --redact --ignore-gitleaks-allow \
    </dev/null 2>"$errf"
rc=$?

if grep -qE 'FTL|Failed to load config' "$errf"; then
    cat "$errf" >&2
    gl_block "Staged scan BLOCKED: gitleaks config failed to load" \
        "Config: $repo_root/$CONFIG (operator rules: $GL_RULES_SOURCE)" \
        "Install the operator ruleset via the blueprint (gitleaks-rules apply)," \
        "or provision the checkout symlink via: setup-claude-profiles.sh"
    exit 1
fi

# Replay gitleaks' log (findings under --verbose are redacted) for pre-commit.
cat "$errf" >&2
exit "$rc"
