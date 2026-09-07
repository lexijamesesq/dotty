#!/usr/bin/env bash
# drift-check-report.sh — run `provision-public-repo.sh --check` across every
# repo declared in rulesets/default-branch.json and aggregate the result into
# one estate-wide drift report.
#
# READ-ONLY. --check reads and compares; it mutates nothing. This runner adds
# no scope of its own — it drives the same App-token-safe reads the provisioner
# already makes, once per declared repo.
#
# Identity: runs on demand from a Claude Code session through the same path
# every converge runs today (the session's own App token via the gh wrapper).
# There is deliberately NO scheduled/unattended trigger: a repo-level self-
# hosted runner serves only its own repo, and the gh wrapper mints the App
# token only inside a session — an unattended cross-repo run needs a read-only
# identity that does not exist yet (owner-tracked follow-up). This script is
# written so it can become the body of that scheduled job unchanged once such
# an identity exists.
#
# Usage:
#   drift-check-report.sh                       check every declared repo
#   drift-check-report.sh <owner/repo> ...      check only the named repos
#   drift-check-report.sh --list                print the repos that would be
#                                               checked, make no live calls
#   drift-check-report.sh --declared-json <p>   use an alternate declared JSON
#                                               (default: the sibling
#                                               rulesets/default-branch.json)
#
# Exit: 0 when no repo reports DRIFT; 1 when any repo reports DRIFT; 2 on a
# usage or configuration error. A repo whose reads fail (FATAL/unreadable) is
# reported as ERROR and also makes the run exit non-zero — a read failure is
# never counted as clean.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVISIONER="$SELF_DIR/provision-public-repo.sh"
DECLARED_JSON_PATH="$SELF_DIR/rulesets/default-branch.json"
LIST_ONLY=""
SLUGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --list)          LIST_ONLY=1; shift ;;
        --declared-json) DECLARED_JSON_PATH="${2:-}"; [[ -n "$DECLARED_JSON_PATH" ]] || { echo "FATAL: --declared-json requires a path" >&2; exit 2; }; shift 2 ;;
        --declared-json=*) DECLARED_JSON_PATH="${1#--declared-json=}"; shift ;;
        -h|--help)       sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        --*)             echo "FATAL: unknown flag '$1'" >&2; exit 2 ;;
        *)               SLUGS+=("$1"); shift ;;
    esac
done

[[ -x "$PROVISIONER" || -r "$PROVISIONER" ]] || { echo "FATAL: cannot find provision-public-repo.sh next to this script ($PROVISIONER)" >&2; exit 2; }
[[ -r "$DECLARED_JSON_PATH" ]] || { echo "FATAL: cannot read declared JSON at '$DECLARED_JSON_PATH'" >&2; exit 2; }

# Repo list: explicit slugs win; otherwise every key under .repos in the
# declared JSON, so the runner stays in lockstep with what is actually declared
# (a repo added to the JSON is checked with no edit here).
if [[ ${#SLUGS[@]} -eq 0 ]]; then
    while IFS= read -r slug; do
        [[ -n "$slug" ]] && SLUGS+=("$slug")
    done < <(jq -r '.repos | keys[]' "$DECLARED_JSON_PATH")
fi
[[ ${#SLUGS[@]} -gt 0 ]] || { echo "FATAL: no repos to check (none passed, none declared under .repos)" >&2; exit 2; }

if [[ -n "$LIST_ONLY" ]]; then
    printf '%s\n' "${SLUGS[@]}"
    exit 0
fi

total_drift=0
total_error=0
declare_report=""

for slug in "${SLUGS[@]}"; do
    out="$(bash "$PROVISIONER" --check --declared-json "$DECLARED_JSON_PATH" "$slug" 2>&1)"
    rc=$?
    n_drift="$(printf '%s\n' "$out" | grep -c '^  DRIFT ' || true)"
    n_skip="$(printf '%s\n' "$out" | grep -c '^  SKIP ' || true)"
    n_ok="$(printf '%s\n' "$out" | grep -c '^  OK ' || true)"
    # A FATAL (or any exit code other than the provisioner's own 0=clean /
    # 1=drift) is a read failure, never "clean".
    if printf '%s\n' "$out" | grep -q '^FATAL' || [[ "$rc" -gt 1 ]]; then
        total_error=$((total_error + 1))
        declare_report="${declare_report}
  ERROR ${slug} (reads failed — rc=${rc}; see detail below)
$(printf '%s\n' "$out" | grep -E '^FATAL' | sed 's/^/      /')"
        continue
    fi
    if [[ "$n_drift" -gt 0 ]]; then
        total_drift=$((total_drift + n_drift))
        declare_report="${declare_report}
  DRIFT ${slug} (OK=${n_ok} SKIP=${n_skip} DRIFT=${n_drift})
$(printf '%s\n' "$out" | grep '^  DRIFT ' | sed 's/^  /      /')"
    else
        declare_report="${declare_report}
  clean ${slug} (OK=${n_ok} SKIP=${n_skip})"
    fi
done

echo "== Estate drift report (provision --check across ${#SLUGS[@]} declared repo(s)) =="
printf '%s\n' "$declare_report"
echo
echo "== Summary: ${total_drift} DRIFT line(s) across all repos; ${total_error} repo(s) unreadable =="
if [[ "$total_drift" -gt 0 || "$total_error" -gt 0 ]]; then
    exit 1
fi
echo "clean: every declared repo conforms to the core"
exit 0
