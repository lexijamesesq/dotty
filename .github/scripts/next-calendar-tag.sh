#!/usr/bin/env bash
# next-calendar-tag.sh <repo-dir>
#
# The whole decision half of this repo's release-on-merge: given a checkout
# whose tags are fetched, print whether a release is due and, if so, the
# calendar tag to cut. Side-effect free — it creates nothing, pushes nothing
# and reads no network. The workflow that calls it owns every write, so this
# logic can be driven by fixture repos in .claude/eval/ instead of proven only
# in production.
#
# Output (always two key=value lines, safe to append straight to $GITHUB_OUTPUT):
#
#   tag=v2026.09.19   reentry=0   a release is due; cut this tag, then its Release
#   tag=v2026.09.19   reentry=1   HEAD already carries this tag; the Release step
#                                 still runs, the tag step does not
#   tag=              reentry=0   nothing to release
#
# Exit 0 in all three cases. Exit 1 only to REFUSE — a same-day tag whose form
# this scheme does not define, or a computed tag that already exists. It never
# invents a tag form to get past either.
#
# Scheme (identical to the one the calendar tags on this repo already follow):
# the first release of a UTC day is vYYYY.MM.DD; a later one that day appends
# -N, N the next integer after the highest existing suffix for that date, the
# bare tag counting as -1. Ordering is numeric, never lexical — this repo's own
# tag list has v2026.09.07-10 above v2026.09.07-9, which -v:refname gets right
# and a plain sort does not.
#
# RELEASE_DATE overrides "today" (YYYY.MM.DD). It exists for the fixture tests
# so a suite can pin a date instead of racing the clock; the workflow never
# sets it.
set -euo pipefail

REPO="${1:-.}"
cd "$REPO"

# The exported surface: what a consumer pins this repo's tags FOR. A merge that
# touches none of it is not a release. Two classes share the one tag: the
# pre-commit-hook exports (.pre-commit-hooks.yaml, git-hooks/**) and the
# reusable workflow/action exports every caller's ci.yml and gate.yml pin.
#
# The estate-*.yml entry is QUOTED so git matches it as a pathspec against each
# side of the diff, rather than the shell matching it against the working tree.
# That is the difference between noticing a reusable workflow being ADDED or
# DELETED and noticing only the ones that happen to exist right now.
EXPORT_PATHS=(
  '.pre-commit-hooks.yaml'
  'git-hooks/'
  '.github/workflows/estate-*.yml'
  '.github/actions/'
)

emit() { printf 'tag=%s\nreentry=%s\n' "$1" "$2"; }
refuse() { echo "REFUSE: $*" >&2; exit 1; }

# ---- Re-entry -------------------------------------------------------------
# A run that created the tag and then failed before cutting the Release must
# not leave the Release uncut forever. Re-running the workflow lands here:
# HEAD is already tagged, so report that tag and let the caller skip straight
# to the Release step.
HEAD_TAG="$(git tag -l 'v20*' --points-at HEAD --sort=-v:refname | head -1)"
if [[ -n "$HEAD_TAG" ]]; then
  echo "re-entry: HEAD already carries $HEAD_TAG" >&2
  emit "$HEAD_TAG" 1
  exit 0
fi

# ---- Is a release due? ----------------------------------------------------
LAST_TAG="$(git tag -l 'v20*' --sort=-v:refname | head -1)"
if [[ -n "$LAST_TAG" ]] && git diff --quiet "$LAST_TAG" HEAD -- "${EXPORT_PATHS[@]}"; then
  echo "no exported surface changed since $LAST_TAG — nothing to release" >&2
  emit "" 0
  exit 0
fi

# ---- Compute the tag ------------------------------------------------------
TODAY="${RELEASE_DATE:-$(TZ=UTC date +%Y.%m.%d)}"
BASE_TAG="v${TODAY}"
EXISTING_TODAY="$(git tag -l "${BASE_TAG}*" --sort=-v:refname)"

if [[ -z "$EXISTING_TODAY" ]]; then
  NEW_TAG="$BASE_TAG"
else
  MAX_N=1
  while IFS= read -r t; do
    [[ -z "$t" ]] && continue
    if [[ "$t" == "$BASE_TAG" ]]; then
      continue # the bare tag is N=1, already the floor
    elif [[ "$t" =~ ^${BASE_TAG}-([1-9][0-9]*)$ ]]; then
      # [1-9][0-9]* rather than [0-9]+: a zero-padded -08 is not a form this
      # scheme defines, and bash would read it as octal and error out. Refuse
      # it by name instead of arithmetic-faulting on it.
      n="${BASH_REMATCH[1]}"
      (( n > MAX_N )) && MAX_N=$n
    else
      refuse "existing tag $t for today doesn't fit the scheme ($BASE_TAG or $BASE_TAG-N) — never inventing a form"
    fi
  done <<< "$EXISTING_TODAY"
  NEW_TAG="${BASE_TAG}-$((MAX_N + 1))"
fi

# Cheap guard, not the real defence: the caller fetches every tag before
# calling, so a hit here means the tag inventory disagreed with the arithmetic
# above. Refuse rather than push at an existing ref (this repo's tag ruleset
# makes tags immutable, so the push would fail anyway — but loudly, halfway
# through, instead of here).
if git rev-parse -q --verify "refs/tags/$NEW_TAG" >/dev/null; then
  refuse "computed tag $NEW_TAG already exists — refusing to guess"
fi

echo "release due: $NEW_TAG" >&2
emit "$NEW_TAG" 0
