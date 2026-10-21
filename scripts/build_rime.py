#!/usr/bin/env python3
"""Build pinned upstream sources into app-owned static libraries; never global-install."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
CMAKE = ROOT / '.tools/python/bin/cmake'
SPECS = {'macos-arm64': ('macosx', 'Darwin', '13.0'), 'ios-sim-arm64': ('iphonesimulator', 'iOS', '16.0'), 'ios-arm64': ('iphoneos', 'iOS', '16.0')}

def run(args, log):
    log.write('COMMAND ' + ' '.join(map(str, args)) + '\n'); log.flush()
    subprocess.run(list(map(str, args)), cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, check=True)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('slice', choices=SPECS)
    parser.add_argument('--dependencies-only', action='store_true')
    args = parser.parse_args()
    sdk, system, target = SPECS[args.slice]
    sdkpath = subprocess.check_output(['xcrun', '--sdk', sdk, '--show-sdk-path'], text=True).strip()
    prefix = ROOT / 'build/rime' / args.slice
    prefix.mkdir(parents=True, exist_ok=True)
    (ROOT / 'evidence/development-20261010').mkdir(parents=True, exist_ok=True)
    options = [f'-DCMAKE_SYSTEM_NAME={system}', f'-DCMAKE_OSX_SYSROOT={sdkpath}', '-DCMAKE_OSX_ARCHITECTURES=arm64', f'-DCMAKE_OSX_DEPLOYMENT_TARGET={target}', f'-DCMAKE_INSTALL_PREFIX={prefix}', f'-DCMAKE_PREFIX_PATH={prefix}', '-DCMAKE_BUILD_TYPE=Release', '-DBUILD_SHARED_LIBS=OFF', '-DCMAKE_POSITION_INDEPENDENT_CODE=ON', '-DCMAKE_CXX_STANDARD=17', '-DCMAKE_MACOSX_BUNDLE=OFF', '-DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO']
    deps = ROOT / 'vendor/librime/deps'
    specs = {
        'yaml-cpp': ['-DYAML_CPP_BUILD_TESTS=OFF', '-DYAML_CPP_BUILD_TOOLS=OFF', '-DYAML_CPP_BUILD_CONTRIB=OFF'],
        'leveldb': ['-DLEVELDB_BUILD_TESTS=OFF', '-DLEVELDB_BUILD_BENCHMARKS=OFF'],
        'marisa-trie': ['-DBUILD_TESTING=OFF', '-DENABLE_TOOLS=OFF'],
        'opencc': ['-DENABLE_GTEST=OFF', '-DBUILD_TESTING=OFF', '-DUSE_SYSTEM_MARISA=ON', '-DENABLE_DARTS=OFF', f'-DCMAKE_CXX_FLAGS=-I{prefix}/include'],
    }
    with (ROOT / f'evidence/development-20261010/rime-{args.slice}.log').open('w') as log:
        for dep, flags in specs.items():
            build = ROOT / 'build/deps' / args.slice / dep
            run([CMAKE, '-S', deps / dep, '-B', build, *options, *flags], log)
            if dep != 'opencc':
                run([CMAKE, '--build', build, '--parallel', '3'], log)
                run([CMAKE, '--install', build], log)
            else:
                run([CMAKE, '--build', build, '--parallel', '3', '--target', 'libopencc'], log)
                (prefix/'include/opencc').mkdir(parents=True, exist_ok=True)
                (prefix/'lib').mkdir(parents=True, exist_ok=True)
                for p in list((deps/dep/'src').glob('*.hpp')) + list((deps/dep/'src').glob('*.h')) + list((build/'src').glob('*.h')):
                    shutil.copy2(p, prefix/'include/opencc'/p.name)
                library = next(build.rglob('libopencc.a'))
                shutil.copy2(library, prefix/'lib/libopencc.a')
        if args.dependencies_only:
            print(json.dumps({'slice': args.slice, 'dependencies': 'built'})); return
        build = ROOT / 'build/librime' / args.slice
        boost = ROOT / 'vendor/boost_1_85_0'
        dependency_paths = []
        for name, library in [('YamlCpp', 'yaml-cpp'), ('LevelDb', 'leveldb'), ('Marisa', 'marisa'), ('Opencc', 'opencc')]:
            dependency_paths += [f'-D{name}_INCLUDE_PATH={prefix}/include', f'-D{name}_LIBRARY={prefix}/lib/lib{library}.a']
        dependency_paths += [f'-DYamlCpp_NEW_API={prefix}/include']
        run([CMAKE, '-S', ROOT/'vendor/librime', '-B', build, *options, *dependency_paths, '-DBUILD_TEST=OFF', '-DENABLE_LOGGING=OFF', '-DENABLE_EXTERNAL_PLUGINS=OFF', '-DBUILD_STATIC=ON', '-DENABLE_TIMESTAMP=OFF', f'-DBOOST_ROOT={boost}', '-DBoost_NO_BOOST_CMAKE=TRUE', '-DBoost_NO_SYSTEM_PATHS=TRUE', f'-DCMAKE_CXX_FLAGS=-I{boost}'], log)
        run([CMAKE, '--build', build, '--parallel', '3'], log)
        run([CMAKE, '--install', build], log)
        libraries = [str(p.relative_to(ROOT)) for p in (prefix/'lib').glob('*.a')]
        print(json.dumps({'slice': args.slice, 'static_libraries': libraries, 'input_logging': False, 'external_plugins': False}))

if __name__ == '__main__':
    main()
