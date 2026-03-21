#!/bin/bash
# fix-obsidian-claude-sync.sh
#
# SessionStart hook: ensures .claude/ directories inside the Obsidian vault
# use the symlink pattern (claude/ real dir + .claude symlink) so Obsidian Sync
# can sync skills/agents across devices.
#
# Only acts on directories inside the Obsidian vault. Does nothing for
# normal code repos or other projects.
#
# Safe to run repeatedly — skips directories already fixed.

set -euo pipefail

VAULT_ROOT="${HOME}/Vaults/Notes"

# Read hook input from stdin (JSON with session context)
INPUT=$(cat)
SESSION_CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)

# If no working directory, nothing to do
if [[ -z "$SESSION_CWD" ]]; then
    exit 0
fi

# Only act inside the Obsidian vault
case "$SESSION_CWD" in
    "$VAULT_ROOT"*) ;;
    *) exit 0 ;;
esac

# Case 1: .claude/ is a real directory (needs conversion)
if [[ -d "$SESSION_CWD/.claude" && ! -L "$SESSION_CWD/.claude" ]]; then
    if [[ -d "$SESSION_CWD/claude" ]]; then
        echo "Warning: Both .claude/ and claude/ exist at $SESSION_CWD — skipping fix" >&2
        exit 0
    fi
    mv "$SESSION_CWD/.claude" "$SESSION_CWD/claude"
    ln -s ./claude "$SESSION_CWD/.claude"
fi

# Case 2: claude/ exists but .claude symlink is missing (new device via Obsidian Sync)
if [[ -d "$SESSION_CWD/claude" && ! -e "$SESSION_CWD/.claude" ]]; then
    ln -s ./claude "$SESSION_CWD/.claude"
fi

exit 0
