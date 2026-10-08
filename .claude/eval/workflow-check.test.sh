#!/usr/bin/env bash
# Real static-tool failures/corrections and scope, without remote execution.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
WRAPPER="$ROOT/git-hooks/workflow-check.sh"
source "$ROOT/.claude/eval/lib/assert.sh"
TASK_TMP=$(mktemp -d)
trap 'rm -rf "$TASK_TMP"' EXIT
while IFS= read -r key; do unset "$key"; done < <(git rev-parse --local-env-vars)
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
cd "$TASK_TMP"
git init -q
mkdir -p .github/workflows .github/actions/example
cat >.github/workflows/good.yml <<'YAML'
name: fixture
on: push
jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - run: echo safe
YAML
git add .github/workflows/good.yml
cp .github/workflows/good.yml .github/workflows/bad.yml
printf '\ninvalid-root-key: true\n' >>.github/workflows/bad.yml
rc=0
git add .github/workflows/bad.yml
bash "$WRAPPER" actionlint .github/workflows/bad.yml >out 2>&1 || rc=$?
assert_eq "malformed workflow fails actionlint" 1 "$rc"
git rm --cached -q .github/workflows/bad.yml
bash "$WRAPPER" actionlint .github/workflows/good.yml >out 2>&1
assert_eq "untracked unrelated workflow is not selected" 0 "$?"
printf 'self-hosted-runner:\n  labels: []\n' >.github/actionlint.yaml
git add .github
rc=0
bash "$WRAPPER" actionlint .github/actionlint.yaml >out 2>&1 || rc=$?
assert_eq "tool configuration change selects all tracked workflows" 1 "$rc"
printf 'name: fixture\ndescription: fixture\nruns:\n  using: composite\n  steps: []\n' >.github/actions/example/action.yml
git add .github/actions/example/action.yml
rc=0
bash "$WRAPPER" actionlint .github/actions/example/action.yml >out 2>&1 || rc=$?
assert_eq "local action metadata selects caller workflows" 1 "$rc"
cp .github/workflows/good.yml .github/workflows/bad.yml
bash "$WRAPPER" actionlint .github/workflows/bad.yml >out 2>&1
assert_eq "corrected workflow passes" 0 "$?"
cat >.github/actions/example/action.yml <<'YAML'
name: fixture
description: fixture
runs:
  using: composite
  steps:
    - shell: bash
      run: echo '${{ github.event.issue.title }}'
YAML
rc=0
bash "$WRAPPER" zizmor .github/actions/example/action.yml >out 2>&1 || rc=$?
[[ "$rc" != 0 ]] && pass "composite injection is blocked" || fail "composite injection is blocked" "passed"
sed -i.bak 's/echo.*$/echo safe/' .github/actions/example/action.yml
bash "$WRAPPER" zizmor .github/actions/example/action.yml >out 2>&1
assert_eq "corrected composite passes selected audits" 0 "$?"
cat >>.github/workflows/good.yml <<'YAML'
      - uses: actions/checkout@v4
YAML
rc=0
bash "$WRAPPER" zizmor .github/workflows/good.yml >out 2>&1 || rc=$?
[[ "$rc" != 0 ]] && pass "unpinned third-party action is blocked" || fail "unpinned action" "passed"
sed -i.bak 's|actions/checkout@v4|actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1|' .github/workflows/good.yml
bash "$WRAPPER" zizmor .github/workflows/good.yml >out 2>&1
assert_eq "corrected immutable action passes" 0 "$?"
mkdir tools
for tool in dirname mktemp git rm; do
	ln -s "$(command -v "$tool")" "tools/$tool"
done
rc=0
PATH="$TASK_TMP/tools" /bin/bash "$WRAPPER" actionlint .github/workflows/good.yml >out 2>&1 || rc=$?
assert_eq "applicable missing tool fails visibly" 2 "$rc"
ln -s "$(command -v actionlint)" tools/actionlint
rc=0
PATH="$TASK_TMP/tools" /bin/bash "$WRAPPER" actionlint .github/workflows/good.yml >out 2>&1 || rc=$?
assert_eq "missing inline ShellCheck cannot silently weaken actionlint" 2 "$rc"
grep -q "BLOCKED: ShellCheck is unavailable" out || fail "missing ShellCheck is the actual failure" "$(cat out)"
git read-tree --empty
PATH="$TASK_TMP/tools" /bin/bash "$WRAPPER" actionlint README.md >out 2>&1
assert_eq "irrelevant input skips without a tool invocation" 0 "$?"
# Native pre-commit omits deleted/renamed-away paths from argv. Exercise the
# actual declaration, not only the wrapper's explicit-file interface.
python3 - "$ROOT" <<'PYTEST'
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import yaml
root = Path(sys.argv[1])
source = yaml.safe_load((root / '.pre-commit-hooks.yaml').read_text())
hook = next(h for h in source if h['id'] == 'actionlint')
hook = dict(hook, entry=str(root / 'git-hooks/workflow-check.sh') + ' actionlint')
env = {k: v for k, v in os.environ.items() if not k.startswith('GIT_')}
env.update(GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1')
with tempfile.TemporaryDirectory(prefix='workflow-native-') as temp:
    checkout = Path(temp)
    def run(args, expected=0):
        result = subprocess.run(args, cwd=checkout, env=env, text=True, capture_output=True)
        assert result.returncode == expected, result.stdout + result.stderr
        return result.stdout + result.stderr
    def check(expected=0):
        return run(['pre-commit', 'run', 'actionlint'], expected)
    def commit():
        run(['git', '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-qm', 'fixture'])
    run(['git', 'init', '-q'])
    (checkout / '.pre-commit-config.yaml').write_text(json.dumps({'repos': [{'repo': 'local', 'hooks': [hook]}]}))
    workflow = checkout / '.github/workflows/check.yml'
    workflow.parent.mkdir(parents=True)
    workflow.write_text('name: fixture\non: push\njobs:\n  check:\n    runs-on: custom-fixture\n    steps:\n      - run: echo safe\n')
    config = checkout / '.github/actionlint.yaml'
    config.write_text('self-hosted-runner:\n  labels: [custom-fixture]\n')
    action = checkout / '.github/actions/example/action.yml'
    action.parent.mkdir(parents=True)
    action.write_text('name: fixture\ndescription: fixture\nruns:\n  using: composite\n  steps: []\n')
    run(['git', 'add', '.'])
    check()
    commit()
    run(['git', 'rm', '.github/actionlint.yaml'])
    assert 'custom-fixture' in check(1), 'deleted config did not select workflows'
    run(['git', 'reset', '--hard', 'HEAD'])
    run(['git', 'mv', '.github/actionlint.yaml', '.github/old-actionlint.txt'])
    assert 'custom-fixture' in check(1), 'renamed config did not select workflows'
    run(['git', 'reset', '--hard', 'HEAD'])
    # Start with a tracked invalid caller so action-only changes reveal selection.
    workflow.write_text(workflow.read_text() + 'invalid-root-key: true\n')
    run(['git', 'add', '.'])
    commit()
    run(['git', 'mv', '.github/actions/example/action.yml', '.github/actions/example/retired.txt'])
    assert 'invalid-root-key' in check(1), 'renamed action did not select callers'
    run(['git', 'reset', '--hard', 'HEAD'])
    (checkout / 'README.md').write_text('Unrelated.\n')
    run(['git', 'add', 'README.md'])
    check()
PYTEST
assert_eq "native deletion/rename selection and unrelated skip" 0 "$?"
finish
