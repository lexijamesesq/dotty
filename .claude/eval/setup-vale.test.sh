#!/usr/bin/env bash
# Retained hosted Vale release/version and checksum checks; no network.
set -euo pipefail
SETUP_VALE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export SETUP_VALE_ROOT
python3 - <<'PYTEST'
import os
import hashlib
import tarfile
import yaml
from pathlib import Path
import subprocess
import shutil
import tempfile
import unittest


class HostedValeInstallation(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='setup-vale-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.env = {k: v for k, v in os.environ.items() if not k.startswith('GIT_')}
        self.env['HOME'] = str(self.root)
        self.repo = self.root / 'source'
        self.repo.mkdir()

    def run_command(self, command, cwd=None, success=True):
        result = subprocess.run(command, cwd=cwd, env=self.env, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout)
        return result.stdout

    def test_shared_vale_release_and_checksum_refusal(self):
        producer = Path(os.environ['SETUP_VALE_ROOT'])
        fixture = self.root / 'producer'
        for name in ['.github/actions/setup-vale/release.sh']:
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
        for name in ('python3', 'bash', 'dirname', 'grep', 'mktemp', 'tar', 'gzip', 'install', 'mkdir', 'rm', 'cat', 'awk'):
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
        action = yaml.safe_load((producer / '.github/actions/setup-vale/action.yml').read_text())
        script = action['runs']['steps'][0]['run']
        self.env.update(VALE_RELEASE_FILE=str(release), VALE_VERSION='')
        output = self.run_command(['bash', '-c', script], cwd=self.repo, success=False)
        self.assertIn('checksum mismatch', output)
        self.assertFalse(installed.exists())
        # Only the disposable data source is changed to trust the synthetic
        # archive. The real hosted installer must consume that same source.
        release.write_text(release.read_text().replace(checksum, hashlib.sha256(archive.read_bytes()).hexdigest()))
        self.run_command(['bash', '-c', script], cwd=self.repo)
        self.assertTrue(installed.exists())
        self.assertEqual(self.run_command([str(installed), '--version']).strip(), 'vale version ' + version)
        self.env['VALE_VERSION'] = 'unreviewed-version'
        self.assertIn('no reviewed checksum', self.run_command(['bash', '-c', script], cwd=self.repo, success=False))


unittest.main()
PYTEST
