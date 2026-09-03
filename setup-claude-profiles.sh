#!/bin/bash
# setup-claude-profiles.sh — First-run profile bootstrap.
#
# Creates the two Claude Code profile directories and establishes the
# minimum viable state so that `blueprint apply` can take over from here.
# On a provisioned machine, `blueprint apply` is the ongoing authority —
# this script is for bare-metal only.
#
# Skills, the agent, and hooks are NOT symlinked from this checkout — they
# are installed as Claude Code plugins from the operator's `work-lifecycle`
# marketplace by the private blueprint's `plugins` slice, which runs after
# this script (see bootstrap.sh below). This script only prepares the
# managed directories the blueprint's core slice still populates by symlink
# (rules, and the handful of skills with no packaged-plugin home yet) and
# points each profile's plugin cache at the shared real directory.

PROFILES=("claude-professional" "claude-personal")

# Directories that blueprint's core slice manages via per-entry symlinks.
# This script creates them as real directories; blueprint populates them.
# Agents are not listed here — the agent ships from the installed plugin.
MANAGED_DIRS=("skills" "rules")

# Real directory the installed Claude Code plugins live in (machine-wide,
# outside any git working tree). Both profiles' `plugins` point here.
PLUGINS_STORE="$HOME/.local/share/claude-estate/plugins"

# Operator gitleaks rules load from the fixed install path (gl_preflight,
# git-hooks/gitleaks-common.sh) — installed by the blueprint's gitleaks-rules
# slice (`apply`), not by this bootstrap script. There is no per-repo symlink
# to create here.

for profile in "${PROFILES[@]}"; do
  dir="$HOME/.$profile"
  mkdir -p "$dir"

  # CLAUDE.md — real file with @ import (not a symlink)
  claude_md="$dir/CLAUDE.md"
  if [ ! -e "$claude_md" ]; then
    echo "@~/bin/dotty-private/.claude/CLAUDE.md" > "$claude_md"
    echo "  created $claude_md (@ import)"
  fi

  # settings.json — owned by the blueprint's settings-personal/settings-professional
  # slice (declared state in dotty-private, applied into a real file here — no
  # symlink). The "Running blueprint apply..." step below seeds and populates it;
  # nothing to do here.

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

  # Installed-plugin cache — real dir outside any checkout, both profiles
  # symlinked to the same shared store (install is machine-wide, enable is
  # per profile; the blueprint's `plugins` slice does the install/enable).
  mkdir -p "$PLUGINS_STORE"
  plugins_link="$dir/plugins"
  if [ -L "$plugins_link" ]; then
    existing_target="$(readlink "$plugins_link")"
    if [ "$existing_target" != "$PLUGINS_STORE" ]; then
      echo "  $plugins_link already links elsewhere ($existing_target) — leaving it; relocate any live plugin cache by hand before pointing it at $PLUGINS_STORE"
    fi
  else
    if [ -e "$plugins_link" ]; then
      echo "  $plugins_link exists and is not a symlink — leaving it; relocate by hand before pointing it at $PLUGINS_STORE"
    else
      ln -sf "$PLUGINS_STORE" "$plugins_link"
      echo "  $plugins_link -> $PLUGINS_STORE"
    fi
  fi

  echo "Profile directory ready: $dir"
done

# If blueprint exists, run it to populate the managed directories.
BOOTSTRAP="$HOME/bin/dotty-private/.claude/blueprint/bootstrap.sh"
if [ -x "$BOOTSTRAP" ]; then
  echo "Running blueprint apply..."
  bash "$BOOTSTRAP" "$@"
fi
