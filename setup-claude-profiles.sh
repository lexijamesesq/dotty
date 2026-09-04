#!/bin/bash
# setup-claude-profiles.sh — First-run profile bootstrap.
#
# Creates the two Claude Code profile directories and establishes the
# minimum viable state so that `blueprint apply` can take over from here.
# On a provisioned machine, `blueprint apply` is the ongoing authority —
# this script is for bare-metal only.
#
# Skills, the agent, and hooks are NOT symlinked from this checkout — they
# are installed as Claude Code plugins from the operator's marketplaces
# (work-lifecycle, wiki, operator) by the private blueprint's `plugins`
# slice, which runs after this script (see bootstrap.sh below). This repo
# carries no skills.
#
# `rules/` and `CLAUDE.md` are NOT written here either, as of the thin-layer
# rules/CLAUDE.md move: both are declared state now, installed by the
# private blueprint's `ways-of-working` and `claude-md` slices (real files,
# not a symlink or an `@` import into this checkout) — see bootstrap.sh
# below, which runs after this script. This script only creates the profile
# directory itself and points each profile's plugin cache at the shared
# real directory; nothing else needs pre-seeding.

PROFILES=("claude-professional" "claude-personal")

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

  # rules/ — real dir, populated by the blueprint's `ways-of-working` slice.
  # CLAUDE.md — real file, populated by the blueprint's `claude-md` slice.
  # settings.json — owned by settings-personal/settings-professional.
  # None of these are seeded here; the "Running blueprint apply..." step
  # below is the sole authority for all three.

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

# If blueprint exists, run it to populate rules/, CLAUDE.md, and everything else declared.
BOOTSTRAP="$HOME/bin/dotty-private/.claude/blueprint/bootstrap.sh"
if [ -x "$BOOTSTRAP" ]; then
  echo "Running blueprint apply..."
  bash "$BOOTSTRAP" "$@"
fi
