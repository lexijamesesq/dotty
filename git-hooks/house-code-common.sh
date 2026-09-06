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

# hc_private_repo_declared — 0 (true) iff the declaration claims private_repo.
# Never sufficient on its own — see hc_private_repo_verified.
hc_private_repo_declared() {
    [[ "$(jq -r '.private_repo // false' <<< "$HC_DECLARATION_JSON")" == "true" ]]
}

# hc_with_timeout <seconds> <cmd...> — portable bound on a command's
# runtime: macOS ships no `timeout`/`gtimeout` by default, so this is a
# manual background-job-plus-watchdog instead of relying on either. Prints
# the command's stdout; returns its exit code, or 124 if the watchdog fired
# first (matching GNU timeout's own convention).
hc_with_timeout() {
    local secs="$1"; shift
    local out rc
    out="$(mktemp)"
    "$@" >"$out" 2>/dev/null &
    local cmd_pid=$!
    ( sleep "$secs"; kill -TERM "$cmd_pid" 2>/dev/null ) &
    local watchdog_pid=$!
    if wait "$cmd_pid" 2>/dev/null; then rc=0; else rc=$?; fi
    kill "$watchdog_pid" 2>/dev/null; wait "$watchdog_pid" 2>/dev/null
    cat "$out"; rm -f "$out"
    return "$rc"
}

# hc_private_repo_verified — verifies a private_repo claim live against
# GitHub's own record of this repo's visibility. Any failure to verify (no
# network, no gh, no auth, a timeout, an unexpected answer) resolves to
# NOT private — uncertain means treat as public, never silently grant the
# relaxation. Mirrors house-code.py's verify_private_repo() exactly.
hc_private_repo_verified() {
    hc_private_repo_declared || return 1
    local remote owner_repo visibility
    remote="$(git remote get-url origin 2>/dev/null)" || return 1
    owner_repo="$(printf '%s' "$remote" | sed -E 's#\.git$##; s#^.*[:/]([^/]+/[^/]+)$#\1#')"
    [[ -n "$owner_repo" ]] || return 1
    visibility="$(hc_with_timeout 10 gh api "repos/${owner_repo}" --jq '.visibility')" || return 1
    [[ "$visibility" == "private" ]]
}
