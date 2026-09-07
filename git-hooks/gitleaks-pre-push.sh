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
# The effective config may be a temp file (see gl_preflight); always remove it,
# along with the native full-tree scanner's scratch dirs (Done When: clean
# temporary data on every exit path, success or failure).
MANDATORY_IGNORE_DIR=""; MTREE=""; MMSG=""; MREFDIR=""
trap 'rm -rf "$GL_TMP_CONFIG" "$GL_MANDATORY_TMP" "$MANDATORY_IGNORE_DIR" "$MTREE" "$MMSG" "$MREFDIR" 2>/dev/null || true' EXIT INT TERM

ZERO="0000000000000000000000000000000000000000"
# GL_CONFIG_PATH: the trusted lane's override. Its base-ref pin writes the
# pinned .gitleaks.toml to a runner-owned temp path OUTSIDE any checkout,
# never into the repo root -- an artifact-review finding proved that writing
# a base-ref-pinned FILE into the PR's own checkout is exploitable regardless
# of content correctness: a PR can commit the destination filename as a
# symlink to a file it does not own (a trusted script in a sibling checkout,
# say), and the shell redirection that "pins" the content follows the
# symlink and TRUNCATES the target before the write ever completes -- fail
# calmly for us here, silently wreck something else entirely. Unset (every
# local/native use), this resolves exactly as before.
CONFIG="${GL_CONFIG_PATH:-.gitleaks.toml}"   # relative default — resolved from cwd (= repo root, see below)

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
# The native full-tree scan (scan_outgoing_full_tree, below) applies the base
# rules and the operator overlay DIRECTLY — independent of the repo's own
# (PR-controlled) config, which gl_preflight resolves for the differential and
# widen layers. Refuse if the overlay is missing or malformed.
gl_mandatory_preflight || exit 1
MANDATORY_IGNORE_DIR="$(mktemp -d)"
MANDATORY_COMMIT_IDS=""

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

    # Identity guard (a scrubbed-email-resurfacing regression class): public commits carry noreply identity
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
    # GL_IGNORE_PATH (trusted lane only): gitleaks reads .gitleaksignore from
    # the SCANNED working tree regardless of --gitleaks-ignore-path (proven
    # on the scratch repo) -- so a PR's own copy at the repo root is removed
    # (rm, never a write -- rm does not follow a symlink to its target) by
    # the caller's base-ref pin step before this ever runs, and the flag
    # below supplies the base's content from a runner-owned path instead.
    local -a ignore_flag=()
    [[ -n "${GL_IGNORE_PATH:-}" ]] && ignore_flag=(--gitleaks-ignore-path "$GL_IGNORE_PATH")
    gitleaks git . \
        --log-opts="$logopts" \
        --config="$GL_EFFECTIVE_CONFIG" \
        --no-banner --redact=100 --ignore-gitleaks-allow \
        "${ignore_flag[@]+"${ignore_flag[@]}"}" \
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

# --- Two more ranges, beyond "not yet on the remote" ---
#
# scan_logopts above answers "is anything NEW in this push dirty?" It misses
# two real gaps (receipted A22): a branch pushed once, then pushed again with
# no new commits after the operator ruleset changed — the not-yet-pushed
# range is empty the second time, so nothing gets rescanned under the new
# rules; and a leak that has sat in the tracked tree since before any range
# scan existed, which no differential range ever revisits. Both widen checks
# run on the TIP being pushed, independent of what changed this push.

# default_branch_ref — the remote's advertised HEAD, "<remote>/<branch>".
#
# GL_BASE_REF short-circuits all of this when the caller already knows the
# base ref (the universal CI: the PR's base branch is a workflow fact, never
# a guess). CI's checkout runs with `persist-credentials: false`, and
# `actions/checkout` never writes `refs/remotes/<remote>/HEAD` -- so on a
# PRIVATE repo, both paths below fail (no local symref, and an anonymous
# `ls-remote` against a private remote fails outright once the token is
# gone), and the widen scan hits the ambiguous-BLOCK every time regardless
# of content -- observed on a clean push with nothing to find. GL_BASE_REF
# is CI's fix for its own gap; the fallbacks below remain for the
# native-hook / local-push case, where no such value exists to pass in.
#
# `refs/remotes/<remote>/HEAD` is only ever written by `git clone` (or an
# explicit `git remote set-head`) — a repo set up via `git remote add` +
# `git fetch`, which is how this hook's own test fixtures (and plenty of
# real checkouts) are built, never gets it. Falling back straight to a BLOCK
# there would fail nearly every push for a reason unrelated to any leak, so
# this tries the local symref first (fast, no network) and only reaches to
# the remote itself (`git ls-remote --symref`, one extra round-trip to a
# remote we are already pushing to this instant) before giving up.
#
# Two distinct failure shapes, returned as distinct exit codes so the caller
# can tell them apart: 1 = the remote has other refs but which one is the
# default branch could not be determined (ambiguous — BLOCK, never guess);
# 2 = the remote genuinely has no refs at all yet (first-ever push to a
# brand-new repo — there IS no default branch to widen against, and the
# primary bootstrap over-scan already covers the whole history, so this is
# a skip, not a block).
default_branch_ref() {
    local remote="${remote_name:-origin}" ref out line target
    if [[ -n "${GL_BASE_REF:-}" ]]; then
        printf '%s' "$GL_BASE_REF"
        return 0
    fi
    if ref="$(git symbolic-ref -q "refs/remotes/$remote/HEAD" 2>/dev/null)"; then
        printf '%s' "${ref#refs/remotes/}"
        return 0
    fi
    # `git ls-remote --symref <remote> HEAD` prints two lines (the "ref:
    # refs/heads/<branch>\tHEAD" symref announcement and the "<sha>\tHEAD"
    # line) — NOT in a documented, version-stable order. An earlier version
    # of this function grabbed only the first line (`head -1`), which broke
    # on a git version/transport where the sha line prints first (a real CI
    # failure, receipted: "cannot resolve the default branch" on a remote
    # that plainly had one). Scan every line instead of trusting position.
    if out="$(git ls-remote --symref "$remote" HEAD 2>/dev/null)"; then
        line="$(grep -m1 '^ref:' <<< "$out")"
        if [[ -n "$line" ]]; then
            target="$(awk '{print $2}' <<< "$line")"   # "refs/heads/<branch>\tHEAD" -> refs/heads/<branch>
            [[ -n "$target" ]] && printf '%s/%s' "$remote" "${target#refs/heads/}" && return 0
        elif [[ -z "$out" ]] && [[ -z "$(git ls-remote --heads "$remote" 2>/dev/null)" ]]; then
            return 2  # virgin remote: no refs of any kind yet
        fi
    fi
    return 1
}

# scan_whole_branch_vs_default <tip> — rescans the WHOLE branch against the
# default branch every push, so a second push with nothing new still gets
# checked under whatever ruleset is installed right now.
scan_whole_branch_vs_default() {
    local tip="$1" base rc
    base="$(default_branch_ref)"; rc=$?
    if [[ "$rc" -eq 2 ]]; then
        return  # virgin remote — nothing to widen against yet
    elif [[ "$rc" -ne 0 ]]; then
        gl_block "Pre-push BLOCKED: cannot resolve the default branch" \
            "The remote has other refs, but neither its HEAD symref nor" \
            "'git ls-remote --symref' named one — refusing to guess which" \
            "branch to widen the rescan against." \
            "Fix: git remote set-head ${remote_name:-<remote>} -a"
        blocked=1
        return
    fi
    # No same-ref short-circuit: $base is a symbolic name ("origin/main"), not
    # a resolved SHA, so it is never string-equal to $tip even when they are
    # the same commit — and scan_logopts already no-ops cleanly on a
    # zero-commit range, so there is nothing to optimize here.
    scan_logopts "whole branch vs default branch ($base..$tip)" "$base..$tip"
}

# --- Native full-tree scanner (the step-3 addition) --------------------------
#
# The differential range scan and the widen-vs-default scan above are diff/patch
# based and resolved through gl_preflight's REPO config (PR-controlled) — the
# trusted lane's contract. This layer is the config-independent backstop a PR
# cannot suppress: for every OUTGOING commit it scans the COMPLETE tree, reading
# each blob DIRECTLY via `git cat-file` (never `git archive`, which honours
# `.gitattributes` export-ignore — a real blind spot for the tree-content scan),
# plus the raw commit message and the destination ref name, under the installed
# operator overlay used directly (base rules + overlay), refusing on a missing or
# malformed overlay. A symlink blob is written as a plain file holding its target
# path (its payload is scanned; the link is never followed). Output is counts and
# commit ids only — filenames, ref names and raw scanner errors can carry the
# secret.
#
# Enumeration is by ancestry off the remote's ADVERTISED object id, never a stale
# local tracking ref: new ref / a base that is not an ancestor -> every commit
# reachable from the tip (over-scan); a base that IS an ancestor -> base..tip; a
# base whose object is missing locally (shallow clone) -> refuse. Each tip's own
# tree is scanned unconditionally too, so a re-push with no new commits still
# rescans the resident tree under the current rules (the A21 coverage that
# scan_tracked_head_tree gave, now cat-file based and config-independent).

# mandatory_ignore_flag — the trusted lane may pin base-ref ignore content at a
# RUNNER-owned path (GL_IGNORE_PATH, never PR-controlled); otherwise point at an
# empty dir so the repo's own (PR-controlled) .gitleaksignore is never consulted.
mandatory_ignore_flag() {
    if [[ -n "${GL_IGNORE_PATH:-}" ]]; then
        printf '%s\0%s\0' "--gitleaks-ignore-path" "$GL_IGNORE_PATH"
    else
        printf '%s\0%s\0' "--gitleaks-ignore-path" "$MANDATORY_IGNORE_DIR"
    fi
}

# materialize_commit_tree <commit> <tree-scratch> — write every blob in the
# commit's complete tree, sha-sharded. The sha-sharded dir IS the same-push
# seen-set: `mkdir` (atomic, no -p) fails if this blob content was already
# materialized, so two blobs at the same path across commits never collide (a
# later clean blob must not overwrite an earlier secret-bearing one). bash-3.2
# safe — no associative array (`declare -A` is a runtime error on /bin/bash 3.2,
# which is what `#!/usr/bin/env bash` resolves to on the estate's Macs).
materialize_commit_tree() {
    local commit="$1" scratch="$2" entry meta path _mode _type blob shard dest
    while IFS= read -r -d '' entry; do
        meta="${entry%%$'\t'*}"; path="${entry#*$'\t'}"
        read -r _mode _type blob <<< "$meta"
        [[ "$_type" == "commit" ]] && continue    # submodule gitlink — no blob
        shard="$scratch/$blob"
        mkdir "$shard" 2>/dev/null || continue
        dest="$shard/$path"
        mkdir -p "$(dirname "$dest")" 2>/dev/null || continue
        git cat-file -p "$blob" > "$dest" 2>/dev/null
    done < <(git ls-tree -r -z --full-tree "$commit" 2>/dev/null)
}

# mandatory_outgoing <tip> <base> — print the outgoing commit shas per the
# ancestry rule, or set blocked=1 and return 1 to refuse (missing remote object).
mandatory_outgoing() {
    local tip="$1" base="$2"
    [[ "$tip" == "$ZERO" ]] && return 0
    if [[ -z "$base" || "$base" == "$ZERO" ]]; then
        git rev-list "$tip" 2>/dev/null; return 0
    fi
    if ! git cat-file -e "${base}^{commit}" 2>/dev/null; then
        gl_block "Pre-push BLOCKED: remote object missing locally" \
            "Cannot verify ancestry for the remote's advertised object (likely a" \
            "shallow clone). Fetch full history before pushing. (Fail-closed.)"
        blocked=1; return 1
    fi
    if git merge-base --is-ancestor "$base" "$tip" 2>/dev/null; then
        git rev-list "${base}..${tip}" 2>/dev/null
    else
        git rev-list "$tip" 2>/dev/null       # force-push / rewrite: over-scan
    fi
    return 0
}

# mandatory_scan_dir <desc> <source-dir> — one gitleaks pass over an
# already-materialized directory under the operator overlay. Sets blocked=1 and
# reports a count plus the push's outgoing commit ids only.
mandatory_scan_dir() {
    local desc="$1" src="$2" report errf rc count
    [[ -z "$(ls -A "$src" 2>/dev/null)" ]] && return 0
    # gitleaks --no-git reads a .gitleaksignore from the SCANNED tree regardless
    # of --gitleaks-ignore-path; neutralise any a PR planted among the blobs.
    find "$src" -type f -name '.gitleaksignore' -delete 2>/dev/null
    local -a ig=(); while IFS= read -r -d '' a; do ig+=("$a"); done < <(mandatory_ignore_flag)
    report="$(mktemp)"; errf="$(mktemp)"
    gitleaks detect --no-git --source "$src" \
        --config "$GL_MANDATORY_CONFIG" "${ig[@]}" \
        --no-banner --redact=100 --ignore-gitleaks-allow \
        --report-format json --report-path "$report" \
        </dev/null >/dev/null 2>"$errf"
    rc=$?
    if grep -qE 'fatal:|stderr is not empty|FTL|Failed to load config|panic:' "$errf" \
        || { [[ "$rc" -eq 0 ]] && command -v jq >/dev/null 2>&1 && ! jq -e . "$report" >/dev/null 2>&1; }; then
        gl_block "Pre-push BLOCKED: scanner error ($desc)" \
            "gitleaks reported an error or produced no valid report." \
            "(Fail-closed: a scanner crash must never pass.)"
        blocked=1
    elif [[ "$rc" -ne 0 ]]; then
        count="$(command -v jq >/dev/null 2>&1 && jq 'length' "$report" 2>/dev/null)"
        gl_block "Pre-push BLOCKED: sensitive content found ($desc)" \
            "${count:-one or more} finding(s) across this push's outgoing commits:" \
            "${MANDATORY_COMMIT_IDS:-(commit list unavailable)}" \
            "Remediation: rewrite the offending commit(s) so the value is gone from" \
            "EVERY commit, not just the tip (rebase -i / commit --amend / filter-repo)."
        blocked=1
    fi
    rm -f "$report" "$errf"
}

# scan_outgoing_full_tree — the driver: enumerate outgoing commits for every ref
# update (MREF_*), materialize every tree + message, collect ref names, then scan
# each under the operator overlay. Reports outgoing commit ids only.
scan_outgoing_full_tree() {
    MTREE="$(mktemp -d)"; MMSG="$(mktemp -d)"; MREFDIR="$(mktemp -d)"
    local i=0 tip base name commit commits
    local -a all_commits=()
    while [[ $i -lt ${#MREF_TIPS[@]} ]]; do
        tip="${MREF_TIPS[$i]}"; base="${MREF_BASES[$i]}"; name="${MREF_NAMES[$i]}"
        [[ -n "$name" ]] && printf '%s' "$name" > "$MREFDIR/ref$i"
        # The tip's own tree, unconditionally (resident-tree / re-push coverage).
        [[ "$tip" != "$ZERO" ]] && materialize_commit_tree "$tip" "$MTREE"
        if commits="$(mandatory_outgoing "$tip" "$base")"; then
            while IFS= read -r commit; do
                [[ -z "$commit" ]] && continue
                all_commits+=("$commit")
                materialize_commit_tree "$commit" "$MTREE"
                git show -s --format='%B' "$commit" > "$MMSG/$commit" 2>/dev/null
            done <<< "$commits"
        fi
        i=$((i + 1))
    done
    if [[ ${#all_commits[@]} -gt 0 ]]; then
        MANDATORY_COMMIT_IDS="$(printf '%s\n' "${all_commits[@]}" | sort -u | tr '\n' ' ')"
    fi
    mandatory_scan_dir "outgoing commit trees" "$MTREE"
    mandatory_scan_dir "outgoing commit messages" "$MMSG"
    mandatory_scan_dir "destination ref names" "$MREFDIR"
    rm -rf "$MTREE" "$MMSG" "$MREFDIR"; MTREE=""; MMSG=""; MREFDIR=""
}

# Tips actually being pushed this invocation — populated below, widened over
# once each after the existing differential scan.
declare -a WIDEN_TIPS=()
# Parallel ref-update record for the config-independent full-tree scan: the tip,
# the remote's advertised base (ZERO/"" = new/unknown -> all reachable), and the
# destination ref name (scanned for secrets in its own right).
declare -a MREF_TIPS=() MREF_BASES=() MREF_NAMES=()

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
        WIDEN_TIPS+=("$to")
        MREF_TIPS+=("$to"); MREF_BASES+=("${from:-$ZERO}"); MREF_NAMES+=("$label")
    else
        scan_logopts "$from..$to ($label)" "$from..$to"
        WIDEN_TIPS+=("$to")
        MREF_TIPS+=("$to"); MREF_BASES+=("$from"); MREF_NAMES+=("$label")
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
        WIDEN_TIPS+=("$local_sha")
        MREF_TIPS+=("$local_sha"); MREF_BASES+=("$remote_sha"); MREF_NAMES+=("$remote_ref")
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
    WIDEN_TIPS+=("HEAD")
    MREF_TIPS+=("HEAD"); MREF_BASES+=("$ZERO"); MREF_NAMES+=("")

else
    # --- genuinely indeterminate: FAIL CLOSED --------------------------------
    # No stdin protocol, no FROM/TO refs, AND no remote name: the hook was
    # invoked outside a real pre-push context. Blocking is correct here.
    gl_block "Pre-push BLOCKED: cannot determine what is being pushed" \
        "No pre-push protocol on stdin, no PRE_COMMIT_TO_REF, and no remote name." \
        "Refusing to push unscanned. (Fail-closed: an unknown range must not pass.)"
    blocked=1
fi

# Widen once per distinct tip actually being pushed (over-scan across
# multiple refs in one invocation is safe; the alternative is under-scan).
if [[ ${#WIDEN_TIPS[@]} -gt 0 ]]; then
    while read -r tip; do
        [[ -z "$tip" ]] && continue
        scan_whole_branch_vs_default "$tip"
    done < <(printf '%s\n' "${WIDEN_TIPS[@]}" | sort -u)
fi

# The config-independent full-tree scan (every outgoing commit's complete tree,
# each raw message, and every destination ref name, under the operator overlay).
# Runs whenever there is a ref update to scan — the backstop a PR cannot suppress.
if [[ ${#MREF_TIPS[@]} -gt 0 ]]; then
    scan_outgoing_full_tree
fi

[[ "$blocked" -ne 0 ]] && exit 1
exit 0
