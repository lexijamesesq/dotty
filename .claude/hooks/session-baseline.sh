#!/usr/bin/env bash
# session-baseline.sh
#
# SessionStart hook: snapshots the starting state of each declared
# deliverable repo so the statusline can later distinguish "state THIS
# session changed" from "state already here at session start."
#
# Writes per-repo baseline to:
#   $TMPDIR/claude-session-state/<session-id>/baseline.json
#
# Schema:
#   {
#     "/abs/path/to/repo": {
#       "branch":     "<current branch or empty for detached>",
#       "uncommitted": <int>,
#       "unpushed":    <int>,
#       "open_prs":    [<int>, ...]
#     },
#     ...
#   }
#
# Statusline uses (current != baseline) on any field as the "this session
# engaged with this repo" signal. File counts always display regardless
# of engagement; branch + PR labels are gated on engagement so they
# reflect THIS session's context, not state inherited from another.
#
# Triggers on `startup` only — `resume` keeps the original baseline so
# multi-day resumed work doesn't get its baseline overwritten.
#
# Tolerant: stderr-warn on failure, exit 0.

set -uo pipefail

INPUT=$(cat 2>/dev/null || true)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(printf '%s' "$INPUT" | jq -r '.workspace.project_dir // .cwd // empty' 2>/dev/null)}"

if [[ -z "$SESSION_ID" || -z "$PROJECT_DIR" ]]; then
    exit 0
fi

CLAUDE_MD="${PROJECT_DIR}/CLAUDE.md"
[[ -f "$CLAUDE_MD" ]] || exit 0

STATE_DIR="${TMPDIR:-/tmp}/claude-session-state/${SESSION_ID}"
BASELINE="${STATE_DIR}/baseline.json"

# If baseline already exists (resume after restart), keep it
[[ -f "$BASELINE" ]] && exit 0

mkdir -p "$STATE_DIR" 2>/dev/null || exit 0

# Parse ## Deliverable Repos — paths only (strip (flags) and # comments)
parse_repos() {
    awk '
        /^## Deliverable Repos[[:space:]]*$/ { in_s=1; next }
        /^## / { in_s=0 }
        in_s && /^-[[:space:]]/ {
            line = $0
            sub(/^-[[:space:]]+/, "", line)
            sub(/[[:space:]]+\([^)]*\)[[:space:]]*/, " ", line)
            sub(/[[:space:]]+#.*$/, "", line)
            sub(/[[:space:]]+$/, "", line)
            if (length(line) > 0) print line
        }
    ' "$CLAUDE_MD"
}

ENTRIES=()
while IFS= read -r raw_path; do
    [[ -z "$raw_path" ]] && continue
    repo="${raw_path/#\~/$HOME}"
    canonical=$(cd "$repo" 2>/dev/null && pwd) || continue
    git -C "$canonical" rev-parse --git-dir >/dev/null 2>&1 || continue

    branch=$(git -C "$canonical" branch --show-current 2>/dev/null)
    uncommitted=$(git -C "$canonical" status --porcelain 2>/dev/null | wc -l | tr -d ' ')

    unpushed=0
    if git -C "$canonical" rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1; then
        unpushed=$(git -C "$canonical" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)
    elif git -C "$canonical" rev-parse origin/HEAD >/dev/null 2>&1; then
        unpushed=$(git -C "$canonical" rev-list --count 'origin/HEAD..HEAD' 2>/dev/null || echo 0)
    fi

    # Open PRs in this repo (numbers only, sorted)
    prs_json="[]"
    if command -v gh >/dev/null 2>&1; then
        prs=$(cd "$canonical" && gh pr list --state open --json number --jq '[.[].number] | sort' 2>/dev/null)
        [[ -n "$prs" ]] && prs_json="$prs"
    fi

    entry=$(jq -nc \
        --arg branch "$branch" \
        --argjson uncommitted "$uncommitted" \
        --argjson unpushed "$unpushed" \
        --argjson prs "$prs_json" \
        '{branch: $branch, uncommitted: $uncommitted, unpushed: $unpushed, open_prs: $prs}')

    # Escape canonical for JSON key
    key_json=$(jq -nc --arg k "$canonical" '$k')
    ENTRIES+=("${key_json}:${entry}")
done < <(parse_repos)

if [[ ${#ENTRIES[@]} -gt 0 ]]; then
    printf '{%s}\n' "$(IFS=,; echo "${ENTRIES[*]}")" > "$BASELINE"
else
    printf '{}\n' > "$BASELINE"
fi

exit 0
