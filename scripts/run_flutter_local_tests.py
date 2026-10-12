#!/usr/bin/env python3
"""Run local unit/widget tests; retain explicitly inventoried connected suites."""

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--list', action='store_true', help='List selection without running Flutter')
    parser.add_argument('--coverage', action='store_true')
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    mobile = root / 'apps/mobile'
    manifest = json.loads((root / 'scripts/flutter_connected_tests.json').read_text(encoding='utf-8'))
    connected = {entry['path'] for entry in manifest['tests']}
    available = {path.relative_to(mobile).as_posix() for path in (mobile / 'test').rglob('*_test.dart')}
    missing = sorted(connected - available)
    if missing:
        parser.error('Connected-test manifest refers to missing files: ' + ', '.join(missing))
    selected = sorted(available - connected)
    if not selected:
        parser.error('No local tests selected')
    print(f'Local test files: {len(selected)}; separate connected fixture files: {len(connected)}', flush=True)
    if args.list:
        print('\n'.join(selected))
        return 0
    flutter = shutil.which('flutter.bat' if os.name == 'nt' else 'flutter')
    if not flutter:
        parser.error('Flutter was not found on PATH')
    # Relative paths keep this command below Windows command-line limits.
    # Timing regressions use the current test VM's loopback service to pause
    # CPU profiling only around native SQLite waits and restore it afterwards.
    command = [flutter, 'test', '--enable-vmservice']
    if args.coverage:
        command.append('--coverage')
    return subprocess.call(command + selected, cwd=mobile)


if __name__ == '__main__':
    sys.exit(main())
