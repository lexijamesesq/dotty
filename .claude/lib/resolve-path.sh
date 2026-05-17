#!/usr/bin/env bash
# Resolve a user-supplied path (or fall back to a sentinel file, then $PWD) to
# a canonical absolute path.
#
# Usage: resolve-path.sh [path] [sentinel-file]
#   - path may be empty, "~/...", "/abs/...", or a relative path
#   - if path is empty AND sentinel-file is provided + exists + non-stale:
#     the sentinel's path is used. Sentinel is NOT auto-deleted (<TEAM>-N).
#       - JSON format: {"path": "/abs", "created_at": "YYYY-MM-DDTHH:MM:SSZ"}
#         older than 5 minutes (SENTINEL_TTL_SECONDS) is treated as absent.
#       - Bare format: first non-empty line is the path. No timestamp; always
#         treated as fresh. Backward compat for callers that wrote bare paths.
#   - if path is empty AND no usable sentinel, falls back to $PWD.
# Exits non-zero if the resolved path does not exist.

set -euo pipefail

SENTINEL_TTL_SECONDS=300

INPUT="${1:-}"
SENTINEL="${2:-}"

read_sentinel_path() {
  # Echoes the resolved sentinel path to stdout on success, exits 0.
  # On stale/unreadable/empty sentinel, exits 1 with no output.
  local file="$1"
  local raw json_path json_created created_epoch now_epoch age

  raw="$(cat "$file" 2>/dev/null)" || return 1
  [ -z "$raw" ] && return 1

  # Try JSON first.
  if json_path=$(printf '%s' "$raw" | jq -r '.path // empty' 2>/dev/null) \
     && [ -n "$json_path" ] && [ "$json_path" != "null" ]; then
    json_created=$(printf '%s' "$raw" | jq -r '.created_at // empty' 2>/dev/null)
    if [ -n "$json_created" ] && [ "$json_created" != "null" ]; then
      # Parse ISO 8601 (strip optional trailing Z). BSD date first (macOS),
      # then GNU date fallback (Linux).
      local ts="${json_created%Z}"
      # Parse as UTC. BSD `date -u -j -f` interprets input as UTC; GNU `date -d`
      # honors the trailing Z in the original string for UTC handling.
      created_epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%S" "$ts" "+%s" 2>/dev/null) \
        || created_epoch=$(date -d "$json_created" "+%s" 2>/dev/null) \
        || return 1
      now_epoch=$(date "+%s")
      age=$((now_epoch - created_epoch))
      if [ "$age" -gt "$SENTINEL_TTL_SECONDS" ]; then
        return 1
      fi
    fi
    printf '%s' "$json_path" | tr -d '\r\n'
    return 0
  fi

  # Bare-path backward compat: first non-empty line, no staleness check.
  printf '%s' "$raw" | head -n1 | tr -d '\r\n'
}

if [ -z "$INPUT" ] && [ -n "$SENTINEL" ] && [ -f "$SENTINEL" ]; then
  sentinel_path="$(read_sentinel_path "$SENTINEL")" || sentinel_path=""
  if [ -n "$sentinel_path" ]; then
    INPUT="$sentinel_path"
  fi
fi

[ -z "$INPUT" ] && INPUT="$PWD"

RESOLVED="${INPUT/#\~/$HOME}"
case "$RESOLVED" in
  /*) ;;
   *) RESOLVED="$PWD/$RESOLVED" ;;
esac
RESOLVED="$(realpath "$RESOLVED" 2>/dev/null || echo "$RESOLVED")"

if [ ! -e "$RESOLVED" ]; then
  echo "Path not found: $INPUT (resolved to $RESOLVED)" >&2
  exit 1
fi

echo "$RESOLVED"
