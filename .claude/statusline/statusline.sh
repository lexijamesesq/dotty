#!/bin/bash
# Claude Code statusline
# Layout: account | model | .../parent/leaf | github-segment (if any repo)
#
# Color: only the github segment (Anthropic convention: color only meaningfully variable things).
#
# GitHub segment — multi-repo aware:
#   Repos are sourced from:
#     a) `## Deliverable Repos` bullet list in $project_dir/CLAUDE.md (declared)
#     b) git repos discovered within $project_dir, depth ≤ 2 (auto-discovered)
#   Declared + discovered are merged, deduped (declared order > discovered alphabetical).
#   If list is empty: segment is hidden.
#   If list has one entry: show that repo's state.
#   If multiple: show the loudest (worst urgency); tie-break by list order.
#
# Repo state ladder:
#   clean (green) < uncommitted (yellow) < unpushed (orange) < both (red)
#   PR-open (cyan) appears as an annotation on the chosen repo, non-main branches only, 60s cache.

input=$(cat)

GREEN="\033[32m"
YELLOW="\033[33m"
ORANGE="\033[38;5;208m"
RED="\033[31m"
CYAN="\033[36m"
RESET="\033[0m"

# --- Account ---
PROFILE=${CLAUDE_PROFILE:-unknown}
case $PROFILE in
  professional) account="Inst";;
  personal)     account="Lexi";;
  *)            account="${PROFILE}";;
esac

# --- Model ---
model=$(printf '%s' "$input" | jq -r '.model.display_name // "Claude"')

# --- Project location ---
project_dir=$(printf '%s' "$input" | jq -r '.workspace.project_dir // .workspace.current_dir // .cwd // "."')
path_display=".../$(printf '%s' "$project_dir" | awk -F/ '{print $(NF-1)"/"$NF}')"

# --- Collect repos ---

# Parse "## Deliverable Repos" from project CLAUDE.md.
# Returns one path per line; tilde-expanded; `(flag)` annotations stripped
# (flags are read by hooks/session-worktrees.sh, not by the statusline);
# trailing `#` comments stripped.
parse_declared_repos() {
    local claude_md="${1}/CLAUDE.md"
    [[ -f "$claude_md" ]] || return
    awk '
        /^## Deliverable Repos[[:space:]]*$/ { flag=1; next }
        /^## / { flag=0 }
        flag && /^-[[:space:]]/ {
            sub(/^-[[:space:]]+/, "")
            sub(/[[:space:]]+\([^)]*\)[[:space:]]*/, " ")  # strip (worktree) etc.
            sub(/[[:space:]]+#.*$/, "")
            sub(/[[:space:]]+$/, "")
            if (length($0) > 0) print
        }
    ' "$claude_md"
}

# Find git repos within $project_dir up to depth 2 (i.e., .git at depth ≤ 3).
discover_repos() {
    local dir="$1"
    [[ -d "$dir" ]] || return
    find "$dir" -maxdepth 3 -type d -name .git 2>/dev/null | while IFS= read -r git_dir; do
        dirname "$git_dir"
    done
}

declared_repos=()
while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    declared_repos+=("${line/#\~/$HOME}")
done < <(parse_declared_repos "$project_dir")

discovered_repos=()
while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    discovered_repos+=("$line")
done < <(discover_repos "$project_dir" | sort)

# Merge declared (first) + discovered (alphabetical), dedupe by canonical path
all_repos=()
seen=":"
for r in "${declared_repos[@]}" "${discovered_repos[@]}"; do
    canonical=$(cd "$r" 2>/dev/null && pwd) || continue
    if [[ "$seen" != *":${canonical}:"* ]]; then
        all_repos+=("$canonical")
        seen="${seen}${canonical}:"
    fi
done

# --- Compute repo state ---
# args: <repo_path> <label> <branch_session_scoped> [<git_path>]
#   branch_session_scoped: "1" if the branch this repo is on is genuinely
#       session-scoped (cwd is the repo, OR we're reading from a per-session
#       worktree). "0" if the branch is shared filesystem state.
#       When "0", the branch is rendered in parens — operator-readable signal
#       that the displayed branch may not reflect their session's intent.
#       Information is preserved; honesty is preserved.
#   git_path: optional, defaults to repo_path. When using a worktree, pass the
#       worktree path so git commands reflect the worktree's state.
# stdout: "<urgency>|<render>"
#   urgency: 0=clean 1=uncommit 2=unpush 3=both (3 for detached HEAD)
compute_repo_state() {
    local repo="$1"
    local label="$2"
    local scoped="$3"
    local git_path="${4:-$1}"

    git -C "$git_path" rev-parse --git-dir >/dev/null 2>&1 || return 1

    local branch
    branch=$(git -C "$git_path" branch --show-current 2>/dev/null)

    if [[ -z "$branch" ]]; then
        local sha
        sha=$(git -C "$git_path" rev-parse --short HEAD 2>/dev/null)
        printf '3|%b%s:(detached @ %s)%b' "$RED" "$label" "$sha" "$RESET"
        return
    fi

    local uncommitted
    uncommitted=$(git -C "$git_path" status --porcelain 2>/dev/null | wc -l | tr -d ' ')

    local unpushed
    if git -C "$git_path" rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1; then
        unpushed=$(git -C "$git_path" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)
    elif git -C "$git_path" rev-parse origin/HEAD >/dev/null 2>&1; then
        unpushed=$(git -C "$git_path" rev-list --count 'origin/HEAD..HEAD' 2>/dev/null || echo 0)
    else
        unpushed=0
    fi

    # PR detection (non-main/master, 60s cache). PR state is a per-branch fact;
    # when branch is shared (parens), the PR annotation is true for the
    # filesystem branch shown, which the parens already disclaim.
    local pr_label=""
    if [[ "$branch" != "main" && "$branch" != "master" ]] && command -v gh >/dev/null 2>&1; then
        local cache_dir="${TMPDIR:-/tmp}/claude-statusline-pr"
        mkdir -p "$cache_dir"
        local cache_key
        cache_key=$(printf '%s' "${git_path}::${branch}" | shasum | cut -d' ' -f1)
        local cache_file="${cache_dir}/${cache_key}"

        local cache_age=999
        if [[ -f "$cache_file" ]]; then
            local mtime
            mtime=$(stat -f %m "$cache_file" 2>/dev/null || stat -c %Y "$cache_file" 2>/dev/null || echo 0)
            cache_age=$(( $(date +%s) - mtime ))
        fi

        local pr_number
        if [[ "$cache_age" -lt 60 ]]; then
            pr_number=$(cat "$cache_file")
        else
            pr_number=$(cd "$git_path" && gh pr list --head "$branch" --json number --jq '.[0].number // empty' 2>/dev/null)
            printf '%s' "$pr_number" > "$cache_file"
        fi

        [[ -n "$pr_number" ]] && pr_label=" · ${CYAN}PR #${pr_number}${RESET}"
    fi

    # Branch always shown when known. Parens flag a branch that isn't
    # session-scoped (shared filesystem state) so the operator can tell at a
    # glance whether the displayed branch reflects their session's intent.
    local head
    if [[ "$scoped" == "1" ]]; then
        head="${label}:${branch}"
    else
        head="${label}:(${branch})"
    fi

    local urgency render
    if [[ "$uncommitted" -gt 0 && "$unpushed" -gt 0 ]]; then
        urgency=3
        render="${RED}${head} · commit (${uncommitted}) · push (${unpushed})${RESET}${pr_label}"
    elif [[ "$uncommitted" -gt 0 ]]; then
        urgency=1
        render="${YELLOW}${head} · commit (${uncommitted})${RESET}${pr_label}"
    elif [[ "$unpushed" -gt 0 ]]; then
        urgency=2
        render="${ORANGE}${head} · push (${unpushed})${RESET}${pr_label}"
    else
        urgency=0
        render="${GREEN}${head}${RESET}${pr_label}"
    fi

    printf '%d|%s' "$urgency" "$render"
}

# --- Session worktree manifest ---
# Written by hooks/session-worktrees.sh on SessionStart. Maps a canonical repo
# path to a per-session worktree path. When a repo has an entry, the statusline
# reads state from the worktree (branch is then genuinely session-scoped).
#
# bash 3.2 (macOS default) has no assoc arrays, so we look up via jq on demand.
session_id=$(printf '%s' "$input" | jq -r '.session_id // empty')
manifest=""
if [[ -n "$session_id" ]]; then
    candidate="${TMPDIR:-/tmp}/claude-session-state/${session_id}/worktrees.json"
    [[ -f "$candidate" ]] && manifest="$candidate"
fi

# Returns worktree path for $1 (canonical repo path), or empty if none.
worktree_for_repo() {
    [[ -z "$manifest" ]] && return
    jq -r --arg k "$1" '.[$k] // empty' "$manifest" 2>/dev/null
}

# Canonical project_dir for cwd-equals-repo detection
project_dir_canonical=$(cd "$project_dir" 2>/dev/null && pwd) || project_dir_canonical="$project_dir"

# --- Pick loudest across repos ---
github=""
best_urgency=-1
for repo in "${all_repos[@]}"; do
    label=$(basename "$repo")
    git_path="$repo"
    scoped=0

    worktree=$(worktree_for_repo "$repo")
    if [[ -n "$worktree" && -d "$worktree" ]]; then
        git_path="$worktree"
        scoped=1
    elif [[ "$repo" == "$project_dir_canonical" ]]; then
        scoped=1
    fi

    state=$(compute_repo_state "$repo" "$label" "$scoped" "$git_path")
    [[ -z "$state" ]] && continue

    urgency="${state%%|*}"
    render="${state#*|}"

    if [[ "$urgency" -gt "$best_urgency" ]]; then
        best_urgency=$urgency
        github=$render
    fi
done

# --- Assemble ---
output="${account} | ${model} | ${path_display}"
[[ -n "$github" ]] && output="${output} | ${github}"

printf '%b' "$output"
