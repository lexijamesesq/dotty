#!/usr/bin/env bash
# vault-mcp-redirect.sh
#
# PreToolUse hook: block Grep/Read on vault paths, redirect to Obsidian MCP.
# Escape hatch: Bash is unhooked. When MCP can't express the operation, use Bash.
#
# Fail-open: if jq is missing or stdin parse fails, exit 0 rather than blocking
# every vault file access. A broken hook should never lock the session out.
#
# Spec: ~/Vaults/Notes/Claude/System/hook-spec-vault-mcp-redirect.md

set -euo pipefail

VAULT="${HOME}/Vaults/Notes"

# Fail-open if jq is not available
if ! command -v jq >/dev/null 2>&1; then
    exit 0
fi

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)

case "$TOOL_NAME" in
    Read)
        TARGET=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)
        ;;
    Grep)
        TARGET=$(echo "$INPUT" | jq -r '.tool_input.path // empty' 2>/dev/null || true)
        [[ -z "$TARGET" ]] && TARGET="$PWD"
        ;;
    *)
        exit 0
        ;;
esac

[[ -z "$TARGET" ]] && exit 0

ABS_TARGET=$(realpath -q "$TARGET" 2>/dev/null || echo "$TARGET")

# Not under the vault — allow
case "$ABS_TARGET" in
    "$VAULT"|"$VAULT"/*) ;;
    *) exit 0 ;;
esac

# Read carve-out: only markdown and JSON go through MCP
if [[ "$TOOL_NAME" == "Read" ]]; then
    case "$ABS_TARGET" in
        *.md|*.markdown|*.json) ;;
        *) exit 0 ;;
    esac
fi

{
    echo "Vault path detected: $ABS_TARGET"
    echo ""
    echo "This operation targets a file or directory inside ~/Vaults/Notes."
    echo "Use the Obsidian MCP equivalent:"
    echo ""
    if [[ "$TOOL_NAME" == "Read" ]]; then
        echo "  Read(vault/*.md)   ->  mcp__obsidian__read_note"
        echo "                          mcp__obsidian__read_multiple_notes (batch <=10)"
        echo "  Read(vault/*.json) ->  mcp__obsidian__read_note"
    else
        echo "  Grep (content)     ->  mcp__obsidian__search_notes"
        echo "  Grep (filename)    ->  mcp__obsidian__list_directory"
        echo "  Grep (tags)        ->  mcp__obsidian__list_all_tags"
        echo "  Grep (frontmatter) ->  mcp__obsidian__search_notes with searchFrontmatter: true"
    fi
    echo ""
    echo "If MCP genuinely cannot express this operation, fall through to Bash."
    echo "See Claude/System/obsidian-integration.md and"
    echo "    Claude/System/knowledge-compilation-architecture.md for rationale."
} >&2

exit 2
