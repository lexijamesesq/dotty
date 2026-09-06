#!/usr/bin/env bash
# Shared test harness for ~/bin/dotty/.claude/eval/ shell suites.
# Convention: each test suite sources this and uses pass/fail/finish.

# Scrub every GIT_* variable git exports into a hook's environment, the
# instant this file is sourced — before any suite creates its first fixture
# repo. A real incident: a suite that creates and mutates nested git repos
# as fixtures, run in a context where these were already set (a git hook
# invocation), had a nested `git -C <fixture-dir>` command land on the OUTER
# repository instead of its own isolated temp directory — the exact
# discipline git's own test suite (t/test-lib.sh) applies for the same
# reason. Every suite that sources this file gets this for free; it does
# not need its own copy.
for _v in GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_PREFIX \
          GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE; do
    unset "$_v"
done
unset _v

# assert_repo_identity <dir> — call immediately after `git init`/`git clone`
# into <dir>. Aborts the whole suite (never a soft failure another test
# could mask) if <dir>'s resolved --git-dir is not inside <dir> itself —
# the second, independent layer against the same class of bug the env
# scrub above defends: even if a variable somehow slipped through, a
# fixture repo that isn't pointed at its own directory must never be
# written to.
assert_repo_identity() {
    local dir="$1" real_dir resolved
    # Resolve $dir to its real (symlink-free) path first — macOS's own
    # /tmp -> /private/tmp symlink would otherwise make every fixture look
    # "outside its own directory" by literal-string comparison alone.
    real_dir="$(cd "$dir" && pwd -P 2>/dev/null)" || {
        echo "FATAL: assert_repo_identity: cannot resolve $dir" >&2
        exit 2
    }
    resolved="$(cd "$dir" && git rev-parse --absolute-git-dir 2>/dev/null)" || {
        echo "FATAL: assert_repo_identity: git rev-parse failed inside $dir" >&2
        exit 2
    }
    case "$resolved" in
        "$real_dir"/*|"$real_dir") : ;;
        *)
            echo "FATAL: assert_repo_identity: $dir resolves to git-dir $resolved" \
                 "— outside its own directory. Refusing to let this fixture touch it." >&2
            exit 2
            ;;
    esac
}

# Counters
TESTS_RUN=0
TESTS_PASS=0
TESTS_FAIL=0
FAILED_NAMES=()

# Color (terminal only; suppressed when not a TTY)
if [[ -t 1 ]]; then
    GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YELLOW=$'\033[0;33m'; RESET=$'\033[0m'
else
    GREEN=""; RED=""; YELLOW=""; RESET=""
fi

# pass <description>
pass() {
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_PASS=$((TESTS_PASS + 1))
    echo "  ${GREEN}PASS${RESET}: $1"
}

# fail <description> [<detail>]
fail() {
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_FAIL=$((TESTS_FAIL + 1))
    FAILED_NAMES+=("$1")
    echo "  ${RED}FAIL${RESET}: $1"
    [[ -n "${2:-}" ]] && echo "        $2"
}

# assert_exit <description> <expected-exit-code> <command...>
# Runs command in subshell, captures exit code, asserts.
assert_exit() {
    local desc="$1"; shift
    local expected="$1"; shift
    "$@" >/dev/null 2>&1
    local actual=$?
    if [[ "$actual" == "$expected" ]]; then
        pass "$desc"
    else
        fail "$desc" "expected exit $expected, got $actual"
    fi
}

# assert_eq <description> <expected> <actual>
assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        pass "$desc"
    else
        fail "$desc" "expected '$expected', got '$actual'"
    fi
}

# section <name>
section() {
    echo ""
    echo "${YELLOW}=== $1 ===${RESET}"
}

# finish — print summary, exit non-zero if any failures
finish() {
    echo ""
    if [[ $TESTS_FAIL -eq 0 ]]; then
        echo "${GREEN}All $TESTS_RUN tests passed.${RESET}"
        exit 0
    else
        echo "${RED}$TESTS_FAIL of $TESTS_RUN tests failed:${RESET}"
        for name in "${FAILED_NAMES[@]}"; do echo "  - $name"; done
        exit 1
    fi
}
