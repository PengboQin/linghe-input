#!/usr/bin/env python3
"""Build/run only synthetic typed-membership tests; optionally cross-build x64.

Source dependencies and the optional current Swift reference are read-only.
Every copied header/library, compiler temporary and output belongs to this
independent Windows project. No downloads, remote calls, key stores or JSON
product integration are involved.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sodium-source-root', type=Path)
    parser.add_argument('--reference-membership', type=Path)
    parser.add_argument('--toolchain', type=Path)
    args = parser.parse_args()
    evidence = ROOT / 'evidence/windows-membership-20261018'
    output = ROOT / 'build/membership-tests'
    temp = ROOT / 'build/tmp'
    for path in (evidence, output, temp):
        path.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env['TMPDIR'] = str(temp)
    env['CLANG_MODULE_CACHE_PATH'] = str(temp / 'membership-module-cache')
    env['SWIFT_MODULECACHE_PATH'] = str(temp / 'membership-module-cache')
    def run(command, name):
        with (evidence / (name + '.log')).open('w') as log:
            subprocess.run(list(map(str, command)), cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
    if args.sodium_source_root:
        source = args.sodium_source_root.resolve()
        records = []
        headers = source / 'vendor/libsodium-1.0.22/src/libsodium/include'
        for arch, build in [('native', 'build/sodium-native'), ('x64', 'build/sodium-windows/x64')]:
            prefix = ROOT / 'build/sodium-membership' / arch
            include, lib = prefix / 'include', prefix / 'lib'
            include.mkdir(parents=True, exist_ok=True)
            lib.mkdir(exist_ok=True)
            for path in [headers / 'sodium.h', *sorted((headers / 'sodium').glob('*.h'))]:
                target = include / path.relative_to(headers)
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(path, target)
            shutil.copy2(source / build / 'src/libsodium/include/sodium/version.h', include / 'sodium/version.h')
            archive = source / build / 'src/libsodium/.libs/libsodium.a'
            shutil.copy2(archive, lib / 'libsodium.a')
            records.append({'arch': arch, 'sourceArchive': str(archive), 'sha256': hashlib.sha256(archive.read_bytes()).hexdigest(), 'copiedTo': str((lib / 'libsodium.a').relative_to(ROOT))})
        (evidence / 'dependency-copy.json').write_text(json.dumps({'readOnlySource': True, 'downloaded': False, 'libraries': records}, indent=2) + '\n')
    fixture = ROOT / 'windows/tests/fixtures'
    reference_json = fixture / 'public-membership-reference.json'
    if args.reference_membership:
        reference = output / 'reference'
        reference.mkdir(exist_ok=True)
        source_bytes = args.reference_membership.resolve().read_bytes()
        (reference / 'Membership.swift').write_bytes(source_bytes)
        shutil.copy2(fixture / 'membership-reference-main.swift', reference / 'main.swift')
        executable = reference / 'membership-reference'
        run(['swiftc', '-module-cache-path', temp / 'membership-module-cache', fixture / 'membership-reference-stubs.swift', reference / 'Membership.swift', reference / 'main.swift', '-o', executable], 'swift-reference-build')
        run([executable, fixture / 'public-membership-v1.json'], 'swift-reference-vectors')
        values = json.loads((evidence / 'swift-reference-vectors.log').read_text())
        reference_json.write_text(json.dumps(values, indent=2) + '\n')
        (evidence / 'swift-reference-source.json').write_text(json.dumps({'source': str(args.reference_membership.resolve()), 'sha256': hashlib.sha256(source_bytes).hexdigest(), 'copiedLocally': True}, indent=2) + '\n')
    values = json.loads(reference_json.read_text())
    generated = output / 'include'
    generated.mkdir(exist_ok=True)
    (generated / 'membership-reference.h').write_text('#pragma once\n' + '\n'.join('inline constexpr char reference' + key[0].upper() + key[1:] + '[]="' + value + '";' for key, value in values.items()) + '\n')
    def build(compiler, arch, suffix, extra):
        prefix = ROOT / 'build/sodium-membership' / arch
        executable = output / ('membership_typed' + suffix)
        command = [compiler, '-std=c++17', '-Wall', '-Wextra', '-Werror', '-DSODIUM_STATIC', '-I' + str(prefix / 'include'), '-I' + str(generated), 'windows/sync/Membership.cpp', 'windows/tests/membership_typed.cpp', prefix / 'lib/libsodium.a', *extra, '-o', executable]
        run(command, 'membership-' + arch + '-build')
        return executable
    executable = build('clang++', 'native', '', [])
    run([executable], 'membership-native-results')
    result = {'module': 'typed Membership v1/v2 verifier only', 'nativeTests': 'passed', 'windowsExecuted': False, 'windowsCrossBuilt': False, 'jsonProductIntegration': False, 'privateKeyAPI': False}
    if args.reference_membership:
        lines = (evidence / 'membership-native-results.log').read_text().splitlines()
        signature = next(line.split(' ', 1)[1] for line in lines if line.startswith('PUBLIC_V2_SIGNATURE_HEX '))
        run([output / 'reference/membership-reference', fixture / 'public-membership-v1.json', signature], 'swift-verifies-portable-signature')
        result['currentSwiftCanonicalAndBidirectionalSignatures'] = 'passed'
    if args.toolchain:
        compiler = args.toolchain.resolve() / 'bin/x86_64-w64-mingw32-clang++'
        cross = build(compiler, 'x64', '-x64.exe', ['-static', '-lbcrypt', '-ladvapi32'])
        result.update(windowsCrossBuilt=True, windowsArtifact=str(cross.relative_to(ROOT)), windowsArtifactSHA256=hashlib.sha256(cross.read_bytes()).hexdigest())
    (evidence / 'results.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result))

if __name__ == '__main__':
    main()
