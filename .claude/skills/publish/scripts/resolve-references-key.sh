#!/usr/bin/env bash
# resolve-references-key.sh — sourceable resolver for a references.* key from
# dotty-private's global CLAUDE.md. NOT meant to be executed directly (no
# shebang-driven behavior of its own) -- `source` it, then call
# resolve_references_key <key>. The one source of truth for this resolution:
# gate-mechanical.sh sources it for --rosters-path/--private-vocab-path, and
# playbooks/gate.md § Criteria 3's own documented hand-run qa.py example
# sources it too, so the two can never drift out of sync again (LEX-718 --
# the prior duplicated, hand-typed form in gate.md is exactly what drifted).
#
# Prerequisite: `yq`, to parse the global CLAUDE.md's Configuration block.
# `yq` is Brewfile-declared (LEX-708) -- its absence must fail loud, never
# silently degrade a resolved path to a caller's own broken pre-key default.
# Callers of this file are expected to `set -euo pipefail` themselves; this
# file only defines a function, it does not exit on its own when sourced.

resolve_references_key_check_yq() {
  if ! command -v yq >/dev/null 2>&1; then
    echo "resolve_references_key: missing prerequisite 'yq' — required to resolve" >&2
    echo "  references.* keys (e.g. tag_taxonomy_rosters) from dotty-private's" >&2
    echo "  global CLAUDE.md. yq is Brewfile-declared (LEX-708); install it" >&2
    echo "  ('brew install yq') and re-run." >&2
    return 1
  fi
}

# Resolve a references.* key from dotty-private's global CLAUDE.md — the
# single source of truth for where a declared file actually lives, never
# hardcoded here. Unlike a project CLAUDE.md (real YAML frontmatter, the
# shape statusline.sh's parse_declared_repos() reads), the global CLAUDE.md's
# Configuration block is a fenced ```yaml section in the body — extract that
# fence, not frontmatter. Empty output (missing file, missing key) is a
# legitimate "unresolved" signal, not an error — every caller falls back to
# its own consumer-side default for that case (qa.py's pre-key vault-relative
# default for rosters; an empty/unset --private-vocab-path, which qa.py
# itself already treats as a no-op). A missing `yq` is NOT one of those
# legitimate cases — call resolve_references_key_check_yq first and handle
# its failure explicitly (gate-mechanical.sh does this once, up front,
# ahead of every resolve_references_key call).
resolve_references_key() {
  local key="$1"
  local claude_md="${HOME}/bin/dotty-private/.claude/CLAUDE.md"
  [[ -f "$claude_md" ]] || return
  local yaml_block value workspace_root
  yaml_block="$(awk '/^```yaml/{c=1; next} /^```$/{c=0} c' "$claude_md")"
  value="$(printf '%s\n' "$yaml_block" | yq -r ".\"${key}\"" - 2>/dev/null | grep -v '^null$')" || true
  [[ -z "$value" ]] && return
  case "$value" in
    "~"*|/*)
      # Repo-absolute or already-expanded — expand a leading ~ (no eval).
      printf '%s\n' "${value/#\~/$HOME}"
      ;;
    *)
      # workspace_root-relative, same convention every other references.*
      # key uses (see the Configuration block's own header comment).
      workspace_root="$(printf '%s\n' "$yaml_block" | yq -r '.workspace_root' - 2>/dev/null | grep -v '^null$')"
      [[ -z "$workspace_root" ]] && workspace_root="${HOME}/Vaults/Notes"
      workspace_root="${workspace_root/#\~/$HOME}"
      printf '%s\n' "${workspace_root%/}/$value"
      ;;
  esac
}
