#!/usr/bin/env bash
# Test suite for .github/scripts/next-calendar-tag.sh — the decision half of
# release-on-merge. Empirical: every assertion builds a real git repository
# with real commits and real tags and runs the actual script against it. No
# mocked git, because the behaviour under test IS git's (pathspec matching on
# both sides of a diff, -v:refname ordering, annotated vs lightweight refs).
#
# Proves NON-VACUOUS (a merge touching no export cuts nothing, a malformed
# same-day tag refuses) as well as the happy path, and covers the three edges
# the live repository actually exhibits: a -9/-10 pair that only numeric
# ordering gets right, annotated and lightweight tags side by side, and a
# re-entry where HEAD is already tagged.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/assert.sh"

SCRIPT="${SCRIPT:-${SCRIPT_DIR}/../../.github/scripts/next-calendar-tag.sh}"
[[ -f "$SCRIPT" ]] || { echo "FATAL: missing $SCRIPT"; exit 2; }

TMP="$(mktemp -d -t next-calendar-tag-test.XXXXXX)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

# `git -C "" <cmd>` is a NO-OP, not an error — git simply stays where it is. A
# helper handed an empty path therefore operates on whatever repository the
# suite was launched from, which is this one. Not hypothetical: an earlier
# draft returned each fixture's path through a command substitution, a machine
# with a global hook chain printed hook output into that capture, the path came
# back unusable, and fixture tags landed on this checkout's own HEAD. Two
# defences, and no command substitution anywhere near a repository path —
# new_repo assigns the global R directly, and fx() refuses any argument that is
# not an existing directory under $TMP.
COUNTER=0
R=""

# fx <repo-dir> <git-args...> — the only way a fixture runs git. It cannot
# reach outside $TMP.
fx() {
    local d="$1"; shift
    case "$d" in
        "$TMP"/*) : ;;
        *) echo "FATAL: fx: '$d' is not a fixture directory under $TMP" >&2; exit 2 ;;
    esac
    [[ -d "$d" ]] || { echo "FATAL: fx: '$d' does not exist" >&2; exit 2; }
    git -C "$d" "$@"
}

# new_repo — sets the global R to a fresh fixture repo holding one non-export
# commit. Every fixture starts from the same floor so a test's own commits are
# the only variable. Assigns rather than echoes, deliberately (see above).
new_repo() {
    COUNTER=$((COUNTER + 1))
    R="$TMP/repo$COUNTER"
    mkdir -p "$R"
    git -C "$R" init -q -b main
    assert_repo_identity "$R"
    fx "$R" config user.email "test@example.invalid"
    fx "$R" config user.name "Test"
    fx "$R" config commit.gpgsign false
    fx "$R" config tag.gpgsign false
    echo "readme" > "$R/README.md"
    fx "$R" add README.md
    # --no-verify on fixture commits, the convention this directory's other
    # suites already follow: a throwaway repo must not drag the machine's
    # installed hook chain into a test about tag arithmetic.
    fx "$R" commit -q -m "base" --no-verify
}

# touch_commit <repo> <path> — writes a file (creating parents) and commits it.
touch_commit() {
    local d="$1" p="$2"
    mkdir -p "$d/$(dirname "$p")"
    echo "change $RANDOM" > "$d/$p"
    fx "$d" add "$p"
    fx "$d" commit -q -m "touch $p" --no-verify
}

# tag_light / tag_annotated — the two forms the live repo carries.
tag_light() { fx "$1" tag "$2"; }
tag_annotated() { fx "$1" tag -a "$2" -m "$2"; }

# run_script <repo> [date] : sets RC, TAG, REENTRY, ERR.
run_script() {
    local d="$1" date="${2:-2026.09.20}" out
    out="$(RELEASE_DATE="$date" bash "$SCRIPT" "$d" 2>"$TMP/err")"
    RC=$?
    ERR="$(cat "$TMP/err")"
    TAG="$(printf '%s\n' "$out" | sed -n 's/^tag=//p')"
    REENTRY="$(printf '%s\n' "$out" | sed -n 's/^reentry=//p')"
}

# ---------------------------------------------------------------------------
section "an export path touched on a fresh day cuts that day's bare tag"

# `rulesets/default-branch.json` and `.github/scripts/` are exports for a
# reason the first four are not: estate-margot.yml's bot path checks this repo
# out at the caller's pin and READS them at run time — the declared
# dependency-bot list and the floor-gate script. A change to either that cut no
# tag would leave every caller pinned at `v1` reading the old copy forever.
for export_path in ".pre-commit-hooks.yaml" "git-hooks/pre-push.sh" \
                   ".github/workflows/estate-ci.yml" ".github/actions/setup-x/action.yml" \
                   "rulesets/default-branch.json" ".github/scripts/margot-floor-gate.py"; do
    new_repo
    tag_annotated "$R" "v2026.09.07"
    touch_commit "$R" "$export_path"
    run_script "$R" "2026.09.20"
    assert_eq "$export_path -> v2026.09.20" "v2026.09.20" "$TAG"
    assert_eq "$export_path -> not re-entry" "0" "$REENTRY"
    assert_eq "$export_path -> exit 0" "0" "$RC"
done

section "NON-VACUOUS: no export path touched cuts nothing"

new_repo
tag_annotated "$R" "v2026.09.07"
touch_commit "$R" "README.md"
touch_commit "$R" "docs/notes.md"
touch_commit "$R" ".github/workflows/ci.yml"          # a caller, not an export
touch_commit "$R" ".claude/eval/some-suite.test.sh"   # this repo's own tests
run_script "$R" "2026.09.20"
assert_eq "non-export changes -> empty tag" "" "$TAG"
assert_eq "non-export changes -> exit 0" "0" "$RC"
printf '%s' "$ERR" | grep -q "nothing to release" && pass "says why it cut nothing" || fail "reason" "$ERR"

section "a DELETED reusable workflow still counts as an export change"
# This is what the quoted git pathspec buys over a shell glob: the deleted file
# is absent from the working tree, so a shell-expanded estate-*.yml would never
# name it and the deletion would ship untagged.

new_repo
touch_commit "$R" ".github/workflows/estate-gate.yml"
tag_annotated "$R" "v2026.09.07"
fx "$R" rm -q ".github/workflows/estate-gate.yml"
fx "$R" commit -q -m "remove an export" --no-verify
run_script "$R" "2026.09.20"
assert_eq "deletion -> v2026.09.20" "v2026.09.20" "$TAG"

section "a second cut the same day appends -2, a third -3"

new_repo
tag_annotated "$R" "v2026.09.20"
touch_commit "$R" "git-hooks/x.sh"
run_script "$R" "2026.09.20"
assert_eq "bare tag present -> -2" "v2026.09.20-2" "$TAG"

tag_annotated "$R" "v2026.09.20-2"
touch_commit "$R" "git-hooks/y.sh"
run_script "$R" "2026.09.20"
assert_eq "-2 present -> -3" "v2026.09.20-3" "$TAG"

section "suffixes increment NUMERICALLY: -9 and -10 present -> -11"
# The live repository carries exactly this pair. Lexically -9 sorts above -10,
# so a plain sort would compute -10 a second time and collide with an immutable
# tag.

new_repo
tag_annotated "$R" "v2026.09.20"
for n in 2 3 4 5 6 7 8 9 10; do tag_annotated "$R" "v2026.09.20-$n"; done
touch_commit "$R" ".pre-commit-hooks.yaml"
run_script "$R" "2026.09.20"
assert_eq "-9 and -10 present -> -11" "v2026.09.20-11" "$TAG"

section "annotated and lightweight tags side by side are read alike"
# The live repository has both: v2026.09.07-N are annotated tag objects,
# v2026.09.16/.17/.18 are lightweight refs.

new_repo
tag_annotated "$R" "v2026.09.07"
touch_commit "$R" "git-hooks/a.sh"
tag_light "$R" "v2026.09.18"
touch_commit "$R" "git-hooks/b.sh"
run_script "$R" "2026.09.20"
assert_eq "mixed tag forms -> v2026.09.20" "v2026.09.20" "$TAG"

new_repo
tag_annotated "$R" "v2026.09.07"
touch_commit "$R" "git-hooks/a.sh"
tag_light "$R" "v2026.09.18"
touch_commit "$R" "README.md"
run_script "$R" "2026.09.20"
assert_eq "mixed tag forms, no export since the lightweight one -> nothing" "" "$TAG"

section "the day's tags are found across a different day's newer tags"

new_repo
tag_annotated "$R" "v2026.09.20"
touch_commit "$R" "git-hooks/x.sh"
tag_annotated "$R" "v2026.09.21"
touch_commit "$R" "git-hooks/y.sh"
run_script "$R" "2026.09.20"
assert_eq "a later date's tag doesn't shadow today's -> -2" "v2026.09.20-2" "$TAG"

section "RE-ENTRY: HEAD already tagged reports that tag and cuts no new one"

new_repo
touch_commit "$R" "git-hooks/x.sh"
tag_annotated "$R" "v2026.09.20"
run_script "$R" "2026.09.20"
assert_eq "HEAD tagged -> same tag" "v2026.09.20" "$TAG"
assert_eq "HEAD tagged -> reentry=1" "1" "$REENTRY"
assert_eq "HEAD tagged -> exit 0" "0" "$RC"

section "a repository with no calendar tag at all releases"

new_repo
touch_commit "$R" "README.md"
run_script "$R" "2026.09.20"
assert_eq "no tags -> v2026.09.20" "v2026.09.20" "$TAG"

section "REFUSES rather than guesses on a same-day tag outside the scheme"

for bad in "v2026.09.20-0" "v2026.09.20-08" "v2026.09.20-rc1" "v2026.09.20.1"; do
    new_repo
    tag_annotated "$R" "v2026.09.20"
    tag_annotated "$R" "$bad"
    touch_commit "$R" "git-hooks/x.sh"
    run_script "$R" "2026.09.20"
    assert_eq "$bad -> exit 1" "1" "$RC"
    printf '%s' "$ERR" | grep -q "never inventing a form" && pass "$bad: names the refusal" || fail "$bad refusal message" "$ERR"
done

section "the last tag is resolved by ANCESTRY, not by which name sorts highest"
# The receipted failure: `v2026.09.18` was cut ad hoc onto an older commit on
# main, and it name-sorts above every `v2026.09.17-N`. A name sort kept answering
# v2026.09.18 however far main advanced, so every merge re-diffed the same stale
# range, saw export changes that were already released, and cut another tag. PR
# #282 touched no exported surface whatsoever and still cut v2026.09.17-3.

new_repo
touch_commit "$R" "git-hooks/exported.sh"
tag_annotated "$R" "v2026.09.18"          # high-sorting, on an OLDER ancestor
touch_commit "$R" "git-hooks/later.sh"
tag_annotated "$R" "v2026.09.17-2"        # lower-sorting, but the real last release
touch_commit "$R" "README.md"             # nothing exported since
run_script "$R" "2026.09.17"
assert_eq "high-sorting older ancestor does not resurrect a released export change" "" "$TAG"
assert_eq "...and it is not a re-entry either" "0" "$REENTRY"

# The mirror: once something exported DOES change past that lower-sorting tag, it
# releases — the ancestry fix must not have made the gate permanently quiet.
touch_commit "$R" "git-hooks/new-export.sh"
run_script "$R" "2026.09.17"
assert_eq "a real export change past the ancestry tag still releases" "v2026.09.17-3" "$TAG"

section "a tag on a branch that is not an ancestor of HEAD is ignored by the due-check"
# Shaped so it actually discriminates. The side branch's tag sits on a commit
# that ALREADY CONTAINS main's unreleased export change, so a name sort would
# diff against it, see the export as identical, and conclude nothing is due —
# silently swallowing a real release. Only an ancestry answer gets this right.

new_repo
tag_annotated "$R" "v2026.09.17"          # the real last release, on the base
touch_commit "$R" "git-hooks/unreleased.sh"   # main's export change, unreleased
MAIN_SHA="$(fx "$R" rev-parse HEAD)"
fx "$R" checkout -q -b sidebranch
touch_commit "$R" "NOTES.md"
tag_annotated "$R" "v2026.09.19"          # higher-sorting, unreachable from main,
                                          # and its tree carries unreleased.sh
fx "$R" checkout -q main
fx "$R" reset -q --hard "$MAIN_SHA"
run_script "$R" "2026.09.20"
assert_eq "an unreachable higher-sorting tag does not swallow main's unreleased export" "v2026.09.20" "$TAG"

touch_commit "$R" ".pre-commit-hooks.yaml"
run_script "$R" "2026.09.20"
assert_eq "...and a further export change on main still releases" "v2026.09.20" "$TAG"

# ...but the -N arithmetic still sees it, deliberately: it exists to avoid
# colliding with an immutable ref, and a ref on another branch collides just as
# hard as one on this line.
run_script "$R" "2026.09.19"
assert_eq "an unreachable same-day tag is still avoided by the suffix arithmetic" "v2026.09.19-2" "$TAG"

section "an untagged HEAD after a non-export commit still cuts nothing"
# The shape a re-entry test could be mistaken for: HEAD moved past the tag, but
# only over a non-export path, so there is nothing to release and nothing to
# resume. The computed-tag-already-exists refusal in the script is a guard
# against a disagreeing tag inventory, not a reachable state from here — the
# suffix arithmetic cannot return a tag the day's tag list already holds.

new_repo
touch_commit "$R" "git-hooks/x.sh"
tag_annotated "$R" "v2026.09.20"
touch_commit "$R" "README.md"
run_script "$R" "2026.09.20"
assert_eq "untagged HEAD, no export change -> nothing" "" "$TAG"
assert_eq "untagged HEAD, no export change -> not re-entry" "0" "$REENTRY"


# ---------------------------------------------------------------------------
section "the v1 tag layout: a LIGHTWEIGHT v1 must lose to the annotated calendar tag"
# ---------------------------------------------------------------------------
# Not about this script's own answer — it passes `--match 'v20*'` and never sees
# v1 — but about the CONSUMPTION side agreeing with it. `pre-commit autoupdate`
# resolves a pin with a bare `git describe --tags --abbrev=0`, which it cannot
# pass a --match to. While v1 was ANNOTATED it shared a commit with the calendar
# tag and carried the newer tagger date, so it won that tie and autoupdate wrote
# `rev: v1` — a moving pin that pre-commit caches by its own text and never
# refreshes. Making v1 lightweight is the whole fix, and this is the assertion
# that the fix holds.
#
# Both creation orders, because release-on-merge moves v1 AFTER cutting the
# calendar tag and a date-based tiebreak would make that order decide it.
new_repo
touch_commit "$R" "git-hooks/x.sh" "x"
fx "$R" tag -a "v2026.09.19" -m "v2026.09.19"
sleep 1
fx "$R" tag -f v1
assert_eq "annotated calendar tag first, lightweight v1 after: describe picks the calendar tag" \
    "v2026.09.19" "$(fx "$R" describe --tags --abbrev=0)"
assert_eq "and v1 really is lightweight" "commit" \
    "$(fx "$R" for-each-ref --format='%(objecttype)' refs/tags/v1)"

new_repo
touch_commit "$R" "git-hooks/y.sh" "y"
fx "$R" tag -f v1
sleep 1
fx "$R" tag -a "v2026.09.20" -m "v2026.09.20"
assert_eq "lightweight v1 first, annotated calendar tag after: describe still picks the calendar tag" \
    "v2026.09.20" "$(fx "$R" describe --tags --abbrev=0)"

# The regression this replaces: an ANNOTATED v1 moved last wins the tie, which
# is exactly what sent `rev: v1` into every consumer.
new_repo
touch_commit "$R" "git-hooks/z.sh" "z"
fx "$R" tag -a "v2026.09.21" -m "v2026.09.21"
sleep 1
fx "$R" tag -f -a v1 -m "v2026.09.21"
assert_eq "an ANNOTATED v1 moved last would win the tie (the bug, kept as a witness)" \
    "v1" "$(fx "$R" describe --tags --abbrev=0)"


finish
