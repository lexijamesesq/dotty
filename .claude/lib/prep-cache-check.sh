#!/usr/bin/env bash
# prep-cache-check.sh — fast cache-hit check for /github-prep.
#
# If the prior marker is still valid (schema, scanner version, policy hash,
# full-scan TTL, and every scoped file's hash all match), the marker's
# verdict + findings are still valid. Refresh evaluated_at + scope and emit.
# This skips LLM-judgment work on the cache-hit path.
#
# Usage: prep-cache-check.sh <repo_root> <scope>
#   scope: change-set | --working-tree | --full-audit | --docs-only
#
# Exit 0: cache-hit. Stdout = path to the refreshed marker. Skill emits the
#         existing report; no LLM work needed.
# Exit 1: cache-miss. Stderr = one-line reason. Skill proceeds with full flow.
# Exit 2: error (missing inputs, etc).

set -uo pipefail

REPO_ROOT="${1:-}"
SCOPE="${2:-change-set}"

if [ -z "$REPO_ROOT" ]; then
  echo "Usage: $0 <repo_root> <scope>" >&2
  exit 2
fi

if [ ! -d "$REPO_ROOT" ]; then
  echo "Not a directory: $REPO_ROOT" >&2
  exit 2
fi

MARKER="$REPO_ROOT/.github-prep-status.json"

# Step 1: marker must exist
if [ ! -f "$MARKER" ]; then
  echo "miss: no prior marker at $MARKER" >&2
  exit 1
fi

# Step 2: schema version must be 2
SCHEMA_VER=$(jq -r '.marker_schema_version // 0' "$MARKER" 2>/dev/null || echo 0)
if [ "$SCHEMA_VER" != "2" ]; then
  echo "miss: marker_schema_version=$SCHEMA_VER (expected 2)" >&2
  exit 1
fi

# Step 3: scanner_version must match (skill should pass current scanner version
# via env var; if unset we fall back to the marker's value as a no-op check).
CURRENT_SCANNER="${GH_SCANNER_VERSION:-}"
MARKER_SCANNER=$(jq -r '.scanner_version // ""' "$MARKER")
if [ -n "$CURRENT_SCANNER" ] && [ "$MARKER_SCANNER" != "$CURRENT_SCANNER" ]; then
  echo "miss: scanner_version mismatch (marker: $MARKER_SCANNER, current: $CURRENT_SCANNER)" >&2
  exit 1
fi

# Step 4: policy_hash must match
if [ -z "${GH_POLICY_HASH:-}" ]; then
  # Try to load it
  if [ -f "$HOME/bin/dotty/.claude/lib/github-policy.sh" ]; then
    # shellcheck disable=SC1091
    source "$HOME/bin/dotty/.claude/lib/github-policy.sh" 2>/dev/null
    load_policy "$REPO_ROOT" 2>/dev/null || true
  fi
fi
MARKER_POLICY=$(jq -r '.policy_hash // ""' "$MARKER")
if [ -n "${GH_POLICY_HASH:-}" ] && [ "$MARKER_POLICY" != "$GH_POLICY_HASH" ]; then
  echo "miss: policy_hash mismatch (marker: $MARKER_POLICY, current: $GH_POLICY_HASH)" >&2
  exit 1
fi

# Step 5: TTL check on last_full_scan_at (only matters for change-set scope)
TTL_DAYS="${GH_POLICY_FULL_SCAN_TTL_DAYS:-30}"
TTL_SECONDS=$((TTL_DAYS * 86400))
LAST_FULL=$(jq -r '.last_full_scan_at // ""' "$MARKER")
if [ "$SCOPE" = "change-set" ] && [ -n "$LAST_FULL" ] && [ "$LAST_FULL" != "null" ]; then
  # Parse timestamp
  LAST_EPOCH=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$LAST_FULL" "+%s" 2>/dev/null \
    || date -d "$LAST_FULL" "+%s" 2>/dev/null \
    || echo 0)
  NOW_EPOCH=$(date "+%s")
  AGE=$((NOW_EPOCH - LAST_EPOCH))
  if [ "$AGE" -gt "$TTL_SECONDS" ]; then
    echo "miss: last_full_scan_at older than ${TTL_DAYS}d (age: $((AGE / 86400))d)" >&2
    exit 1
  fi
fi

# Step 6: file hash check on scoped files
FILE_LIST=$(mktemp)
cleanup() { rm -f "$FILE_LIST"; }
trap cleanup EXIT

if ! "$HOME/bin/dotty/.claude/lib/changed-files.sh" "$REPO_ROOT" "$SCOPE" > "$FILE_LIST" 2>/dev/null; then
  echo "miss: changed-files.sh failed for scope $SCOPE" >&2
  exit 1
fi

if [ ! -s "$FILE_LIST" ]; then
  # Empty scope (e.g., change-set with no staged changes) — cache is trivially valid
  # for "nothing to scan." Refresh the marker and exit hit.
  :
fi

# For each file in the scope, verify its current hash matches the marker's
# file_hashes entry. If ANY mismatch, cache-miss.
MISMATCH=""
while IFS= read -r -d '' f; do
  [ -f "$REPO_ROOT/$f" ] || { MISMATCH="$f (file gone)"; break; }
  CURRENT_HASH="sha256:$(shasum -a 256 "$REPO_ROOT/$f" 2>/dev/null | awk '{print $1}')"
  MARKER_HASH=$(jq -r --arg path "$f" '.file_hashes[$path] // ""' "$MARKER")
  if [ -z "$MARKER_HASH" ]; then
    MISMATCH="$f (no prior hash — new file in scope)"
    break
  fi
  if [ "$CURRENT_HASH" != "$MARKER_HASH" ]; then
    MISMATCH="$f (hash differs)"
    break
  fi
done < "$FILE_LIST"

if [ -n "$MISMATCH" ]; then
  echo "miss: $MISMATCH" >&2
  exit 1
fi

# All checks passed. Cache is valid. Refresh evaluated_at + scope and emit.
NOW_UTC=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
TMP_MARKER=$(mktemp)
jq --arg now "$NOW_UTC" --arg scope "$SCOPE" \
  '.evaluated_at = $now | .scope = $scope | .scope_upgrade_reason = null' \
  "$MARKER" > "$TMP_MARKER"

# Atomic replace
mv "$TMP_MARKER" "$MARKER"

# Emit the (refreshed) marker path so the caller can read it.
echo "$MARKER"
exit 0
