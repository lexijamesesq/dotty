#!/usr/bin/env bash
# Plant author routing/config in a disposable surrogate; prove child isolation.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
python3 - "$ROOT/.claude/eval/lib/fixture-env.sh" "${1:-$ROOT/.claude/eval/lib/fixture-env.sh}" <<'PY'
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tempfile

clean = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
clean.update(GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_SYSTEM='/dev/null', GIT_CONFIG_NOSYSTEM='1', GIT_TEMPLATE_DIR='')
with tempfile.TemporaryDirectory(prefix='fixture-isolation-') as temporary:
    root = Path(temporary)
    author = root / 'author'
    author.mkdir()
    def git(*args):
        return subprocess.check_output(['git', '-C', str(author), *args], env=clean)
    git('init', '-q')
    git('config', 'user.name', 'Author surrogate')
    git('config', 'user.email', 'surrogate@example.invalid')
    (author / 'tracked').write_text('base\n')
    git('add', '.')
    git('commit', '-qm', 'base')
    (author / 'tracked').write_text('staged author change\n')
    git('add', 'tracked')
    (author / 'tracked').write_text('unstaged author change\n')
    (author / 'untracked').write_text('author untracked content\n')
    external = root / 'external-objects'
    external.mkdir()
    hooks = root / 'external-hooks'
    hooks.mkdir()
    marker = root / 'external-hook-ran'
    hook = hooks / 'pre-commit'
    hook.write_text('#!/bin/sh\ntouch "' + str(marker) + '"\n')
    hook.chmod(0o755)
    config = root / 'global.gitconfig'
    config.write_text('[core]\n hooksPath = ' + str(hooks) + '\n[commit]\n gpgsign = true\n[credential]\n helper = !exit 99\n')
    planted = dict(clean, GIT_DIR=str(author / '.git'), GIT_COMMON_DIR=str(author / '.git'), GIT_WORK_TREE=str(author), GIT_INDEX_FILE=str(author / '.git/index'), GIT_OBJECT_DIRECTORY=str(external), GIT_ALTERNATE_OBJECT_DIRECTORIES=str(author / '.git/objects'), GIT_CONFIG_GLOBAL=str(config), GIT_CONFIG_COUNT='1', GIT_CONFIG_KEY_0='test.inherited', GIT_CONFIG_VALUE_0='must-clear', PRE_COMMIT_FROM_REF='1111111111111111111111111111111111111111', PRE_COMMIT_TO_REF='2222222222222222222222222222222222222222', PRE_COMMIT_REMOTE_NAME='outside', PRE_COMMIT_HOME=str(root / 'native-cache'), GIT_AUTHOR_NAME='Inherited author', GIT_AUTHOR_EMAIL='inherited@example.invalid', GIT_COMMITTER_NAME='Inherited author', GIT_COMMITTER_EMAIL='inherited@example.invalid')
    def snapshot():
        # Includes effective object storage, refs, HEAD, index, config and every
        # worktree byte; Git status alone cannot detect leaked loose objects.
        return {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest()
                for base in [author, external] for path in base.rglob('*') if path.is_file()}
    command = '''set -eu
mkdir -p "$1"
git -C "$1" init -q
git -C "$1" config user.name Fixture
git -C "$1" config user.email fixture@example.invalid
git -C "$1" config commit.gpgsign false
printf 'fixture object\n' | git -C "$1" hash-object -w --stdin >/dev/null
git -C "$1" add -A
git -C "$1" commit --allow-empty -qm fixture
'''
    before = snapshot()
    for number, boundary in enumerate(dict.fromkeys(sys.argv[1:])):
        result = subprocess.run(['bash', boundary, 'bash', '-c', command, '--', str(root / ('fixture-' + str(number)))], env=planted, capture_output=True, text=True)
        assert result.returncode == 0, result.stdout + result.stderr
        assert snapshot() == before, 'isolated fixture modified author state/object storage'
        assert not marker.exists(), 'isolated fixture inherited an external hook'
        probe = subprocess.run(['bash', boundary, 'bash', '-c', 'git config --get test.inherited; git config --get credential.helper; git config --get commit.gpgsign'], cwd=root, env=planted, capture_output=True, text=True)
        assert not probe.stdout, 'isolated fixture inherited command/global configuration'
        context = subprocess.run(['bash', boundary, 'bash', '-c', 'test -z "${PRE_COMMIT_FROM_REF:-}${PRE_COMMIT_TO_REF:-}${PRE_COMMIT_REMOTE_NAME:-}" && test "$PRE_COMMIT_HOME" = "$1"', '--', str(root / 'native-cache')], env=planted)
        assert context.returncode == 0, 'parent push context leaked or native cache was discarded'
    # The same successful fixture operation WITHOUT the boundary must expose
    # the planted bug in the disposable author surrogate (never the real repo).
    result = subprocess.run(['bash', '-c', command, '--', str(root / 'unsafe-fixture')], env=planted, capture_output=True, text=True)
    assert result.returncode == 0, result.stdout + result.stderr
    assert snapshot() != before, 'negative control did not expose routing/object leakage'
    assert marker.exists(), 'negative control did not exercise inherited hook ownership'
    print('PASS child isolation preserves author HEAD/refs/index/worktree/effective objects; planted negative control mutates surrogate')
PY
