#!/usr/bin/env python3
"""Local navigation regression + optional Windows x64 direct-key TSF fixture build.

Never runs a remote command, registers an input source, downloads dependencies,
or builds Rime. A toolchain may be read from another existing installation;
all outputs and temporary files stay inside this independent project.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--toolchain', type=Path)
    args = parser.parse_args()
    evidence = ROOT / 'evidence/windows-input-20261018'
    output = ROOT / 'build/windows-input-tests/x64'
    temp = ROOT / 'build/tmp'
    for path in (evidence, output, temp):
        path.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env['TMPDIR'] = str(temp)
    def run(command, name):
        with (evidence / (name + '.log')).open('w') as log:
            subprocess.run(list(map(str, command)), cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
    navigation = output / 'candidate_navigation'
    run(['clang++', '-std=c++17', '-Wall', '-Wextra', '-pedantic', '-Icore/include', '-Iwindows/src',
         'windows/tests/candidate_navigation.cpp', '-o', navigation], 'candidate-navigation-build')
    run([navigation], 'candidate-navigation')
    result = {'nativeNavigationAndStream': 'passed', 'windowsFixtureBuilt': False, 'windowsFixtureExecuted': False}
    if args.toolchain:
        compiler = args.toolchain.resolve() / 'bin/x86_64-w64-mingw32-clang++'
        if not compiler.is_file():
            raise SystemExit('An existing LLVM-MinGW x64 toolchain is required')
        prefix = ROOT / 'build/rime/windows-x64'
        fixture = output / 'tsf_input_regression.exe'
        command = [compiler, '-std=c++17', '-static', '-municode', '-DUNICODE', '-D_UNICODE', '-DNOMINMAX',
                   '-DPRIVATE_INPUT_TSF_TEST_HOOKS', '-D_WIN32_WINNT=0x0A00', '-DWINVER=0x0A00', '-DNTDDI_VERSION=0x0A000003', '-DRIME_IMPORTS',
                   '-Iwindows/src', '-Icore/include', '-I' + str(prefix / 'include'),
                   'windows/tests/tsf_input_regression.cpp', 'windows/src/TextService.cpp', 'windows/tests/activity/FixtureIPC.cpp',
                   'windows/src/CandidateWindow.cpp', 'windows/activity/Json.cpp', 'core/src/private_input.cpp',
                   prefix / 'lib/librime.dll.a', prefix / 'lib/libleveldb.a',
                   '-lole32', '-loleaut32', '-lshell32', '-ladvapi32', '-luser32', '-lgdi32', '-luuid', '-o', fixture]
        run(command, 'tsf-input-fixture-cross-build')
        result.update(windowsFixtureBuilt=True, fixture=str(fixture.relative_to(ROOT)))
    (evidence / 'local-results.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result))

if __name__ == '__main__':
    main()
