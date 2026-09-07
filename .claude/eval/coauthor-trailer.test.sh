#!/usr/bin/env bash
# Test suite for git-hooks/coauthor-trailer.sh — the prepare-commit-msg hook
# that adds the operator's co-author trailer to a fresh BOT commit, idempotently
# and only then: not to her own commits, and not to merge/squash/amend. The
# commit source is read from positional $2 OR $PRE_COMMIT_COMMIT_MSG_SOURCE, so
# both invocation contracts (raw git hook, and pre-commit) are covered here.
#
# Run: bash ~/bin/dotty/.claude/eval/coauthor-trailer.test.sh
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/assert.sh"

HOOKS_DIR="${HOOKS_DIR:-${SCRIPT_DIR}/../../git-hooks}"
HOOK="$HOOKS_DIR/coauthor-trailer.sh"
[[ -f "$HOOK" ]] || { echo "FATAL: $HOOK not found"; exit 2; }

BOT="325510841+claude-the-enduring[bot]@users.noreply.github.com"
TRAILER="Co-authored-by: Alexis Bussa <938162+lexijamesesq@users.noreply.github.com>"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# grep -c already prints the count on stdout; capture it and swallow grep's
# nonzero exit on zero matches so it doesn't double-print via `|| echo`.
count_trailer() { local n; n=$(grep -cF "$TRAILER" "$1" 2>/dev/null); printf '%s' "${n:-0}"; }

section "A bot commit gets the trailer, idempotently"
printf 'Add a thing\n' > "$WORK/m1"
GIT_AUTHOR_EMAIL="$BOT" bash "$HOOK" "$WORK/m1" message
assert_eq "trailer added for a bot commit" "1" "$(count_trailer "$WORK/m1")"
GIT_AUTHOR_EMAIL="$BOT" bash "$HOOK" "$WORK/m1" message
assert_eq "a second run adds no duplicate" "1" "$(count_trailer "$WORK/m1")"

section "A plain commit with no source still gets the trailer"
printf 'No source given\n' > "$WORK/m-nosrc"
GIT_AUTHOR_EMAIL="$BOT" bash "$HOOK" "$WORK/m-nosrc"
assert_eq "no source (fresh commit) -> trailer added" "1" "$(count_trailer "$WORK/m-nosrc")"

section "Her own commit gets no trailer"
printf 'Her commit\n' > "$WORK/m2"
GIT_AUTHOR_EMAIL="lexi@her.example" bash "$HOOK" "$WORK/m2" message
assert_eq "no trailer for a non-bot author" "0" "$(count_trailer "$WORK/m2")"
printf 'Author unset\n' > "$WORK/m2b"
env -u GIT_AUTHOR_EMAIL bash "$HOOK" "$WORK/m2b" message
assert_eq "no trailer when GIT_AUTHOR_EMAIL is unset" "0" "$(count_trailer "$WORK/m2b")"

section "History is never relabelled (merge/squash/amend skipped) — via positional \$2"
for src in merge squash commit; do
  printf 'Imported %s\n' "$src" > "$WORK/m-$src"
  GIT_AUTHOR_EMAIL="$BOT" bash "$HOOK" "$WORK/m-$src" "$src"
  assert_eq "source=$src (\$2) is skipped even for the bot" "0" "$(count_trailer "$WORK/m-$src")"
done

section "History skip also honours the pre-commit env var (PRE_COMMIT_COMMIT_MSG_SOURCE, no \$2)"
for src in merge squash commit; do
  printf 'Imported env %s\n' "$src" > "$WORK/e-$src"
  GIT_AUTHOR_EMAIL="$BOT" PRE_COMMIT_COMMIT_MSG_SOURCE="$src" bash "$HOOK" "$WORK/e-$src"
  assert_eq "source=$src (env) is skipped even for the bot" "0" "$(count_trailer "$WORK/e-$src")"
done
# and the env-var 'message' source still gets the trailer
printf 'Env message source\n' > "$WORK/e-message"
GIT_AUTHOR_EMAIL="$BOT" PRE_COMMIT_COMMIT_MSG_SOURCE="message" bash "$HOOK" "$WORK/e-message"
assert_eq "source=message (env) -> trailer added" "1" "$(count_trailer "$WORK/e-message")"

section "The trailer lands in a proper trailer block on a multi-line message"
printf 'Subject line\n\nA body paragraph explaining the change.\n' > "$WORK/m3"
GIT_AUTHOR_EMAIL="$BOT" bash "$HOOK" "$WORK/m3" message
assert_eq "multi-line message gets exactly one trailer" "1" "$(count_trailer "$WORK/m3")"
assert_eq "trailer is the last non-empty line" "$TRAILER" "$(grep -v '^[[:space:]]*$' "$WORK/m3" | tail -1)"

section "Missing/empty args are a clean no-op"
bash "$HOOK" >/dev/null 2>&1; assert_eq "no message file -> exit 0" "0" "$?"
bash "$HOOK" "$WORK/does-not-exist" message >/dev/null 2>&1; assert_eq "absent file -> exit 0" "0" "$?"

finish
