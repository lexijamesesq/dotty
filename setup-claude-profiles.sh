#!/bin/bash
# setup-claude-profiles.sh — First-run profile bootstrap.
#
# Creates the two Claude Code profile directories and establishes the
# minimum viable state so that `blueprint apply` can take over from here.
# On a provisioned machine, `blueprint apply` is the ongoing authority —
# this script is for bare-metal only.

PRIVATE_CLAUDE="$HOME/bin/dotty-private/.claude"
PROFILES=("claude-professional" "claude-personal")

# Directories that blueprint's core slice manages via per-entry symlinks.
# This script creates them as real directories; blueprint populates them.
MANAGED_DIRS=("skills" "rules" "agents")

# Private repo directories still whole-dir symlinked (third-party plugins).
PRIVATE_DIRS=("plugins")

# Repos that extend operator PII rules from dotty-private via symlink.
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

  # CLAUDE.md — real file with @ import (not a symlink)
  claude_md="$dir/CLAUDE.md"
  if [ ! -e "$claude_md" ]; then
    echo "@~/bin/dotty-private/.claude/CLAUDE.md" > "$claude_md"
    echo "  created $claude_md (@ import)"
  fi

  # settings.json — symlink to shared base (blueprint apply will generate later)
  settings_target="$PRIVATE_CLAUDE/settings.json"
  settings_link="$dir/settings.json"
  if [ -e "$settings_target" ] && [ ! -e "$settings_link" ]; then
    ln -sf "$settings_target" "$settings_link"
    echo "  $settings_link -> $settings_target"
  fi

  # Managed directories — create as real dirs (blueprint populates with per-entry symlinks)
  for d in "${MANAGED_DIRS[@]}"; do
    target="$dir/$d"
    if [ -L "$target" ]; then
      echo "  converting $target from whole-dir symlink to real dir"
      rm "$target"
      mkdir -p "$target"
    elif [ ! -d "$target" ]; then
      mkdir -p "$target"
      echo "  created $target/"
    fi
  done

  # Private dirs — still whole-directory symlinks (third-party plugin store)
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

# If blueprint exists, run it to populate the managed directories.
BOOTSTRAP="$HOME/bin/dotty-private/.claude/blueprint/bootstrap.sh"
if [ -x "$BOOTSTRAP" ]; then
  echo "Running blueprint apply..."
  bash "$BOOTSTRAP" "$@"
fi
