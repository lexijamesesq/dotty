#!/usr/bin/env bash
# converge-enrolled.sh <mode> <dotty-checkout>
#   mode = converge | check
#
# Runs provision-public-repo.sh across every enrolled repo, under ONE identity.
#
# WHY THIS EXISTS, and the receipt. Until tonight the converge was run by a
# session, by hand. It had to be: the Claude App's token has no Administration
# grant, so a session could not write a ruleset under the App — which meant the
# `gh` wrapper fell through to the OPERATOR'S login and every converge in this
# estate was performed as her, by a machine. That is the identity confusion this
# job ends. Ollie holds the Administration grant; the operator holds none of the
# keystrokes.
#
# The two inputs that change what a converge would WRITE are the declared JSON
# and the provisioner itself, which is exactly what the workflow watches. A
# schedule re-runs it in `check` mode so a repo that drifts between merges is
# reported rather than discovered at the next one.
#
# Side effects are entirely the provisioner's. This file decides WHICH repos and
# WHAT counts as failure, and nothing else.
set -euo pipefail

MODE="${1:?usage: converge-enrolled.sh <converge|check> <dotty-checkout>}"
DOTTY="${2:?usage: converge-enrolled.sh <converge|check> <dotty-checkout>}"
case "$MODE" in converge|check) : ;; *) echo "FATAL: mode must be converge or check" >&2; exit 2 ;; esac

RULESETS="${DOTTY}/rulesets/default-branch.json"
[[ -f "$RULESETS" ]] || { echo "FATAL: no rulesets JSON at $RULESETS" >&2; exit 2; }

# The DRIFT classes a scheduled `check` is allowed to report without failing the
# run. `tag-origin` alone, and the reason is historical rather than a shrug: this
# estate carries tags cut before release-on-merge existed — lightweight, or from
# a tagger no longer declared — and no ruleset can restrict tag CREATION, so they
# cannot be converged away. They are a known backlog, not a regression.
#
# Declared as a list and matched on the CLASS NAME, never grepped out of the
# prose: a substring filter would also swallow a future `tag-origin-policy` class
# nobody meant to exempt.
TOLERATED_DRIFT_CLASSES=(tag-origin)

# drift_class <drift-line> — the class name from a provisioner DRIFT line, which
# always reads `  DRIFT <class>[<detail>] = ...` or `  DRIFT <class> = ...`.
# Prints the bare class, or nothing if the line is not a DRIFT line.
drift_class() {
    printf '%s\n' "$1" | sed -n 's/^[[:space:]]*DRIFT[[:space:]]\{1,\}\([A-Za-z0-9._-]*\).*/\1/p'
}

# tolerated <class> — is this class on the declared exemption list?
tolerated() {
    local c="$1" t
    for t in "${TOLERATED_DRIFT_CLASSES[@]}"; do [[ "$c" == "$t" ]] && return 0; done
    return 1
}

# enrolled_repos — every declared repo. A repo leaves the estate by losing its
# entry, so this list is the whole definition of "ours".
enrolled_repos() { jq -r '.repos | keys[]' "$RULESETS"; }

PROVISION="${PROVISION_CMD:-bash ${DOTTY}/provision-public-repo.sh}"

# Counters only. A bare list of names after these assignments is a COMMAND to
# bash, not a declaration — `repo out rc line cls` ran as one and the script died
# with "repo: command not found" before touching a single repo. Caught by the
# suite on its first run.
failed=0
converged=0
drifted=0
while IFS= read -r repo; do
    [[ -n "$repo" ]] || continue
    printf '\n========== %s (%s) ==========\n' "$repo" "$MODE"

    set +e
    if [[ "$MODE" == check ]]; then
        out="$($PROVISION --check "$repo" 2>&1)"; rc=$?
    else
        out="$($PROVISION "$repo" 2>&1)"; rc=$?
    fi
    set -e
    printf '%s\n' "$out"

    if [[ "$MODE" == converge ]]; then
        # A converge that cannot finish its own work is a hard failure. There is
        # no "mostly converged": a half-applied ruleset is the state this job
        # exists to prevent.
        if [[ "$rc" -ne 0 ]]; then
            echo "::error::${repo}: converge exited ${rc} — see the log above"
            failed=$((failed + 1))
        else
            converged=$((converged + 1))
        fi
        continue
    fi

    # check mode: exit 1 means drift was reported. Whether that fails the RUN
    # depends on the class, so the exit code alone is not the verdict.
    drift_here=0
    while IFS= read -r line; do
        cls="$(drift_class "$line")"
        [[ -n "$cls" ]] || continue
        if tolerated "$cls"; then
            echo "::notice::${repo}: tolerated drift class '${cls}' — known backlog, not a regression"
        else
            echo "::error::${repo}: DRIFT ${cls} — ${line}"
            drift_here=1
        fi
    done <<< "$out"

    if [[ "$drift_here" -eq 1 ]]; then
        drifted=$((drifted + 1))
    elif [[ "$rc" -gt 1 ]]; then
        # >1 is a FATAL from the provisioner (bad declaration, unreadable input),
        # which is a failure in every mode.
        echo "::error::${repo}: check exited ${rc} (not a drift exit) — see the log above"
        failed=$((failed + 1))
    fi
done < <(enrolled_repos)

printf '\n========== summary ==========\n'
if [[ "$MODE" == converge ]]; then
    echo "converged: ${converged}  failed: ${failed}"
else
    echo "clean-or-tolerated: $(( $(enrolled_repos | wc -l | tr -d ' ') - drifted - failed ))  drifted: ${drifted}  failed: ${failed}"
fi
[[ "$failed" -eq 0 && "$drifted" -eq 0 ]]
