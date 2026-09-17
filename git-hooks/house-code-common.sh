#!/usr/bin/env bash
# house-code-common.sh — shared declaration-file reading for the
# house-scaffold-* hooks (house-code.py, Python, reads the same file
# itself via json — this is the bash-side equivalent, for hooks that
# read the whole tracked tree rather than taking file args).
#
# One declared file at the repo root, .house-code.json — see house-code.py's
# own module docstring for the full shape and rationale (private_repo is a
# claim VERIFIED live via `gh api`, never trusted blind; exemptions are a
# true one-off — a specific rule against a specific, narrowly-targeted
# path regex, with a required reason. A cause that recurs across repos is a
# defect in the hook, not a second declared entry).
#
# This file is sourced, not executed. Requires jq (already a estate-wide
# dependency of the gitleaks hooks' report summarizer).
#
# Scope note: this file serves the two house-scaffold hooks that read the whole
# tracked tree. It used to also carry the live GitHub-visibility helpers
# (hc_with_timeout, hc_repo_visibility_is_private, hc_private_repo_verified)
# for gitleaks-common.sh's runtime private-repo detection. That detection is
# gone — a private repo now declares its own relaxation in its own
# .gitleaks.toml — and those helpers went with it. house-code.py keeps its own
# Python implementation of the same check, which is what it always used.

HC_DECLARATION_FILE=".house-code.json"

# hc_load_declaration — sets HC_DECLARATION_JSON (raw JSON text, "{}" if the
# file is absent) or calls hc_block_declaration and returns 1 if the file
# exists but fails to parse (fail-closed: a broken declaration must never
# be silently treated as "nothing declared").
hc_load_declaration() {
    HC_DECLARATION_JSON="{}"
    [[ -f "$HC_DECLARATION_FILE" ]] || return 0
    if ! HC_DECLARATION_JSON="$(jq -c '.' "$HC_DECLARATION_FILE" 2>&1)"; then
        echo "BLOCKED: $HC_DECLARATION_FILE exists but could not be parsed as JSON: $HC_DECLARATION_JSON" >&2
        return 1
    fi
    return 0
}

# hc_declared_exempt_paths <rule> — prints one repo-relative regex per line,
# for every exemptions[] entry in the loaded declaration matching <rule>.
# Caller matches tracked paths against these with `grep -Ex` (anchored,
# matching house-code.py's re.fullmatch semantics).
hc_declared_exempt_paths() {
    local rule="$1"
    jq -r --arg rule "$rule" '(.exemptions // []) | map(select(.rule == $rule)) | .[].path' <<< "$HC_DECLARATION_JSON"
}
