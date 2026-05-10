#!/usr/bin/env bash
# Resolve a user-supplied path (or fall back to a sentinel file, then $PWD) to
# a canonical absolute path.
#
# Usage: resolve-path.sh [path] [sentinel-file]
#   - path may be empty, "~/...", "/abs/...", or a relative path
#   - if path is empty AND sentinel-file is provided + exists, the sentinel's
#     first non-empty line is used as the path (and the sentinel is deleted to
#     prevent stale reuse)
#   - if both are empty/absent, falls back to $PWD
# Exits non-zero if the resolved path does not exist.

set -euo pipefail

INPUT="${1:-}"
SENTINEL="${2:-}"

if [ -z "$INPUT" ] && [ -n "$SENTINEL" ] && [ -f "$SENTINEL" ]; then
  INPUT="$(head -n1 "$SENTINEL" | tr -d '\r\n')"
  rm -f "$SENTINEL"
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
