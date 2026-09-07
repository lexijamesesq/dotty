#!/usr/bin/env bash
# gate-resolve-profile.sh — resolve the trusted lane's per-repo scan profile
# from dotty's own TRUSTED declared state, and print the one env line the
# gate workflow appends to $GITHUB_ENV.
#
#     gate-resolve-profile.sh <owner/repo> <declared-json-path>
#
# Prints exactly one line on success:  GATE_SKIP_OVERLAY=0   or   =1
#   0 -> standard two-pass scan (base-rules + operator-overlay)
#   1 -> PRIVATE-REPO PROFILE: the identity/operator-overlay pass is dropped,
#        the credential/base-rules pass stays on ("drop identity, keep
#        credential"). This whole-pass skip == "drop identity, keep credential"
#        ONLY while the operator overlay is identity-class-only. That is NOT
#        enforced here: the overlay is generated in dotty-private and delivered
#        as OPERATOR_RULES, so nothing in this repo sees its rule classes. The
#        actual guard is dotty-private's RULE-SHAPES.md invariant (credentials
#        are never a custom operator class; gitleaks' stock rules + push
#        protection own them), with an owed generator-eval assertion (tracked on the rollout map).
#        If a credential-class rule is ever added to the overlay, this skip
#        would silently drop that credential check on a private repo and must
#        instead become a per-rule class filter -- a maintainer adding a rule
#        class in dotty-private owns updating this skip.
#
# The profile is read ONLY from the pinned _dotty checkout's
# rulesets/default-branch.json `.repos[<slug>].private_repo` -- dotty's own
# trusted state, keyed by the repo under scan -- NEVER from the PR's own tree.
# Absent/false -> standard (the safe default).
#
# FAIL-CLOSED. A declared-private repo relaxes the identity scan, so it MUST be
# verified actually private, live. A declared-private repo found public (or
# whose visibility cannot be read) exposes the very identity content the
# profile stops scanning for -- this exits non-zero with an ::error, blocking,
# rather than relaxing on a false or unverifiable premise. Unreadable/malformed
# declared JSON is likewise a block, never a silent "not private".
#
# Visibility is read live via `gh api repos/<slug> --jq .private` (stdout
# "true"/"false"). GATE_VISIBILITY_OVERRIDE, when set, supplies that answer
# directly instead -- the eval suite's injection point, so every branch runs
# offline without a network or a real gh, and with no `eval` of any command.
#
# Spec: {workspace_root}/System/Knowledge/leak-prevention-architecture.md

set -uo pipefail

repo="${1:-}"
declared_json="${2:-}"

if [[ -z "$repo" || -z "$declared_json" ]]; then
    echo "usage: gate-resolve-profile.sh <owner/repo> <declared-json-path>" >&2
    exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "::error::gate-resolve-profile: jq not installed -- cannot read the declared profile (fail-closed)." >&2
    exit 1
fi

if [[ ! -r "$declared_json" ]]; then
    echo "::error::gate-resolve-profile: declared ruleset JSON not readable at '$declared_json' -- cannot resolve the trusted-lane profile (fail-closed)." >&2
    exit 1
fi

# A malformed JSON must block, never resolve to "not private". jq -e on a parse
# error exits non-zero; capture that explicitly rather than letting `// false`
# paper over an unparseable file.
if ! jq -e . "$declared_json" >/dev/null 2>&1; then
    echo "::error::gate-resolve-profile: declared ruleset JSON at '$declared_json' is not valid JSON (fail-closed)." >&2
    exit 1
fi

declared_private="$(jq -r --arg r "$repo" '.repos[$r].private_repo // false' "$declared_json")"

if [[ "$declared_private" != "true" ]]; then
    echo "GATE_SKIP_OVERLAY=0"
    exit 0
fi

# Declared private -> verify live. GATE_VISIBILITY_OVERRIDE (tests) supplies
# the answer directly; otherwise read the repo's own metadata live.
if [[ -n "${GATE_VISIBILITY_OVERRIDE:-}" ]]; then
    actual_private="$GATE_VISIBILITY_OVERRIDE"
else
    actual_private="$(gh api "repos/$repo" --jq .private 2>/dev/null || echo "unknown")"
fi

if [[ "$actual_private" != "true" ]]; then
    echo "::error::gate-resolve-profile: $repo is declared private_repo:true but its live visibility is '$actual_private' (not verified private) -- refusing to relax the identity scan on a repo that is or may be public. Fail-closed." >&2
    exit 1
fi

echo "GATE_SKIP_OVERLAY=1"
exit 0
