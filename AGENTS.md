# Agent working contract

The existing estate Git template installs pre-commit, pre-push, commit-msg and
prepare-commit-msg entrypoints in new agent clones and initializations. Linked
worktrees share their repository's hook directory. Checks run at ordinary Git
events; no session-start setup is needed. Pre-commit installs and caches managed
hook environments when first used.

For an existing checkout missing its native hooks, install them once from its
root through the enrolled author identity:

```sh
pre-commit validate-config .pre-commit-config.yaml
pre-commit install --hook-type pre-commit --hook-type pre-push \
  --hook-type commit-msg --hook-type prepare-commit-msg
```

Preserve custom hooks and `core.hooksPath`; integrate their owner rather than
unsetting or overwriting it. Native hook installation does not install system
binaries. Existing host provisioning owns them, including Vale for prose checks;
the established Homebrew declaration supplies Vale through normal package
verification. Repository-native setup owns project dependencies and required files. Missing
prerequisites must fail clearly through the applicable hook or project command.
Do not run project tests merely to install hooks, or rerun installation each
session. `DOTTY_CHECKOUT` selects maintained reviewed source for shared commands.

For estate Git/GitHub authoring from Codex (app or CLI), use the installed process
boundary on every invocation:

```sh
~/.config/op-agent/bin/estate-codex --mode estate -- bash -c '"$APP_GH" pr list'
```

Run subsequent Git commands in the same launcher boundary. Use `"$APP_GH"` for
GitHub operations inside that child shell. Missing Cody installation or binding
blocks authoring; never fall back to human/Claude credentials or set `CLAUDECODE`.
Claude keeps its enrolled profile and the same existing estate Git template.
Git events run local checks independently of either agent's session startup.

Use the native hook stages and repository commands. Do not bypass checks with
`--no-verify`, `SKIP`, altered hook paths, or disabled scanners. Correct the finding
and retry. Keep staged-content, commit-message and outgoing-history scans active;
never expose scanner findings containing confidential content. Before every PR create or body edit, validate the exact body file with
`python3 "$DOTTY_CHECKOUT/.github/scripts/pr-body-check.py" --template .github/pull_request_template.md --body-file <body-file>`
(or `--body-file -` for stdin). Publish that same file with `gh pr create --body-file`
or `gh pr edit --body-file` through the appropriate agent identity. This validates
structure; retain applicable content/confidentiality scanning too.

Finish the candidate and relevant local checks before publication. For a new PR,
push successfully, then create it once with the complete title and validated
body. Do not publish a placeholder and immediately replace it, or edit
descriptions just to add CI progress or run links visible on GitHub.

For an existing PR, finish the local changes and prepare any necessary description
update before pushing. Identify the outgoing commit and only checks already
completed; do not claim a future push or hook result. Validate and scan the exact
body file as above. After the normal push succeeds, publish the necessary edit
once, immediately, before polling CI or drafting further prose. Combine title and
body changes in that edit. If the push fails, resolve it and revalidate any changed
candidate or body before publication. Read back the final head, title and body,
then follow CI and Margot through completion.

Keep scope, risk and verification claims accurate for the published head. A push
and a description edit are separate GitHub events; a prompt edit gives native
cancellation an earlier opportunity to stop superseded work but cannot guarantee
zero wasted runner time. Preserve description-triggered scanning, classification
and review, and the existing cancellation behavior.

Test changed behavior through its real interface using the narrowest relevant
existing suite. Do not add implementation-mirroring assertions, test-count quotas
or a new fleet suite. A new regression assertion needs a meaningful negative
control or red/green result; invalid imports or broken fixtures do not count.
Fixture repositories must clear inherited Git routing so tests cannot mutate the
caller's object store. Distinguish source tests from actual installed-agent proof.

Dotty's focused suites are `.claude/eval/*.test.sh`. Select the component touched.
Run manual fixture suites through `bash .claude/eval/lib/fixture-env.sh`; it
clears inherited Git and push context without changing the author session. Dotty's retained
regression suites run automatically once in `release-on-merge.yml`, after a
release is due and before any tag or release write. Agents may run suites
manually ad hoc; pre-push does not invoke them.
