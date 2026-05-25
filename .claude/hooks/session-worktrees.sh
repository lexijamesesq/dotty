#!/usr/bin/env bash
# session-worktrees.sh
#
# SessionStart hook: creates per-session git worktrees for any deliverable
# repo flagged `(worktree)` in the project's CLAUDE.md ## Deliverable Repos
# section. The worktree gets its own branch, so two concurrent sessions
# rooted in the same project can each have their own branch state of the
# same deliverable repo without colliding.
#
# Triggers on both `startup` and `resume`:
#   - startup: creates worktrees if missing, generates a manifest.
#   - resume:  verifies worktrees still exist; if a worktree was removed
#              externally, drops it from the manifest. Does NOT recreate
#              (the operator likely removed it intentionally).
#
# Manifest path: $TMPDIR/claude-session-state/<session-id>/worktrees.json
# Worktree path: <repo>/.worktrees/session-<short-id>/
# Branch name:   claude-session/<short-id>
#
# Tolerant: stderr-warn on failure, exit 0 (don't block the session).
#
# CONTRACT: the worktree is useful only if you actually work in it.
# Edits to the canonical repo path bypass it. See the statusline for
# truth — when a worktree exists, the github segment reads from it.

set -uo pipefail

INPUT=$(cat 2>/dev/null || true)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(printf '%s' "$INPUT" | jq -r '.workspace.project_dir // .cwd // empty' 2>/dev/null)}"

if [[ -z "$SESSION_ID" || -z "$PROJECT_DIR" ]]; then
    echo "session-worktrees: missing session_id or project_dir; nothing to do" >&2
    exit 0
fi

CLAUDE_MD="${PROJECT_DIR}/CLAUDE.md"
[[ -f "$CLAUDE_MD" ]] || exit 0

STATE_DIR="${TMPDIR:-/tmp}/claude-session-state/${SESSION_ID}"
MANIFEST="${STATE_DIR}/worktrees.json"
SHORT_ID="${SESSION_ID:0:8}"
BRANCH_NAME="claude-session/${SHORT_ID}"

mkdir -p "$STATE_DIR" 2>/dev/null || {
    echo "session-worktrees: failed to mkdir $STATE_DIR" >&2
    exit 0
}

# Parse ## Deliverable Repos. Emits one line per repo:
#   <expanded-path>\t<flag-or-empty>
parse_repos() {
    awk '
        /^## Deliverable Repos[[:space:]]*$/ { in_section=1; next }
        /^## / { in_section=0 }
        in_section && /^-[[:space:]]/ {
            line = $0
            sub(/^-[[:space:]]+/, "", line)
            sub(/[[:space:]]+#.*$/, "", line)

            flag = ""
            if (match(line, /\([^)]+\)/)) {
                flag = substr(line, RSTART+1, RLENGTH-2)
                line = substr(line, 1, RSTART-1) substr(line, RSTART+RLENGTH)
            }
            sub(/[[:space:]]+$/, "", line)
            gsub(/[[:space:]]+/, " ", line)
            if (length(line) > 0) print line "\t" flag
        }
    ' "$CLAUDE_MD"
}

# Build manifest entries: for each (worktree)-flagged repo, ensure worktree
# exists, then emit a JSON map entry.
ENTRIES=()
SUMMARY=()
while IFS=$'\t' read -r raw_path flag; do
    [[ -z "$raw_path" ]] && continue
    [[ "$flag" != "worktree" ]] && continue

    # Expand ~
    repo="${raw_path/#\~/$HOME}"

    if [[ ! -d "$repo/.git" ]] && ! git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
        echo "session-worktrees: skipping $repo — not a git repo" >&2
        continue
    fi

    canonical=$(cd "$repo" 2>/dev/null && pwd)
    [[ -z "$canonical" ]] && continue

    worktree_path="${canonical}/.worktrees/session-${SHORT_ID}"

    if [[ -d "$worktree_path" ]]; then
        # Already exists — verify git agrees
        if git -C "$worktree_path" rev-parse --git-dir >/dev/null 2>&1; then
            SUMMARY+=("$(basename "$canonical") (existing): $worktree_path")
        else
            echo "session-worktrees: $worktree_path exists but is not a worktree; skipping" >&2
            continue
        fi
    else
        # Determine base ref: prefer origin/HEAD, fall back to current HEAD
        base_ref=""
        if git -C "$canonical" rev-parse origin/HEAD >/dev/null 2>&1; then
            base_ref=$(git -C "$canonical" rev-parse --abbrev-ref origin/HEAD)
        else
            base_ref=$(git -C "$canonical" rev-parse --abbrev-ref HEAD)
        fi

        if git -C "$canonical" worktree add -b "$BRANCH_NAME" "$worktree_path" "$base_ref" 2>/dev/null; then
            SUMMARY+=("$(basename "$canonical") (created): $worktree_path on $BRANCH_NAME from $base_ref")
        else
            echo "session-worktrees: failed to create worktree for $canonical" >&2
            continue
        fi
    fi

    ENTRIES+=("\"$canonical\":\"$worktree_path\"")
done < <(parse_repos)

# Write manifest (empty object if no worktree-flagged repos)
if [[ ${#ENTRIES[@]} -gt 0 ]]; then
    printf '{%s}\n' "$(IFS=,; echo "${ENTRIES[*]}")" > "$MANIFEST"
else
    printf '{}\n' > "$MANIFEST"
fi

# Operator summary on stderr (Claude Code surfaces hook stderr to the session)
if [[ ${#SUMMARY[@]} -gt 0 ]]; then
    {
        echo ""
        echo "Session worktrees for ${SHORT_ID}:"
        for line in "${SUMMARY[@]}"; do
            echo "  - $line"
        done
        echo "  cd into a worktree path before editing files in that repo for the statusline to reflect your work accurately."
    } >&2
fi

exit 0
