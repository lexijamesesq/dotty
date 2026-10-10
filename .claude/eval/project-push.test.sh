#!/usr/bin/env bash
# Native project dispatch: deleted inputs, shared context, failures, unknown range.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
python3 - "$ROOT" "${1:-}" <<'PY'
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import yaml

sources = [('dotty', Path(sys.argv[1]))]
if sys.argv[2]:
    sources.append(('core-skills', Path(sys.argv[2])))
env = {key: value for key, value in os.environ.items() if not key.startswith('GIT_') and not key.startswith('PRE_COMMIT_')}
env.update(GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_SYSTEM='/dev/null', GIT_CONFIG_NOSYSTEM='1', GIT_TEMPLATE_DIR='')
with tempfile.TemporaryDirectory(prefix='project-push-') as temporary:
    for repo, source in sources:
        root = Path(temporary) / repo
        root.mkdir()
        def write(name, text):
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
            return path
        def copy(name):
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source / name, path)
        def run(args, expected=0, extra=None):
            result = subprocess.run(args, cwd=root, env=dict(env, **(extra or {})), text=True, capture_output=True)
            assert result.returncode == expected, result.stdout + result.stderr
            return result.stdout + result.stderr
        def commit():
            run(['git', 'add', '.'])
            run(['git', 'commit', '-qm', 'fixture'])
            return run(['git', 'rev-parse', 'HEAD']).strip()
        run(['git', 'init', '-q'])
        run(['git', 'config', 'user.name', 'Fixture'])
        run(['git', 'config', 'user.email', 'fixture@example.invalid'])
        config = yaml.safe_load((source / '.pre-commit-config.yaml').read_text())
        prefix = 'dotty-' if repo == 'dotty' else 'core-'
        hooks = [h for r in config['repos'] if r['repo'] == 'local' for h in r['hooks'] if h['id'].startswith(prefix)]
        write('.pre-commit-config.yaml', json.dumps({'repos': [{'repo': 'local', 'hooks': hooks}]}))
        write('README.md', 'Original.\n')
        if repo == 'dotty':
            copy('.claude/eval/run-all.sh')
            copy('.claude/eval/lib/fixture-env.sh')
            for suite in (source / '.claude/eval').glob('*.test.sh'):
                write('.claude/eval/' + suite.name, 'echo CALLED:' + suite.stem + '\n')
            entry = ['bash', '.claude/eval/run-all.sh', '--push']
            required = '.github/scripts/next-calendar-tag.sh'
            component, hook_id, marker = 'release', 'dotty-release-tests', 'CALLED:next-calendar-tag'
            shared = 'rulesets/default-branch.json'
            shared_component, shared_marker = 'workflows', 'CALLED:estate-self-instrument-alert'
            broken_suite = '.claude/eval/next-calendar-tag.test.sh'
        else:
            copy('.github/scripts/check-push.sh')
            copy('plugins/estate-hooks/tests/lib/fixture-env.sh')
            write('plugins/estate-hooks/tests/probe.test.sh', 'echo CALLED:estate-hooks\n')
            write('.github/scripts/standalone-check.sh', 'echo CALLED:standalone\n')
            write('.github/scripts/drift-check.sh', 'echo CALLED:shared-copy\n')
            (root / 'plugins/core/skills/linear/scripts').mkdir(parents=True)
            for tool in ['uvx', 'claude']:
                path = write('tools/' + tool, '#!/bin/sh\necho CALLED:' + tool + '\n')
                path.chmod(0o755)
            env['PATH'] = str(root / 'tools') + ':' + env['PATH']
            env['DOTTY_CHECKOUT'] = str(Path(sys.argv[1]))
            entry = ['bash', '.github/scripts/check-push.sh']
            required = 'plugins/estate-hooks/hooks/deleted.sh'
            component, hook_id, marker = 'estate-hooks', 'core-estate-hook-tests', 'CALLED:estate-hooks'
            shared = 'plugins/core/skills/linear/scripts/shared.py'
            shared_component, shared_marker = 'standalone', 'CALLED:standalone'
            broken_suite = 'plugins/estate-hooks/tests/probe.test.sh'
        write(required, 'required input\n')
        write(shared, 'shared input\n')
        base = commit()
        write('README.md', 'Only unrelated prose changed.\n')
        head = commit()
        scope = dict(PRE_COMMIT_FROM_REF=base, PRE_COMMIT_TO_REF=head)
        assert 'no affected inputs' in run(entry + [component], extra=scope)
        run(['git', 'rm', required])
        deleted = commit()
        # Native pre-commit cannot pass an absent filename; always_run + range
        # selection must still invoke the actual component entrypoint.
        output = run(['pre-commit', 'run', hook_id, '--hook-stage', 'pre-push', '--from-ref', head, '--to-ref', deleted, '--verbose'])
        assert marker in output, output
        write(broken_suite, 'echo meaningful-fixture-failure\nexit 1\n')
        fault = commit()
        assert 'meaningful-fixture-failure' in run(entry + [component], expected=1, extra=dict(PRE_COMMIT_FROM_REF=head, PRE_COMMIT_TO_REF=fault))
        write(broken_suite, 'echo ' + marker + '\n')
        corrected = commit()
        assert marker in run(entry + [component], extra=dict(PRE_COMMIT_FROM_REF=head, PRE_COMMIT_TO_REF=corrected))
        run(['git', 'mv', shared, shared + '.retired'])
        renamed = commit()
        assert shared_marker in run(entry + [shared_component], extra=dict(PRE_COMMIT_FROM_REF=deleted, PRE_COMMIT_TO_REF=renamed))
        if repo == 'dotty':
            # An isolated canonical template rename selects the release owner.
            template = 'new-repo/templates/common/README.md'
            write(template, 'template input\n')
            template_base = commit()
            run(['git', 'mv', template, template + '.retired'])
            template_head = commit()
            assert marker in run(entry + [component], extra=dict(PRE_COMMIT_FROM_REF=template_base, PRE_COMMIT_TO_REF=template_head))
            write('.vale.ini', 'fixture policy input\n')
            policy_base = commit()
            run(['git', 'rm', '.vale.ini'])
            policy_head = commit()
            output = run(['pre-commit', 'run', hook_id, '--hook-stage', 'pre-push', '--from-ref', policy_base, '--to-ref', policy_head, '--verbose'])
            assert marker in output, output
        if repo == 'dotty':
            current = run(['git', 'rev-parse', 'HEAD']).strip()
            def refused(extra):
                output = run(entry + [component], expected=2, extra=extra)
                assert 'BLOCKED: push checks require a clean checkout/worktree' in output, output
                assert 'CALLED:' not in output, output
            # The older outgoing commit contains a real failing suite; current
            # HEAD is corrected. Do not accidentally test this other tree.
            refused(dict(PRE_COMMIT_FROM_REF=head, PRE_COMMIT_TO_REF=fault))
            refused(dict(PRE_COMMIT_REMOTE_NAME='origin', PRE_COMMIT_LOCAL_BRANCH=fault))
            scope = dict(PRE_COMMIT_FROM_REF=head, PRE_COMMIT_TO_REF=current)
            saved = (root / broken_suite).read_text()
            write(broken_suite, 'echo wrong-uncommitted-suite\nexit 1\n')
            refused(scope)
            run(['git', 'add', broken_suite])
            write(broken_suite, saved)  # index dirty even when disk matches HEAD
            refused(scope)
            run(['git', 'reset', '-q', 'HEAD', '--', broken_suite])
            write('.claude/eval/untracked-input.py', 'raise RuntimeError("untracked")\n')
            refused(scope)
            (root / '.claude/eval/untracked-input.py').unlink()
            write('.gitignore', 'tool-cache/\n')
            current = commit()
            write('tool-cache/ordinary-cache', 'ignored\n')
            scope['PRE_COMMIT_TO_REF'] = current
            assert marker in run(entry + [component], extra=scope)
            output = run(['pre-commit', 'run', hook_id, '--hook-stage', 'pre-push', '--from-ref', head, '--to-ref', fault, '--verbose'], expected=1)
            assert 'BLOCKED: push checks require' in output and 'CALLED:' not in output, output
            print('dotty: exact outgoing HEAD, tracked/index/untracked refusal and ignored-cache controls pass')
        run(entry + [component], expected=2)
        result = subprocess.run(entry + [component], cwd=root, env=dict(env, PRE_COMMIT_FROM_REF='not-a-ref', PRE_COMMIT_TO_REF=renamed), capture_output=True)
        assert result.returncode != 0, 'unresolved range passed'
        assert marker in run(entry + [component], extra=dict(PRE_COMMIT_REMOTE_NAME='origin', PRE_COMMIT_LOCAL_BRANCH='HEAD'))
        print(repo + ': native deletion, dependency rename, unrelated skip, failure/correction and first-push/unknown-range cases pass')
PY
