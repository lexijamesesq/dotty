#!/bin/bash
# profile-symlink-guard.sh
#
# SessionStart hook: warns when a ~/.claude-* profile carries a REAL directory
# or file where this repo's canonical .claude copy exists — the symlink pattern
# silently shadowed by a stale copy. Receipt: 2026-08-10 — both profiles carried
# stale real-dir copies of two skills; sessions loaded a generations-old agent
# while canonical moved on, and merged changes were dark at runtime.
#
# Warn-only by design: a real dir may hold newer unported work — deletion is
# the operator's act, after a diff, never this hook's.

set -uo pipefail

CANON="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # this repo's .claude

for profile in "$HOME"/.claude-personal "$HOME"/.claude-professional; do
  for kind in skills agents; do
    dir="$profile/$kind"
    [[ -d "$dir" ]] || continue
    for entry in "$dir"/*; do
      [[ -e "$entry" ]] || continue
      if [[ ! -L "$entry" ]]; then
        name=$(basename "$entry")
        if [[ -e "$CANON/$kind/$name" ]]; then
          echo "profile-symlink-guard: $entry is a real copy while canonical $CANON/$kind/$name exists — likely a stale copy shadowing canonical. Diff it, then delete + re-symlink (operator's act)." >&2
        fi
      fi
    done
  done
done

exit 0
