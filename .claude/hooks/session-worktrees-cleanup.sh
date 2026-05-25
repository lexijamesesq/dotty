#!/usr/bin/env bash
# session-worktrees-cleanup.sh
#
# SessionEnd hook: cleans up per-session worktrees created by
# session-worktrees.sh. For each entry in the session's manifest:
#   - If the worktree is clean AND its branch has no unmerged commits
#     vs origin/HEAD: `git worktree remove` and delete the branch.
#   - Otherwise: leave it intact and warn — operator must handle.
#
# Manifest is removed last if all worktrees cleaned. If any were left,
# manifest persists so the operator can re-find paths later.
#
# Tolerant: stderr-warn on failure, exit 0.

set -uo pipefail

INPUT=$(cat 2>/dev/null || true)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)

if [[ -z "$SESSION_ID" ]]; then
    exit 0
fi

STATE_DIR="${TMPDIR:-/tmp}/claude-session-state/${SESSION_ID}"
MANIFEST="${STATE_DIR}/worktrees.json"

[[ -f "$MANIFEST" ]] || exit 0

LEFT=()
REMOVED=()

while IFS=$'\t' read -r canonical worktree_path; do
    [[ -z "$canonical" || -z "$worktree_path" ]] && continue
    [[ ! -d "$worktree_path" ]] && continue

    # Check cleanliness
    dirty=$(git -C "$worktree_path" status --porcelain 2>/dev/null | wc -l | tr -d ' ')

    # Check unpushed commits vs origin/HEAD (the worktree branch is session-scoped
    # and likely has no upstream, so we compare to origin/HEAD)
    unpushed=0
    if git -C "$worktree_path" rev-parse origin/HEAD >/dev/null 2>&1; then
        unpushed=$(git -C "$worktree_path" rev-list --count 'origin/HEAD..HEAD' 2>/dev/null || echo 0)
    fi

    branch=$(git -C "$worktree_path" branch --show-current 2>/dev/null)

    if [[ "$dirty" -eq 0 && "$unpushed" -eq 0 ]]; then
        if git -C "$canonical" worktree remove "$worktree_path" 2>/dev/null; then
            # Delete the session branch if it follows our naming convention
            if [[ "$branch" == claude-session/* ]]; then
                git -C "$canonical" branch -D "$branch" 2>/dev/null || true
            fi
            REMOVED+=("$(basename "$canonical"): $worktree_path")
        else
            LEFT+=("$(basename "$canonical") (remove failed): $worktree_path")
        fi
    else
        reason=""
        [[ "$dirty" -gt 0 ]] && reason="${dirty} uncommitted"
        [[ "$unpushed" -gt 0 ]] && reason="${reason:+$reason, }${unpushed} unpushed"
        LEFT+=("$(basename "$canonical") ($reason): $worktree_path [branch $branch]")
    fi
done < <(jq -r 'to_entries[] | "\(.key)\t\(.value)"' "$MANIFEST" 2>/dev/null)

# bash 3.2 + set -u quirk: empty arrays explode under ${arr[@]}; use :+ guards
n_removed=${#REMOVED[@]}
n_left=${#LEFT[@]}

# Manifest survives iff anything was left behind
if [[ "$n_left" -eq 0 ]]; then
    rm -rf "$STATE_DIR"
fi

if [[ "$n_removed" -gt 0 || "$n_left" -gt 0 ]]; then
    {
        echo ""
        echo "Session worktrees cleanup:"
        if [[ "$n_removed" -gt 0 ]]; then
            for line in "${REMOVED[@]}"; do echo "  removed: $line"; done
        fi
        if [[ "$n_left" -gt 0 ]]; then
            for line in "${LEFT[@]}"; do echo "  KEPT: $line"; done
            echo "  Resolve KEPT worktrees manually; manifest preserved at $MANIFEST"
        fi
    } >&2
fi

exit 0
