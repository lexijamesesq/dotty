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
#
# Network discipline: each gh call has a short timeout so a slow or
# unreachable GitHub never blocks session startup. One retry on
# transient failure; stale cache is better than no session.

set -uo pipefail

GH_TIMEOUT=5    # seconds per gh call
GH_RETRIES=1    # retry once on failure

INPUT=$(cat 2>/dev/null || true)

# Self-scope. As a PostToolUse hook this fires for far more than `gh pr
# create`/`merge`: the settings `if:` field is a pre-filter that FAILS OPEN into
# running the hook whenever the pattern names more than the bare command and the
# command contains $(...), backticks, or $VAR — which is most non-trivial shell.
# Below, each declared deliverable repo costs a `gh pr list` network round-trip,
# so an unscoped refresh charges several network calls to an unrelated command.
# SessionStart payloads carry no tool_name and always refresh.
TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)
if [[ "$TOOL_NAME" == "Bash" ]]; then
    CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
    CMD=$(printf '%s' "$CMD" | tr -s '[:space:]' ' ')
    RE_GHPR='(^|[;&|(`])[[:space:]]*gh[[:space:]]+pr[[:space:]]+(create|merge)'
    [[ "$CMD" =~ $RE_GHPR ]] || exit 0
fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(printf '%s' "$INPUT" | jq -r '.workspace.project_dir // .cwd // empty' 2>/dev/null)}"
[[ -z "$PROJECT_DIR" ]] && exit 0

CLAUDE_MD="${PROJECT_DIR}/CLAUDE.md"
[[ -f "$CLAUDE_MD" ]] || exit 0

CACHE_DIR="${TMPDIR:-/tmp}/claude-statusline-pr"
mkdir -p "$CACHE_DIR" 2>/dev/null || exit 0

command -v gh >/dev/null 2>&1 || exit 0

parse_repos() {
    command -v yq >/dev/null 2>&1 || return
    awk '/^---[[:space:]]*$/{c++; next} c==1' "$CLAUDE_MD" | yq -r '.build_home[]' - 2>/dev/null
}

gh_with_retry() {
    local attempt=0 prs=""
    while [[ $attempt -le $GH_RETRIES ]]; do
        prs=$(cd "$1" && timeout "${GH_TIMEOUT}" gh pr list --state open --json number,headRefName 2>/dev/null) && break
        attempt=$((attempt + 1))
        [[ $attempt -le $GH_RETRIES ]] && sleep 1
    done
    printf '%s' "${prs:-[]}"
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

    prs=$(gh_with_retry "$canonical")
    printf '%s' "$prs" > "$cache_file"
done < <(parse_repos)

exit 0
