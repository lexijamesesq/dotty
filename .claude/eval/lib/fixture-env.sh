#!/usr/bin/env bash
# Child-only fixture boundary: never source in the authoring/push selector shell.
# Ask Git for its full routing list; clear other inherited Git controls too.
while IFS= read -r fixture_key; do unset "$fixture_key"; done < <(git rev-parse --local-env-vars)
while IFS= read -r fixture_key; do unset "$fixture_key"; done < <(compgen -v GIT_)
# Nested hook fixtures must receive their own range, not the author's push.
while IFS= read -r fixture_key; do
	[[ "$fixture_key" == PRE_COMMIT_HOME ]] || unset "$fixture_key"
done < <(compgen -v PRE_COMMIT_)
unset SKIP GL_RANGE_BASE GL_RANGE_HEAD GL_CONFIG_PATH GITLEAKS_OPERATOR_RULES
unset fixture_key GH_TOKEN GITHUB_TOKEN GH_CONFIG_DIR APP_GH SSH_AUTH_SOCK SSH_ASKPASS
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_TEMPLATE_DIR='' GIT_TERMINAL_PROMPT=0 PYTHONDONTWRITEBYTECODE=1
# Suites set their own fixture identities/config where needed. Do not carry the
# caller's signing, credential helpers, hooks or init template into new repos.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	[[ $# -gt 0 ]] || {
		echo 'usage: fixture-env.sh <fixture command...>' >&2
		exit 2
	}
	exec "$@"
fi
