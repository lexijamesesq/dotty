// Self-hosted Renovate's global config. Dependency policy lives in default.json,
// the shared preset every enrolled repo extends; only engine settings go here.
module.exports = {
  platform: "github",
  // The repo list arrives as RENOVATE_REPOSITORIES, derived in the workflow from
  // rulesets/default-branch.json so the two cannot drift.
  autodiscover: false,
  // Every enrolled repo already has a renovate.json, so `required` processes them
  // all and hard-skips anything reaching the list without one.
  onboarding: false,
  requireConfig: "required",
  // MIGRATION FLAG — turn off once the pull requests the hosted Mend app left open
  // have merged. It drops the author filter so Ollie adopts them instead of opening
  // duplicates; its companion is gitIgnoredAuthors in default.json.
  ignorePrAuthor: true,
  // gitAuthor is deliberately unset: Renovate derives it from the token's own App.
};
