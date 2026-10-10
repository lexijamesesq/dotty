# Agent working contract

On entering this checkout, a fresh clone or a linked worktree, prepare its native
checks before authoring. Use the maintained dotty checkout at
`${DOTTY_CHECKOUT:-$HOME/Repos/dotty}` and run `scripts/prepare-checkout.sh <checkout>`.
The helper validates `.pre-commit-config.yaml`, installs all three hook stages and
their environments, and verifies declared local tools. It does not run project
tests. Resolve any failure before writing commits or publishing. Preserve custom
hook owners and `core.hooksPath`; do not disable them to make setup pass.

For estate Git/GitHub authoring from Codex (app or CLI), use the installed process
boundary on every invocation:

```sh
~/.config/op-agent/bin/estate-codex --mode estate -- bash -c '"$APP_GH" pr list'
~/.config/op-agent/bin/estate-codex --mode estate -- bash -c 'bash "${DOTTY_CHECKOUT:-$HOME/Repos/dotty}/scripts/prepare-checkout.sh" "$1"' -- "$PWD"
```

Run subsequent Git commands in the same launcher boundary. Use `"$APP_GH"` for
GitHub operations inside that child shell. Missing Cody installation or binding
blocks authoring; never fall back to human/Claude credentials or set `CLAUDECODE`.
Claude keeps its existing enrolled profile and session-init hook. Re-run readiness
when entering another clone/worktree during either session; setup in one checkout
does not prepare a different checkout.

Use the native hook stages and repository commands. Do not bypass checks with
`--no-verify`, `SKIP`, altered hook paths, or disabled scanners. Correct the finding
and retry. Keep staged-content, commit-message and outgoing-history scans active;
never expose scanner findings containing confidential content. Before every PR create or body edit, validate the exact body file with
`python3 "$DOTTY_CHECKOUT/.github/scripts/pr-body-check.py" --template .github/pull_request_template.md --body-file <body-file>`
(or `--body-file -` for stdin). Publish that same file with `gh pr create --body-file`
or `gh pr edit --body-file` through the appropriate agent identity. This validates
structure; retain applicable content/confidentiality scanning too.

Test changed behavior through its real interface using the narrowest relevant
existing suite. Do not add implementation-mirroring assertions, test-count quotas
or a new fleet suite. A new regression assertion needs a meaningful negative
control or red/green result; invalid imports or broken fixtures do not count.
Fixture repositories must clear inherited Git routing so tests cannot mutate the
caller's object store. Distinguish source tests from actual installed-agent proof.

Dotty's focused suites are `.claude/eval/*.test.sh`. Select the component touched;
checkout-readiness changes use `bash .claude/eval/lib/fixture-env.sh bash .claude/eval/prepare-checkout.test.sh`. Run manual fixture suites through that child boundary too; it clears inherited Git and push context without changing the author session. Native push entries select hook, workflow and release components from the outgoing range; do not manually repeat the complete suite before them. The
shared CI release must preserve the independently pinned Margot legacy path.
