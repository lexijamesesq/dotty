#!/bin/bash

PRIVATE_CLAUDE="$HOME/bin/dotty-private/.claude"
PUBLIC_CLAUDE="$HOME/bin/dotty/.claude"
PROFILES=("claude-professional" "claude-personal")

# Files from private repo
PRIVATE_FILES=("CLAUDE.md" "settings.json")

# Directories from public repo
PUBLIC_DIRS=("skills" "agents" "rules")

# Directories from private repo
PRIVATE_DIRS=("plugins")

# Repos that extend operator PII rules from dotty-private via symlink.
# Each repo's .gitleaks.toml uses [extend] path = ".gitleaks-operator-rules.toml"
# which must be a gitignored symlink to the single source of truth below.
OPERATOR_RULES="$HOME/bin/dotty-private/gitleaks-operator-rules.toml"
GITLEAKS_REPOS=(
  "$HOME/bin/dotty"
)
if [[ -n "${VAULT_ROOT:-}" ]]; then
  GITLEAKS_REPOS+=("$VAULT_ROOT/Projects/Home Assistant")
fi

if [ -f "$OPERATOR_RULES" ]; then
  for repo in "${GITLEAKS_REPOS[@]}"; do
    link="$repo/.gitleaks-operator-rules.toml"
    if [ -d "$repo" ]; then
      rm -f "$link"
      ln -sf "$OPERATOR_RULES" "$link"
      echo "  $link -> $OPERATOR_RULES"
    fi
  done
fi

for profile in "${PROFILES[@]}"; do
  dir="$HOME/.$profile"
  mkdir -p "$dir"

  for file in "${PRIVATE_FILES[@]}"; do
    target="$PRIVATE_CLAUDE/$file"
    link="$dir/$file"
    if [ -e "$target" ]; then
      rm -f "$link"
      ln -sf "$target" "$link"
      echo "  $link -> $target"
    fi
  done

  for d in "${PUBLIC_DIRS[@]}"; do
    target="$PUBLIC_CLAUDE/$d"
    link="$dir/$d"
    if [ -d "$target" ]; then
      rm -f "$link"
      ln -sf "$target" "$link"
      echo "  $link -> $target"
    fi
  done

  for d in "${PRIVATE_DIRS[@]}"; do
    target="$PRIVATE_CLAUDE/$d"
    link="$dir/$d"
    if [ -d "$target" ]; then
      rm -f "$link"
      ln -sf "$target" "$link"
      echo "  $link -> $target"
    fi
  done

  echo "Profile directory ready: $dir"
done
