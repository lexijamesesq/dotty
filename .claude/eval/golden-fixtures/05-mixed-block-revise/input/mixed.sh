#!/usr/bin/env bash
# Mixed-finding fixture — both a Block (secret) and a Revise (hardcoded path).

GH_TOKEN="ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
CONFIG="/Users/devperson/code/myapp"

git config --global token "$GH_TOKEN"
cd "$CONFIG"
