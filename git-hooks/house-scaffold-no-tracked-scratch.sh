#!/usr/bin/env bash
# house-scaffold-no-tracked-scratch.sh — no evals/ or scratch/ dir may be
# tracked. Ported from gate-mechanical.sh's Step 1 (gate.md § Scaffold, A3);
# the verb's own copy retires once this hook covers every consumer.
#
# Runs over the whole tracked tree, not the staged diff — a scratch dir
# tracked in an earlier commit and never touched again is still a violation.
set -uo pipefail

TRACKED="$(git ls-files)"
HITS="$(printf '%s\n' "${TRACKED}" | grep -Ei '(^|/)(evals|scratch)(/|$)' || true)"

if [[ -n "${HITS}" ]]; then
    echo "BLOCKED: non-shipping dir tracked:" >&2
    printf '%s\n' "${HITS}" | sed 's/^/  /' >&2
    exit 1
fi
exit 0
