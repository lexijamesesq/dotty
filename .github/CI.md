# CI workflow shape

For consumers use [the native setup assets](../new-repo/README.md).
Their `CI` caller invokes `estate-pr-ci.yml@v1`, which runs the trusted scan
and classification in one reusable job. Dotty's own `ci.yml` uses the same
caller. Keep the required local proof for each caller and the separate release,
plugin-release and Ollie workflows that serve their own project duties.

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
  run per group and replaces it, not just cancels a *running* one. (A repo
  whose release job instead delegates to this repo's own
  `estate-plugin-release.yml` gets the release-is-never-dropped half of this
  guarantee for free, at that one shared definition: its `release-tag` job
  keys its own concurrency group on `github.sha` independent of whatever the
  caller's own workflow-level block does, specifically so the guarantee
  doesn't depend on every caller's block agreeing — see that file's own
  concurrency comment. The event-conditional workflow-level form above still
  matters for a repo's *other* jobs, or for a repo that releases without the
  reusable.)
- **`timeout-minutes:`** on every job. A hung step should fail loud, not eat
  the default 6-hour runner cap.
- **Diff-scoped checks use git's own rename detection** (`git diff
  --name-status -M100% --diff-filter=d`, excluding `R100` entries) —
  exact renames are not changed content. A raw `--name-only` diff, or a
  third-party action's default changed-files list, doesn't make this
  distinction: a whole-directory rename (e.g. `claude/` -> `.claude/`)
  makes every file's path change with zero content change, so any check
  gated on "files this PR touched" ends up gating on the entire
  pre-existing tree instead. This exact rename-aware scope is not used by the
  current native CI workflow. Revisit with a real reference implementation if
  a repo needs renamed-file-aware diff scoping again.
- **Every `uses:` action pinned to a full commit SHA**, version in a trailing
  comment (`uses: owner/repo@<40-char-sha> # vX.Y.Z`) — never a floating tag.
  A tag can be retargeted; `tj-actions/changed-files`' tags v1–v45.0.7 were
  retroactively rewritten in a real 2025 supply-chain compromise
  (CVE-2025-30066, CVSS 8.6) that exfiltrated CI secrets from 23,000+ repos.
  Resolve a tag's SHA once (`gh api repos/<owner>/<repo>/git/refs/tags/<tag>`
  or `gh api repos/<owner>/<repo>/commits/<tag>`) to pin it the first time.
  After that, Renovate owns every bump — including a major — and automerges
  it on green (see Renovate below); nobody hand-bumps a third-party pin
  again.
  This is a rule about **third-party** actions, and it is not the estate's own
  rule for its own reusables. A caller pins `lexijamesesq/dotty/.github/
  workflows/estate-*.yml@v1` — a first-party major tag that dotty's
  release-on-merge moves, GitHub's own convention for same-owner actions, and
  the reason one dotty release no longer fans out into a pin-bump pull request
  per caller. The retargeting risk the CVE above describes is a risk from
  someone else's tag; `v1` is moved by this estate's own release job. The
  calendar tags stay immutable and are what a human cites for "what shipped
  when" — only `v1` ever moves.

**Workflow headings remain `CI`.** The caller job is named `Shared`, and
the reusable job is named `Pre-Merge Checks`. GitHub's live PR merge panel
displays `CI / Shared / Pre-Merge Checks`; the API check name and required
context are `Shared / Pre-Merge Checks`. The public reviewer package job is
named `Package Validation`, displayed as `CI / Package Validation` under
the same workflow. Required-check configuration uses the API name without
the outer workflow heading and preserves its GitHub Actions reporter binding.

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
is purely functional. Consumers that run their own gitleaks job reference
`uses: lexijamesesq/dotty/.github/actions/setup-gitleaks@v1` (or, if already
checking dotty out locally for another reason, the local relative path).
`v1` is the moving tag release-on-merge places on every release, so a
consumer follows dotty's current release. A calendar-commit
pin was the earlier shape; it went stale within the day and nothing bumped
it.

Dotty's own workflows use the local composite action from the checkout.
`.github/zizmor.yml` permits the floating `v1` form only at this exact
consumer subpath, while `default.json` keeps Renovate from digest-pinning the
first-party moving tag.

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

When a release is due, this workflow installs the retained eval-suite tools and
runs `.claude/eval/run-all.sh` once before writing the calendar tag, GitHub
Release, or `v1`. The retained suites no longer run automatically on each PR;
agents may still run them manually ad hoc.

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
its job — neither pin channel below is Dependabot; no repo in this
estate carries a `.github/dependabot.yml` (checked across dotty and
every readable enrolled repo). Both channels are Renovate instead,
self-hosted in `renovate.yml` and run as Ollie — not the hosted Mend
Renovate app, which that workflow's own header records as uninstalled.
It fires on `Release on merge` completing on `main`, a 15-minute
schedule, and `workflow_dispatch`; the repo list it bumps is derived
live from `rulesets/default-branch.json`'s `.repos` keys, so enrolling
a repo there also enrolls it here. Its shared preset (`default.json`)
enables the `github-actions` and `pre-commit` managers (plus one
`custom.regex` manager for the npm pin beside a node pre-commit hook's
`rev:`): every pre-commit hook bump groups into one PR per repo and
automerges on green; this estate's own reusable workflows (`@v1`) and
composite actions (`setup-gitleaks@v1`) are excluded from Renovate's
default digest-pinning so they keep floating; third-party actions
automerge on every update type, including majors.
