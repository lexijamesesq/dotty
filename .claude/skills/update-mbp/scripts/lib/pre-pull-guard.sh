#!/usr/bin/env bash
# _ump_pre_pull_guard — refuse a dotty pull while a profile still symlinks a
# packaged skill into the checkout without the work-lifecycle plugin enabled
# for that profile.
#
# Why this exists: a dotty pull deletes the packaged skill directories once
# the harness cutover ships. If a profile's skills/<name> entries still link
# into that checkout and work-lifecycle isn't enabled there, the pull leaves
# the profile with neither the symlink's target nor the plugin — every
# command "succeeds" but the skill resolves nowhere. This guard runs before
# any pull so that state can never be produced by an unattended apply.
#
# Shared source: embedded into the remote script apply-updates.sh generates
# (so it runs on the target host, before the pull) and read directly by this
# directory's guard test, so both run the exact same logic. Sourcing this
# file only defines the function below — nothing executes on source.
#
# The four skills below have no installed-plugin replacement yet and stay
# declared and linked into dotty until each is given a plugin or thin-layer
# home; the guard does not fire for them.
_UMP_STILL_LINKED_SKILLS=(lexi-persona new-project system-blueprint update-mbp)

_ump_pre_pull_guard() {
  local profile profile_dir skills_dir settings entry name kept skip target

  for profile in personal professional; do
    profile_dir="$HOME/.claude-$profile"
    [ -d "$profile_dir" ] || continue
    skills_dir="$profile_dir/skills"
    [ -d "$skills_dir" ] || continue
    settings="$profile_dir/settings.json"

    for entry in "$skills_dir"/*; do
      [ -L "$entry" ] || continue
      name=$(basename "$entry")

      skip=0
      for kept in "${_UMP_STILL_LINKED_SKILLS[@]}"; do
        if [ "$name" = "$kept" ]; then
          skip=1
          break
        fi
      done
      [ "$skip" = "1" ] && continue

      target=$(readlink "$entry")
      case "$target" in
        "$HOME/bin/dotty/.claude/skills"/*) ;;
        *) continue ;;
      esac

      if command -v jq >/dev/null 2>&1 && [ -f "$settings" ] \
         && jq -e '.enabledPlugins["work-lifecycle@work-lifecycle"] == true' "$settings" >/dev/null 2>&1; then
        continue
      fi

      echo "refusing to pull dotty: $profile still links $name into the checkout and the work-lifecycle plugin is not enabled — run the harness cutover sitting first (see README)" >&2
      return 1
    done
  done
  return 0
}
