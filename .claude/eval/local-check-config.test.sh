#!/usr/bin/env bash
# Exercise commit-stage tool ownership, whitespace and Markdown hard breaks.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
python3 - "$ROOT" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import yaml

root = Path(sys.argv[1])
source = yaml.safe_load((root / '.pre-commit-config.yaml').read_text())
ids = {'end-of-file-fixer', 'trailing-whitespace', 'biome-check'}
config = {key: source[key] for key in ['default_stages', 'default_install_hook_types']}
config['repos'] = []
for repo in source['repos']:
    hooks = [hook for hook in repo['hooks'] if hook['id'] in ids]
    if hooks:
        config['repos'].append(dict(repo, hooks=hooks))
env = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
env.update(GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1')
with tempfile.TemporaryDirectory(prefix='local-check-config-') as temporary:
    checkout = Path(temporary)
    def command(args, expected=0):
        result = subprocess.run(args, cwd=checkout, env=env, text=True, capture_output=True)
        assert result.returncode == expected, result.stdout + result.stderr
        return result.stdout
    def run(hook, expected=0, stage='pre-commit'):
        return command(['pre-commit', 'run', hook, '--all-files', '--hook-stage', stage], expected)
    command(['git', 'init', '-q'])
    (checkout / '.pre-commit-config.yaml').write_text(json.dumps(config))
    (checkout / 'biome.json').write_bytes((root / 'biome.json').read_bytes())
    (checkout / 'README.md').write_text('<!-- markdownlint-disable MD041 -->\nPurpose prose.  \nNext line.\n\n## Details\n\n<details>\n<summary>More</summary>\n\nText.\n\n</details>\n')
    (checkout / 'data.txt').write_text('text with accidental space \n')
    (checkout / 'module.mjs').write_text('export const answer = 1;  \n')
    command(['git', 'add', '.'])
    command(['pre-commit', 'run', '--all-files', '--hook-stage', 'pre-push'])
    assert (checkout / 'data.txt').read_text().endswith(' \n'), 'push repeated whitespace fixing'
    run('trailing-whitespace', 1)
    assert (checkout / 'data.txt').read_text() == 'text with accidental space\n'
    assert 'prose.  \n' in (checkout / 'README.md').read_text(), 'Markdown hard break lost'
    assert (checkout / 'module.mjs').read_text().endswith('  \n'), 'whitespace duplicated Biome ownership'
    run('biome-check', 1)
    assert (checkout / 'module.mjs').read_text().endswith(';\n'), 'Biome did not own mjs formatting'
    print('PASS commit-only whitespace with hard breaks; Biome owns mjs formatting')
PY
