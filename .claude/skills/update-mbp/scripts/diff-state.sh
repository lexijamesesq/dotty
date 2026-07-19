#!/usr/bin/env bash
# Compare two state dumps from collect-state.sh and emit a report.
# Usage: diff-state.sh <baseline> <target>
#   baseline = source-of-truth machine (Mini)
#   target   = machine being audited/updated (MBP)
#
# Output is two parts:
#   1. Section-by-section human report (stdout)
#   2. Machine-readable apply hints (lines starting with APPLY:)
#      consumed by apply phase. Each APPLY: line is one independent action.

set -uo pipefail

BASE="${1:?baseline state file}"
TGT="${2:?target state file}"

[ -f "$BASE" ] || { echo "missing baseline: $BASE" >&2; exit 1; }
[ -f "$TGT"  ] || { echo "missing target: $TGT"  >&2; exit 1; }

# Exclusions file: items the user has previously marked "not relevant" so they
# stop appearing in the missing-on-target picker. Lives next to this script.
# Format: one entry per line, of the form `kind=value` where kind is one of
#   formula, cask, mas, repo
# Lines starting with `#` and blank lines are ignored. A trailing `# comment`
# is allowed.
EXCLUSIONS_FILE="$(cd "$(dirname "$0")" && pwd)/../exclusions.txt"
load_exclusions() {
  local kind="$1"
  [ -f "$EXCLUSIONS_FILE" ] || return 0
  awk -v k="$kind" -F'#' '
    { sub(/[ \t]+$/, "", $1); if ($1 == "") next }
    $1 ~ "^"k"=" { sub("^"k"=", "", $1); print $1 }
  ' "$EXCLUSIONS_FILE"
}
is_excluded() {
  # Match val against each exclusion entry as a shell glob, so values like
  # `.gemini/*` exclude any repo path under .gemini/, while plain `gitstatus`
  # still works as an exact match.
  local kind="$1" val="$2" pattern
  while IFS= read -r pattern; do
    [ -z "$pattern" ] && continue
    # shellcheck disable=SC2254  # intentional: $pattern is a glob, not a literal
    case "$val" in
      $pattern) return 0 ;;
    esac
  done < <(load_exclusions "$kind")
  return 1
}

# Extract a named section from a state file.
section() {
  local file="$1" name="$2"
  awk -v s="=== $name ===" '
    $0 == s { in_s=1; next }
    /^=== / { in_s=0 }
    in_s { print }
  ' "$file" | sed '/^[[:space:]]*$/d'
}

# Fetch a single key=value line's value from a section.
kv() {
  local file="$1" name="$2" key="$3"
  section "$file" "$name" | awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/,""); print; exit}'
}

hr() { printf '\n%s\n' "────────────────────────────────────────────────────────"; }
hd() { printf '\n## %s\n' "$1"; }

base_host=$(kv "$BASE" host scutil_computername)
tgt_host=$(kv "$TGT"  host scutil_computername)
base_os=$(kv "$BASE" host os_version)
tgt_os=$(kv "$TGT"  host os_version)

echo "# update-mbp state report"
echo "baseline : $base_host (macOS $base_os)"
echo "target   : $tgt_host (macOS $tgt_os)"
echo "generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"

hd "macOS minor updates available on target"
# softwareupdate -l output. Filter to same major track as target's os_version.
target_major=$(printf '%s' "$tgt_os" | cut -d. -f1)
section "$TGT" softwareupdate | while IFS= read -r line; do
  if printf '%s' "$line" | grep -qE 'macOS .* (Version: '"$target_major"'\.)'; then
    echo "MINOR (apply): $line"
    label=$(printf '%s' "$line" | sed -nE 's/.*Label: ([^,]+),.*/\1/p')
    [ -n "$label" ] && echo "APPLY: macos_minor label=\"$label\""
  elif printf '%s' "$line" | grep -qE 'Title: macOS .* Version: [0-9]+'; then
    echo "MAJOR (skip — held back intentionally): $line"
  elif printf '%s' "$line" | grep -qE 'Title: Safari'; then
    label=$(printf '%s' "$line" | sed -nE 's/.*Label: ([^,]+),.*/\1/p')
    echo "Safari update: $line"
    [ -n "$label" ] && echo "APPLY: macos_minor label=\"$label\""
  else
    echo "$line"
  fi
done

hd "Homebrew formulae outdated on target"
section "$TGT" brew_outdated_formula | grep -v '^missing$' | while read -r f; do
  [ -n "$f" ] && { echo "  $f"; echo "APPLY: brew_upgrade_formula name=$f"; }
done

hd "Homebrew casks outdated on target"
section "$TGT" brew_outdated_cask | grep -v '^missing$' | while read -r c; do
  [ -n "$c" ] && { echo "  $c"; echo "APPLY: brew_upgrade_cask name=$c"; }
done

hd "Casks brew thinks are outdated but that self-update (informational)"
section "$TGT" brew_outdated_cask_auto_update_informational | grep -v '^missing$' | while read -r c; do
  [ -n "$c" ] && echo "  ~ $c (skipped — app handles its own updates)"
done

hd "Mac App Store apps outdated on target"
section "$TGT" mas_outdated | grep -v '^missing$' | while read -r line; do
  [ -n "$line" ] || continue
  echo "  $line"
  id=$(printf '%s' "$line" | awk '{print $1}')
  [ -n "$id" ] && echo "APPLY: mas_upgrade id=$id"
done

hd "Formulae installed on baseline but missing on target"
# Only consider top-level (leaves) — not transitive deps.
comm -23 \
  <(section "$BASE" brew_formulae_leaves | grep -v '^missing$' | sort -u) \
  <(section "$TGT"  brew_formulae_leaves | grep -v '^missing$' | sort -u) \
| while read -r f; do
    [ -n "$f" ] || continue
    if is_excluded formula "$f"; then
      echo "  - $f (excluded — see exclusions.txt)"
    else
      echo "  + $f"
      echo "APPLY: brew_install_formula name=$f"
    fi
  done

hd "Casks installed on baseline but missing on target"
comm -23 \
  <(section "$BASE" brew_casks | grep -v '^missing$' | sort -u) \
  <(section "$TGT"  brew_casks | grep -v '^missing$' | sort -u) \
| while read -r c; do
    [ -n "$c" ] || continue
    if is_excluded cask "$c"; then
      echo "  - $c (excluded — see exclusions.txt)"
      continue
    fi
    # Don't auto-install machine-specific casks (display drivers, hardware utils
    # tied to peripherals on the Mini). Flag for review only.
    case "$c" in
      logitech-*|elgato-*|sonos|loupedeck|drobo*|displaylink|*-mac-mini*)
        echo "  ? $c (machine-specific, skipping auto-apply)"
        ;;
      *)
        echo "  + $c"
        echo "APPLY: brew_install_cask name=$c"
        ;;
    esac
  done

hd "App Store apps installed on baseline but missing on target"
# mas list rows: <id>  <name>  (<version>)
comm -23 \
  <(section "$BASE" mas_list | grep -v '^missing$' | awk '{print $1}' | sort -u) \
  <(section "$TGT"  mas_list | grep -v '^missing$' | awk '{print $1}' | sort -u) \
| while read -r id; do
    [ -n "$id" ] || continue
    name=$(section "$BASE" mas_list | awk -v i="$id" '$1==i {$1=""; sub(/^ +/,""); print; exit}')
    if is_excluded mas "$id"; then
      echo "  - $id  $name (excluded — see exclusions.txt)"
    else
      echo "  + $id  $name"
      echo "APPLY: mas_install id=$id"
    fi
  done

hd "VS Code extensions on baseline but missing on target"
comm -23 \
  <(section "$BASE" vscode_extensions | grep -v '^missing$' | cut -d@ -f1 | sort -u) \
  <(section "$TGT"  vscode_extensions | grep -v '^missing$' | cut -d@ -f1 | sort -u) \
| while read -r ext; do
    [ -n "$ext" ] && { echo "  + $ext"; echo "APPLY: vscode_install_ext id=$ext"; }
  done

hd "Ghostty config"
b_state=$(kv "$BASE" ghostty_config state)
t_state=$(kv "$TGT"  ghostty_config state)
b_target=$(kv "$BASE" ghostty_config target)
t_target=$(kv "$TGT"  ghostty_config target)
t_resolves=$(kv "$TGT" ghostty_config resolves)
# Normalize ~ vs $HOME so the two machines' symlink targets compare fairly.
norm() { printf '%s' "$1" | sed -e "s|^~|$HOME|" -e 's|/$||'; }
echo "  baseline: $b_state${b_target:+ -> $b_target}"
echo "  target:   $t_state${t_target:+ -> $t_target}"
if [ "$t_state" = absent ] && [ "$b_state" = absent ]; then
  echo "  → not configured on either machine; nothing to sync."
elif [ "$t_state" != symlink ]; then
  echo "  → target is not symlinked into dotty-private; config will NOT travel with the git pull lane. Review manually."
elif [ "$t_resolves" != true ]; then
  echo "  → target symlink is dangling ($t_target); Ghostty is running without its config. Review manually."
elif [ "$b_state" != symlink ]; then
  echo "  → target is symlinked correctly, but the baseline is $b_state — nothing to compare against. Review the baseline manually."
elif [ "$(norm "$b_target")" != "$(norm "$t_target")" ]; then
  echo "  → both symlinked but to different paths; review manually."
else
  echo "  → both symlinked to the same dotty-private path; config travels via the git pull lane — in sync."
fi

hd "Claude Code setup"
for k in claude_json claude_personal_dir claude_professional_dir claude_cli; do
  bv=$(kv "$BASE" claude_code_meta "$k"); tv=$(kv "$TGT" claude_code_meta "$k")
  if [ "$bv" != "$tv" ]; then
    echo "  $k: baseline=$bv  target=$tv"
  fi
done
b_cli=$(kv "$BASE" claude_code_meta claude_cli_version)
t_cli=$(kv "$TGT"  claude_code_meta claude_cli_version)
if [ -n "$b_cli$t_cli" ] && [ "$b_cli" != "$t_cli" ]; then
  echo "  claude CLI version: baseline=$b_cli  target=$t_cli"
fi

hd "dotty repo sync state"
for repo in dotty dotty-private; do
  for k in branch head dirty_files ahead_behind; do
    bv=$(kv "$BASE" dotty_repos "${repo}_${k}")
    tv=$(kv "$TGT"  dotty_repos "${repo}_${k}")
    if [ "$bv" != "$tv" ]; then
      echo "  ${repo}.${k}: baseline=$bv  target=$tv"
    fi
  done
done
# If MBP behind on either repo, we'll pull as part of apply.
for repo in dotty dotty-private; do
  t_dirty=$(kv "$TGT"  dotty_repos "${repo}_dirty_files")
  if [ "$t_dirty" != "0" ] && [ -n "$t_dirty" ]; then
    echo "  ⚠ $repo on target has $t_dirty dirty file(s); skipping auto-pull"
  else
    echo "APPLY: git_pull repo=$repo"
  fi
done

hd "Git repos outside vault — present on baseline but absent on target"
# Match by relative path. We don't auto-clone; just report so user can decide.
comm -23 \
  <(section "$BASE" git_repos_outside_vault | cut -d'|' -f1 | sort -u) \
  <(section "$TGT"  git_repos_outside_vault | cut -d'|' -f1 | sort -u) \
| while read -r r; do
    [ -n "$r" ] || continue
    if is_excluded repo "$r"; then
      echo "  - $r (excluded — see exclusions.txt)"
    else
      echo "  ? $r (review — not auto-cloned)"
    fi
  done

hd "Git repos present on both — branch/HEAD divergence"
# shellcheck disable=SC2034  # branch/dirty/remote fields are positional filler; only path + head are consumed
section "$BASE" git_repos_outside_vault | while IFS='|' read -r path b_branch b_head b_dirty b_remote; do
  [ -n "$path" ] || continue
  tline=$(section "$TGT" git_repos_outside_vault | awk -F'|' -v p="$path" '$1==p {print; exit}')
  [ -z "$tline" ] && continue
  t_head=$(printf '%s' "$tline" | awk -F'|' '{print $3}' | sed 's/head=//')
  b_head_v=$(printf '%s' "$b_head" | sed 's/head=//')
  if [ "$b_head_v" != "$t_head" ]; then
    echo "  ↻ $path baseline=$b_head_v  target=$t_head"
    # Only auto-pull repos already known to be safe. Built-in allowlist covers this
    # skill's own home + a common third-party framework; extend by editing the
    # case below for your own additional repos.
    case "$path" in
      bin/dotty|bin/dotty-private|.oh-my-zsh|.oh-my-zsh/*)
        echo "APPLY: git_pull_path path=$path"
        ;;
      *)
        echo "    (manual — not in auto-pull allowlist)"
        ;;
    esac
  fi
done

hd "Obsidian"
b_av=$(kv "$BASE" obsidian_app obsidian_app_version)
t_av=$(kv "$TGT"  obsidian_app obsidian_app_version)
if [ "$b_av" != "$t_av" ]; then
  echo "  Obsidian app: baseline=$b_av  target=$t_av"
  echo "  → Obsidian app updates itself; or if installed via Homebrew cask, will be covered by 'brew upgrade --cask obsidian' if outdated above."
fi
# Plugins/themes are vault-resident and synced via Obsidian Sync; just report.
b_plugins=$(section "$BASE" obsidian_vault_plugins | grep '^plugin=' | sort -u)
t_plugins=$(section "$TGT"  obsidian_vault_plugins | grep '^plugin=' | sort -u)
b_count=$(printf '%s\n' "$b_plugins" | grep -c '^plugin=' || true)
t_count=$(printf '%s\n' "$t_plugins" | grep -c '^plugin=' || true)
echo "  vault plugins: baseline=$b_count  target=$t_count (synced via Obsidian Sync)"
if [ "$b_count" != "$t_count" ] && [ "$b_count" -gt 0 ]; then
  diff <(printf '%s\n' "$b_plugins") <(printf '%s\n' "$t_plugins") | sed 's/^/    /'
fi

hd "Shell config (zsh)"
b_zshrc=$(kv "$BASE" shell_meta zshrc)
t_zshrc=$(kv "$TGT"  shell_meta zshrc)
if [ "$b_zshrc" != "$t_zshrc" ]; then
  echo "  ~/.zshrc: baseline=$b_zshrc"
  echo "            target  =$t_zshrc"
  echo "  → .zshrc is symlinked into ~/bin/dotty/ via stow on most setups; verify symlink target matches dotty repo."
fi
