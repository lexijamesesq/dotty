#!/usr/bin/env bash
# gitleaks-pre-push.sh — FAIL-CLOSED pre-push scan of the FULL outgoing commit
# range. This is the enforcement line: the staged scan (pre-commit) only sees
# one commit's worth of changes; a secret can still reach a public remote via
# an un-scanned intermediate commit, a rebase, or a new-branch push. This hook
# closes that gap.
#
# TWO INVOCATION CONTEXTS — this hook handles both, and fails closed if it can
# recognize neither (never silently passes an unknown range):
#
#   1. Under the pre-commit framework (stages: [pre-push]) — the deployment
#      path for dotty and every consuming repo. pre-commit CONSUMES the raw
#      pre-push protocol from stdin and instead exports the range as
#      PRE_COMMIT_FROM_REF / PRE_COMMIT_TO_REF (verified, pre-commit 4.6.0). A
#      stdin-only hook would read EMPTY stdin here and FAIL OPEN — the trap this
#      rewrite exists to avoid. We read the env vars.
#
#   2. As a native .git/hooks/pre-push — git feeds the real protocol on stdin,
#      one line per ref:  <local_ref> <local_sha> <remote_ref> <remote_sha>.
#
# THE EMPTY-REMOTE TRAP (repo bootstrap — `gh repo create` then
# `git push -u origin main`; exactly what the repo-provisioning script does): when the
# remote has NO refs at all, pre-commit leaves BOTH refs unset but STILL exports
# PRE_COMMIT_REMOTE_NAME. Being invoked with a remote name IS the signal of a
# genuine pre-push. Treating "no refs" as indeterminate would (a) block clean
# bootstrap pushes — friction that teaches humans to `git push --no-verify` — and
# (b) let a canary in the initial commit through unscanned. Instead we over-scan:
# every local commit absent from that remote (`--all --not --remotes=<remote>`).
# `--all` (not `--branches`) is deliberate: we do not know which ref the push
# targets, so we scan the widest local set that is not yet on the remote — the
# pushed subset is guaranteed covered. Over-scan is safe; under-scan is the bug.
#
# THE ALL-ZEROS TRAP (empirically confirmed, gitleaks 8.30.1):
#   `gitleaks git --log-opts="<range>"` FAILS OPEN on an unresolvable range —
#   e.g. git's all-zeros SHA that a NEW-BRANCH push carries as <remote_sha>. It
#   logs `fatal: Invalid revision range ...`, then `0 commits scanned` /
#   `no leaks found`, and EXITS 0. We never build a zero-based range: for a new
#   ref we scan `<tip> --not --remotes=<target-remote>`. We also (a) validate
#   every range with `git rev-list --count` before scanning and (b) treat
#   gitleaks stderr carrying `fatal:` / `stderr is not empty` as a BLOCK
#   regardless of exit code.
#
# THE TARGET-REMOTE TRAP: the remote being pushed to is NOT necessarily
# `origin`. Excluding the wrong remote's refs under-scans — a commit already on
# `origin` but NEW to the actual target (e.g. a separate public `upstream`) gets
# dropped from the range and the push passes unscanned. We resolve the ACTUAL
# remote: PRE_COMMIT_REMOTE_NAME under pre-commit, $1 as a native hook. If the
# remote name cannot be determined we deliberately DO NOT fall back to a
# `--not --remotes=...` exclusion of any kind — excluding refs scans LESS, the
# unsafe direction. We fall back to scanning EVERYTHING reachable from the tip
# (`git rev-list <tip>`, no `--not`). Over-scanning re-scans already-published
# commits (safe, slower); under-scanning misses secrets (the bug).
#
# Note: gitleaks resolves a config's RELATIVE `[extend] path` against the
# PROCESS cwd, so this hook cd's to the repo root before scanning, and passes
# gl_preflight's effective config — see gitleaks-common.sh for how the operator
# ruleset is resolved.
#
# Spec: {workspace_root}/System/Knowledge/leak-prevention-architecture.md

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/gitleaks-common.sh"
# The effective config may be a temp file (see gl_preflight); always remove it.
trap 'rm -f "$GL_TMP_CONFIG" 2>/dev/null || true' EXIT INT TERM

ZERO="0000000000000000000000000000000000000000"
CONFIG=".gitleaks.toml"   # relative — resolved from cwd (= repo root, see below)

repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    gl_block "Pre-push BLOCKED: not inside a git work tree" \
        "Could not determine the repository root — refusing to push unscanned."
    exit 1
}
# Enforce cwd = repo root so gitleaks resolves the [extend] path correctly.
cd "$repo_root" || {
    gl_block "Pre-push BLOCKED: cannot enter the repository root" \
        "cd '$repo_root' failed — refusing to push unscanned."
    exit 1
}

gl_preflight "$CONFIG" || exit 1

# Resolve the ACTUAL target remote: pre-commit exports PRE_COMMIT_REMOTE_NAME;
# a native pre-push hook gets it as $1. Empty in neither-recognized/odd cases.
remote_name="${PRE_COMMIT_REMOTE_NAME:-${1:-}}"

blocked=0

# new_branch_logopts <tip>
# git-log-opts for "commits on <tip> not yet on the target remote". When the
# remote name is known, exclude that remote's refs. When it is NOT known, scan
# everything reachable from the tip (over-scan) — NEVER exclude a guessed remote
# (that under-scans, the fail-open direction). See the header's target-remote note.
new_branch_logopts() {
    local tip="$1"
    if [[ -n "$remote_name" ]]; then
        printf '%s --not --remotes=%s' "$tip" "$remote_name"
    else
        printf '%s' "$tip"
    fi
}

# scan_logopts <human-range-desc> <git-log-opts-string>
# Validates the range ourselves (fail-closed), then scans it with gitleaks.
# Sets blocked=1 on any problem or finding. logopts is a git-log expression:
# "A..B", "<tip> --not --remotes=<remote>", or a bare "<tip>".
scan_logopts() {
    local desc="$1" logopts="$2"
    local -a lo
    read -ra lo <<< "$logopts"

    local count
    if ! count="$(git rev-list --count "${lo[@]}" </dev/null 2>/dev/null)"; then
        gl_block "Pre-push BLOCKED: unresolvable commit range" \
            "Range: $desc" \
            "git rev-list could not resolve it — refusing to push unscanned commits." \
            "(Fail-closed: an unverifiable range must never pass.)"
        blocked=1
        return
    fi
    if ! [[ "$count" =~ ^[0-9]+$ ]]; then
        gl_block "Pre-push BLOCKED: commit count unreadable" \
            "Range: $desc — refusing to push a range we cannot size."
        blocked=1
        return
    fi
    [[ "$count" -eq 0 ]] && return   # nothing new to scan for this range

    # Identity guard (LEX-321 class): public commits carry noreply identity
    # only. gitleaks never sees author/committer metadata, so a stale
    # pre-rewrite clone can resurrect scrubbed emails through a clean scan.
    # Substring test is deliberate — the estate identity is a users.noreply
    # address and GitHub's squash committer is noreply@github.com; the threat
    # is accidental leakage, not evasion. Names SHA + field, never the value.
    # Tab-delimited on purpose: git accepts a SPACE inside an env-supplied
    # email, which under space-splitting shifts columns and lets a bad
    # committer email inherit a noreply substring. Emails cannot contain tabs.
    # Fail-closed: a non-empty range whose identities cannot be read is a
    # BLOCK. No early return — the gitleaks scan below still runs.
    local idlog sha ae ce f
    if ! idlog="$(git log --format='%H%x09%ae%x09%ce' "${lo[@]}" </dev/null 2>/dev/null)" || [[ -z "$idlog" ]]; then
        gl_block "Pre-push BLOCKED: cannot read commit identities" \
            "Range: $desc — refusing to push commits whose author/committer" \
            "emails cannot be verified. (Fail-closed.)"
        blocked=1
    else
        while IFS=$'\t' read -r sha ae ce; do
            for f in "author:$ae" "committer:$ce"; do
                [[ "${f#*:}" == *noreply* ]] && continue
                gl_block "Pre-push BLOCKED: non-noreply ${f%%:*} email in outgoing commits" \
                    "Commit: $sha (${f%%:*} email; value withheld)" \
                    "Estate policy: public commits carry noreply identity only." \
                    "A non-noreply email in the outgoing range usually means a stale" \
                    "pre-rewrite clone — re-point the checkout before pushing."
                blocked=1
            done
        done <<< "$idlog"
    fi

    local report errf
    report="$(mktemp)"
    errf="$(mktemp)"
    gitleaks git . \
        --log-opts="$logopts" \
        --config="$GL_EFFECTIVE_CONFIG" \
        --no-banner --redact --ignore-gitleaks-allow \
        --report-format json --report-path "$report" \
        </dev/null >/dev/null 2>"$errf"
    local rc=$?

    if grep -qE 'fatal:|stderr is not empty' "$errf"; then
        # The documented fail-open: gitleaks hit a git range error and would
        # otherwise exit 0. Treat as BLOCK; never trust its "no leaks found".
        gl_block "Pre-push BLOCKED: scanner could not resolve the range" \
            "Range: $desc" \
            "gitleaks reported a git error; its exit code is untrustworthy here." \
            "(Fail-closed backstop against the known log-opts fail-open.)"
        blocked=1
    elif grep -qE 'FTL|Failed to load config' "$errf"; then
        gl_block "Pre-push BLOCKED: gitleaks config failed to load" \
            "Config: $repo_root/$CONFIG (operator rules: $GL_RULES_SOURCE)" \
            "Install the operator ruleset via the blueprint (gitleaks-rules apply)."
        blocked=1
    elif [[ "$rc" -ne 0 ]]; then
        gl_block "Pre-push BLOCKED: sensitive content in outgoing commits" \
            "Range: $desc" \
            "Findings (rule / commit / file:line — matched values withheld):"
        gl_summarize_report "$report" >&2
        {
            echo "  Remediation:"
            echo "    * Rewrite the offending commit(s): git rebase -i  /  git commit --amend"
            echo "    * If already in history, purge it: git filter-repo"
            echo "    * The value must be gone from EVERY commit in the range, not just HEAD."
            echo ""
        } >&2
        blocked=1
    fi
    rm -f "$report" "$errf"
}

# Slurp stdin up front (empty under pre-commit; the ref protocol natively).
stdin_data="$(cat)"

if [[ -n "${PRE_COMMIT_TO_REF:-}" ]]; then
    # --- pre-commit framework path -------------------------------------------
    to="${PRE_COMMIT_TO_REF}"
    from="${PRE_COMMIT_FROM_REF:-}"
    label="${PRE_COMMIT_REMOTE_BRANCH:-push}"
    if [[ "$to" == "$ZERO" ]]; then
        : # branch deletion — nothing to scan
    elif [[ -z "$from" || "$from" == "$ZERO" ]]; then
        # New branch / no usable base ref: scan commits not yet on the target
        # remote. (Defends both the all-zeros and target-remote traps here too.)
        scan_logopts "new push of $label to '${remote_name:-?}' (commits not yet on it)" \
            "$(new_branch_logopts "$to")"
    else
        scan_logopts "$from..$to ($label)" "$from..$to"
    fi

elif [[ -n "$stdin_data" ]]; then
    # --- native git hook path (raw protocol on stdin) ------------------------
    while read -r local_ref local_sha remote_ref remote_sha; do
        [[ -z "${local_ref:-}" ]] && continue
        : "$remote_ref"                                  # documented, unused
        [[ "$local_sha" == "$ZERO" ]] && continue        # branch deletion
        if [[ "$remote_sha" == "$ZERO" ]]; then
            scan_logopts "new ref '$local_ref' -> '${remote_name:-?}' (commits not yet on it)" \
                "$(new_branch_logopts "$local_sha")"
        else
            scan_logopts "$remote_sha..$local_sha ($local_ref)" \
                "$remote_sha..$local_sha"
        fi
    done <<< "$stdin_data"

elif [[ -n "$remote_name" ]]; then
    # --- empty/refless remote (FIX 3) ----------------------------------------
    # No stdin protocol and no FROM/TO refs, but a remote name IS set — this is
    # a first push to a remote with no matching refs (repo bootstrap). We cannot
    # be told which ref is being pushed, so over-scan: every local commit absent
    # from that remote. (For a truly empty remote nothing is excluded, so the
    # whole initial history is scanned.) count 0 => nothing to push => pass.
    scan_logopts "first push to '$remote_name' (all local commits not yet on it)" \
        "--all --not --remotes=$remote_name"

else
    # --- genuinely indeterminate: FAIL CLOSED --------------------------------
    # No stdin protocol, no FROM/TO refs, AND no remote name: the hook was
    # invoked outside a real pre-push context. Blocking is correct here.
    gl_block "Pre-push BLOCKED: cannot determine what is being pushed" \
        "No pre-push protocol on stdin, no PRE_COMMIT_TO_REF, and no remote name." \
        "Refusing to push unscanned. (Fail-closed: an unknown range must not pass.)"
    blocked=1
fi

[[ "$blocked" -ne 0 ]] && exit 1
exit 0
