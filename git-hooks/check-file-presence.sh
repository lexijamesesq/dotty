#!/usr/bin/env bash
# Configured filename presence: --setup checks disk; --staged checks the index
# only when a required filename or its native declaration changes.
# Exit 1 means missing files; exit 2 means the check could not run.
set -euo pipefail
mode=--setup
if [[ "${1:-}" == --setup || "${1:-}" == --staged ]]; then
	mode=$1
	shift
fi
python3 - "$mode" "$@" <<'PY'
from pathlib import Path
import os
import subprocess
import sys

mode, *required = sys.argv[1:]
required = [os.path.normpath(name) for name in required]
if any(os.path.isabs(name) or name == '..' or name.startswith('../') for name in required):
    print('BLOCKED: required filenames must be inside the repository root', file=sys.stderr)
    sys.exit(2)
if not required:
    print('BLOCKED: check-file-presence.sh: no required files given', file=sys.stderr)
    sys.exit(2)
if mode == '--setup':
    missing = [name for name in required if not Path(name).is_file()]
else:
    try:
        root = subprocess.check_output(['git', 'rev-parse', '--show-toplevel'], text=True).strip()
        # Disabling rename folding returns both sides, including staged deletions.
        changed = subprocess.check_output(['git', 'diff', '--cached', '--name-only',
                                           '--no-renames', '-z'], cwd=root).split(b'\0')
        relevant = {os.fsencode(name) for name in required} | {b'.pre-commit-config.yaml'}
        if not relevant.intersection(changed):
            sys.exit(0)
        missing = []
        for name in required:
            result = subprocess.run(['git', 'cat-file', '-t', ':' + name], cwd=root,
                                    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            if result.returncode or result.stdout.strip() != b'blob':
                missing.append(name)
    except subprocess.CalledProcessError:
        print('BLOCKED: cannot inspect staged required-file changes', file=sys.stderr)
        sys.exit(2)
if missing:
    sys.exit('BLOCKED: missing required file(s): ' + ' '.join(missing))
PY
