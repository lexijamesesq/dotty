#!/usr/bin/env bash
# pr-cache.sh
#
# Queries GitHub for open PRs in each declared deliverable repo and
# writes results to a cache file the statusline reads.
#
# Called by: SessionStart (capture initial state),
#           PostToolUse after gh pr create/merge (refresh).
#
# Cache: $TMPDIR/claude-statusline-pr/<repo-hash>.json
#        Array of {number, headRefName} objects.

set -uo pipefail

INPUT=$(cat 2>/dev/null || true)
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(printf '%s' "$INPUT" | jq -r '.workspace.project_dir // .cwd // empty' 2>/dev/null)}"
[[ -z "$PROJECT_DIR" ]] && exit 0

CLAUDE_MD="${PROJECT_DIR}/CLAUDE.md"
[[ -f "$CLAUDE_MD" ]] || exit 0

CACHE_DIR="${TMPDIR:-/tmp}/claude-statusline-pr"
mkdir -p "$CACHE_DIR" 2>/dev/null || exit 0

command -v gh >/dev/null 2>&1 || exit 0

parse_repos() {
    awk '
        /^## Deliverable Repos[[:space:]]*$/ { flag=1; next }
        /^## / { flag=0 }
        flag && /^-[[:space:]]/ {
            sub(/^-[[:space:]]+/, "")
            sub(/[[:space:]]+\([^)]*\)[[:space:]]*/, " ")
            sub(/[[:space:]]+#.*$/, "")
            sub(/[[:space:]]+$/, "")
            if (length($0) > 0) print
        }
    ' "$CLAUDE_MD"
}

while IFS= read -r raw_path; do
    [[ -z "$raw_path" ]] && continue
    if [[ "$(printf '%s' "$raw_path" | tr '[:upper:]' '[:lower:]')" == "none" ]]; then
        continue
    fi
    repo="${raw_path/#\~/$HOME}"
    canonical=$(cd "$repo" 2>/dev/null && pwd) || continue
    git -C "$canonical" rev-parse --git-dir >/dev/null 2>&1 || continue

    cache_key=$(printf '%s' "$canonical" | shasum | cut -d' ' -f1)
    cache_file="${CACHE_DIR}/${cache_key}.json"

    prs=$(cd "$canonical" && gh pr list --state open --json number,headRefName 2>/dev/null)
    if [[ -n "$prs" ]]; then
        printf '%s' "$prs" > "$cache_file"
    else
        printf '[]' > "$cache_file"
    fi
done < <(parse_repos)

exit 0
