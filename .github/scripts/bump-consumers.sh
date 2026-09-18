#!/usr/bin/env bash
# bump-consumers.sh <tag> <dotty-checkout>
#
# The consumer half of this repo's release path: after release-on-merge has cut
# <tag> and moved `v1`, walk every enrolled consumer and, for each one whose
# `.pre-commit-config.yaml` pins this repository at some other rev, open (or
# update) one pull request moving that pin to <tag> — authored by Ollie, merged
# by the estate's dependency-bot path with nobody in the loop.
#
# WHAT THIS REPLACES, and the receipted failure behind it. The retired
# `release-dotty` skill had two halves: cut the tag, then bump every consumer's
# pin (`release-dotty.sh:253` ran `pre-commit autoupdate --repo <this repo>` by
# hand, in a local checkout, at the operator's keystroke). release-on-merge took
# over the first half. This script is the second half, and it exists because the
# skill was only ever run by hand, so it was not run: the pre-commit hook channel
# sat at v2026.09.07 while CI ran v2026.09.18. A propagation step a human has to
# start is a propagation step that does not happen.
#
# ONE central job, not a scheduled workflow per consumer. Fourteen daily
# schedules would burn Actions minutes on a budget already at 100% to discover
# nothing on most days, and would add up to a day of latency to a bump that
# queued work is waiting on. This runs exactly when there is something to
# propagate, because the thing that propagates is the thing that just happened.
#
# =========================================================================
# WHY THIS DOES NOT RUN `pre-commit autoupdate`, which is what the plan named.
# =========================================================================
# Because on this repository it resolves the WRONG TAG, deterministically, on
# every release. Receipted live 2026-09-17 against main at 5394ce9:
#
#   $ git describe --tags --abbrev=0 origin/main        ->  v1
#   $ pre-commit autoupdate --repo <this repo>          ->  updating ... -> v1
#
# autoupdate resolves a pin with `git describe --tags --abbrev=0`, which, when
# several annotated tags sit on one commit, returns the one with the newest
# tagger date. release-on-merge moves `v1` AFTER it cuts the calendar tag, in the
# same run, so `v1` is seconds newer every time and wins every time. Note that
# next-calendar-tag.sh avoids this only because it passes `--match 'v20*'`, which
# autoupdate has no way to pass.
#
# And `rev: v1` is not merely a different answer, it is a BROKEN one. pre-commit's
# local store is keyed `PRIMARY KEY (repo, ref)`, so a moving ref is cloned once
# and reused forever: every machine would freeze at whatever `v1` pointed to the
# first time it ran, while the config file went on reading as current. pre-commit
# says so itself, in a warning this estate has already seen in the wild:
#   "The 'rev' field ... appears to be a mutable reference (moving tag / branch).
#    Mutable references are never updated after first install and are not
#    supported."
# That would silently undo the gating pre-push slice B shipped, which is the exact
# hole the A2 -> B -> A1 sequencing exists to keep closed.
#
# So this script writes the tag it was HANDED — the one release-on-merge just cut,
# known exactly, never re-derived — and then asserts the rewritten file reads back
# as that tag. The stolen APPROACH the operator named (bot PR -> green ->
# auto-merge) is intact; only the stolen COMMAND is dropped, because it is
# structurally incompatible with a floating tag sharing a commit with the calendar
# tag. The assertion is something autoupdate could not have given: it has no
# target-rev flag to check itself against.
#
# =========================================================================
# THE READINESS GATE, and the receipted failure behind it.
# =========================================================================
# A consumer is bumped only if it is already ON the bot pipe: its margot.yml must
# both pin `estate-margot.yml@v1` and pass `OLLIE_APP_KEY`. Without this gate the
# first run would open a pull request in all thirteen consumers at once, and
# twelve of them still call `estate-margot.yml@v2026.09.18`, which has no bot path
# and no Ollie. Each would draw a full paid Margot review (the ~$5.60-$44 per
# patch the operator's decision exists to avoid) and NONE would merge, because
# Ollie is not a bypass actor in a caller that never hands it the key. The signal
# lives in the consumer's own files, so this needs no new declared surface: a repo
# joins the pipe by taking the caller change, and the bump follows it.
#
# Side effects are confined to the four api() calls below. Everything that
# DECIDES is a pure function over file text, so the suite in
# .claude/eval/bump-consumers.test.sh drives it on fixtures instead of proving it
# in production.
set -euo pipefail

TAG="${1:?usage: bump-consumers.sh <tag> <dotty-checkout>}"
DOTTY="${2:?usage: bump-consumers.sh <tag> <dotty-checkout>}"

# This repository, as a consumer's `.pre-commit-config.yaml` names it, and as the
# enrolled-repo list names it. One constant, because a mismatch between the two
# would silently bump nothing.
SELF_REPO="lexijamesesq/dotty"
SELF_URL="https://github.com/${SELF_REPO}"
BUMP_BRANCH="dotty-bump"

log()  { printf '%s\n' "$*" >&2; }
note() { printf '::notice::%s\n' "$*"; }

# ---- The only seam that touches the network -------------------------------
# Every read and write goes through here, so the eval suite replaces exactly one
# function and drives the whole script on fixtures. Overridable by pointing
# BUMP_CONSUMERS_LIB at a file that redefines it.
api() { gh api "$@"; }

if [[ -n "${BUMP_CONSUMERS_LIB:-}" ]]; then
  # shellcheck disable=SC1090
  source "$BUMP_CONSUMERS_LIB"
fi

# ---- Pure: who is enrolled ------------------------------------------------
# The declared list, read from the same rulesets JSON the ruleset converge and
# estate-margot's bot path read. One source, so a repo cannot be enrolled for
# review and invisible to propagation. This repository is excluded: it does not
# pin itself.
consumer_list() {
  jq -r --arg self "$SELF_REPO" \
    '.repos | keys[] | select(. != $self)' "$1"
}

# ---- Pure: the current pin ------------------------------------------------
# Prints the `rev:` value of the block whose `repo:` is this repository, or
# nothing if this repository is not pinned at all (a legitimate case — not every
# enrolled repo consumes the hooks).
#
# Anchored on the repo line and then the FIRST rev line after it, which is
# pre-commit's own file shape. Deliberately not a bare `grep rev:`: a config
# pinning several repositories would otherwise have some other project's pin
# rewritten to this repository's tag.
pin_rev() {
  awk -v url="$SELF_URL" '
    $1 == "-" && $2 == "repo:" { inblock = ($3 == url || $3 == url ".git") ; next }
    $1 == "repo:"              { inblock = ($2 == url || $2 == url ".git") ; next }
    inblock && $1 == "rev:"    { print $2; exit }
  ' "$1"
}

# ---- Pure: the rewrite ----------------------------------------------------
# Rewrites that one `rev:` value to $TAG, in place, preserving indentation, any
# trailing comment, and every other line byte for byte. A YAML round-trip would
# have been the obvious tool and is the wrong one: it would reformat the file and
# drop the comments these configs carry.
rewrite_rev() {
  local file="$1" tag="$2" tmp
  tmp="$(mktemp)"
  awk -v url="$SELF_URL" -v tag="$tag" '
    function emit_rev(line,   indent, rest, comment) {
      match(line, /^[[:space:]]*/); indent = substr(line, 1, RLENGTH)
      rest = substr(line, RLENGTH + 1)
      # The match starts at the WHITESPACE before the `#`, not at the `#`, so a
      # comment keeps the exact spacing the author gave it. Re-emitting it with a
      # single space would rewrite a line this job is not there to reformat, and
      # would show up as noise in a diff nobody reviews.
      comment = ""
      if (match(rest, /[[:space:]]*#.*$/)) comment = substr(rest, RSTART)
      print indent "rev: " tag comment
    }
    $1 == "-" && $2 == "repo:" { inblock = ($3 == url || $3 == url ".git") ; print; next }
    $1 == "repo:"              { inblock = ($2 == url || $2 == url ".git") ; print; next }
    inblock && $1 == "rev:" && !done { emit_rev($0); done = 1; next }
    { print }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

# ---- Pure: is this consumer on the bot pipe? ------------------------------
# Both halves are required and each answers a different failure. The `@v1` pin is
# what makes the caller reach a reusable that HAS a bot path at all. The
# OLLIE_APP_KEY pass-through is what lets that path's merge step actually merge
# rather than log why it stopped. A consumer with one and not the other opens a
# pull request that cannot finish, which is worse than not opening one.
#
# A trailing `# comment` on the `uses:` line is ACCEPTED. The stricter form
# (`@v1` then end of line) fails closed, which is the right direction, but it
# would have been a trap: the callers this gate reads are hand-written and the
# provisioner is about to start writing them, and a comment on that line is
# ordinary. Refusing to bump a repo that is genuinely on the pipe, silently and
# forever, is not the failure this gate is for. `@v1` still has to be the whole
# ref — `@v1.2` and `@v10` do not match.
pipe_ready() {
  local margot="$1"
  grep -Eq '^[[:space:]]*uses:[[:space:]]*lexijamesesq/dotty/\.github/workflows/estate-margot\.yml@v1[[:space:]]*(#.*)?$' "$margot" \
    && grep -Eq '^[[:space:]]*OLLIE_APP_KEY:' "$margot"
}

# ---- Effectful: read one file from a consumer's default branch ------------
# Prints the decoded content to stdout, or returns 1 if the path does not exist.
# `-q .content` with base64 decoding rather than the raw media type, so a missing
# path is a clean non-zero rather than an empty file that would read as "no pin".
read_file() {
  local repo="$1" path="$2" out
  out="$(api "repos/${repo}/contents/${path}" -q '.content' 2>/dev/null)" || return 1
  [[ -n "$out" ]] || return 1
  printf '%s' "$out" | tr -d '\n' | base64 --decode
}

main() {
  local rulesets="${DOTTY}/rulesets/default-branch.json"
  [[ -f "$rulesets" ]] || { log "FATAL: no rulesets JSON at $rulesets"; exit 1; }

  local due=0 skipped=0 failed=0 repo
  while IFS= read -r repo; do
    [[ -n "$repo" ]] || continue

    local workdir config margot
    workdir="$(mktemp -d)"
    config="${workdir}/.pre-commit-config.yaml"
    margot="${workdir}/margot.yml"

    if ! read_file "$repo" ".pre-commit-config.yaml" > "$config"; then
      note "${repo}: no .pre-commit-config.yaml — nothing to bump."
      skipped=$((skipped + 1)); rm -rf "$workdir"; continue
    fi

    local current
    current="$(pin_rev "$config")"
    if [[ -z "$current" ]]; then
      note "${repo}: does not pin ${SELF_REPO} — nothing to bump."
      skipped=$((skipped + 1)); rm -rf "$workdir"; continue
    fi

    if [[ "$current" == "$TAG" ]]; then
      note "${repo}: already at ${TAG}."
      skipped=$((skipped + 1)); rm -rf "$workdir"; continue
    fi

    if ! read_file "$repo" ".github/workflows/margot.yml" > "$margot" || ! pipe_ready "$margot"; then
      note "${repo}: not on the bot pipe yet (margot.yml must pin estate-margot.yml@v1 AND pass OLLIE_APP_KEY). Pin stays at ${current}; the rollout PR for this repo is what opens the gate."
      skipped=$((skipped + 1)); rm -rf "$workdir"; continue
    fi

    rewrite_rev "$config" "$TAG"

    # The assertion autoupdate could not give: read the rewritten file back and
    # require it to say exactly the tag release-on-merge cut. A rewrite that
    # silently matched nothing would otherwise open a no-op pull request that
    # merges and propagates nothing.
    local after
    after="$(pin_rev "$config")"
    if [[ "$after" != "$TAG" ]]; then
      log "FAIL ${repo}: rewrite produced rev '${after}', expected '${TAG}'"
      failed=$((failed + 1)); rm -rf "$workdir"; continue
    fi

    if publish_bump "$repo" "$config" "$current"; then
      due=$((due + 1))
    else
      failed=$((failed + 1))
    fi
    rm -rf "$workdir"
  done < <(consumer_list "$rulesets")

  log "bumped: ${due}  skipped: ${skipped}  failed: ${failed}"
  [[ "$failed" -eq 0 ]]
}

# ---- Effectful: branch, commit, pull request ------------------------------
# One bump branch per consumer, at a fixed name, RESET to the consumer's current
# default-branch tip on every run. That reset is not tidiness: the bot path's
# merge step enforces `behind_by == 0` itself, because a bypass actor is not
# subject to the ruleset's strict-checks policy. A branch left where it was cut
# would fall behind its base and the merge would skip forever, silently. Cutting
# it fresh each release is what keeps it mergeable.
#
# An open bump pull request is UPDATED, never stacked: the branch name is fixed,
# so pushing to it updates the existing pull request and re-fires its CI, which
# re-fires the bot path. A second pull request for the same purpose is never
# opened.
#
# EVERY call below carries an explicit `|| return 1`, and that is not belt and
# braces — without it this function does not fail at all. `set -e` is DISABLED
# for the whole body of a function invoked as an `if` condition, which is exactly
# how main() calls this one. Verified, not assumed:
#
#   set -euo pipefail
#   f() { x="$(false)"; echo "STILL RUNNING x='${x}'"; return 0; }
#   if f; then echo "failure swallowed"; fi
#   -> STILL RUNNING x=''
#   -> failure swallowed
#
# So a failing first API call would leave base_sha empty, every later call would
# fail and be ignored in turn, and the function would still return 0 and be
# counted as a successful bump. "Failure is isolated per consumer" would have
# been false in precisely the case that matters. An explicit `|| return 1` works
# regardless of the errexit context; wrapping the body in a `set -e` subshell
# would not, because the caller's `if` is what suppresses it.
publish_bump() {
  local repo="$1" config="$2" old="$3"
  local base base_sha blob_sha content

  base="$(api "repos/${repo}" -q '.default_branch')" || return 1
  base_sha="$(api "repos/${repo}/git/ref/heads/${base}" -q '.object.sha')" || return 1
  [[ -n "$base" && -n "$base_sha" ]] || return 1

  # Create the branch, or force it back onto the current base tip if a previous
  # release left one behind.
  if api "repos/${repo}/git/ref/heads/${BUMP_BRANCH}" >/dev/null 2>&1; then
    api -X PATCH "repos/${repo}/git/refs/heads/${BUMP_BRANCH}" \
      -f "sha=${base_sha}" -F "force=true" >/dev/null || return 1
  else
    api -X POST "repos/${repo}/git/refs" \
      -f "ref=refs/heads/${BUMP_BRANCH}" -f "sha=${base_sha}" >/dev/null || return 1
  fi

  # The blob sha on the branch, which now equals the base tip.
  blob_sha="$(api "repos/${repo}/contents/.pre-commit-config.yaml?ref=${BUMP_BRANCH}" -q '.sha')" || return 1
  [[ -n "$blob_sha" ]] || return 1

  # Encoded BEFORE the call rather than inside its argument list: a command
  # substitution that fails inside an argument is another failure this function's
  # suppressed errexit would not catch.
  content="$(base64 < "$config" | tr -d '\n')" || return 1

  # The contents API, not a clone and a git push. It needs no working tree, it
  # cannot leak a token into a remote URL, and a commit it creates under an App
  # token is GitHub-signed and therefore verified — which a pushed commit from a
  # bare token is not.
  api -X PUT "repos/${repo}/contents/.pre-commit-config.yaml" \
    -f "message=Bump the dotty pre-commit pin to ${TAG}" \
    -f "content=${content}" \
    -f "sha=${blob_sha}" \
    -f "branch=${BUMP_BRANCH}" >/dev/null || return 1

  local existing
  existing="$(api "repos/${repo}/pulls?state=open&head=${repo%%/*}:${BUMP_BRANCH}" -q '.[0].html_url' 2>/dev/null || true)"
  if [[ -n "$existing" && "$existing" != "null" ]]; then
    note "${repo}: updated the open bump PR to ${TAG} (${old} -> ${TAG}) ${existing}"
    return 0
  fi

  # A short factual body. Dependency bots are exempt from the pr-body-check, so
  # this deliberately does not carry the seven-heading template: it would be
  # ceremony around a one-line diff nobody reviews. It names the two revs and the
  # Release, and nothing else — no secret, no token, no key material.
  local url
  url="$(api -X POST "repos/${repo}/pulls" \
    -f "title=Bump the dotty pre-commit pin to ${TAG}" \
    -f "head=${BUMP_BRANCH}" \
    -f "base=${base}" \
    -f "body=Moves this repo's \`.pre-commit-config.yaml\` pin of ${SELF_REPO} from \`${old}\` to \`${TAG}\`, so the hook channel runs the same release CI does.

Opened automatically by dotty's release-on-merge after it cut ${TAG}. Release notes: ${SELF_URL}/releases/tag/${TAG}" \
    -q '.html_url')" || return 1
  [[ -n "$url" ]] || return 1
  note "${repo}: opened ${url} (${old} -> ${TAG})"
}

# Run only when EXECUTED, not when sourced. The eval suite sources this file to
# drive the pure functions directly on fixtures; without this guard, sourcing it
# would run the whole walk against the real network.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
