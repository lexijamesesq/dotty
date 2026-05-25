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
# Returns one path per line; tilde-expanded; trailing comments stripped.
parse_declared_repos() {
    local claude_md="${1}/CLAUDE.md"
    [[ -f "$claude_md" ]] || return
    awk '
        /^## Deliverable Repos[[:space:]]*$/ { flag=1; next }
        /^## / { flag=0 }
        flag && /^-[[:space:]]/ {
            sub(/^-[[:space:]]+/, "")
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
# stdout: "<urgency>|<render>"
#   urgency: 0=clean 1=uncommit 2=unpush 3=both (also: 3 for detached HEAD)
compute_repo_state() {
    local repo="$1"
    local label
    label=$(basename "$repo")

    git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || return 1

    local branch
    branch=$(git -C "$repo" branch --show-current 2>/dev/null)

    if [[ -z "$branch" ]]; then
        local sha
        sha=$(git -C "$repo" rev-parse --short HEAD 2>/dev/null)
        printf '3|%b%s:(detached @ %s)%b' "$RED" "$label" "$sha" "$RESET"
        return
    fi

    local uncommitted
    uncommitted=$(git -C "$repo" status --porcelain 2>/dev/null | wc -l | tr -d ' ')

    local unpushed
    if git -C "$repo" rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1; then
        unpushed=$(git -C "$repo" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)
    elif git -C "$repo" rev-parse origin/HEAD >/dev/null 2>&1; then
        unpushed=$(git -C "$repo" rev-list --count 'origin/HEAD..HEAD' 2>/dev/null || echo 0)
    else
        unpushed=0
    fi

    # PR detection (non-main/master only, 60s cache)
    local pr_label=""
    if [[ "$branch" != "main" && "$branch" != "master" ]] && command -v gh >/dev/null 2>&1; then
        local cache_dir="${TMPDIR:-/tmp}/claude-statusline-pr"
        mkdir -p "$cache_dir"
        local cache_key
        cache_key=$(printf '%s' "${repo}::${branch}" | shasum | cut -d' ' -f1)
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
            pr_number=$(cd "$repo" && gh pr list --head "$branch" --json number --jq '.[0].number // empty' 2>/dev/null)
            printf '%s' "$pr_number" > "$cache_file"
        fi

        [[ -n "$pr_number" ]] && pr_label=" · ${CYAN}PR #${pr_number}${RESET}"
    fi

    local urgency render
    if [[ "$uncommitted" -gt 0 && "$unpushed" -gt 0 ]]; then
        urgency=3
        render="${RED}${label}:${branch} · commit (${uncommitted}) · push (${unpushed})${RESET}${pr_label}"
    elif [[ "$uncommitted" -gt 0 ]]; then
        urgency=1
        render="${YELLOW}${label}:${branch} · commit (${uncommitted})${RESET}${pr_label}"
    elif [[ "$unpushed" -gt 0 ]]; then
        urgency=2
        render="${ORANGE}${label}:${branch} · push (${unpushed})${RESET}${pr_label}"
    else
        urgency=0
        render="${GREEN}${label}:${branch}${RESET}${pr_label}"
    fi

    printf '%d|%s' "$urgency" "$render"
}

# --- Pick loudest across repos ---
github=""
best_urgency=-1
for repo in "${all_repos[@]}"; do
    state=$(compute_repo_state "$repo")
    [[ -z "$state" ]] && continue

    urgency="${state%%|*}"
    render="${state#*|}"

    # Strictly greater wins — preserves list order on ties
    if [[ "$urgency" -gt "$best_urgency" ]]; then
        best_urgency=$urgency
        github=$render
    fi
done

# --- Assemble ---
output="${account} | ${model} | ${path_display}"
[[ -n "$github" ]] && output="${output} | ${github}"

printf '%b' "$output"
