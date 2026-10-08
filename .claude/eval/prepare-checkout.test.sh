#!/usr/bin/env bash
# Native setup/hook behavior in disposable clones and worktrees; no network.
set -euo pipefail
PREPARE_CHECKOUT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/prepare-checkout.sh"
export PREPARE_CHECKOUT
python3 - <<'PY'
import os
import hashlib
import tarfile
import yaml
from pathlib import Path
import subprocess
import shutil
import tempfile
import unittest


class Readiness(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='prepare-checkout-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        # Fixture Git cannot address the caller's object store or identity.
        self.env = {k: v for k, v in os.environ.items() if not k.startswith('GIT_')}
        self.env.update(HOME=str(self.root), GIT_CONFIG_GLOBAL='/dev/null',
                        GIT_CONFIG_NOSYSTEM='1', GIT_AUTHOR_NAME='Fixture',
                        GIT_COMMITTER_NAME='Fixture', GIT_AUTHOR_EMAIL='fixture@example.invalid',
                        GIT_COMMITTER_EMAIL='fixture@example.invalid',
                        PRE_COMMIT_HOME=str(self.root / 'cache'))
        self.repo = self.root / 'source'
        self.run_command(['git', 'init', '-q', str(self.repo)])
        (self.repo / '.pre-commit-config.yaml').write_text('''repos:
- repo: local
  hooks:
  - id: commit-check
    name: commit-check
    language: system
    entry: python3 check.py commit
    always_run: true
    pass_filenames: false
    stages: [pre-commit]
  - id: message-check
    name: message-check
    language: system
    entry: python3 check.py message
    stages: [commit-msg]
  - id: push-check
    name: push-check
    language: system
    entry: python3 check.py push
    always_run: true
    pass_filenames: false
    stages: [pre-push]
''')
        (self.repo / 'check.py').write_text('''import pathlib, sys
stage = sys.argv[1]
if stage == 'message':
    sys.exit('BAD' in pathlib.Path(sys.argv[2]).read_text())
sys.exit(pathlib.Path('.reject-' + stage).exists())
''')
        self.git('add', '.', cwd=self.repo)
        self.git('commit', '-qm', 'fixture seed', cwd=self.repo)

    def run_command(self, command, cwd=None, success=True):
        result = subprocess.run(command, cwd=cwd, env=self.env, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout)
        return result.stdout

    def git(self, *args, **kwargs):
        return self.run_command(['git', *args], **kwargs)

    def prepare(self, cwd, success=True):
        return self.run_command(['bash', os.environ['PREPARE_CHECKOUT'], str(cwd)], success=success)

    def test_clone_worktree_stages_and_repeat(self):
        clone = self.root / 'clone'
        self.git('clone', '-q', str(self.repo), str(clone))
        worktree = self.root / 'worktree'
        self.git('worktree', 'add', '-qb', 'fixture-worktree', str(worktree), cwd=clone)
        for checkout in (clone, worktree):
            with self.subTest(checkout=checkout.name):
                self.prepare(checkout)
                hooks = [Path(self.git('rev-parse', '--path-format=absolute', '--git-path',
                                       'hooks/' + stage, cwd=checkout).strip())
                         for stage in ('pre-commit', 'commit-msg', 'pre-push')]
                contents = [path.read_bytes() for path in hooks]
                status = self.git('status', '--porcelain', cwd=checkout)
                self.prepare(checkout)
                self.assertEqual([p.read_bytes() for p in hooks], contents)
                self.assertEqual(self.git('status', '--porcelain', cwd=checkout), status)
                (checkout / 'change.txt').write_text('a change\n')
                self.git('add', 'change.txt', cwd=checkout)
                (checkout / '.reject-commit').touch()
                self.assertIn('commit-check', self.git('commit', '-qm', 'good message', cwd=checkout, success=False))
                (checkout / '.reject-commit').unlink()
                self.assertIn('message-check', self.git('commit', '-qm', 'BAD message', cwd=checkout, success=False))
                self.git('commit', '-qm', 'corrected message', cwd=checkout)
                remote = self.root / (checkout.name + '-remote.git')
                self.git('init', '--bare', '-q', str(remote))
                (checkout / '.reject-push').touch()
                self.assertIn('push-check', self.git('push', str(remote), 'HEAD:main', cwd=checkout, success=False))
                (checkout / '.reject-push').unlink()
                self.git('push', str(remote), 'HEAD:main', cwd=checkout)

    def test_custom_hook_path_preserved(self):
        self.git('config', 'core.hooksPath', 'custom-hooks', cwd=self.repo)
        custom = self.repo / 'custom-hooks'
        custom.mkdir()
        hook = custom / 'pre-commit'
        hook.write_text('#!/bin/sh\nexit 23\n')
        self.assertIn('core.hooksPath', self.prepare(self.repo, success=False))
        self.assertEqual(hook.read_text(), '#!/bin/sh\nexit 23\n')
        self.assertEqual(self.git('config', '--get', 'core.hooksPath', cwd=self.repo).strip(), 'custom-hooks')

    def test_native_coexistence_preserves_existing_hook(self):
        hook = self.repo / '.git/hooks/pre-commit'
        hook.write_text('#!/bin/sh\necho existing-hook >&2\nexit 19\n')
        hook.chmod(0o755)
        self.prepare(self.repo)
        self.assertEqual(hook.with_name('pre-commit.legacy').read_text(), '#!/bin/sh\necho existing-hook >&2\nexit 19\n')
        output = self.git('commit', '--allow-empty', '-qm', 'good', cwd=self.repo, success=False)
        self.assertIn('existing-hook', output)

    def test_invalid_config_and_missing_tool_fail(self):
        config = self.repo / '.pre-commit-config.yaml'
        config.write_text('repos: invalid\n')
        self.prepare(self.repo, success=False)
        self.assertFalse((self.repo / '.git/hooks/pre-commit').exists())
        config.write_text('''repos:
- repo: local
  hooks:
  - id: unavailable
    name: unavailable
    language: system
    entry: estate-fixture-tool-not-installed
''')
        self.assertIn('required tool missing', self.prepare(self.repo, success=False))
        self.assertFalse((self.repo / '.git/hooks/pre-commit').exists())

    def test_project_wrapper_tools_are_ready_without_running_them(self):
        tools = self.root / 'tools'
        tools.mkdir()
        for name in ('python3', 'pre-commit', 'bash', 'git', 'dirname', 'grep'):
            (tools / name).symlink_to(shutil.which(name))
        self.env['PATH'] = str(tools)
        config = self.repo / '.pre-commit-config.yaml'
        npm = tools / 'npm'
        npm.write_text('#!/bin/sh\necho project-tool-must-not-run >&2\nexit 99\n')
        npm.chmod(0o755)
        suite = self.repo / '.github/scripts/check-push.sh'
        suite.parent.mkdir(parents=True)
        suite.write_text('#!/bin/sh\necho project-tool-must-not-run >&2\nexit 99\n')
        for hook_id, tool, entry in [
            ('core-linear-tests', 'uvx', 'bash nonexistent-suite.sh'),
            ('core-plugin-validation', 'claude', 'bash nonexistent-suite.sh'),
            ('plugin-validation', 'claude', 'bash .github/scripts/check-push.sh plugin'),
            ('margot-route-contract', 'jq', 'bash .github/scripts/check-push.sh route'),
            ('margot-workflow-policy', 'conftest', 'bash .github/scripts/check-push.sh closer'),
            ('agent-ops-studio-project', 'node', 'npm --ignore-scripts --prefix studio run check:push'),
            ('studio-project', 'node', 'npm --ignore-scripts run check:push'),
        ]:
            with self.subTest(tool=tool):
                config.write_text('repos:\n- repo: local\n  hooks:\n  - id: ' + hook_id +
                                  '\n    name: project\n    language: system\n    entry: ' + entry + '\n    stages: [pre-push]\n')
                self.assertIn('required tool missing: ' + tool, self.prepare(self.repo, success=False))
                binary = tools / tool
                binary.write_text('#!/bin/sh\necho project-tool-must-not-run >&2\nexit 99\n')
                binary.chmod(0o755)
                output = self.prepare(self.repo)
                self.assertNotIn('project-tool-must-not-run', output)
                before = config.read_bytes()
                self.prepare(self.repo)
                self.assertEqual(config.read_bytes(), before)
                binary.unlink()

    def test_shared_vale_release_and_checksum_refusal(self):
        producer = Path(os.environ['PREPARE_CHECKOUT']).resolve().parent.parent
        fixture = self.root / 'producer'
        for name in ['scripts/prepare-checkout.sh', '.github/actions/setup-vale/release.sh']:
            target = fixture / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(producer / name, target)
        release = fixture / '.github/actions/setup-vale/release.sh'
        version = self.run_command(['bash', '-c', 'source "$1"; echo "$VALE_RELEASE_VERSION"', '--', str(release)]).strip()
        checksum = self.run_command(['bash', '-c', 'source "$1"; vale_release_checksum "$VALE_RELEASE_VERSION" Linux_64-bit', '--', str(release)]).strip()
        self.run_command(['bash', '-c', 'source "$1"; vale_release_checksum wrong Linux_64-bit', '--', str(release)], success=False)
        self.run_command(['bash', '-c', 'source "$1"; vale_release_checksum "$VALE_RELEASE_VERSION" unsupported', '--', str(release)], success=False)
        binary = self.root / 'vale'
        binary.write_text('#!/bin/sh\necho "vale version ' + version + '"\n')
        binary.chmod(0o755)
        archive = self.root / 'fixture.tgz'
        with tarfile.open(archive, 'w:gz') as output:
            output.add(binary, arcname='vale')
        tools = self.root / 'vale-tools'
        tools.mkdir()
        for name in ('python3', 'pre-commit', 'bash', 'git', 'dirname', 'grep', 'mktemp', 'tar', 'gzip', 'install', 'mkdir', 'rm', 'cat', 'awk'):
            (tools / name).symlink_to(shutil.which(name))
        def tool(name, script):
            target = tools / name
            target.write_text('#!/bin/sh\n' + script)
            target.chmod(0o755)
        tool('uname', '[ "$1" = -s ] && echo Linux || echo x86_64\n')
        tool('curl', 'while [ "$#" -gt 0 ]; do if [ "$1" = -o ]; then shift; exec "' + shutil.which('cp') + '" "' + str(archive) + '" "$1"; fi; shift; done; exit 91\n')
        tool('sha256sum', 'exec python3 -c \'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest(), sys.argv[1])\' "$1"\n')
        installed = self.root / '.local/bin/vale'
        installed.parent.mkdir(parents=True)
        tool('sudo', '[ "$*" = "install -m 0755 vale /usr/local/bin/vale" ] || exit 92\nexec install -m 0755 vale "' + str(installed) + '"\n')
        self.env['PATH'] = str(installed.parent) + ':' + str(tools)
        (self.repo / '.pre-commit-config.yaml').write_text('repos:\n- repo: local\n  hooks:\n  - id: vale-self-narration\n    name: vale\n    entry: bash unused.sh\n    language: system\n')
        action = yaml.safe_load((producer / '.github/actions/setup-vale/action.yml').read_text())
        script = action['runs']['steps'][0]['run']
        self.env.update(VALE_RELEASE_FILE=str(release), VALE_VERSION='')
        for command in (['bash', str(fixture / 'scripts/prepare-checkout.sh'), str(self.repo)], ['bash', '-c', script]):
            with self.subTest(installer=command[1]):
                output = self.run_command(command, cwd=self.repo, success=False)
                self.assertIn('checksum mismatch', output)
                self.assertFalse(installed.exists())
        # Only the disposable data source is changed to trust the synthetic
        # archive. Both real installer bodies must consume that same source.
        release.write_text(release.read_text().replace(checksum, hashlib.sha256(archive.read_bytes()).hexdigest()))
        self.run_command(['bash', str(fixture / 'scripts/prepare-checkout.sh'), str(self.repo)])
        self.assertEqual(self.run_command([str(installed), '--version']).strip(), 'vale version ' + version)
        installed.unlink()
        self.run_command(['bash', '-c', script], cwd=self.repo)
        self.assertTrue(installed.exists())
        self.env['VALE_VERSION'] = 'unreviewed-version'
        self.assertIn('no reviewed checksum', self.run_command(['bash', '-c', script], cwd=self.repo, success=False))

    def test_symlink_owner_is_not_overwritten(self):
        original = self.root / 'owned-hook'
        original.write_text('#!/bin/sh\nexit 0\n')
        hook = self.repo / '.git/hooks/pre-commit'
        hook.symlink_to(original)
        self.assertIn('custom owner', self.prepare(self.repo, success=False))
        self.assertTrue(hook.is_symlink())
        self.assertEqual(original.read_text(), '#!/bin/sh\nexit 0\n')
        hook.unlink()
        directory = self.repo / '.git/hooks'
        moved = self.root / 'owned-hooks'
        directory.rename(moved)
        directory.symlink_to(moved, target_is_directory=True)
        self.assertIn('custom symlinked hook directory', self.prepare(self.repo, success=False))
        self.assertTrue(directory.is_symlink())


unittest.main()
PY
