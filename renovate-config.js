// Self-hosted Renovate's GLOBAL configuration — the half that cannot live in a
// repository's own config. Dependency policy (what to bump, what to automerge,
// what to leave alone) stays in default.json, the shared preset every enrolled
// repo extends, so this file changes only when the ENGINE changes.
//
// Read by the container the Renovate workflow starts. The workflow mounts this
// file alone, so it must stay self-contained: no `require` of anything else in
// the repo would resolve inside that container.
module.exports = {
  platform: 'github',

  // The repository list is NOT here. It arrives as RENOVATE_REPOSITORIES, which
  // the workflow derives from rulesets/default-branch.json — the same declaration
  // the estate converges rulesets from — so the two cannot drift apart.
  //
  // `autodiscover: false` is Renovate's default and is restated because it is
  // load-bearing: with it off and an explicit list supplied, Renovate runs over
  // that list verbatim and discovers nothing. No repo outside the list is read
  // or written, whatever the owner-scoped token could otherwise reach.
  autodiscover: false,

  // Every enrolled repo already carries a two-line renovate.json extending the
  // preset, so `required` processes all of them — and hard-skips anything that
  // ever lands in the list WITHOUT one, instead of onboarding it. That skip is
  // the backstop against a repo joining the list by accident; `optional` would
  // throw it away, which is why the action's README recommendation is not
  // followed here.
  onboarding: false,
  requireConfig: 'required',

  // MIGRATION FLAG — not a steady-state setting.
  //
  // By default Renovate filters the PR list to its own account, so the pull
  // requests the hosted Mend app opened as `renovate[bot]` are invisible to
  // `ollie-the-intern[bot]` and would be silently reopened as duplicates. This
  // drops that filter so Ollie finds, updates and merges them instead.
  //
  // Its companion is `gitIgnoredAuthors` in default.json: without that, Renovate
  // sees the hosted app's commits on those branches, treats each branch as
  // modified by someone else, and refuses to commit to it (`pr-edited`).
  //
  // TURN THIS OFF once the adopted pull requests have merged. It costs a full
  // PR-list and a full Issues fetch per repo per run, forever, and buys nothing
  // after the migration.
  ignorePrAuthor: true,

  // `gitAuthor` is deliberately unset. Renovate derives it from the token's own
  // App identity, which is one less hand-maintained string — and a stale one
  // would be actively harmful: Renovate would commit as one identity and then
  // fail its own modified-branch check on the next run, and stop updating its
  // own pull requests.
};
