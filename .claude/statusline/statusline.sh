#!/bin/bash
# Claude Code statusline
#
# Header: account | model | .../parent/leaf
# Per-repo lines (one per declared/discovered repo with state):
#   repo/branch · modified(N) · commit(N) · PR #X
#   repo/branch · up to date
#
# modified = all working-tree changes (untracked + modified + deleted)
# commit = local commits not yet pushed
# PR = open PRs, read from cache (no network call here)

input=$(cat)

DEFAULT="\033[39m"
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

# --- Path ---
project_dir=$(printf '%s' "$input" | jq -r '.workspace.project_dir // .workspace.current_dir // .cwd // "."')
path_display=".../$(printf '%s' "$project_dir" | awk -F/ '{print $(NF-1)"/"$NF}')"

# --- Parse declared repos from CLAUDE.md ---
parse_declared_repos() {
    local claude_md="${1}/CLAUDE.md"
    [[ -f "$claude_md" ]] || return
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
    ' "$claude_md"
}

# --- Discover repos in project dir (depth <= 2) ---
discover_repos() {
    local dir="$1"
    [[ -d "$dir" ]] || return
    find "$dir" -maxdepth 3 -type d -name .git 2>/dev/null | while IFS= read -r git_dir; do
        dirname "$git_dir"
    done
}

# --- Build repo list ---
declared_repos=()
suppress_all=0
while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if [[ "$(printf '%s' "$line" | tr '[:upper:]' '[:lower:]')" == "none" ]]; then
        suppress_all=1
        continue
    fi
    declared_repos+=("${line/#\~/$HOME}")
done < <(parse_declared_repos "$project_dir")

discovered_repos=()
if [[ "$suppress_all" -eq 0 ]]; then
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        discovered_repos+=("$line")
    done < <(discover_repos "$project_dir" | sort)
fi

all_repos=()
seen=":"
for r in "${declared_repos[@]}" "${discovered_repos[@]}"; do
    canonical=$(cd "$r" 2>/dev/null && pwd) || continue
    if [[ "$seen" != *":${canonical}:"* ]]; then
        all_repos+=("$canonical")
        seen="${seen}${canonical}:"
    fi
done

# --- Render repo lines ---
repo_lines=""
for repo in "${all_repos[@]}"; do
    label=$(basename "$repo")
    git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || continue

    branch=$(git -C "$repo" branch --show-current 2>/dev/null)
    [[ -z "$branch" ]] && branch="detached"

    modified=$(git -C "$repo" status --porcelain 2>/dev/null | grep -vc '^??' | tr -d ' ')

    commits=0
    if git -C "$repo" rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1; then
        commits=$(git -C "$repo" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)
    elif git -C "$repo" rev-parse origin/HEAD >/dev/null 2>&1; then
        commits=$(git -C "$repo" rev-list --count 'origin/HEAD..HEAD' 2>/dev/null || echo 0)
    fi

    # PR from cache (written by hooks/pr-cache.sh, never fetched here)
    pr_display=""
    cache_key=$(printf '%s' "$repo" | shasum | cut -d' ' -f1)
    cache_file="${TMPDIR:-/tmp}/claude-statusline-pr/${cache_key}.json"
    if [[ -f "$cache_file" ]]; then
        pr_nums=$(jq -r '.[].number // empty' "$cache_file" 2>/dev/null | head -5)
        if [[ -n "$pr_nums" ]]; then
            pr_display="PR $(echo "$pr_nums" | sed 's/^/#/' | paste -sd', ' -)"
        fi
    fi

    # Build state string
    state=""
    sep=" · "
    if [[ "$modified" -gt 0 ]]; then
        state="modified(${modified})"
    fi
    if [[ "$commits" -gt 0 ]]; then
        [[ -n "$state" ]] && state="${state}${sep}"
        state="${state}commit(${commits})"
    fi
    if [[ -n "$pr_display" ]]; then
        [[ -n "$state" ]] && state="${state}${sep}"
        state="${state}${pr_display}"
    fi

    # Color by urgency
    if [[ -n "$state" ]]; then
        if [[ "$modified" -gt 0 && "$commits" -gt 0 ]]; then
            color="$RED"
        elif [[ "$modified" -gt 0 ]]; then
            color="$YELLOW"
        elif [[ "$commits" -gt 0 ]]; then
            color="$ORANGE"
        else
            color="$CYAN"
        fi
        repo_lines="${repo_lines}\n${color} \xEE\x9C\xA5 ${label}/${branch} → ${state}${RESET}"
    else
        repo_lines="${repo_lines}\n${DEFAULT} \xEE\x9C\xA5 ${label}/${branch} → up to date${RESET}"
    fi
done

printf '%b' "${account} | ${model} | ${path_display}${repo_lines}"
