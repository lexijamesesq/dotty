#!/usr/bin/env bash
# gitleaks-common.sh — the small shared layer under the estate's gitleaks
# wrappers: gitleaks-staged.sh, gitleaks-commit-msg.sh, gitleaks-pre-push.sh
# and gitleaks-range-scan.sh (the CI diff-scoped scan).
#
# FAIL-CLOSED contract: any inability to complete a scan — missing binary,
# unresolvable config, unresolvable commit range, scanner error — is a BLOCK,
# never a silent pass. gitleaks' `git --log-opts` is known to exit 0 on an
# unresolvable range (#2129); gitleaks-range-scan.sh compensates.
#
# COMPOSITION IS GITLEAKS' OWN, NOT OURS. Every estate repo's .gitleaks.toml
# declares `[extend] path = "<token>"`, a repo-relative token. gitleaks resolves
# a relative `[extend] path` against the PROCESS cwd (verified, 8.30.1), and the
# operator ruleset lives at exactly one installed place:
#
#     ${XDG_CONFIG_HOME:-$HOME/.config}/gitleaks/operator-rules.toml
#
# installed by the operator's blueprint (`gitleaks-rules` slice — `apply`), the
# Pi's deploy step, or a CI job at start. That path is NOT expressible inside
# the repo's TOML: $HOME differs per machine (the Macs, the Colima runner, a
# GitHub-hosted runner) and TOML cannot interpolate an environment variable.
#
# So gl_resolve does not rewrite anybody's config. It builds a small RESOLUTION
# DIRECTORY holding one entry named by the repo config's own token, and names
# that directory as the cwd gitleaks runs from. The token then resolves to
# whatever that entry is:
#
#   default (local hooks)  entry -> a symlink to the installed overlay
#                          => base rules + operator overlay + the repo's own rules
#   GL_NO_OVERLAY          entry -> `[extend]\nuseDefault = true`
#                          => gitleaks' stock ruleset + the repo's own rules, by
#                             design, no operator content (the CI routine lane)
#
# PROVEN `useDefault` BEHAVIOUR, gitleaks 8.30.1 — do not re-derive it, and do
# not trust the older claim this file used to carry (that useDefault is "NOT
# honored when set only in a file reached via a nested [extend]"). Measured
# against the pinned version, both halves:
#   * useDefault DOES propagate UP through a nested extend. A repo config that
#     sets no useDefault, extending a file that sets `useDefault = true`, loads
#     gitleaks' stock ruleset. That is what makes GL_NO_OVERLAY a two-line stub
#     here instead of the awk rewrite of the repo's config it used to be.
#   * An outer `useDefault = false` does NOT override an extended file's own
#     `useDefault = true`. The inner true wins. That is why GL_OVERLAY_ONLY
#     below cannot be expressed as a wrapper config and needs the flip.
#
# Because the caller runs gitleaks from that directory, it passes the scan
# target as an EXPLICIT path argument and the config by ABSOLUTE path. It must
# also pass `-i` explicitly: gitleaks' --gitleaks-ignore-path defaults to ".",
# which is the resolution directory, not the repo.
#
# GL_OVERLAY_ONLY is the one mode a resolution directory cannot express. The
# trusted lane scans the operator overlay STANDALONE, with useDefault false so
# it inherits neither gitleaks' stock ruleset nor its stock global allowlist
# (live-verified receipt: a private pattern planted in a `.png`/`.bin`-named
# file, or under node_modules/, scanned clean under useDefault=true and was
# detected with it false — the stock allowlist is path-based and a PR chooses
# filenames). An outer config's `useDefault = false` does NOT override the
# extended overlay's own `useDefault = true` (verified, 8.30.1), so this mode,
# and only this mode, writes a temp copy of the overlay with that one line
# flipped. It is the single runtime config rewrite that remains.
#
# PRIVATE-REPO RELAXATION IS NOT HERE. A private repo that legitimately holds
# operator patterns declares its own relaxation in its own .gitleaks.toml
# (`[extend] disabledRules = [...]`) — gitleaks' native mechanism, which loads
# cleanly whether or not the overlay is present. There is no runtime
# private-repo detection in this layer. CI's trusted lane resolves its own
# per-repo profile from dotty's declared state (git-hooks/gate-resolve-profile.sh).
#
# This file is sourced, not executed. It defines functions only.
#
# Spec: {workspace_root}/System/Knowledge/leak-prevention-architecture.md

# The globals below are consumed by the hooks that SOURCE this file, not here.
# shellcheck disable=SC2034

# Outputs of gl_resolve. Callers pass GL_CONFIG as --config, run gitleaks from
# GL_CWD, and `rm -rf "$GL_SCRATCH"` in their exit trap (empty when none).
GL_CONFIG=""
GL_CWD=""
GL_SCRATCH=""
GL_RULES_SOURCE=""

# gl_block <title> [line ...]
# Need: a finding must be reportable without printing what matched (the PII
# rule). Emit a formatted blocking message to stderr; callers set their exit 1.
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

# gl_overlay_path
# Need: one install path, named once, with an XDG seam so the eval suite
# isolates itself with XDG_CONFIG_HOME instead of touching $HOME.
gl_overlay_path() {
    printf '%s/gitleaks/operator-rules.toml' "${XDG_CONFIG_HOME:-$HOME/.config}"
}

# gl_extend_token <config_file>
# Need: gl_resolve must name the resolution directory's entry after the token
# THIS repo's config actually uses — the estate is not uniform (dotty uses
# ".gitleaks-operator-rules.toml", dotty-private uses
# "gitleaks-operator-rules.toml"), so the token cannot be a constant.
# Prints the `path` value under `[extend]`, or nothing. Single- or
# double-quoted, one line. A token this cannot read is not guessed at: gitleaks
# then fails to load the config and the caller blocks on its FTL.
gl_extend_token() {
    awk '
        /^[[:space:]]*\[/ { in_extend = ($0 ~ /^[[:space:]]*\[extend\]/) ? 1 : 0; next }
        in_extend && /^[[:space:]]*path[[:space:]]*=/ {
            if (match($0, /"[^"]*"/))          { print substr($0, RSTART+1, RLENGTH-2); exit }
            if (match($0, /\x27[^\x27]*\x27/)) { print substr($0, RSTART+1, RLENGTH-2); exit }
        }
    ' "$1" 2>/dev/null
}

# gl_extend_has_path_key <config_file>
# Need: "gl_extend_token printed nothing" has two causes with opposite safe
# answers — this config names no operator ruleset (scan it as-is), or it names
# one in a shape this parser cannot read (block; treating it as "no overlay"
# would silently drop the operator rules from the scan). Returns 0 iff the
# [extend] section carries a `path` key at all.
gl_extend_has_path_key() {
    awk '
        /^[[:space:]]*\[/ { in_extend = ($0 ~ /^[[:space:]]*\[extend\]/) ? 1 : 0; next }
        in_extend && /^[[:space:]]*path[[:space:]]*=/ { found = 1; exit }
        END { exit found ? 0 : 1 }
    ' "$1" 2>/dev/null
}

# gl_resolve <absolute_config_path> <repo_root>
# Need: every wrapper needs the same three answers — which config, from which
# cwd, and what to clean up — and the fail-closed "the overlay this scan
# requires is not installed" block. Sets GL_CONFIG / GL_CWD / GL_SCRATCH /
# GL_RULES_SOURCE and returns 0, or emits a cause-specific gl_block and
# returns 1.
gl_resolve() {
    local config="$1" repo_root="$2" overlay token entry
    GL_CONFIG="$config"; GL_CWD="$repo_root"; GL_SCRATCH=""; GL_RULES_SOURCE=""
    overlay="$(gl_overlay_path)"

    if ! command -v gitleaks >/dev/null 2>&1; then
        gl_block "BLOCKED: gitleaks is not installed" \
            "The mechanical secret/PII scanner is missing from PATH." \
            "This hook fails closed rather than commit/push unscanned." \
            "Install:  brew install gitleaks"
        return 1
    fi

    # The trusted lane's standalone overlay pass. The repo's own config is not
    # consulted at all; the overlay is mandatory, and its useDefault is flipped
    # (see the header — the one remaining runtime rewrite, and why).
    if [[ -n "${GL_OVERLAY_ONLY:-}" ]]; then
        if [[ ! -f "$overlay" || ! -r "$overlay" ]]; then
            gl_block "BLOCKED: operator ruleset is not installed" \
                "Expected a readable file at: $overlay" \
                "GL_OVERLAY_ONLY scans the operator overlay standalone and has" \
                "nothing to fall back to. Install it via the blueprint (gitleaks-rules apply)."
            return 1
        fi
        GL_SCRATCH="$(mktemp -d 2>/dev/null)" || {
            gl_block "BLOCKED: could not create a scratch directory"; return 1; }
        if ! awk '{ sub(/^useDefault[[:space:]]*=[[:space:]]*true[[:space:]]*$/, "useDefault = false"); print }' \
                "$overlay" > "$GL_SCRATCH/overlay-only.toml" 2>/dev/null \
            || ! grep -q '^useDefault = false$' "$GL_SCRATCH/overlay-only.toml"; then
            gl_block "BLOCKED: could not build the overlay-only config" \
                "Overlay: $overlay" \
                "Flipping its useDefault to false failed, or it carries no" \
                "'useDefault = true' line to flip. (Fail-closed: an overlay-only" \
                "scan that silently inherits gitleaks' stock path allowlist can be" \
                "defeated by a PR-chosen filename.)"
            return 1
        fi
        GL_CONFIG="$GL_SCRATCH/overlay-only.toml"
        GL_RULES_SOURCE="operator overlay only, no stock defaults (GL_OVERLAY_ONLY)"
        return 0
    fi

    if [[ ! -f "$config" ]]; then
        gl_block "BLOCKED: gitleaks config not found" \
            "Expected: $config" \
            "Without the config the operator ruleset cannot be applied." \
            "Provision it via: setup-claude-profiles.sh"
        return 1
    fi

    token="$(gl_extend_token "$config")"

    # No extend token: this config names no operator ruleset, so none is
    # required. Its own rules (and useDefault, if it sets one) are the scan.
    if [[ -z "$token" ]]; then
        if gl_extend_has_path_key "$config"; then
            gl_block "BLOCKED: cannot parse the operator-rules extend path" \
                "Config: $config" \
                "Its [extend] section has a 'path' key whose value could not be read" \
                "(expected a single- or double-quoted string on one line)." \
                "Fix the config; this hook will not scan without the ruleset the" \
                "config says it needs."
            return 1
        fi
        GL_RULES_SOURCE="repo-config (no operator extend)"
        return 0
    fi

    # An absolute token: the config already names its ruleset and gitleaks
    # resolves it from any cwd. Honour it, in every mode.
    if [[ "$token" == /* ]]; then
        if [[ ! -e "$token" ]]; then
            gl_block "BLOCKED: gitleaks operator ruleset is unresolvable" \
                "Config $config extends: $token" \
                "Target does not resolve."
            return 1
        fi
        GL_RULES_SOURCE="repo-config (absolute extend: $token)"
        return 0
    fi

    GL_SCRATCH="$(mktemp -d 2>/dev/null)" || {
        gl_block "BLOCKED: could not create a scratch directory"; return 1; }
    entry="$GL_SCRATCH/$token"
    mkdir -p "$(dirname "$entry")" 2>/dev/null || {
        gl_block "BLOCKED: could not build the config resolution directory" \
            "Config $config extends the relative token: $token"
        return 1
    }

    if [[ -n "${GL_NO_OVERLAY:-}" ]]; then
        # CI's routine lane: gitleaks' stock ruleset, no operator content, BY
        # DESIGN — the repo's own [[rules]]/[allowlist] still apply, because the
        # repo's own config is what gitleaks loads, unmodified. useDefault is
        # honoured through a nested extend (verified, 8.30.1).
        printf '[extend]\nuseDefault = true\n' > "$entry" 2>/dev/null || {
            gl_block "BLOCKED: could not write the base-only extend target"; return 1; }
        GL_CWD="$GL_SCRATCH"
        GL_RULES_SOURCE="base only by design (GL_NO_OVERLAY)"
        return 0
    fi

    if [[ ! -f "$overlay" || ! -r "$overlay" ]]; then
        gl_block "BLOCKED: operator ruleset is not installed" \
            "Expected a readable file at: $overlay" \
            "Config $config extends the relative token '$token', which this scan" \
            "resolves to that installed ruleset. There is no fallback." \
            "Install it via the blueprint (gitleaks-rules apply)."
        return 1
    fi
    ln -sfn "$overlay" "$entry" 2>/dev/null || {
        gl_block "BLOCKED: could not point the extend token at the operator ruleset" \
            "Token: $token -> $overlay"
        return 1
    }
    GL_CWD="$GL_SCRATCH"
    GL_RULES_SOURCE="installed overlay ($overlay)"
    return 0
}

# gl_summarize_report <report_json>
# Need: the blocking message has to say WHICH rule fired and WHERE without
# printing the Secret/Match fields (the PII rule). jq when available; a rule-id
# count otherwise, which discloses no literals either.
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
