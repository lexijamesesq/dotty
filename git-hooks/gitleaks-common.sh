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
GL_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$GL_COMMON_DIR/house-code-common.sh"

# --- private-repo declaration: two trusted sources, OR-ed ---------------------
# A repo is "declared private" if EITHER its own .house-code.json says so OR
# dotty's co-shipped rulesets/default-branch.json (the SAME trusted map the CI
# gate-resolve-profile lane reads) lists it private by origin slug. hazel and
# dotty-private carry no .house-code.json, so the map is their only declaration
# — without this the local full-tree scan applies the operator identity overlay
# a private repo's lane deliberately drops, and the two lanes disagree (the
# hazel case). The live gh visibility check (hc_repo_visibility_is_private)
# stays the mandatory second factor; an unresolvable declaration stays stricter
# (overlay kept). GL_DECLARED_JSON overrides the map path (eval injection point).
gl_origin_slug() {
    local remote
    remote="$(git remote get-url origin 2>/dev/null)" || return 1
    printf '%s' "$remote" | sed -E 's#\.git$##; s#^.*[:/]([^/]+/[^/]+)$#\1#'
}
gl_map_declares_private() {   # <owner/repo>
    local slug="$1" map
    map="${GL_DECLARED_JSON:-$GL_COMMON_DIR/../rulesets/default-branch.json}"
    [[ -n "$slug" && -r "$map" ]] || return 1
    command -v jq >/dev/null 2>&1 || return 1
    jq -e --arg r "$slug" '.repos[$r].private_repo == true' "$map" >/dev/null 2>&1
}
gl_repo_declared_private() {
    hc_private_repo_declared && return 0          # source 1: the repo's own .house-code.json
    gl_map_declares_private "$(gl_origin_slug)"   # source 2: dotty's co-shipped declared map
}

# Outputs of gl_preflight (globals, so a sourcing hook can use them and clean up).
GL_EFFECTIVE_CONFIG=""
GL_RULES_SOURCE=""
GL_TMP_CONFIG=""

# Output of gl_mandatory_preflight (the native pre-push full-tree scanner's
# config — resolved from the LANE-controlled env modes and the installed
# overlay, never the repo's own PR-controlled config). GL_MANDATORY_TMP names a
# temp file the caller must remove (empty when none was made).
GL_MANDATORY_CONFIG=""
GL_MANDATORY_TMP=""

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
# gl_apply_private_profile [<config-var-name> <tmp-var-name>]
# Surgically disable the operator identity rule (operator-network-domain-1) in
# the TARGET config when this repo is declared private (.house-code.json) AND
# verified live-private. Default target is GL_EFFECTIVE_CONFIG / GL_TMP_CONFIG
# (gl_preflight's differential/widen config); the pre-push mandatory full-tree
# scan calls it with GL_MANDATORY_CONFIG / GL_MANDATORY_TMP so the whole-tree
# backstop honours the SAME profile as the differential and staged scans — one
# mechanism, all three lanes consistent, surgical ("drop identity, keep
# everything else"), never a whole-overlay drop.
gl_apply_private_profile() {
    local cfgvar="${1:-GL_EFFECTIVE_CONFIG}" tmpvar="${2:-GL_TMP_CONFIG}" mode="${3:-append}"
    # Under GL_NO_OVERLAY / GL_OVERLAY_ONLY no stock+overlay config carrying
    # operator-network-domain-1 is loaded, so there is nothing for this profile
    # to relax and appending the stub allowlist would make gitleaks refuse the
    # config. A no-op here is correct, not a relaxation.
    [[ -n "${GL_NO_OVERLAY:-}" || -n "${GL_OVERLAY_ONLY:-}" ]] && return 0
    # Every branch below that KEEPS the operator identity rule (rather than
    # dropping it for a verified-private repo) prints ONE clear line, so a
    # plain-shell push on a private repo blocks LOUDLY with a stated cause instead
    # of silently not relaxing. jq is needed to read the declaration at all; a
    # missing jq means the profile cannot be evaluated -> keep the rule, say why.
    if ! command -v jq >/dev/null 2>&1; then
        printf '%s\n' "note: jq not found — cannot evaluate the private-repo profile; keeping the operator identity rule active (stricter scan)." >&2
        return 0
    fi
    hc_load_declaration || return 0            # a parse error already prints its own cause
    # Declared private via EITHER source: the repo's .house-code.json OR dotty's
    # co-shipped declared map (keyed by origin slug — hazel/dotty-private have no
    # .house-code.json, so the map is their only declaration). Not declared ->
    # the full overlay is correct here; silent by design.
    gl_repo_declared_private || return 0
    # From here the repo CLAIMS private, so any failure to confirm-and-relax is a
    # "keeping the rule" case that MUST be loud. gh does the live visibility read
    # (hc_private_repo_verified, via "${GH:-gh}"): the estate exports GH to the
    # adapter's full path so the read uses the App token / broker; else PATH's gh
    # (never a single hardcoded binary). The gh check sits AFTER the declared check
    # so its notice fires only for a repo that actually claims private — never on
    # an ordinary public-repo push.
    if ! command -v "${GH:-gh}" >/dev/null 2>&1; then
        printf '%s\n' "note: gh not found — cannot verify visibility for a repo that declares private_repo; keeping the operator identity rule active (stricter scan)." >&2
        return 0
    fi
    if ! hc_repo_visibility_is_private; then
        # Declared private (via .house-code.json or the map) but not verifiable
        # live-private (gh unreachable/unauthenticated, or the repo is actually
        # public): keep the operator identity rule active (stricter), say so once.
        printf '%s\n' "note: this repo declares private_repo but it could not be verified live-private (gh unreachable/unauthenticated, or the repo is not private) — keeping the operator identity rule active (stricter scan)." >&2
        return 0
    fi

    # The override for operator-network-domain-1 (an all-matching allowlist) must
    # live in a DIFFERENT extend layer from the rule's regex DEFINITION, or
    # gitleaks rejects the config ("both |regex| and |path| are empty"). Two
    # target shapes, two mechanisms:
    #   append (differential): the target is a repo config that EXTENDS the
    #     overlay (the rule's regex is in the extended layer). Copy the target and
    #     append the allowlist rule — gitleaks merges it by id across the layers.
    #     The copy is self-contained, so the previous tmp is safe to delete.
    #   wrap (mandatory): the target IS the operator overlay, used DIRECTLY, which
    #     DEFINES the rule in-file. Build a wrapper that EXTENDS that overlay and
    #     adds the allowlist override in the wrapper layer. The extended overlay is
    #     the PERMANENT installed file (never a tmp), so nothing is deleted.
    local tmp src src_abs
    src="${!cfgvar}"
    tmp="$(mktemp 2>/dev/null)" || return 0
    if [[ "$mode" == wrap ]]; then
        case "$src" in
            /*) src_abs="$src" ;;
            *)  src_abs="$(cd "$(dirname "$src")" 2>/dev/null && pwd)/$(basename "$src")" ;;
        esac
        [[ -f "$src_abs" ]] || { rm -f "$tmp"; return 0; }
        cat > "$tmp" <<EOF || { rm -f "$tmp"; return 0; }
[extend]
path = "$src_abs"

[[rules]]
id = "operator-network-domain-1"
[rules.allowlist]
regexes = ['''.*''']
EOF
        # wrap extends the PERMANENT overlay; there is no prior tmp to remove.
    else
        cp "$src" "$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }
        cat >> "$tmp" <<'EOF'

[[rules]]
id = "operator-network-domain-1"
[rules.allowlist]
regexes = ['''.*''']
EOF
        local oldtmp="${!tmpvar:-}"
        [[ -n "$oldtmp" ]] && rm -f "$oldtmp"
    fi
    printf -v "$cfgvar" '%s' "$tmp"
    printf -v "$tmpvar" '%s' "$tmp"
    GL_RULES_SOURCE="${GL_RULES_SOURCE:-} + private_repo profile (operator-network-domain-1 disabled, verified live)"
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
# gl_mandatory_preflight
# Resolves the config for the native pre-push full-tree scanner (the
# config-independent backstop) from the LANE-controlled env modes and the
# installed overlay — NEVER the repo's own tracked .gitleaks.toml. The
# distinction is who controls the input: GL_NO_OVERLAY / GL_CONFIG_PATH are set
# by the base branch's workflow file, which a PR cannot change (trusted); the
# repo's .gitleaks.toml / .gitleaksignore / .gitattributes are PR-controlled
# (untrusted). "Mandatory overlay, independent of any PR-controlled config" means
# the backstop honors the lane modes and ignores repo config:
#
#   * GL_NO_OVERLAY set (Lane A — a runner with no overlay by design): base
#     rules only (a temp config carrying just `[extend] useDefault = true`); the
#     overlay is NOT required, so a missing/malformed one does not refuse here.
#   * GL_CONFIG_PATH set (a pinned base-ref config, runner-owned): that pinned
#     config IS the base config — reuse gl_preflight's already-resolved
#     GL_EFFECTIVE_CONFIG (gl_preflight ran first on CONFIG=GL_CONFIG_PATH), with
#     the overlay mandatory (a missing/malformed overlay refuses).
#   * neither (local push): the installed operator overlay at its fixed path
#     used DIRECTLY (it carries `[extend] useDefault = true`, so base + overlay),
#     mandatory — a missing/malformed overlay refuses.
#
# In every mode the repo's own config/ignore/attributes have no effect on this
# scan (the caller points --gitleaks-ignore-path away from the repo and strips
# any materialized .gitleaksignore, and cat-file materialization ignores
# .gitattributes export-ignore entirely). Must be called AFTER gl_preflight (it
# reuses GL_EFFECTIVE_CONFIG for the GL_CONFIG_PATH mode). Sets GL_MANDATORY_CONFIG
# (and GL_MANDATORY_TMP when it makes a temp file — the caller removes it) on
# success; emits a cause-specific gl_block and returns 1 otherwise.
gl_mandatory_preflight() {
    GL_MANDATORY_CONFIG=""; GL_MANDATORY_TMP=""

    if ! command -v gitleaks >/dev/null 2>&1; then
        gl_block "Pre-push BLOCKED: gitleaks is not installed" \
            "The mechanical secret/PII scanner is missing from PATH." \
            "This hook fails closed rather than push unscanned." \
            "Install:  brew install gitleaks"
        return 1
    fi

    # Lane mode: base rules only, no overlay (a PR cannot set GL_NO_OVERLAY).
    if [[ -n "${GL_NO_OVERLAY:-}" ]]; then
        local tmp
        if ! tmp="$(mktemp 2>/dev/null)"; then
            gl_block "Pre-push BLOCKED: could not build the base-only scan config"
            return 1
        fi
        printf '[extend]\nuseDefault = true\n' > "$tmp"
        GL_MANDATORY_CONFIG="$tmp"; GL_MANDATORY_TMP="$tmp"
        return 0
    fi

    # From here the overlay is mandatory: refuse on a missing/malformed one.
    local fixed
    fixed="$(gl_fixed_rules_path)"
    if [[ ! -f "$fixed" || ! -r "$fixed" ]]; then
        gl_block "Pre-push BLOCKED: operator overlay is missing" \
            "Expected the mandatory ruleset at: $fixed" \
            "The full-tree scan applies base rules and the operator overlay" \
            "independently of any repo config; without the overlay it refuses." \
            "Install it via the blueprint (gitleaks-rules apply)."
        return 1
    fi
    # Malformed-overlay guard: load it against an EMPTY tree. A config gitleaks
    # cannot parse prints FTL / 'Failed to load config' and exits non-zero; a
    # loadable config over an empty source exits 0 with no findings.
    local probe errf rc
    probe="$(mktemp -d)"; errf="$(mktemp)"
    gitleaks detect --no-git --source "$probe" --config "$fixed" \
        --no-banner </dev/null >/dev/null 2>"$errf"
    rc=$?
    rm -rf "$probe"
    if [[ "$rc" -ne 0 ]] || grep -qE 'FTL|Failed to load config' "$errf"; then
        rm -f "$errf"
        gl_block "Pre-push BLOCKED: operator overlay failed to load" \
            "Config: $fixed" \
            "gitleaks could not parse the installed overlay (malformed ruleset)." \
            "Reinstall it via the blueprint (gitleaks-rules apply)." \
            "(Fail-closed: a malformed overlay must never pass a scan silently.)"
        return 1
    fi
    rm -f "$errf"

    # Lane mode: a pinned base-ref config (runner-owned) is the base config.
    # gl_preflight already resolved it into GL_EFFECTIVE_CONFIG (extend rewritten
    # to this same overlay), and being base-ref it is PR-independent.
    if [[ -n "${GL_CONFIG_PATH:-}" && -n "$GL_EFFECTIVE_CONFIG" ]]; then
        GL_MANDATORY_CONFIG="$GL_EFFECTIVE_CONFIG"
        return 0
    fi

    # Local / default: the fixed overlay directly (base + overlay).
    GL_MANDATORY_CONFIG="$fixed"
    # Apply the SAME private-repo profile the differential/staged scans use
    # (gl_preflight -> gl_apply_private_profile): a declared + verified-private
    # repo has the operator identity rule (operator-network-domain-1) disabled
    # in the MANDATORY config too, so the full-tree backstop and the differential
    # scan can never disagree on a private repo (the hazel case). Verified-public,
    # unverifiable, or non-private keeps the overlay intact (stricter). The lane
    # modes above (GL_NO_OVERLAY / GL_CONFIG_PATH) resolve the profile their own
    # way and never reach here; gl_apply_private_profile also no-ops under them.
    gl_apply_private_profile GL_MANDATORY_CONFIG GL_MANDATORY_TMP wrap
    return 0
}

# gl_scan_tree_at <repo> <report-out> <tree-ish>...
# The estate's single whole-tree secret/PII scan implementation. Materializes
# every blob in each <tree-ish>'s COMPLETE tree by reading it DIRECTLY via
# `git cat-file` (never `git archive` — archive honours .gitattributes
# export-ignore, a real blind spot), sha-sharded so identical blobs across
# tree-ishes dedupe and a later blob never overwrites an earlier one at the same
# path; symlink blobs (mode 120000) land as plain files holding the target-path
# bytes (payload scanned, link never followed). Then ONE gitleaks pass under
# GL_MANDATORY_CONFIG (base + overlay — the caller MUST have run
# gl_mandatory_preflight first), with a PR-authored .gitleaksignore neutralised
# (empty ignore path unless the trusted lane pinned GL_IGNORE_PATH, and any
# materialised .gitleaksignore stripped). Writes the JSON findings report to
# <report-out>. Returns 0 = clean, 1 = findings, 2 = scanner error / misuse.
# Callers own the report (summarise / gl_block); this function never blocks or
# prints findings. bash-3.2 safe (no associative array). Both the native
# pre-push hook and /publish's gate-mechanical.sh call this — one scan, one place.
gl_scan_tree_at() {
    local repo="$1" report="$2"; shift 2
    if [[ -z "${GL_MANDATORY_CONFIG:-}" ]]; then
        echo "gl_scan_tree_at: GL_MANDATORY_CONFIG unset — call gl_mandatory_preflight first" >&2
        return 2
    fi
    local scratch ignore_dir errf rc t entry meta path _mode _type blob shard dest
    scratch="$(mktemp -d)"; ignore_dir="$(mktemp -d)"; errf="$(mktemp)"
    for t in "$@"; do
        [[ -z "$t" ]] && continue
        while IFS= read -r -d '' entry; do
            meta="${entry%%$'\t'*}"; path="${entry#*$'\t'}"
            read -r _mode _type blob <<< "$meta"
            [[ "$_type" == "commit" ]] && continue   # submodule gitlink — no blob
            shard="$scratch/$blob"
            mkdir "$shard" 2>/dev/null || continue
            dest="$shard/$path"
            mkdir -p "$(dirname "$dest")" 2>/dev/null || continue
            # Fail CLOSED, never skip: an unreadable blob would go unscanned.
            if ! git -C "$repo" cat-file -p "$blob" > "$dest" 2>/dev/null; then
                echo "gl_scan_tree_at: unreadable blob $blob in $t — failing closed" >&2
                rm -rf "$scratch" "$ignore_dir" "$errf"; return 2
            fi
        done < <(git -C "$repo" ls-tree -r -z --full-tree "$t" 2>/dev/null)
    done
    find "$scratch" -type f -name '.gitleaksignore' -delete 2>/dev/null
    if [[ -z "$(ls -A "$scratch" 2>/dev/null)" ]]; then
        printf '[]' > "$report"; rm -rf "$scratch" "$ignore_dir" "$errf"; return 0
    fi
    gitleaks detect --no-git --source "$scratch" \
        --config "$GL_MANDATORY_CONFIG" \
        --gitleaks-ignore-path "${GL_IGNORE_PATH:-$ignore_dir}" \
        --no-banner --redact=100 --ignore-gitleaks-allow \
        --report-format json --report-path "$report" \
        </dev/null >/dev/null 2>"$errf"
    rc=$?
    rm -rf "$scratch" "$ignore_dir"
    if grep -qE 'fatal:|stderr is not empty|FTL|Failed to load config|panic:' "$errf" \
        || { [[ "$rc" -eq 0 ]] && command -v jq >/dev/null 2>&1 && ! jq -e . "$report" >/dev/null 2>&1; }; then
        rm -f "$errf"; return 2
    fi
    rm -f "$errf"
    [[ "$rc" -ne 0 ]] && return 1
    return 0
}

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
