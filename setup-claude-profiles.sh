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
