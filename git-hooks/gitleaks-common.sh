#!/usr/bin/env bash
# gitleaks-common.sh — shared helpers for the fail-closed gitleaks
# git-lifecycle hooks (gitleaks-pre-push.sh, gitleaks-commit-msg.sh).
#
# FAIL-CLOSED contract: any inability to complete a scan — missing binary,
# unresolvable config, unresolvable commit range, scanner error — is a BLOCK,
# never a silent pass. gitleaks' `git --log-opts` is known to exit 0 on an
# unresolvable range (see gitleaks-pre-push.sh); the caller compensates. LLM
# review layers are advisory; THIS layer is mechanical enforcement.
#
# This file is sourced, not executed. It defines functions only.
#
# Spec: {workspace_root}/System/Knowledge/leak-prevention-architecture.md

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

# gl_preflight <config_file>
# Fail-closed preconditions for any scan. Returns 0 if all pass; otherwise
# emits a cause-specific gl_block and returns 1.
gl_preflight() {
    local config="$1"

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

    # If the config extends another file (the operator ruleset symlink), that
    # target MUST resolve. A broken symlink or missing file is fail-closed:
    # gitleaks would FTL, but we name the cause and the fix here.
    local ext resolved
    ext="$(gl_extend_path "$config")"
    if [[ -n "$ext" ]]; then
        case "$ext" in
            /*) resolved="$ext" ;;
            *)  resolved="$(cd "$(dirname "$config")" && pwd)/$ext" ;;
        esac
        # -e follows symlinks and is false for a broken symlink → BLOCK.
        if [[ ! -e "$resolved" ]]; then
            gl_block "BLOCKED: gitleaks operator ruleset is unresolvable" \
                "Config $config extends: $ext" \
                "Target does not resolve: $resolved" \
                "(most likely a missing or broken symlink to the private ruleset)." \
                "Provision it via: setup-claude-profiles.sh"
            return 1
        fi
    fi
    return 0
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
