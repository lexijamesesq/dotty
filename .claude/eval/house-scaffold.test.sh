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
#
# Every call site captures this via command substitution (REPO="$(make_repo
# ...)"), which runs the function in a SUBSHELL — an `exit` inside it only
# kills that subshell, not the suite, and a failed assert_repo_identity
# would silently yield an EMPTY captured path instead of aborting (verified:
# `git -C "" ...` treats an empty -C as "use the real cwd", the exact
# wrong-repo class this check exists to close). So the identity assertion
# runs OUTER, once per call site, on the captured path itself — never
# inside the subshelled helper.
make_repo() {
    local dir="$TMP/$1"
    mkdir -p "$dir"
    git -C "$dir" init -q
    git -C "$dir" config user.email "fixture@example.invalid"
    git -C "$dir" config user.name "Fixture"
    echo "$dir"
}

section "Hook: house-scaffold-no-tracked-scratch"

REPO="$(make_repo scratch-tracked)"; assert_repo_identity "$REPO"
mkdir -p "$REPO/scratch"
echo "x" > "$REPO/scratch/notes.md"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m fixture
assert_exit "no-tracked-scratch: blocks a tracked scratch/ dir" 1 bash -c "cd '$REPO' && '$NO_SCRATCH'"

REPO="$(make_repo scratch-clean)"; assert_repo_identity "$REPO"
echo "x" > "$REPO/README.md"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m fixture
assert_exit "no-tracked-scratch: passes with no scratch/evals tracked" 0 bash -c "cd '$REPO' && '$NO_SCRATCH'"

section "Hook: house-scaffold-sample-shape"

# The reference name is assembled at runtime, never spelled out as one
# contiguous literal in this file's own source: dotty's publish-gate
# scaffold check (a different, out-of-scope tool this ticket does not
# touch) greps tracked file TEXT for this exact shape with no path
# exemption of its own, so a static literal here reads as a real bare
# reference in dotty's own tree, not a fixture. The runtime behavior under
# test — a real repo whose tracked CLAUDE.md names this reference — is
# unchanged.
ref_name="widget-conf"; ref_name="${ref_name}ig.json"

REPO="$(make_repo sample-missing)"; assert_repo_identity "$REPO"
printf 'Resolve secrets via %s for this repo.\n' "$ref_name" > "$REPO/CLAUDE.md"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m fixture
assert_exit "sample-shape: blocks a bare reference with no sample counterpart" 1 bash -c "cd '$REPO' && '$SAMPLE_SHAPE'"

REPO="$(make_repo sample-present)"; assert_repo_identity "$REPO"
printf 'Resolve secrets via %s for this repo.\n' "$ref_name" > "$REPO/CLAUDE.md"
echo '{"TODO: fill in": true}' > "$REPO/${ref_name%.json}.sample.json"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m fixture
assert_exit "sample-shape: passes when the sample counterpart is tracked" 0 bash -c "cd '$REPO' && '$SAMPLE_SHAPE'"

# The recurring false positive (rollout receipt): Claude Code's own standard
# per-user local-override settings file is always gitignored, never
# repo-committed, and never needs a sample of its own — fixed in the hook
# itself after the same exemption showed up independently in four separate
# consumer repos. Assembled at runtime for the same self-trip reason as
# ref_name above.
settings_local="settings.local"; settings_local="${settings_local}.json"

REPO="$(make_repo sample-shape-settings-local)"; assert_repo_identity "$REPO"
printf '.claude/%s\n' "$settings_local" > "$REPO/.gitignore"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m fixture
assert_exit "sample-shape: never flags settings.local.json (no sample needed, ever)" 0 bash -c "cd '$REPO' && '$SAMPLE_SHAPE'"

section "Hook: house-scaffold-sample-placeholder"

REPO="$(make_repo placeholder-missing)"; assert_repo_identity "$REPO"
echo '{"real_looking_key": "not-a-placeholder-value"}' > "$REPO/config.sample.json"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m fixture
assert_exit "sample-placeholder: blocks a sample with no placeholder marker" 1 bash -c "cd '$REPO' && '$SAMPLE_PLACEHOLDER'"

REPO="$(make_repo placeholder-present)"; assert_repo_identity "$REPO"
echo '{"api_key": "YOUR_VALUE_HERE"}' > "$REPO/config.sample.json"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m fixture
assert_exit "sample-placeholder: passes when a placeholder marker is present" 0 bash -c "cd '$REPO' && '$SAMPLE_PLACEHOLDER'"

# Widened marker set (rollout receipt: real sample files in three consumer
# repos used these two conventions and were false-flagged before the fix).
REPO="$(make_repo placeholder-your-inline)"; assert_repo_identity "$REPO"
echo '- cloud_id: YOUR_ATLASSIAN_CLOUD_ID' > "$REPO/config.sample.md"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m fixture
assert_exit "sample-placeholder: passes on an inline YOUR_X marker (no angle brackets)" 0 bash -c "cd '$REPO' && '$SAMPLE_PLACEHOLDER'"

REPO="$(make_repo placeholder-bracket)"; assert_repo_identity "$REPO"
echo '# Product Brief: [Initiative Name]' > "$REPO/config.sample.md"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m fixture
assert_exit "sample-placeholder: passes on a [Bracketed] marker" 0 bash -c "cd '$REPO' && '$SAMPLE_PLACEHOLDER'"

section "Declared one-off exemption (.house-code.json): a deprecated stub, not a --exclude flag"

REPO="$(make_repo placeholder-declared-exempt)"; assert_repo_identity "$REPO"
echo '# Deprecated: superseded, no fill-in values left' > "$REPO/persona.sample.md"
cat > "$REPO/.house-code.json" <<'EOF'
{"exemptions": [{"path": "persona\\.sample\\.md", "rule": "sample-placeholder", "reason": "deprecated stub, still referenced elsewhere; not a fill-in template (test fixture)"}]}
EOF
git -C "$REPO" add -A && git -C "$REPO" commit -q -m fixture
assert_exit "sample-placeholder: a declared exemption passes a marker-less sample" 0 bash -c "cd '$REPO' && '$SAMPLE_PLACEHOLDER'"

# The SAME declaration must not exempt an UNRELATED sample file with no
# markers — proves the exemption is scoped to the one named path, not a
# blanket "placeholder rule off" switch.
echo '{"real_looking_key": "not-a-placeholder-value"}' > "$REPO/other.sample.json"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m fixture2
assert_exit "sample-placeholder: a declared exemption does not cover an unrelated file" 1 bash -c "cd '$REPO' && '$SAMPLE_PLACEHOLDER'"

REPO="$(make_repo sample-shape-declared-exempt)"; assert_repo_identity "$REPO"
printf 'Resolve secrets via %s for this repo.\n' "$ref_name" > "$REPO/CLAUDE.md"
cat > "$REPO/.house-code.json" <<'EOF'
{"exemptions": [{"path": "widget-config\\.json", "rule": "sample-shape", "reason": "test fixture: a declared one-off for sample-shape"}]}
EOF
git -C "$REPO" add -A && git -C "$REPO" commit -q -m fixture
assert_exit "sample-shape: a declared exemption passes a reference with no sample counterpart" 0 bash -c "cd '$REPO' && '$SAMPLE_SHAPE'"

section "Fail-closed: a malformed .house-code.json blocks the scaffold hooks too"

REPO="$(make_repo scaffold-bad-declaration)"; assert_repo_identity "$REPO"
echo '{"api_key": "YOUR_VALUE_HERE"}' > "$REPO/config.sample.json"
printf 'not valid json{' > "$REPO/.house-code.json"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m fixture
assert_exit "sample-placeholder: malformed .house-code.json exits 2 (fail-closed)" 2 bash -c "cd '$REPO' && '$SAMPLE_PLACEHOLDER'"
assert_exit "sample-shape: malformed .house-code.json exits 2 (fail-closed)" 2 bash -c "cd '$REPO' && '$SAMPLE_SHAPE'"

finish
