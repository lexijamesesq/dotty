# CI workflow shape

The pattern every repo's `.github/workflows/*.yml` copies. Land new
workflows this way; bring existing ones up to it opportunistically, not as a
standalone effort.

## The shape

- **Least-privilege `permissions:`** at the workflow's top level, not per-job
  unless a job genuinely needs more. `contents: read` covers a workflow that
  only checks out code and runs tests/lint — no PR comments, no pushes, no
  releases. Widen only for a job that actually calls the GitHub API.
- **`concurrency:`**, grouped on `${{ github.workflow }}-${{ github.ref }}`
  (or similarly unique per-branch). `cancel-in-progress: true` unconditionally
  is correct for a test-only workflow (this repo's own) — a superseded push
  shouldn't keep burning runner minutes on a PR nobody's looking at anymore.
  A repo whose workflow also **tags and releases on push to `main`** needs
  the event-conditional form instead: `cancel-in-progress: ${{
  github.event_name == 'pull_request' }}`, group keyed on `github.sha` for
  non-PR events and `github.ref` for PR events. Unconditional
  cancel-in-progress on a shared push-triggered group can silently drop a
  version-bump's release run in favor of a later no-bump push landing before
  the first run starts — GitHub's default queue holds at most one *pending*
  run per group and replaces it, not just cancels a *running* one. See
  `core-skills/.github/CI.md` and its `ci.yml` for the reference
  implementation and the receipted reasoning.
- **`timeout-minutes:`** on every job. A hung step should fail loud, not eat
  the default 6-hour runner cap.
- **Diff-scoped checks use git's own rename detection** (`git diff
  --name-status -M100% --diff-filter=d`, excluding `R100` entries) —
  exact renames are not changed content. A raw `--name-only` diff, or a
  third-party action's default changed-files list, doesn't make this
  distinction: a whole-directory rename (e.g. `claude/` -> `.claude/`)
  makes every file's path change with zero content change, so any check
  gated on "files this PR touched" ends up gating on the entire
  pre-existing tree instead. See Wiki's `.github/workflows/ci.yml` for the
  reference implementation, including the path-scoped-exemption edge case
  (a file moving out of an exempt directory via a pure rename still needs
  re-evaluating under its new path).
- **Every `uses:` action pinned to a full commit SHA**, version in a trailing
  comment (`uses: owner/repo@<40-char-sha> # vX.Y.Z`) — never a floating tag.
  A tag can be retargeted; `tj-actions/changed-files`' tags v1–v45.0.7 were
  retroactively rewritten in a real 2025 supply-chain compromise
  (CVE-2025-30066, CVSS 8.6) that exfiltrated CI secrets from 23,000+ repos.
  Resolve a tag's SHA once (`gh api repos/<owner>/<repo>/git/refs/tags/<tag>`
  or `gh api repos/<owner>/<repo>/commits/<tag>`) and pin it; bump
  deliberately, not automatically.

**Workflow `name:` is inconsistent across repos, documented not fixed.** dotty's and dotty-private's own workflow file is named `Tests`; the five other active repos' equivalent is named `CI`. Neither is wrong on its own, but the split is unintentional (no ticket named it) rather than a stated convention. Left as-is rather than renamed here — a workflow `name:` change is a live-repo edit with its own blast radius (required-check matching, notification text) that a documentation pass shouldn't fold in silently; pick one name and land it as its own small change if it's worth doing.

## Decisions recorded here so they aren't re-proposed without new facts

**gitleaks: a composite action (`.github/actions/setup-gitleaks`), not
`gitleaks/gitleaks-action`.** The vendor action runs its own self-contained
scan inside a Node process with no documented way to leave the `gitleaks`
binary on PATH for a later step — dotty's eval suite hard-requires the real
binary on PATH (`gh-pr-body-guard.test.sh` and `gitleaks-hooks.test.sh` both
drive the actual pre-commit gitleaks hook during tests, `exit 2` if the
binary is missing). Its default PR-scan-range and `gitleaks:allow`-comment
handling are also undocumented, which would silently change security
behavior this repo currently controls explicitly (`--log-opts` range
scoping, `--ignore-gitleaks-allow`). No license cost either way (free for
personal-account repos; only orgs need `GITLEAKS_LICENSE`) — the rejection
is purely functional. Consumers (Wiki, hazel) pin
`uses: lexijamesesq/dotty/.github/actions/setup-gitleaks@<full-sha>` (or, if
already checking dotty out locally for another reason, the local relative
path) — only once `<full-sha>` is a commit on dotty's `main`, never a
pre-merge branch tip.

**actionlint: kept as a pinned curl+checksum install, not a reusable
action.** `rhysd/actionlint` publishes no official `uses:` action — only a
curl-run shell script with no documented independent checksum verification.
dotty's existing install (pinned release, checksums-file verified,
`sha256sum -c`, exact-match assertion) is at least as rigorous. Revisit only
if actionlint ships an official reusable action with equivalent integrity
verification.

**This repo's release scheme is CI, on merge, with nobody in the loop
— `release-on-merge.yml`.** It was a local, operator-invoked skill
until v2026.09.18, and the failure that ended that arrangement is on
the record: a release step a human has to start is a release step that
does not get started. v2026.09.16, .17 and .18 were cut by hand with
no GitHub Release behind them, and the pre-commit hook channel sat at
v2026.09.07 while CI ran v2026.09.18. Releasing is now a consequence
of merging, not a separate act.

The workflow runs on `push` to `main`. `.github/scripts/
next-calendar-tag.sh` decides — side-effect free, so
`.claude/eval/next-calendar-tag.test.sh` can drive it against fixture
repositories rather than prove it in production. A merge that changes
no exported surface (`.pre-commit-hooks.yaml`, `git-hooks/**`,
`.github/workflows/estate-*.yml`, `.github/actions/**`) releases
nothing. Otherwise the tag is `vYYYY.MM.DD` for the day's first
release and `vYYYY.MM.DD-N` for a later one, N the next integer
(compared numerically, never lexically) after the highest existing
suffix, the bare tag counting as `-1`. It refuses rather than guesses
on a same-day tag that does not fit the scheme.

The tag is ANNOTATED and tagged as `github-actions[bot]`, which
`rulesets/default-branch.json` declares a release-tag author — the
drift check audits tag origin because no ruleset can. Tag and Release
are created independently, in both the fresh-cut and the re-entry
path, so a failure between them never leaves a tag permanently without
its Release; re-running the failed run resumes at the Release.

The workflow is deliberately NOT named `estate-*.yml`: that glob is
the exported-workflow surface it watches. Consumer pin bumps are not
its job — the workflow channel's callers are kept current by each
repo's own Dependabot `github-actions` updater. The pre-commit
channel's `rev:` bumps have no automated lane yet; that is a separate
piece of work, and this one deliberately moves no consumer's pin.
