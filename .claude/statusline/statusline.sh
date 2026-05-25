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
# args: <repo_path> <label> <engaged> [<git_path>]
#   engaged: "1" if this session has engaged with the repo (baseline-diff or
#       per-session worktree). When "1" the render includes the branch label
#       (in parens) and the open PR for the current branch, if any. When "0"
#       only the repo name + counts render — branch + PR are hidden because
#       they'd be inherited filesystem state, not this session's context.
#       File counts (uncommitted, unpushed) always render based on real state.
#   git_path: optional, defaults to repo_path. When using a worktree, pass the
#       worktree path so git commands reflect the worktree's state.
# stdout: "<urgency>|<render>"
#   urgency: 0=clean 1=uncommit 2=unpush 3=both (3 for detached HEAD)
compute_repo_state() {
    local repo="$1"
    local label="$2"
    local engaged="$3"
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

    # PR detection: only when engaged AND branch != main/master. 60s cache.
    local pr_label=""
    if [[ "$engaged" == "1" ]] && [[ "$branch" != "main" && "$branch" != "master" ]] && command -v gh >/dev/null 2>&1; then
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

    # Branch label shown only when this session is engaged. When not engaged,
    # the branch is filesystem state inherited from elsewhere — render just the
    # repo name + counts so the mess surfaces without false branch context.
    local head
    if [[ "$engaged" == "1" ]]; then
        head="${label}:(${branch})"
    else
        head="${label}"
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
        # Clean repo with engagement still surfaces (shows the branch you're on);
        # clean + not engaged would show just the label with no signal — hide.
        if [[ "$engaged" == "1" ]]; then
            render="${GREEN}${head}${RESET}${pr_label}"
        else
            return 1
        fi
    fi

    printf '%d|%s' "$urgency" "$render"
}

# --- Session state files ---
# baseline.json: written by hooks/session-baseline.sh on SessionStart.
#   { "<repo>": { "branch":..., "uncommitted":..., "unpushed":..., "open_prs":[...] } }
#   Used to detect engagement (current != baseline = this session engaged).
# worktrees.json: written by hooks/session-worktrees.sh for repos flagged
#   (worktree). Maps repo path to per-session worktree path.
#
# bash 3.2 (macOS default) has no assoc arrays, so we look up via jq on demand.
session_id=$(printf '%s' "$input" | jq -r '.session_id // empty')
baseline=""
manifest=""
if [[ -n "$session_id" ]]; then
    bl="${TMPDIR:-/tmp}/claude-session-state/${session_id}/baseline.json"
    wt="${TMPDIR:-/tmp}/claude-session-state/${session_id}/worktrees.json"
    [[ -f "$bl" ]] && baseline="$bl"
    [[ -f "$wt" ]] && manifest="$wt"
fi

worktree_for_repo() {
    [[ -z "$manifest" ]] && return
    jq -r --arg k "$1" '.[$k] // empty' "$manifest" 2>/dev/null
}

# Computes engagement for a repo by diffing current state against baseline.
# stdout: "1" if engaged this session, "0" if not.
session_engaged() {
    local canonical="$1"
    local git_path="$2"

    [[ -z "$baseline" ]] && { printf '0'; return; }

    # Pull baseline fields for this repo
    local b_branch b_uncommitted b_unpushed b_prs
    b_branch=$(jq -r --arg k "$canonical" '.[$k].branch // ""' "$baseline" 2>/dev/null)
    b_uncommitted=$(jq -r --arg k "$canonical" '.[$k].uncommitted // 0' "$baseline" 2>/dev/null)
    b_unpushed=$(jq -r --arg k "$canonical" '.[$k].unpushed // 0' "$baseline" 2>/dev/null)
    b_prs=$(jq -r --arg k "$canonical" '.[$k].open_prs // [] | join(",")' "$baseline" 2>/dev/null)

    # Repo not in baseline (added after session start): treat as engaged
    if ! jq -e --arg k "$canonical" 'has($k)' "$baseline" >/dev/null 2>&1; then
        printf '1'; return
    fi

    # Current state
    local c_branch c_uncommitted c_unpushed
    c_branch=$(git -C "$git_path" branch --show-current 2>/dev/null)
    c_uncommitted=$(git -C "$git_path" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    if git -C "$git_path" rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1; then
        c_unpushed=$(git -C "$git_path" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)
    elif git -C "$git_path" rev-parse origin/HEAD >/dev/null 2>&1; then
        c_unpushed=$(git -C "$git_path" rev-list --count 'origin/HEAD..HEAD' 2>/dev/null || echo 0)
    else
        c_unpushed=0
    fi

    [[ "$c_branch" != "$b_branch" ]] && { printf '1'; return; }
    [[ "$c_uncommitted" != "$b_uncommitted" ]] && { printf '1'; return; }
    [[ "$c_unpushed" != "$b_unpushed" ]] && { printf '1'; return; }

    # Compare open PRs (sorted CSV)
    local c_prs=""
    if command -v gh >/dev/null 2>&1; then
        c_prs=$(cd "$git_path" && gh pr list --state open --json number --jq '[.[].number] | sort | join(",")' 2>/dev/null)
    fi
    [[ "$c_prs" != "$b_prs" ]] && { printf '1'; return; }

    printf '0'
}

# --- Pick loudest across repos ---
github=""
best_urgency=-1
for repo in "${all_repos[@]}"; do
    label=$(basename "$repo")
    git_path="$repo"
    engaged=0

    worktree=$(worktree_for_repo "$repo")
    if [[ -n "$worktree" && -d "$worktree" ]]; then
        # Per-session worktree: branch is session-scoped by construction
        git_path="$worktree"
        engaged=1
    else
        engaged=$(session_engaged "$repo" "$git_path")
    fi

    state=$(compute_repo_state "$repo" "$label" "$engaged" "$git_path")
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
