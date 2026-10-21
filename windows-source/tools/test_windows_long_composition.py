#!/usr/bin/env python3
"""Run the independent Windows core against an existing macOS Rime library.

The supplied prefix is read-only. All compilation, engine data and log output
stay inside this project; no remote execution, downloads or system IME changes.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--rime-prefix', required=True, type=Path)
args = parser.parse_args()
prefix = args.rime_prefix.resolve()
assert (prefix / 'lib/librime.a').is_file()
output = ROOT / 'build/windows-long-composition'
evidence = ROOT / 'evidence/windows-long-composition-20261018'
output.mkdir(parents=True, exist_ok=True)
evidence.mkdir(parents=True, exist_ok=True)
(evidence / 'results.json').unlink(missing_ok=True)
env = os.environ.copy()
env['TMPDIR'] = str(output)
def run(command, name):
    with (evidence / (name + '.log')).open('w') as log:
        subprocess.run(list(map(str, command)), cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
binary = output / 'windows_long_composition'
run(['xcrun', 'clang++', '-std=c++17', '-O2', '-Wall', '-Wextra', '-Icore/include', '-I' + str(prefix / 'include'),
     'core/src/private_input.cpp', 'core/tests/windows_long_composition.cpp',
     '-Wl,-force_load,' + str(prefix / 'lib/librime.a'), '-L' + str(prefix / 'lib'),
     '-lyaml-cpp', '-lleveldb', '-lmarisa', '-lopencc', '-o', binary], 'build')
workspace = Path(tempfile.mkdtemp(prefix='fixture-', dir=output))
try:
    # Deploy is disabled; only user-side runtime metadata may be written.
    run([binary, ROOT / 'resources/rime', workspace / 'user'], 'core-regression')
finally:
    shutil.rmtree(workspace)
(evidence / 'results.json').write_text(json.dumps({'passed': True, 'nativeCoreExecuted': True,
    'windowsExecution': False, 'windowsInstalled': False, 'rimePrefixReadOnly': str(prefix)}, indent=2) + '\n')
print((evidence / 'results.json').read_text())
