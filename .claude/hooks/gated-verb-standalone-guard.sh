#!/usr/bin/env bash
# gated-verb-standalone-guard.sh
#
# PreToolUse hook (matcher: Bash): denies Bash commands where a gated git verb
# (git push, gh pr merge, gh pr create) appears anywhere except the one
# position the per-action approval gate can see — the very start of the
# command, in bare form, with no chain operators after it.
#
# Receipt: the permission layer's ask rules prefix-match the Bash command
# string. A publish sequence embedding `git push` and `gh pr merge` mid-chain
# (`cd repo && git log && git push`) presented commands that start with `cd`,
# so no ask rule matched and public pushes plus a merge landed without the
# operator's per-action word. The gate was intact; the command style walked
# around its matcher. This guard closes that shape: a gated verb must be the
# whole command, so the ask rule always fires on it.
#
# Allowed shapes — exactly the forms the estate's ask rules glob-match, and
# nothing else: `git push [args]`, `git -C <path> push [args]`,
# `gh pr merge [args]`, `gh pr create [args]` — each as the entire command.
# The rule set carries bare and starred forms for every verb
# (`Bash(git push)` + `Bash(git push *)`, `Bash(git -C * push)` +
# `Bash(git -C * push *)`, `Bash(gh pr merge)` + `Bash(gh pr merge *)`,
# `Bash(gh pr create)` + `Bash(gh pr create *)`) so every admitted shape
# has a matching rule. From another directory, `git -C <path> push` is the
# sanctioned form; gh takes `--repo`.
#
# Denied shapes:
#   1. A gated verb after any chain operator (&&, ;, ||, |) — the mid-chain
#      form the receipt is about.
#   2. A gated verb at the start but with a chain operator later
#      (`git push && gh pr merge`, `git push | tail`) — one prompt would
#      cover two actions, or output-trimming hides what the approval saw.
#   3. Prefixed/flagged forms outside the ask rules' globs: env-var
#      prefixes, `git --git-dir=... push`, `git -c <cfg> push`. The
#      allowed-shape check is case-sensitive because the ask globs are —
#      `Git Push` matches no rule, so it matches no allowance here either.
#
# Accepted over-blocks (safe direction — a false deny costs a retype, a
# false allow skips an approval gate): ANY command that mentions a gated
# verb — in a grep pattern, a commit message, a PR-comment body, prose —
# and does not itself start with an askable shape is denied, chain operator
# or not (`rg "git push" hooks/`, `echo remember to gh pr merge later`).
# An askable start with chain characters anywhere, including inside quoted
# args (`gh pr create --body "a && b"`), is denied too. Restructure the
# command rather than routing around the check.
# Same honesty note as git-hook-bypass-guard.sh: this is string-matching on
# one tool_input.command, porous to shell indirection (variable-assembled
# verbs, aliases, eval). It is defense-in-depth for the approval gate's
# matcher, not a boundary.
#
# Failure posture: FAIL-OPEN on infra errors (jq missing, empty/malformed
# stdin, wrong tool_name) — no opinion, exit 0, normal permission
# evaluation runs untouched. Same rationale as git-hook-bypass-guard.sh:
# a broken hook must narrow defense-in-depth, not brick the Bash tool.
#
# Tests: .claude/eval/gated-verb-standalone-guard.test.sh
# Spec: {workspace_root}/System/Knowledge/publishing-gate-architecture.md

set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat 2>/dev/null)
[[ -z "$INPUT" ]] && exit 0

TOOL_NAME=$(jq -r '.tool_name // empty' <<<"$INPUT" 2>/dev/null)
[[ "$TOOL_NAME" == "Bash" ]] || exit 0

CMD=$(jq -r '.tool_input.command // empty' <<<"$INPUT" 2>/dev/null)
[[ -z "$CMD" ]] && exit 0

# Normalize whitespace runs to single spaces; trim leading/trailing space.
CMD_NORM=$(tr -s '[:space:]' ' ' <<<"$CMD" | sed -e 's/^ //' -e 's/ $//')
LOWER_NORM=$(tr '[:upper:]' '[:lower:]' <<<"$CMD_NORM")

deny() {
    {
        echo "gated-verb-standalone-guard: blocked — $1"
        echo ""
        echo "Public-repo push/PR/merge require per-action approval, and the approval"
        echo "gate glob-matches the command string. Run the gated verb as the entire"
        echo "command — git push, git -C <path> push, gh pr merge, gh pr create (flags"
        echo "and args fine; no chains, no pipes, no env/--git-dir prefix). From another"
        echo "directory use git -C <path> push; gh takes --repo."
    } >&2
    exit 2
}

# Boundary class shared with git-hook-bypass-guard.sh.
BND="[[:space:];&|\"']"

# Gated-verb detection, including flagged git forms (git -C <path> push,
# git --git-dir=<p> push). Flag tokens may carry =values or a following
# non-dash value token; POSIX ERE backtracking still matches bare
# `git push` through the optional groups.
FLAGVAL="[[:space:]]-[-[:alnum:]]+(=[^[:space:]]+)?([[:space:]][^-][^[:space:]]*)?"
RE_GATED="(^|$BND)(git($FLAGVAL)*[[:space:]]push|gh[[:space:]]pr[[:space:]](merge|create))($|$BND)"

[[ "$LOWER_NORM" =~ $RE_GATED ]] || exit 0

# A gated verb is present. Allowed only in the exact shapes the ask rules
# glob-match — case-sensitive, checked against the case-preserved command —
# and with no chain operators anywhere.
RE_ASKABLE="^(git push|git -C [^[:space:]]+ push|gh pr (merge|create))($|[[:space:]])"
if [[ "$CMD_NORM" =~ $RE_ASKABLE ]]; then
    if [[ "$CMD_NORM" == *"&&"* || "$CMD_NORM" == *";"* || "$CMD_NORM" == *"||"* || "$CMD_NORM" == *"|"* ]]; then
        deny "gated verb with a chain operator (&&, ;, ||, |) in the same command"
    fi
    exit 0
fi

deny "gated verb outside the ask rules' matchable shapes (mid-chain, prefixed, or wrong case)"
