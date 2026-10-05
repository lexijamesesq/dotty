#!/usr/bin/env bash
# tag-plugin-release.sh <plugin_dir> <plugin_name>
#
# Push-time (main only). If the plugin's declared version isn't
# tagged on origin yet, cuts the tag and a GitHub Release. Idempotent and
# re-entrant: the tag-exists check is remote-authoritative
# (git ls-remote), and the Release is checked and created independently of
# the tag so a failure between the two steps doesn't leave a tag with no
# Release forever.
set -euo pipefail

PLUGIN_DIR="$1"
PLUGIN_NAME="$2"

# PLUGIN_DIR is a workflow-controlled literal (never interpolated into
# untrusted content); the version string plugin.json holds is read via
# argv/json, never through a python -c string interpolation, since this
# job holds contents: write + a real GH token.
CURRENT_VERSION="$(python3 -c "
import json, sys
print(json.load(open(sys.argv[1] + '/.claude-plugin/plugin.json'))['version'])
" "$PLUGIN_DIR")"
TAG="${PLUGIN_NAME}--v${CURRENT_VERSION}"

if git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1; then
	echo "$PLUGIN_NAME: $TAG already exists on origin"
else
	echo "$PLUGIN_NAME: tagging $TAG"
	claude plugin tag --push -m "%s" "$PLUGIN_DIR"
fi

if gh release view "$TAG" >/dev/null 2>&1; then
	echo "$PLUGIN_NAME: Release $TAG already exists"
	exit 0
fi

PREV_TAG="$(git tag -l "${PLUGIN_NAME}--v*" --sort=-v:refname | grep -vF "$TAG" | head -1 || true)"

echo "$PLUGIN_NAME: cutting Release $TAG"
if [[ -n "$PREV_TAG" ]]; then
	gh release create "$TAG" --generate-notes --notes-start-tag "$PREV_TAG"
else
	gh release create "$TAG" --generate-notes
fi
