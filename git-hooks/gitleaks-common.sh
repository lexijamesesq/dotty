#!/usr/bin/env bash
# gitleaks-common.sh — shared helpers for the fail-closed gitleaks
# git-lifecycle hooks (gitleaks-staged.sh, gitleaks-pre-push.sh,
# gitleaks-commit-msg.sh) and the PreToolUse PR guard (gh-pr-body-guard.sh).
#
# FAIL-CLOSED contract: any inability to complete a scan — missing binary,
# unresolvable config, unresolvable commit range, scanner error — is a BLOCK,
# never a silent pass. gitleaks' `git --log-opts` is known to exit 0 on an
# unresolvable range (see gitleaks-pre-push.sh); the caller compensates. LLM
# review layers are advisory; THIS layer is mechanical enforcement.
#
# OPERATOR-RULES RESOLUTION (the thin-layer install). Every estate repo's
# .gitleaks.toml carries `[extend] path = ".gitleaks-operator-rules.toml"` — a
# checkout-relative token that gitleaks resolves against the PROCESS cwd. The
# operator ruleset itself is private and lives in exactly one installed place:
#
#     ${XDG_CONFIG_HOME:-$HOME/.config}/gitleaks/operator-rules.toml
#
# installed by the operator's blueprint (`gitleaks-rules` slice — `apply`), the
# Pi's deploy step, or a private-repo CI job at start. gl_preflight resolves the
# EFFECTIVE config for a scan, fixed path only:
#
#   1. fixed path readable  -> a temp copy of the repo config with ONLY the
#      [extend] path line rewritten to the fixed path's ABSOLUTE path (gitleaks
#      8.30.1 loads an absolute [extend] path from any cwd; the repo config's own
#      [allowlist]/[[rules]] are preserved verbatim). GL_RULES_SOURCE=fixed-path.
#      A checkout-relative symlink, present or not, is NOT consulted.
#   2. fixed path absent    -> BLOCK naming the install (gitleaks-rules apply).
#      There is no fallback: a checkout-relative symlink, if one is somehow
#      still present, is never consulted.
#   3. repo config with an ABSOLUTE [extend] path, or no [extend] path at all
#      (e.g. a `useDefault = true`-only config) -> unchanged, no injection.
#      A config that HAS an [extend] path key this parser cannot read -> BLOCK
#      (never "pass it through and let a leftover symlink decide").
#
# Callers use "$GL_EFFECTIVE_CONFIG" as their --config and remove
# "$GL_TMP_CONFIG" (empty when no temp copy was made) in their exit trap.
# gl_preflight prints nothing on success; callers may name GL_RULES_SOURCE.
#
# This file is sourced, not executed. It defines functions only.
#
# Spec: {workspace_root}/System/Knowledge/leak-prevention-architecture.md

# The globals below are consumed by the hooks that SOURCE this file, not here.
# shellcheck disable=SC2034

# hc_with_timeout and the .house-code.json readers: shared with house-code's
# own scaffold hooks (one definition, not a second copy) for gl_apply_private_profile below.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/house-code-common.sh"

# Outputs of gl_preflight (globals, so a sourcing hook can use them and clean up).
GL_EFFECTIVE_CONFIG=""
GL_RULES_SOURCE=""
GL_TMP_CONFIG=""

# gl_block <title> [line ...]
# Emit a formatted blocking message to stderr. Callers set their own exit 1.
# Never pass a matched secret/PII literal here — only rule ids and locations.
gl_block() {
    local title="$1"; shift
    {
        echo ""
        echo "──────────────────────────────────────────────────────────────"
        echo "  $title"
        echo "──────────────────────────────────────────────────────────────"
        local line
        for line in "$@"; do
            echo "  $line"
        done
        echo "──────────────────────────────────────────────────────────────"
        echo ""
    } >&2
}

# gl_fixed_rules_path
# Print the fixed install path of the operator ruleset (XDG default honored, so
# tests isolate themselves with XDG_CONFIG_HOME rather than touching $HOME).
gl_fixed_rules_path() {
    printf '%s/gitleaks/operator-rules.toml' "${XDG_CONFIG_HOME:-$HOME/.config}"
}

# gl_extend_path <config_file>
# Print the value of `path` under a `[extend]` section, or nothing.
# Handles single- or double-quoted values. Only inspects the [extend] section.
gl_extend_path() {
    local config="$1"
    awk '
        /^[[:space:]]*\[/ { in_extend = ($0 ~ /^[[:space:]]*\[extend\]/) ? 1 : 0; next }
        in_extend && /^[[:space:]]*path[[:space:]]*=/ {
            if (match($0, /"[^"]*"/))   { print substr($0, RSTART+1, RLENGTH-2); exit }
            if (match($0, /\x27[^\x27]*\x27/)) { print substr($0, RSTART+1, RLENGTH-2); exit }
        }
    ' "$config" 2>/dev/null
}

# gl_extend_has_path_key <config_file>
# Return 0 iff the [extend] section carries a `path` key at all (readable or
# not). Used to tell "no operator extend" (pass-through) apart from "an extend
# path this parser could not read" (BLOCK).
gl_extend_has_path_key() {
    local config="$1"
    awk '
        /^[[:space:]]*\[/ { in_extend = ($0 ~ /^[[:space:]]*\[extend\]/) ? 1 : 0; next }
        in_extend && /^[[:space:]]*path[[:space:]]*=/ { found = 1; exit }
        END { exit found ? 0 : 1 }
    ' "$config" 2>/dev/null
}

# gl_rewrite_extend <config_file> <absolute_rules_path> <out_file>
# Copy <config_file> to <out_file> with ONLY the first `path = ...` line inside
# the [extend] section replaced by `path = "<absolute_rules_path>"`. Every other
# byte is preserved. Returns non-zero if the write fails.
gl_rewrite_extend() {
    local config="$1" rules="$2" out="$3"
    awk -v rules="$rules" '
        /^[[:space:]]*\[/ { in_extend = ($0 ~ /^[[:space:]]*\[extend\]/) ? 1 : 0; print; next }
        in_extend && !done && /^[[:space:]]*path[[:space:]]*=/ {
            printf "path = \"%s\"\n", rules; done = 1; next
        }
        { print }
    ' "$config" > "$out" 2>/dev/null
}

# gl_rewrite_extend_base_only <config_file> <out_file>
# Copy <config_file> to <out_file> with the [extend] section's `path = ...`
# line replaced by `useDefault = true` — gitleaks' own stock ruleset, no
# operator content, no external file to keep alive after this call returns.
# Every other byte (including the repo's own [[rules]]/[allowlist], which
# live outside [extend]) is preserved verbatim — the same guarantee
# gl_rewrite_extend gives for the fixed-path case, just substituting a flag
# instead of a path. `useDefault` must be set on the config gitleaks
# is INVOKED with directly — empirically confirmed it is NOT honored when set
# only in a file reached via a nested [extend] (a two-level chain merges
# explicit [[rules]] fine, but does not propagate `useDefault`), so this
# rewrites the top-level effective config itself rather than pointing at a
# second synthetic file. Returns non-zero if the write fails.
gl_rewrite_extend_base_only() {
    local config="$1" out="$2"
    awk '
        /^[[:space:]]*\[/ { in_extend = ($0 ~ /^[[:space:]]*\[extend\]/) ? 1 : 0; print; next }
        in_extend && !done && /^[[:space:]]*path[[:space:]]*=/ {
            printf "useDefault = true\n"; done = 1; next
        }
        { print }
    ' "$config" > "$out" 2>/dev/null
}

# gl_rewrite_useDefault_false <config_file> <out_file>
# Copy <config_file> to <out_file> with the [extend] section's
# `useDefault = true` line flipped to `useDefault = false`. The installed
# operator-rules file (gl_fixed_rules_path) carries `useDefault = true` so
# per-repo configs chaining onto it via [extend] path inherit gitleaks'
# stock ruleset without re-declaring it — but that same inheritance also
# pulls in gitleaks' stock global ALLOWLIST (common binary/doc extensions,
# node_modules/, lockfiles, etc.), which a PR-chosen filename can land
# private-pattern content inside to defeat the scan entirely (live-verified:
# a name planted only in a `.png`- or `.bin`-named file, or under
# node_modules/, produced a clean "no leaks found" with useDefault=true —
# and full detection with it flipped false). The trusted lane's
# private-pattern-only scan runs the operator overlay STANDALONE, with this
# rewrite, precisely to not inherit that allowlist. Every other byte
# (the overlay's own [[rules]]) is preserved verbatim. Returns non-zero if
# the write fails or the input has no `useDefault = true` line to flip
# (fail-closed at the caller — a config with no such line was not built the
# way this rewrite assumes).
gl_rewrite_useDefault_false() {
    local config="$1" out="$2"
    awk '
        /^[[:space:]]*\[/ { in_extend = ($0 ~ /^[[:space:]]*\[extend\]/) ? 1 : 0; print; next }
        in_extend && !done && /^[[:space:]]*useDefault[[:space:]]*=[[:space:]]*true[[:space:]]*$/ {
            printf "useDefault = false\n"; done = 1; next
        }
        { print }
    ' "$config" > "$out" 2>/dev/null
}

# gl_preflight <config_file>
# Fail-closed preconditions for any scan, and the operator-rules resolution
# described in the header. Returns 0 with GL_EFFECTIVE_CONFIG / GL_RULES_SOURCE /
# GL_TMP_CONFIG set; otherwise emits a cause-specific gl_block and returns 1.
# gl_apply_private_profile
# The private-repo profile's gitleaks half: disables ONLY the enumerated
# public-disclosure rule (operator-network-domain-1) — never a path-scoped
# allowlist, never the roster/credential rules, which stay active in every
# repo regardless of visibility. `private_repo: true` in this repo's
# .house-code.json is a claim, verified live the same way house-code.py's
# verify_private_repo() does (git remote -> gh api .visibility); any
# failure to verify resolves to NOT private. Rewrites GL_EFFECTIVE_CONFIG
# (chaining onto whatever gl_preflight already resolved) only when verified;
# otherwise a no-op. Requires jq; if it's not on PATH this step is skipped
# (not a block — the base scan above already ran and jq's absence here
# only means the private-repo relaxation isn't available, the stricter,
# safe direction).
gl_apply_private_profile() {
    # Under GL_NO_OVERLAY (the universal CI's base-only routine lane) no real operator
    # ruleset is loaded at all, so there is no "operator-network-domain-1"
    # rule for this profile to relax — appending the stub rule below would
    # make gitleaks refuse the config (a rule with neither regex nor path).
    # A no-op here is correct, not a relaxation: nothing this profile would
    # have disabled is active in base-only mode either way.
    [[ -n "${GL_NO_OVERLAY:-}" || -n "${GL_OVERLAY_ONLY:-}" ]] && return 0
    command -v jq >/dev/null 2>&1 || return 0
    command -v gh >/dev/null 2>&1 || return 0
    hc_load_declaration || return 0
    hc_private_repo_verified || return 0

    local tmp
    tmp="$(mktemp 2>/dev/null)" || return 0
    cp "$GL_EFFECTIVE_CONFIG" "$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }
    cat >> "$tmp" <<'EOF'

[[rules]]
id = "operator-network-domain-1"
[rules.allowlist]
regexes = ['''.*''']
EOF
    [[ -n "$GL_TMP_CONFIG" ]] && rm -f "$GL_TMP_CONFIG"
    GL_EFFECTIVE_CONFIG="$tmp"; GL_TMP_CONFIG="$tmp"
    GL_RULES_SOURCE="${GL_RULES_SOURCE} + private_repo profile (operator-network-domain-1 disabled, verified live)"
}

gl_preflight() {
    local config="$1"
    GL_EFFECTIVE_CONFIG="$config"; GL_RULES_SOURCE=""; GL_TMP_CONFIG=""

    if ! command -v gitleaks >/dev/null 2>&1; then
        gl_block "BLOCKED: gitleaks is not installed" \
            "The mechanical secret/PII scanner is missing from PATH." \
            "This hook fails closed rather than push/commit unscanned." \
            "Install:  brew install gitleaks"
        return 1
    fi

    if [[ ! -f "$config" ]]; then
        gl_block "BLOCKED: gitleaks config not found" \
            "Expected: $config" \
            "Without the config the operator ruleset cannot be applied." \
            "Provision it via: setup-claude-profiles.sh"
        return 1
    fi

    # The extend-path parser is awk; without it this function cannot tell which
    # ruleset a config names, so it cannot let the scan proceed (fail-closed).
    if ! command -v awk >/dev/null 2>&1; then
        gl_block "BLOCKED: awk is not installed" \
            "The hook reads the config's [extend] path with awk and refuses to" \
            "guess which operator ruleset applies without it."
        return 1
    fi

    # GL_OVERLAY_ONLY: the trusted lane's private-pattern-only scan, run as a
    # SEPARATE gitleaks invocation from the base-rules scan (which keeps its
    # stock defaults). Goes straight to the fixed operator-rules path,
    # ignoring $config's own [extend] entirely -- this scan tests the
    # operator overlay standalone, not chained under the repo's config -- and
    # flips its useDefault to false so it inherits neither gitleaks' stock
    # ruleset NOR its stock global allowlist (see gl_rewrite_useDefault_false).
    # Same fail-closed discipline as the fixed-path branch below: absent or
    # unreadable is a BLOCK, never a silent fall-through.
    if [[ -n "${GL_OVERLAY_ONLY:-}" ]]; then
        local fixed tmp
        fixed="$(gl_fixed_rules_path)"
        if [[ ! -e "$fixed" && ! -L "$fixed" ]]; then
            gl_block "BLOCKED: operator ruleset is not installed" \
                "Expected: $fixed" \
                "GL_OVERLAY_ONLY scans the operator overlay standalone and has" \
                "nothing to fall back to. Install it via the blueprint (gitleaks-rules apply)."
            return 1
        fi
        if [[ ! -f "$fixed" || ! -r "$fixed" ]]; then
            gl_block "BLOCKED: installed operator ruleset is unreadable" \
                "Fixed path: $fixed" \
                "It exists but is not a readable file (broken symlink, wrong mode," \
                "or a directory). Reinstall it via the blueprint (gitleaks-rules apply)."
            return 1
        fi
        if ! tmp="$(mktemp 2>/dev/null)" || ! gl_rewrite_useDefault_false "$fixed" "$tmp" \
            || ! grep -q '^useDefault = false$' "$tmp"; then
            [[ -n "${tmp:-}" ]] && rm -f "$tmp"
            gl_block "BLOCKED: could not build the overlay-only effective config" \
                "Fixed path: $fixed" \
                "Rewriting its useDefault to false failed."
            return 1
        fi
        GL_EFFECTIVE_CONFIG="$tmp"; GL_TMP_CONFIG="$tmp"
        GL_RULES_SOURCE="operator overlay only, no stock defaults (GL_OVERLAY_ONLY)"
        gl_apply_private_profile
        return 0
    fi

    local ext rc=0
    ext="$(gl_extend_path "$config")"

    # No readable [extend] path.
    if [[ -z "$ext" ]]; then
        if gl_extend_has_path_key "$config"; then
            # The key is there but the value shape is one this parser cannot
            # read. Passing the config through would let gitleaks resolve it
            # from cwd — i.e. a leftover checkout symlink would decide. BLOCK.
            gl_block "BLOCKED: cannot parse the operator-rules extend path" \
                "Config: $config" \
                "Its [extend] section has a 'path' key whose value could not be read" \
                "(expected a single- or double-quoted string on one line)." \
                "Fix the config; the hook will not guess which ruleset applies."
            return 1
        fi
        GL_RULES_SOURCE="repo-config (no operator extend)"
    # An absolute [extend] path: the config already names its ruleset. Honor it.
    elif [[ "$ext" == /* ]]; then
        if [[ ! -e "$ext" ]]; then
            gl_block "BLOCKED: gitleaks operator ruleset is unresolvable" \
                "Config $config extends: $ext" \
                "Target does not resolve."
            return 1
        fi
        GL_RULES_SOURCE="repo-config (absolute extend: $ext)"
    elif [[ -n "${GL_NO_OVERLAY:-}" ]]; then
        # The universal CI's routine lane: base rules only, BY DESIGN — never the "fixed path
        # is absent" fallback below. Rewrites the [extend] `path = ...` line
        # to `useDefault = true` directly in a temp copy of the REPO's own
        # config (gl_rewrite_extend_base_only) — gitleaks' stock ruleset,
        # with the repo's own [[rules]]/[allowlist] (outside [extend])
        # preserved verbatim. Never a placeholder passed as --config, never
        # a second external file to keep alive after this call returns.
        local tmp
        if ! tmp="$(mktemp 2>/dev/null)" || ! gl_rewrite_extend_base_only "$config" "$tmp" \
            || ! grep -q '^useDefault = true$' "$tmp"; then
            [[ -n "${tmp:-}" ]] && rm -f "$tmp"
            gl_block "BLOCKED: could not build the base-only effective config" \
                "Config: $config" \
                "Rewriting its [extend] path to useDefault=true failed."
            return 1
        fi
        GL_EFFECTIVE_CONFIG="$tmp"; GL_TMP_CONFIG="$tmp"
        GL_RULES_SOURCE="base only by design (GL_NO_OVERLAY)"
    else
        # Relative [extend] path — the checkout-relative token. Fixed path first.
        local fixed
        fixed="$(gl_fixed_rules_path)"
        if [[ -e "$fixed" || -L "$fixed" ]]; then
            # Present but unusable (broken symlink, directory, unreadable) is a
            # misconfiguration of the install, never a reason to fall back.
            if [[ ! -f "$fixed" || ! -r "$fixed" ]]; then
                gl_block "BLOCKED: installed operator ruleset is unreadable" \
                    "Fixed path: $fixed" \
                    "It exists but is not a readable file (broken symlink, wrong mode," \
                    "or a directory). Reinstall it via the blueprint (gitleaks-rules apply)."
                return 1
            fi
            local tmp
            if ! tmp="$(mktemp 2>/dev/null)" || ! gl_rewrite_extend "$config" "$fixed" "$tmp" \
                || [[ "$(gl_extend_path "$tmp")" != "$fixed" ]]; then
                [[ -n "${tmp:-}" ]] && rm -f "$tmp"
                gl_block "BLOCKED: could not build the effective gitleaks config" \
                    "Config: $config" \
                    "Rewriting its [extend] path to the installed ruleset ($fixed) failed." \
                    "(Fail-closed: no derived config means no scan means no pass.)"
                return 1
            fi
            GL_EFFECTIVE_CONFIG="$tmp"; GL_TMP_CONFIG="$tmp"
            GL_RULES_SOURCE="fixed-path ($fixed)"
        else
            # Fixed path absent. No fallback: BLOCK naming the install.
            gl_block "BLOCKED: operator ruleset is not installed" \
                "Expected: $fixed" \
                "Config $config extends: $ext (checkout-relative, no longer consulted)." \
                "Install it via the blueprint (gitleaks-rules apply)."
            return 1
        fi
    fi

    gl_apply_private_profile
    return "$rc"
}

# gl_summarize_report <report_json>
# Print a SAFE per-finding summary (rule id + commit + file:line) to stdout.
# NEVER prints the Secret/Match fields. Uses jq when available; falls back to
# extracting only RuleID values (which disclose no literals) when jq is absent.
gl_summarize_report() {
    local report="$1"
    [[ -s "$report" ]] || return 0
    if command -v jq >/dev/null 2>&1; then
        jq -r '
            .[] |
            (if (.Commit // "") == "" then "(no commit)" else .Commit[0:12] end) as $c |
            "  [" + .RuleID + "]  " + $c + "  —  " + .File + ":" + (.StartLine | tostring)
        ' "$report" 2>/dev/null
    else
        echo "  (jq not installed — rule ids only; matched values withheld)"
        grep -oE '"RuleID":[[:space:]]*"[^"]*"' "$report" 2>/dev/null \
            | sed -E 's/.*"([^"]*)"$/  [\1]/' \
            | sort | uniq -c
    fi
}
