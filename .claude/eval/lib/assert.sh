#!/usr/bin/env bash
# Shared test harness for ~/bin/dotty/.claude/eval/ shell suites.
# Convention: each test suite sources this and uses pass/fail/finish.

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
