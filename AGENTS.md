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
unsetting or overwriting it. Existing host provisioning owns system binaries;
repository-native setup owns project dependencies and required files. Missing
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
