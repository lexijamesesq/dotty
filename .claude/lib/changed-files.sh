#!/usr/bin/env bash
# changed-files.sh — emit the file list github-prep should scan.
#
# Modes (default: change-set):
#   change-set    staged-only (cached vs HEAD) + commits-ahead-of-baseline
#   --working-tree  staged + unstaged + untracked
#   --full-audit   full commitable surface
#   --docs-only    change-set filtered to .md / .txt / LICENSE / README
#
# Staged-only is the default so that one session's unstaged changes don't
# show up as findings in another session's verdict (Revise has no ack path).
#
# All modes are bounded to the commitable surface via
# `git ls-files --cached --others --exclude-standard`. Files outside the repo,
# in .git/, or gitignored are unreachable by construction.
#
# Usage: changed-files.sh <repo_root> [mode]
# Output: NUL-separated paths on stdout. Non-zero exit on error.
#
# Baseline detection (for change-set and --working-tree modes):
#   1. If origin/main or origin/master reachable: diff `<baseline>...HEAD`.
#   2. Else if @{u} upstream: diff against upstream.
#   3. Always include staged (--cached vs HEAD).
#   4. --working-tree additionally includes unstaged + untracked.
#   5. Empty change set → caller decides (typically: full surface).

set -euo pipefail

REPO_ROOT="${1:-}"
MODE="${2:-change-set}"

if [ -z "$REPO_ROOT" ]; then
  echo "Usage: $0 <repo_root> [--full-audit | --docs-only | change-set]" >&2
  exit 1
fi

if [ ! -d "$REPO_ROOT" ]; then
  echo "Not a directory: $REPO_ROOT" >&2
  exit 1
fi

cd "$REPO_ROOT"

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "Not a git repo: $REPO_ROOT" >&2
  exit 1
fi

# --- function definitions (must be defined before first call) -----------------

# Get the full commitable surface — load-bearing safety bound.
commitable_surface() {
  git ls-files --cached --others --exclude-standard -z
}

# Compute the change set as a NUL-separated list.
# include_working_tree=true → include unstaged + untracked (old behavior).
# include_working_tree=false (default) → staged-only + commits-ahead-of-baseline.
# Output empty if no baseline AND no relevant changes.
compute_change_set() {
  local include_working_tree="${1:-false}"
  local on_branch baseline upstream candidate

  on_branch=$(git symbolic-ref --short -q HEAD 2>/dev/null || echo "")
  baseline=""

  # Try origin/main, then origin/master.
  for candidate in origin/main origin/master; do
    if git rev-parse --verify --quiet "$candidate" >/dev/null 2>&1; then
      baseline="$candidate"
      break
    fi
  done

  # Fall back to upstream tracking branch if no origin/main|master.
  if [ -z "$baseline" ]; then
    upstream=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || echo "")
    [ -n "$upstream" ] && baseline="$upstream"
  fi

  {
    if [ -n "$baseline" ]; then
      # Files changed between baseline and HEAD (commits ahead).
      git diff --name-only -z "$baseline"...HEAD 2>/dev/null || true
    fi
    # Staged changes (cached vs HEAD) — always included, this is the
    # operator's actual about-to-commit surface.
    git diff --name-only -z --cached 2>/dev/null || true

    if [ "$include_working_tree" = "true" ]; then
      # Unstaged changes (working tree vs index).
      git diff --name-only -z 2>/dev/null || true
      # Untracked-not-gitignored.
      git ls-files --others --exclude-standard -z 2>/dev/null || true
    fi
  }
}

# Filter a NUL-separated list to docs-only (markdown / text / LICENSE / README).
filter_docs_only() {
  while IFS= read -r -d '' f; do
    case "$f" in
      *.md|*.markdown|*.txt|LICENSE|LICENSE.*|README|README.*)
        printf '%s\0' "$f"
        ;;
    esac
  done
}

# Intersect a NUL-separated list on stdin against the commitable surface.
# Files that aren't in the commitable surface (gitignored, deleted, etc.)
# are dropped — the hard bound.
intersect_with_surface() {
  local input_file surface_file
  input_file=$(mktemp)
  surface_file=$(mktemp)

  cat > "$input_file"
  commitable_surface > "$surface_file"

  # Convert both to newline-separated, sort-unique, intersect, convert back.
  tr '\0' '\n' < "$input_file" | sort -u > "$input_file.sorted"
  tr '\0' '\n' < "$surface_file" | sort -u > "$surface_file.sorted"
  comm -12 "$input_file.sorted" "$surface_file.sorted" | tr '\n' '\0'

  rm -f "$input_file" "$input_file.sorted" "$surface_file" "$surface_file.sorted"
}

# --- main dispatch ------------------------------------------------------------

CS_TMP=""
cleanup() { [ -n "$CS_TMP" ] && rm -f "$CS_TMP"; }
trap cleanup EXIT

case "$MODE" in
  --full-audit)
    commitable_surface
    ;;

  --docs-only)
    CS_TMP=$(mktemp)
    compute_change_set false > "$CS_TMP"
    if [ ! -s "$CS_TMP" ]; then
      # No staged docs — filter the full surface to docs.
      commitable_surface | filter_docs_only
    else
      filter_docs_only < "$CS_TMP" | intersect_with_surface
    fi
    ;;

  --working-tree)
    CS_TMP=$(mktemp)
    compute_change_set true > "$CS_TMP"
    if [ ! -s "$CS_TMP" ]; then
      commitable_surface
    else
      intersect_with_surface < "$CS_TMP"
    fi
    ;;

  change-set|"")
    # Default: staged-only (multi-session safe).
    CS_TMP=$(mktemp)
    compute_change_set false > "$CS_TMP"
    if [ ! -s "$CS_TMP" ]; then
      # No staged changes and no commits ahead. The operator likely doesn't
      # need to scan anything (nothing to push). Return empty — caller
      # decides whether that's "verdict: allow, no findings" or "ask the
      # operator to opt into --working-tree or --full-audit".
      : # emit nothing
    else
      intersect_with_surface < "$CS_TMP"
    fi
    ;;

  *)
    echo "Unknown mode: $MODE (expected: change-set | --working-tree | --full-audit | --docs-only)" >&2
    exit 1
    ;;
esac
