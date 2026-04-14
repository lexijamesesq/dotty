#!/usr/bin/env bash
# vault-mcp-redirect.sh
#
# PreToolUse hook: block Read/Grep/Edit/Write on Obsidian-parsed files in the
# vault, redirect to Obsidian MCP. Tool-family-aware error message lists the
# relevant Obsidian MCP alternatives by operation.
#
# Scope: file types mcpvault parses, per
# /opt/homebrew/lib/node_modules/@bitbonsai/mcpvault/dist/src/pathfilter.js:
#   .md, .markdown, .txt, .base, .canvas (case-insensitive)
#
# Everything else in the vault (.json, images, PDFs, scripts, YAML, binaries)
# falls through to generic tools — mcpvault doesn't parse those.
#
# Escape hatch: Bash is unhooked. When MCP can't express the operation, use Bash.
# Also covers Obsidian CLI (wikilink-safe moves, base queries, daily notes).
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
    Read|Edit|Write)
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

# Scope check.
#   Read/Edit/Write target a specific file: extension must match mcpvault's
#     allowed extensions (case-insensitive). Non-matching extensions
#     (.json, .pdf, .png, .yaml, scripts, binaries) fall through to generic
#     tools because mcpvault can't parse them.
#   Grep targets a directory or a file:
#     - Directory: always block (search intent → search_notes / list_all_tags).
#     - File: block only if the extension matches.
if [[ "$TOOL_NAME" == "Grep" && -d "$ABS_TARGET" ]]; then
    : # directory target — fall through to block
else
    shopt -s nocasematch
    case "$ABS_TARGET" in
        *.md|*.markdown|*.txt|*.base|*.canvas) ;;
        *) shopt -u nocasematch; exit 0 ;;
    esac
    shopt -u nocasematch
fi

# Block with tool-family-aware redirect message
{
    echo "Vault file detected: $ABS_TARGET"
    echo ""
    echo "mcpvault parses this file. Use Obsidian MCP for the operation:"
    echo ""
    case "$TOOL_NAME" in
        Read)
            echo "  Read one note:        mcp__obsidian__read_note"
            echo "  Read batch (<=10):    mcp__obsidian__read_multiple_notes"
            echo "  Search content:       mcp__obsidian__search_notes"
            echo "  Metadata only:        mcp__obsidian__get_notes_info"
            ;;
        Grep)
            echo "  Content / frontmatter: mcp__obsidian__search_notes"
            echo "                          (set searchFrontmatter: true for frontmatter)"
            echo "  Vault-wide tag list:   mcp__obsidian__list_all_tags"
            echo "  Directory listing:     mcp__obsidian__list_directory"
            echo "  Metadata scan:         mcp__obsidian__get_notes_info"
            ;;
        Edit)
            echo "  Targeted replace:     mcp__obsidian__patch_note"
            echo "                          (vault-aware Edit — same exact-match semantics)"
            echo "  Frontmatter update:   mcp__obsidian__update_frontmatter"
            echo "  Tag add / remove:     mcp__obsidian__manage_tags"
            ;;
        Write)
            echo "  Create / overwrite:   mcp__obsidian__write_note"
            echo "  Append / prepend:     mcp__obsidian__write_note with mode: append or prepend"
            echo "  Delete:               mcp__obsidian__delete_note"
            ;;
    esac
    echo ""
    echo "Non-Obsidian file types in the vault (.json, images, PDFs, scripts,"
    echo "YAML, binaries) use generic tools. Move/rename uses Obsidian CLI via Bash."
    echo ""
    echo "Full mapping: global CLAUDE.md > Tool Selection Rules > Vault files"
    echo "Detail:        ~/Vaults/Notes/Claude/System/obsidian-integration.md"
} >&2

exit 2
