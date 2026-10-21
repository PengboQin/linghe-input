#!/usr/bin/env python3
"""Check the shared-core boundary without modifying either workspace."""
import argparse
import hashlib
import json
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def verify(root, consumer):
    canonical = root / 'core'
    forwarded = consumer / 'core'
    errors, files = [], {}
    sources = {p.relative_to(canonical): p for p in canonical.rglob('*') if p.is_file()}
    actual = {p.relative_to(forwarded): p for p in forwarded.rglob('*') if p.is_file()}
    for rel, source in sources.items():
        target = forwarded / rel
        expected = ('// Generated forwarding file. Edit the canonical core, never this file.\n'
                    '#include "' + os.path.relpath(source, target.parent).replace(os.sep, '/') + '"\n')
        if not target.is_file() or target.is_symlink() or target.read_text() != expected:
            errors.append('Missing or independently modified forwarding file: ' + str(rel))
        files[str(rel)] = hashlib.sha256(source.read_bytes()).hexdigest()
    for rel in actual.keys() - sources.keys():
        errors.append('Independent consumer core file: ' + str(rel))
    cmake = (consumer / 'windows/CMakeLists.txt').read_text()
    consumers = '\n'.join(line for line in cmake.splitlines()
                          if line.startswith(('add_library(', 'add_executable(', 'target_include_directories(')))
    if '../core/src/' in consumers or '../core/include' in consumers:
        errors.append('Windows CMake bypasses PRIVATE_INPUT_CORE_ROOT')
    return {'passed': not errors, 'coreFiles': files, 'errors': errors,
            'installedAppsChanged': False}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--consumer', type=Path, default=ROOT.parent / 'private-input-windows')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    result = verify(ROOT, args.consumer.resolve())
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({'passed': result['passed'], 'coreFileCount': len(result['coreFiles']),
                      'errors': result['errors']}))
    raise SystemExit(0 if result['passed'] else 1)
