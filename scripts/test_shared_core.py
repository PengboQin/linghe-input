#!/usr/bin/env python3
"""Run shared-core regressions with pinned local Rime and fresh fixture users.

No downloads, device operations, installs, or real user database access.
One native object and one disposable executable keep peak storage bounded.
"""
from pathlib import Path
import hashlib
import json
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / 'build/core-unification'
EVIDENCE = ROOT / 'evidence/core-unification-20261021'
PREFIX = ROOT / 'build/rime/macos-arm64'


def main():
    BUILD.mkdir(parents=True, exist_ok=True)
    EVIDENCE.mkdir(parents=True, exist_ok=True)
    results = []
    def run(command, name, timeout=180):
        with (EVIDENCE / (name + '.log')).open('w') as log:
            result = subprocess.run(list(map(str, command)), cwd=ROOT,
                                    stdout=log, stderr=subprocess.STDOUT, timeout=timeout)
        results.append({'name': name, 'exitCode': result.returncode})
        (EVIDENCE / 'test-results.json').write_text(json.dumps(results, indent=2) + '\n')
        if result.returncode:
            raise RuntimeError(name + ' failed; see evidence log')
    include = ['-Icore/include', '-I' + str(PREFIX / 'include')]
    run(['xcrun', 'clang++', '-std=c++17', '-O1', *include, '-c',
         'core/src/private_input.cpp', '-o', BUILD / 'core.o'], 'shared-core-compile')
    cases = ['shared_core_contract', 'pinyin_text_repair', 'windows_long_composition',
             'nine_prefix_smoke', 'nine_key_smoke', 'nine_filter_smoke',
             'candidate_scroll_smoke', 'candidate_management_smoke']
    for name in cases:
        binary = BUILD / 'test'
        user = BUILD / ('user-' + name)
        if user.exists():
            raise RuntimeError('Existing fixture preserved: ' + str(user))
        command = ['xcrun', 'clang++', '-std=c++17', '-O1', *include, 'core/tests/' + name + '.cpp']
        if name not in cases[:2]:
            command += [str(BUILD / 'core.o'), '-Wl,-force_load,' + str(PREFIX / 'lib/librime.a'),
                        '-L' + str(PREFIX / 'lib'), '-lyaml-cpp', '-lleveldb', '-lmarisa', '-lopencc']
        command += ['-o', str(binary)]
        run(command, name + '-build')
        arguments = [binary]
        if name == 'pinyin_text_repair':
            arguments += [ROOT / 'resources/semantic/pinyin-syllables.txt']
        elif name != 'shared_core_contract':
            arguments += [ROOT / 'resources/rime', user]
        if name == 'nine_filter_smoke':
            arguments += ['NO_DEPLOY']
        try:
            run(arguments, name)
        finally:
            if user.exists():
                shutil.rmtree(user)
            if binary.exists():
                binary.unlink()
    print(json.dumps({'commandsPassed': len(results), 'rimeSuites': 6, 'pureSuites': 2,
                      'installedAppsChanged': False}))


if __name__ == '__main__':
    main()
