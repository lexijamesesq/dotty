#!/usr/bin/env bash
# Real Git/tag fixtures; child isolation must precede any fixture mutation.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
exec bash "$here/lib/fixture-env.sh" python3 - "$here/../.." <<'PY'
from pathlib import Path
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile

producer = Path(sys.argv[1]).resolve()
adapter = producer / 'git-hooks/release-version.sh'
checker = producer / '.github/scripts/check-plugin-version.sh'
with tempfile.TemporaryDirectory(prefix='release-version-test-') as temporary:
    root = Path(temporary)
    env = dict(os.environ, PRE_COMMIT_HOME=str(root / 'cache'))
    def run(cwd, args, extra=None, fail=False):
        p = subprocess.run(args, cwd=cwd, env=dict(env, **(extra or {})),
                           text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        assert (p.returncode != 0) == fail, p.stdout
        return p.stdout
    def git(cwd, *args):
        return run(cwd, ['git', *args]).strip()
    def write(repo, name, value):
        p = repo / name
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(value)
    def commit(repo):
        git(repo, 'add', '.')
        git(repo, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
            'commit', '-qm', 'fixture')
        return git(repo, 'rev-parse', 'HEAD')
    author = root / 'author'
    author.mkdir()
    git(author, 'init', '-q', '-b', 'main')
    write(author, '.claude-plugin/plugin.json', '{"name":"demo","version":"1.0.0"}\n')
    write(author, 'skills/demo/SKILL.md', 'original\n')
    released = commit(author)
    git(author, 'tag', 'demo--v1.0.0')
    remote = root / 'remote.git'
    git(root, 'clone', '--bare', str(author), str(remote))
    git(author, 'remote', 'add', 'origin', str(remote))
    git(author, 'tag', 'demo--v999.0.0')  # Unpublished tags must have no effect.
    def check(outgoing, fail=False, remote_url=None, extra=None, repo=author):
        native = {'PRE_COMMIT_TO_REF': outgoing, 'PRE_COMMIT_REMOTE_NAME': 'origin',
                  'PRE_COMMIT_REMOTE_URL': str(remote if remote_url is None else remote_url)}
        native.update(extra or {})
        return run(repo, ['bash', str(adapter), 'plugin', '.', 'demo'], native, fail)
    assert 'tree identical' in check(released)
    write(author, 'skills/demo/SKILL.md', 'changed\n')
    unbumped = commit(author)
    assert 'without a version bump' in check(unbumped, True)
    write(author, '.claude-plugin/plugin.json', '{"name":"demo","version":"1.1.0"}\n')
    bumped = commit(author)
    assert 'version bumped' in check(bumped)
    # Exact non-HEAD ref, with unrelated staged and unstaged author work preserved.
    write(author, 'staged.txt', 'staged work\n')
    git(author, 'add', 'staged.txt')
    write(author, 'untracked.txt', 'untracked work\n')
    def snapshot():
        return {str(p.relative_to(author)): hashlib.sha256(p.read_bytes()).hexdigest()
                for p in author.rglob('*') if p.is_file()}
    before = snapshot()
    assert 'without a version bump' in check(unbumped, True)
    assert before == snapshot(), 'author Git refs/index/objects/worktree changed'
    assert 'without a version bump' in check(unbumped, True, extra={
        'GIT_DIR': str(author / '.git'), 'GIT_WORK_TREE': str(author),
        'GIT_CONFIG_COUNT': '1', 'GIT_CONFIG_KEY_0': 'core.worktree',
        'GIT_CONFIG_VALUE_0': str(author)})
    assert before == snapshot(), 'inherited config routed writes into author checkout'
    git(author, 'reset', '-q', '--hard', released)
    (author / 'untracked.txt').unlink()
    write(author, '.github/scripts/new-hook.sh', 'infrastructure\n')
    write(author, '.shellcheckrc', 'external-sources=true\n')
    write(author, '.pre-commit-config.yaml', 'repos: []\n')
    infra = commit(author)
    assert 'tree identical' in check(infra)
    assert 'tree identical' in check('', extra={'PRE_COMMIT_LOCAL_BRANCH': 'HEAD'})
    assert 'native outgoing ref' in check('', True)
    check('does-not-exist', True)
    check(infra, True, root / 'unreachable.git')
    empty = root / 'empty.git'
    git(root, 'init', '--bare', '-q', str(empty))
    assert 'no existing tag' in check(infra, remote_url=empty)
    git(author, 'config', 'remote.origin.pushurl', str(empty))
    assert 'no existing tag' in check(infra, extra={'PRE_COMMIT_REMOTE_URL': ''})
    git(author, 'config', '--unset', 'remote.origin.pushurl')
    shallow = root / 'shallow'
    git(root, 'clone', '--depth=1', remote.as_uri(), str(shallow))
    assert 'shallow history' in check('HEAD', True, repo=shallow)
    git(author, 'config', 'remote.origin.promisor', 'true')
    assert 'incomplete promisor history' in check('HEAD', True)
    git(author, 'config', '--unset', 'remote.origin.promisor')
    # Source config overlays and credential selectors survive the temp routing
    # boundary. An authenticated synthetic transport uses no network or secrets.
    transport = root / 'transport.sh'
    transport.write_text('#!/bin/sh\n[ "$TEST_CREDENTIAL_SELECTOR" = allowed ] || exit 31\n'
                         '[ "$(git config test.auth)" = configured ] || exit 32\n'
                         'exec git-upload-pack "$1"\n')
    transport.chmod(0o755)
    git(author, 'config', 'test.auth', 'configured')
    git(author, 'config', 'protocol.ext.allow', 'always')
    assert 'tree identical' in check(infra, remote_url=f'ext::{transport} {remote}',
                                    extra={'TEST_CREDENTIAL_SELECTOR': 'allowed'})
    # Environment auth overlays must outrank conflicting repository settings.
    git(author, 'config', 'test.auth', 'wrong-local-value')
    assert 'tree identical' in check(infra, remote_url=f'ext::{transport} {remote}', extra={
        'TEST_CREDENTIAL_SELECTOR': 'allowed', 'GIT_CONFIG_COUNT': '1',
        'GIT_CONFIG_KEY_0': 'test.auth', 'GIT_CONFIG_VALUE_0': 'configured'})
    git(author, 'config', 'test.auth', 'configured')
    # Scratch reference transactions must not invoke inherited external hooks.
    hooks = root / 'external-hooks'
    hooks.mkdir()
    sentinel = root / 'external-hook-fired'
    hook = hooks / 'reference-transaction'
    hook.write_text(f'#!/bin/sh\necho fired >> "{sentinel}"\n')
    hook.chmod(0o755)
    assert 'tree identical' in check(infra, extra={
        'GIT_CONFIG_COUNT': '1', 'GIT_CONFIG_KEY_0': 'core.hooksPath',
        'GIT_CONFIG_VALUE_0': str(hooks)})
    assert not sentinel.exists(), 'scratch ref mutation invoked an external hook'
    # Missing comparison objects must fail even when the declared version rose.
    broken = root / 'broken'
    git(root, 'clone', '--no-hardlinks', str(author), str(broken))
    write(broken, '.claude-plugin/plugin.json', '{"name":"demo","version":"2.0.0"}\n')
    commit(broken)
    git(broken, 'tag', '-d', 'demo--v999.0.0')
    tree = git(broken, 'rev-parse', 'demo--v1.0.0^{tree}')
    obj = broken / '.git/objects' / tree[:2] / tree[2:]
    assert obj.exists()
    obj.unlink()
    assert 'incomplete or invalid Git objects' in run(
        broken, ['bash', str(checker), '.', 'demo'], fail=True)
    # Install the real exported hook from a synthetic immutable producer commit;
    # this proves native dispatch without publishing the candidate producer.
    exported = root / 'producer'
    exported.mkdir()
    for name in ['git-hooks/release-version.sh', '.github/scripts/check-plugin-version.sh',
                 '.pre-commit-hooks.yaml']:
        p = exported / name
        p.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(producer / name, p)
    git(exported, 'init', '-q')
    revision = commit(exported)
    write(author, '.pre-commit-config.yaml', json.dumps({'repos': [
        {'repo': str(exported), 'rev': revision, 'hooks': [
            {'id': 'release-version', 'args': ['plugin', '.', 'demo']}
        ]}]}))
    configured = commit(author)
    output = run(author, ['pre-commit', 'run', 'release-version', '--hook-stage', 'pre-push',
                         '--from-ref', released, '--to-ref', configured, '--verbose'],
                 {'PRE_COMMIT_REMOTE_NAME': 'origin', 'PRE_COMMIT_REMOTE_URL': str(remote)})
    assert 'tree identical' in output, output
    print('PASS real remote tags, unchanged/unbumped/bumped/new, exact non-HEAD/staged '
          'safety, infra, failed/unknown/shallow/incomplete, auth context, native export')
PY
