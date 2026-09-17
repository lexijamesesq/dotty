#!/usr/bin/env bash
# gitleaks-staged.sh — FAIL-CLOSED scan of the STAGED diff before a commit is
# created (the pre-commit stage). A thin wrapper around `gitleaks git --staged`
# so the operator ruleset is composed by gl_resolve like every other hook's
# (see gitleaks-common.sh). Why a wrapper and not a bare gitleaks entry: the
# repo config's `[extend]` token only resolves from the resolution directory
# gl_resolve builds, so a bare entry would FTL on it.
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

errf=""
trap 'rm -f "$errf" 2>/dev/null; [[ -n "${GL_SCRATCH:-}" ]] && rm -rf "$GL_SCRATCH" 2>/dev/null; true' EXIT INT TERM

repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    gl_block "Staged scan BLOCKED: not inside a git work tree" \
        "Could not determine the repository root — refusing to commit unscanned."
    exit 1
}

# GL_CONFIG_PATH: no consumer needs this locally (this hook never runs in the
# trusted lane), but gitleaks-range-scan.sh and gitleaks-commit-msg.sh both
# honor it — kept consistent here rather than leaving a third, differently-
# behaved copy of the same CONFIG line in the tree. Absolutised BEFORE the scan,
# because gitleaks runs from gl_resolve's resolution directory, not the repo.
CONFIG="${GL_CONFIG_PATH:-$repo_root/.gitleaks.toml}"
[[ "$CONFIG" == /* ]] || CONFIG="$repo_root/$CONFIG"

gl_resolve "$CONFIG" "$repo_root" || exit 1

errf="$(mktemp)"
( cd "$GL_CWD" && gitleaks git --staged "$repo_root" \
    --config="$GL_CONFIG" \
    --gitleaks-ignore-path "${GL_IGNORE_PATH:-$repo_root}" \
    --verbose --redact=100 --ignore-gitleaks-allow \
    </dev/null 2>"$errf" )
rc=$?

if grep -qE 'FTL|Failed to load config' "$errf"; then
    cat "$errf" >&2
    gl_block "Staged scan BLOCKED: gitleaks config failed to load" \
        "Config: $CONFIG (operator rules: $GL_RULES_SOURCE)" \
        "Install the operator ruleset via the blueprint (gitleaks-rules apply)."
    exit 1
fi

# Replay gitleaks' log (findings under --verbose are redacted) for pre-commit.
cat "$errf" >&2
exit "$rc"
