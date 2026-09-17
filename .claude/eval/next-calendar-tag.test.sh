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

for export_path in ".pre-commit-hooks.yaml" "git-hooks/pre-push.sh" \
                   ".github/workflows/estate-ci.yml" ".github/actions/setup-x/action.yml"; do
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
touch_commit "$R" ".github/scripts/next-calendar-tag.sh"
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

finish
