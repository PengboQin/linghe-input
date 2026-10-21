#!/usr/bin/env python3
"""Run the offline English algorithm under native ASan/UBSan, without deployment."""
from pathlib import Path
import json
import os
import subprocess
ROOT = Path(__file__).resolve().parents[1]
output = ROOT / 'build/windows-input-tests/native'
evidence = ROOT / 'evidence/windows024'
temp = ROOT / 'build/tmp'
for path in (output, evidence, temp):
    path.mkdir(parents=True, exist_ok=True)
env = dict(os.environ, TMPDIR=str(temp))
binary = output / 'english_suggestions'
with (evidence / 'english-native-build.log').open('w') as log:
    subprocess.run(['clang++', '-std=c++17', '-Wall', '-Wextra', '-pedantic',
                    '-fsanitize=address,undefined', '-Iwindows/src',
                    'windows/tests/english_suggestions.cpp', '-o', str(binary)],
                   cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
result = subprocess.run([str(binary)], cwd=ROOT, env=env, text=True, capture_output=True, check=True)
(evidence / 'english-native.log').write_text(result.stdout + result.stderr)
report = json.loads(result.stdout)
report.update(nativeASanUBSan='passed', windowsExecution=False, hostTextRead=False, learning=False, network=False)
(evidence / 'english-native-results.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report))
