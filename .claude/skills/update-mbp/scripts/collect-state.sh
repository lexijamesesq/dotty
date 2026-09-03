#!/usr/bin/env bash
# Collect installed/configured state on a Mac for cross-machine comparison.
# Self-contained: no skill-internal dependencies. Safe to scp + run anywhere.
# Output is sectioned plain text. Each section is sorted where order is irrelevant.

set -uo pipefail

# Non-interactive SSH sessions don't get the user's login PATH. Prepend the
# common Homebrew prefixes so brew/mas/code/gh are findable when this script
# is invoked via `ssh host /path/collect-state.sh`.
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:$PATH"

emit() { printf '\n=== %s ===\n' "$1"; }

emit host
echo "hostname=$(hostname)"
echo "scutil_computername=$(scutil --get ComputerName 2>/dev/null || echo NA)"
echo "scutil_localhostname=$(scutil --get LocalHostName 2>/dev/null || echo NA)"
echo "arch=$(uname -m)"
echo "os_product=$(sw_vers -productName 2>/dev/null || echo NA)"
echo "os_version=$(sw_vers -productVersion 2>/dev/null || echo NA)"
echo "os_build=$(sw_vers -buildVersion 2>/dev/null || echo NA)"
echo "collected_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"

emit clt
xcode-select -p 2>/dev/null || echo "missing"
pkgutil --pkg-info=com.apple.pkg.CLTools_Executables 2>/dev/null | awk -F': ' '/^version/ {print "clt_version=" $2}'

emit rosetta
if /usr/bin/pgrep -q oahd 2>/dev/null; then echo "running"; else echo "not_running_or_native"; fi

emit brew_meta
if command -v brew >/dev/null 2>&1; then
  echo "brew_path=$(command -v brew)"
  echo "brew_prefix=$(brew --prefix 2>/dev/null)"
  echo "brew_version=$(brew --version 2>/dev/null | head -1)"
else
  echo "missing"
fi

emit brew_taps
command -v brew >/dev/null 2>&1 && brew tap 2>/dev/null | sort || echo "missing"

emit brew_formulae_leaves
# Top-level user-requested formulae only (excludes deps)
command -v brew >/dev/null 2>&1 && brew leaves --installed-on-request 2>/dev/null | sort || echo "missing"

emit brew_casks
command -v brew >/dev/null 2>&1 && brew list --cask 2>/dev/null | sort || echo "missing"

emit brew_outdated_formula
command -v brew >/dev/null 2>&1 && brew outdated --formula --quiet 2>/dev/null | sort || echo "missing"

emit brew_outdated_cask
# Without --greedy-auto-updates: only casks brew is confident need an upgrade.
# Apps that self-update (Chrome, Slack, 1Password, Arc, Raycast, etc.) are
# excluded so we don't fight their built-in updaters.
command -v brew >/dev/null 2>&1 && brew outdated --cask --quiet 2>/dev/null | sort || echo "missing"

emit brew_outdated_cask_auto_update_informational
# Casks brew tracks as outdated only because the app self-updated past brew's
# pinned version. Informational only — never auto-upgraded by this skill.
command -v brew >/dev/null 2>&1 && {
  all_greedy=$(brew outdated --cask --quiet --greedy-auto-updates 2>/dev/null | sort)
  confident=$(brew outdated --cask --quiet 2>/dev/null | sort)
  comm -23 <(echo "$all_greedy") <(echo "$confident")
} || echo "missing"

emit mas_signed_in
if command -v mas >/dev/null 2>&1; then
  mas account 2>&1 | head -1
else
  echo "mas_missing"
fi

emit mas_list
# id<TAB>name<TAB>version
command -v mas >/dev/null 2>&1 && mas list 2>/dev/null | sort -k1,1n || echo "missing"

emit mas_outdated
command -v mas >/dev/null 2>&1 && mas outdated 2>/dev/null | sort -k1,1n || echo "missing"

emit softwareupdate
softwareupdate -l 2>&1 | grep -E '(Label|Recommended|Title)' | head -40 || true

emit vscode_extensions
if command -v code >/dev/null 2>&1; then
  code --list-extensions --show-versions 2>/dev/null | sort
else
  echo "missing"
fi

emit ghostty_config
# Config is expected to be a symlink into dotty-private, so it travels with the git pull lane.
F="$HOME/Library/Application Support/com.mitchellh.ghostty/config"
if [ -L "$F" ]; then
  echo "state=symlink"
  # Prefix every line, not just the first: a symlink target may contain newlines,
  # and an unprefixed continuation line could forge a `=== section ===` marker.
  readlink "$F" | sed 's/^/target=/'
  echo "resolves=$([ -e "$F" ] && echo true || echo false)"
elif [ -f "$F" ]; then
  echo "state=regular"
  echo "sha256=$(shasum -a 256 "$F" | awk '{print $1}')"
else
  echo "state=absent"
fi

emit claude_code_meta
[ -f "$HOME/.claude.json" ] && echo "claude_json=present" || echo "claude_json=missing"
[ -d "$HOME/.claude-personal" ] && echo "claude_personal_dir=present" || echo "claude_personal_dir=missing"
[ -d "$HOME/.claude-professional" ] && echo "claude_professional_dir=present" || echo "claude_professional_dir=missing"
if command -v claude >/dev/null 2>&1; then
  echo "claude_cli_path=$(command -v claude)"
  claude --version 2>/dev/null | sed 's/^/claude_cli_version=/' || true
else
  echo "claude_cli=missing"
fi

emit dotty_repos
for repo in "$HOME/bin/dotty" "$HOME/bin/dotty-private"; do
  if [ -d "$repo/.git" ]; then
    name=$(basename "$repo")
    head=$(git -C "$repo" rev-parse HEAD 2>/dev/null)
    branch=$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null)
    dirty=$(git -C "$repo" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    upstream=$(git -C "$repo" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || echo none)
    ahead_behind=$(git -C "$repo" rev-list --left-right --count 'HEAD...@{u}' 2>/dev/null || echo "?	?")
    echo "${name}_branch=${branch}"
    echo "${name}_head=${head}"
    echo "${name}_dirty_files=${dirty}"
    echo "${name}_upstream=${upstream}"
    echo "${name}_ahead_behind=${ahead_behind}"
  else
    echo "$(basename "$repo")=missing"
  fi
done

emit git_repos_outside_vault
# Find git repos in $HOME, excluding the Obsidian vault and node_modules/Library noise.
# Obsidian Sync handles vault content; we care about everything else with a remote.
find "$HOME" \
  -maxdepth 5 \
  -type d \
  \( -name node_modules -o -name Library -o -name .Trash -o -name "Vaults" -o -name ".cache" -o -name ".npm" -o -name ".gem" -o -name "go" -o -name ".cargo" -o -name ".rustup" \) -prune \
  -o -type d -name .git -print 2>/dev/null \
| while read -r gitdir; do
    repo="${gitdir%/.git}"
    rel="${repo#"$HOME"/}"
    head=$(git -C "$repo" rev-parse HEAD 2>/dev/null || echo none)
    branch=$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null || echo none)
    remote=$(git -C "$repo" config --get remote.origin.url 2>/dev/null || echo none)
    dirty=$(git -C "$repo" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    printf '%s|branch=%s|head=%s|dirty=%s|remote=%s\n' "$rel" "$branch" "$head" "$dirty" "$remote"
  done | sort

emit obsidian_app
F="$HOME/Library/Application Support/obsidian"
if [ -d "$F" ]; then
  echo "support_dir=present"
  find "$F" -mindepth 1 -maxdepth 1 -exec basename {} \; 2>/dev/null | sort | sed 's/^/entry=/'
else
  echo "support_dir=missing"
fi
# Obsidian itself usually installs as a cask; check version if present
if [ -d "/Applications/Obsidian.app" ]; then
  v=$(defaults read "/Applications/Obsidian.app/Contents/Info" CFBundleShortVersionString 2>/dev/null)
  echo "obsidian_app_version=${v:-unknown}"
else
  echo "obsidian_app=missing"
fi

emit obsidian_vault_plugins
# Plugins are per-vault under .obsidian/plugins/. Set VAULT_ROOT (same env var
# used by dotty's vault-aware hooks) to your vault's absolute path to enable
# this section; skipped if unset — this script has no built-in guess at where
# your vault lives.
vault="${VAULT_ROOT:-}"
if [ -z "$vault" ]; then
  echo "vault=unset  # export VAULT_ROOT to enable"
elif [ -d "$vault/.obsidian" ]; then
  echo "vault=$vault"
  if [ -d "$vault/.obsidian/plugins" ]; then
    for p in "$vault/.obsidian/plugins"/*/; do
      [ -d "$p" ] || continue
      name=$(basename "$p")
      ver=$(grep -h '"version"' "$p/manifest.json" 2>/dev/null | head -1 | sed 's/.*"version" *: *"\([^"]*\)".*/\1/')
      echo "plugin=${name}@${ver:-?}"
    done | sort
  fi
  # Themes
  if [ -d "$vault/.obsidian/themes" ]; then
    for t in "$vault/.obsidian/themes"/*/; do
      [ -d "$t" ] || continue
      echo "theme=$(basename "$t")"
    done | sort
  fi
else
  echo "vault=$vault  # no .obsidian dir found there"
fi

emit ssh_known_keys
find "$HOME/.ssh" -maxdepth 1 -name '*.pub' -exec basename {} \; 2>/dev/null | sort

emit shell_meta
echo "shell=$SHELL"
[ -f "$HOME/.zshrc" ] && echo "zshrc=present sha=$(shasum -a 256 "$HOME/.zshrc" | awk '{print $1}')" || echo "zshrc=missing"
[ -f "$HOME/.zshenv" ] && echo "zshenv=present sha=$(shasum -a 256 "$HOME/.zshenv" | awk '{print $1}')" || echo "zshenv=missing"

emit fonts_homebrew_casks_only
command -v brew >/dev/null 2>&1 && brew list --cask 2>/dev/null | grep -i '^font-' | sort || true

emit claude_hooks_health
# Sanity checks for the estate-hooks plugin deployment (installed, not
# symlinked from a dotty checkout). Flag-only — no auto-fix.
# Expected on every machine that runs Claude Code with the harness wired up.
if command -v jq >/dev/null 2>&1; then
  echo "jq=present version=$(jq --version 2>/dev/null)"
else
  echo "jq=missing  # required by session-init.sh, vault-mcp-redirect.sh, fix-obsidian-claude-sync.sh; install: brew install jq"
fi
CLAUDE_CLI="$(command -v claude || echo "$HOME/.local/bin/claude")"
# Per-profile, not one hardcoded settings.json: ~/.claude-personal and
# ~/.claude-professional are the stable, profile-scoped entry points Claude
# Code itself resolves — true regardless of what's on the other end.
for _profile in personal professional; do
  SETTINGS="$HOME/.claude-$_profile/settings.json"
  PLUGIN_JSON=""
  if command -v "$CLAUDE_CLI" >/dev/null 2>&1; then
    PLUGIN_JSON=$(CLAUDE_CONFIG_DIR="$HOME/.claude-$_profile" "$CLAUDE_CLI" plugin list --json 2>/dev/null)
  fi
  install_path=""
  if [ -n "$PLUGIN_JSON" ] && command -v jq >/dev/null 2>&1; then
    version=$(printf '%s' "$PLUGIN_JSON" | jq -r '.[] | select(.id == "estate-hooks@work-lifecycle") | .version // empty' 2>/dev/null)
    enabled=$(printf '%s' "$PLUGIN_JSON" | jq -r '.[] | select(.id == "estate-hooks@work-lifecycle") | .enabled // false' 2>/dev/null)
    install_path=$(printf '%s' "$PLUGIN_JSON" | jq -r '.[] | select(.id == "estate-hooks@work-lifecycle") | .installPath // empty' 2>/dev/null)
    echo "estate_hooks_installed_${_profile}=${version:-missing}"
    echo "estate_hooks_enabled_${_profile}=${enabled:-false}"
  else
    echo "estate_hooks_installed_${_profile}=missing  # claude CLI or 'plugin list --json' unavailable"
    echo "estate_hooks_enabled_${_profile}=false"
  fi
  if [ -f "$SETTINGS" ] && command -v jq >/dev/null 2>&1; then
    if jq -e '(.hooks // {}) == {}' "$SETTINGS" >/dev/null 2>&1; then
      echo "hooks_block_empty_${_profile}=true"
    else
      echo "hooks_block_empty_${_profile}=false  # expected {} once estate-hooks is enabled for this profile"
    fi
  else
    echo "hooks_block_empty_${_profile}=missing  # settings file not found at $SETTINGS"
  fi
  if [ -n "$install_path" ] && [ -d "$install_path" ]; then
    find "$install_path" -type f -name '*.sh' 2>/dev/null | sort | while read -r hook; do
      echo "estate_hooks_sha_${_profile}_$(basename "$hook")=$(shasum -a 256 "$hook" | awk '{print $1}')"
    done
  else
    echo "estate_hooks_sha_${_profile}=missing  # enabled plugin's installPath not found"
  fi
done
if [ -d "$HOME/.cache/claude" ]; then
  echo "cache_dir=present perms=$(stat -f '%Lp' "$HOME/.cache/claude" 2>/dev/null || stat -c '%a' "$HOME/.cache/claude" 2>/dev/null)"
else
  echo "cache_dir=missing  # auto-created by session-init.sh on first session start"
fi

emit blueprint_declared_files
# Presence + sha256 (never contents) of every machine-fixed-path file a
# dotty-private blueprint slice installs (LEX-718) -- so a machine missing
# one is a visible drift, not a silent gap discovered only when a skill
# fails to find its rosters/vocab/config file. New slices of this class
# (single declared file -> one fixed path) just need one more line here.
for entry in \
  "rosters|$HOME/.config/estate/tag-taxonomy-rosters.md" \
  "qa_private_vocab|$HOME/.config/estate/qa-private-vocab.md" \
  "metrics_config_jira|$HOME/Repos/Metrics/jira-config.md" \
  "metrics_config_pendo|$HOME/Repos/Metrics/pendo-config.md" \
; do
  name="${entry%%|*}"
  path="${entry#*|}"
  if [ -f "$path" ]; then
    echo "${name}=present sha256=$(shasum -a 256 "$path" | awk '{print $1}')"
  else
    echo "${name}=missing"
  fi
done

emit hazel_seed_presence
# NOT blueprint-managed -- hazel's own documented design is a deliberate,
# undeclared hand-carry for this single-copy PII file (LEX-718 ruling,
# system-d0 comment 8fe93003: "no hazel file is modified by this ticket").
# Presence-only report so a machine lacking it is visible, never silent.
F="$HOME/Agents/hazel/dev/seed/real-seed.json"
if [ -f "$F" ]; then
  echo "real_seed_json=present"
else
  echo "real_seed_json=missing  # hand-carried by design, not synced -- see hazel/DEPLOYMENT.md:1012"
fi

emit "done"
echo "ok"
