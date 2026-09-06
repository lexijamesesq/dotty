#!/usr/bin/env bash
# Test suite for the three house-scaffold pre-commit hooks, ported
# from gate-mechanical.sh's Step 1/2 (gate.md § Scaffold, A3/A6/A7):
#   git-hooks/house-scaffold-no-tracked-scratch.sh
#   git-hooks/house-scaffold-sample-shape.sh
#   git-hooks/house-scaffold-sample-placeholder.sh
#
# Each runs over `git ls-files`, so every case builds a throwaway git repo,
# tracks its fixture files, and runs the hook from inside it.
#
# Run: bash ~/bin/dotty/.claude/eval/house-scaffold.test.sh

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/assert.sh"

HOOKS_DIR="${HOOKS_DIR:-${SCRIPT_DIR}/../../git-hooks}"
NO_SCRATCH="$HOOKS_DIR/house-scaffold-no-tracked-scratch.sh"
SAMPLE_SHAPE="$HOOKS_DIR/house-scaffold-sample-shape.sh"
SAMPLE_PLACEHOLDER="$HOOKS_DIR/house-scaffold-sample-placeholder.sh"

for f in "$NO_SCRATCH" "$SAMPLE_SHAPE" "$SAMPLE_PLACEHOLDER"; do
    [[ -f "$f" ]] || { echo "FATAL: missing $f"; exit 2; }
done

TMP="$(mktemp -d -t house-scaffold-test.XXXXXX)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

# make_repo <name> — a fresh, tracked-and-committed throwaway git repo.
make_repo() {
    local dir="$TMP/$1"
    mkdir -p "$dir"
    git -C "$dir" init -q
    git -C "$dir" config user.email "fixture@example.invalid"
    git -C "$dir" config user.name "Fixture"
    echo "$dir"
}

section "Hook: house-scaffold-no-tracked-scratch"

REPO="$(make_repo scratch-tracked)"
mkdir -p "$REPO/scratch"
echo "x" > "$REPO/scratch/notes.md"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m fixture
assert_exit "no-tracked-scratch: blocks a tracked scratch/ dir" 1 bash -c "cd '$REPO' && '$NO_SCRATCH'"

REPO="$(make_repo scratch-clean)"
echo "x" > "$REPO/README.md"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m fixture
assert_exit "no-tracked-scratch: passes with no scratch/evals tracked" 0 bash -c "cd '$REPO' && '$NO_SCRATCH'"

section "Hook: house-scaffold-sample-shape"

REPO="$(make_repo sample-missing)"
echo 'Resolve secrets via settings.local.json for this repo.' > "$REPO/CLAUDE.md"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m fixture
assert_exit "sample-shape: blocks a bare reference with no sample counterpart" 1 bash -c "cd '$REPO' && '$SAMPLE_SHAPE'"

REPO="$(make_repo sample-present)"
echo 'Resolve secrets via settings.local.json for this repo.' > "$REPO/CLAUDE.md"
echo '{"TODO: fill in": true}' > "$REPO/settings.local.sample.json"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m fixture
assert_exit "sample-shape: passes when the sample counterpart is tracked" 0 bash -c "cd '$REPO' && '$SAMPLE_SHAPE'"

section "Hook: house-scaffold-sample-placeholder"

REPO="$(make_repo placeholder-missing)"
echo '{"real_looking_key": "not-a-placeholder-value"}' > "$REPO/config.sample.json"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m fixture
assert_exit "sample-placeholder: blocks a sample with no placeholder marker" 1 bash -c "cd '$REPO' && '$SAMPLE_PLACEHOLDER'"

REPO="$(make_repo placeholder-present)"
echo '{"api_key": "YOUR_VALUE_HERE"}' > "$REPO/config.sample.json"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m fixture
assert_exit "sample-placeholder: passes when a placeholder marker is present" 0 bash -c "cd '$REPO' && '$SAMPLE_PLACEHOLDER'"

finish
