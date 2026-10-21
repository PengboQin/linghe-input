#!/usr/bin/env python3
"""Build Windows Rime and TSF from pinned sources using project-local LLVM-MinGW."""
import argparse
from pathlib import Path
import shutil
import subprocess
import json
import os

ROOT = Path(__file__).resolve().parents[1]
TOOLS = ROOT/'.tools/llvm-mingw-20261006-ucrt-macos-universal'
CMAKE = ROOT/'.tools/python/bin/cmake'

def execute(args, log):
    log.write('COMMAND ' + ' '.join(map(str,args)) + '\n');log.flush()
    env=os.environ.copy();env['PATH']=str(TOOLS/'bin')+os.pathsep+env.get('PATH','')
    subprocess.run(list(map(str,args)),cwd=ROOT,env=env,stdout=log,stderr=subprocess.STDOUT,check=True)

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('arch',choices=['arm64','x64'])
    parser.add_argument('--sodium-prefix',type=Path,help='Existing same-architecture libsodium 1.0.22 prefix; no automatic download')
    args=parser.parse_args()
    sodium_prefix=(args.sodium_prefix or ROOT/'build/sodium-membership'/args.arch).resolve()
    if not (sodium_prefix/'include/sodium.h').is_file() or not (sodium_prefix/'lib/libsodium.a').is_file():
        parser.error('Provide a built same-architecture libsodium prefix with include/sodium.h and lib/libsodium.a')
    triplet='aarch64-w64-mingw32' if args.arch=='arm64' else 'x86_64-w64-mingw32'
    prefix=ROOT/'build/rime'/('windows-'+args.arch);prefix.mkdir(parents=True,exist_ok=True)
    common=['-DCMAKE_SYSTEM_NAME=Windows',f'-DCMAKE_C_COMPILER={TOOLS}/bin/{triplet}-clang',f'-DCMAKE_CXX_COMPILER={TOOLS}/bin/{triplet}-clang++',f'-DCMAKE_RC_COMPILER={TOOLS}/bin/{triplet}-windres',f'-DCMAKE_AR={TOOLS}/bin/llvm-ar',f'-DCMAKE_RANLIB={TOOLS}/bin/llvm-ranlib',f'-DCMAKE_INSTALL_PREFIX={prefix}',f'-DCMAKE_PREFIX_PATH={prefix}','-DCMAKE_BUILD_TYPE=Release','-DBUILD_SHARED_LIBS=OFF','-DCMAKE_CXX_STANDARD=17','-DCMAKE_SHARED_LINKER_FLAGS=-static','-DCMAKE_EXE_LINKER_FLAGS=-static']
    specs={
        'yaml-cpp':['-DYAML_CPP_BUILD_TESTS=OFF','-DYAML_CPP_BUILD_TOOLS=OFF','-DYAML_CPP_BUILD_CONTRIB=OFF'],
        'leveldb':['-DLEVELDB_BUILD_TESTS=OFF','-DLEVELDB_BUILD_BENCHMARKS=OFF','-DCMAKE_CXX_FLAGS=-include type_traits'],
        'marisa-trie':['-DBUILD_TESTING=OFF','-DENABLE_TOOLS=OFF'],
        'opencc':['-DENABLE_GTEST=OFF','-DBUILD_TESTING=OFF','-DUSE_SYSTEM_MARISA=ON','-DENABLE_DARTS=OFF',f'-DCMAKE_CXX_FLAGS=-I{prefix}/include'],
    }
    logpath=ROOT/'evidence/development-20261010-round2'/('windows-'+args.arch+'-build.log')
    logpath.parent.mkdir(parents=True,exist_ok=True)
    with logpath.open('w') as log:
        for dep,flags in specs.items():
            source=ROOT/'vendor/librime/deps'/dep;build=ROOT/'build/windows-deps'/args.arch/dep
            execute([CMAKE,'-S',source,'-B',build,*common,*flags],log)
            if dep!='opencc':
                execute([CMAKE,'--build',build,'--parallel','2'],log);execute([CMAKE,'--install',build],log)
            else:
                execute([CMAKE,'--build',build,'--parallel','2','--target','libopencc'],log)
                (prefix/'include/opencc').mkdir(parents=True,exist_ok=True);(prefix/'lib').mkdir(exist_ok=True)
                for p in list((source/'src').glob('*.hpp'))+list((source/'src').glob('*.h'))+list((build/'src').glob('*.h')):
                    shutil.copy2(p,prefix/'include/opencc'/p.name)
                archive=next(build.rglob('libopencc.a'));shutil.copy2(archive,prefix/'lib/libopencc.a')
        paths=[]
        for name,library in [('YamlCpp','yaml-cpp'),('LevelDb','leveldb'),('Marisa','marisa'),('Opencc','opencc')]:
            paths += [f'-D{name}_INCLUDE_PATH={prefix}/include',f'-D{name}_LIBRARY={prefix}/lib/lib{library}.a']
        paths += [f'-DYamlCpp_NEW_API={prefix}/include']
        # Keep the upstream checkout immutable. Its Clang RC heuristic assumes
        # clang-cl; LLVM-MinGW needs the GNU windres command template instead.
        source=ROOT/'build/windows-source/librime-33e7814-mingw-rcfix'
        if not source.exists():
            shutil.copytree(ROOT/'vendor/librime',source,ignore=shutil.ignore_patterns('.git','deps'))
            rc=source/'cmake/AddRCInfo.cmake';text=rc.read_text()
            old='# if clang build, use llvm-rc to compile resource file\nif(CMAKE_CXX_COMPILER_ID STREQUAL "Clang")'
            if text.count(old)!=1:raise SystemExit('RC compatibility anchor differs from pinned source')
            rc.write_text(text.replace(old,'# Use llvm-rc only for the MSVC Clang frontend.\nif(CMAKE_CXX_COMPILER_ID STREQUAL "Clang" AND MSVC)',1))
        rime=ROOT/'build/windows-librime-mingw'/args.arch;boost=ROOT/'vendor/boost_1_85_0'
        execute([CMAKE,'-S',source,'-B',rime,*common,*paths,'-DBUILD_SHARED_LIBS=ON','-DBUILD_STATIC=ON','-DBUILD_TEST=OFF','-DENABLE_LOGGING=OFF','-DENABLE_EXTERNAL_PLUGINS=OFF','-DENABLE_TIMESTAMP=OFF',f'-DBOOST_ROOT={boost}','-DBoost_NO_BOOST_CMAKE=TRUE','-DBoost_NO_SYSTEM_PATHS=TRUE',f'-DCMAKE_CXX_FLAGS=-I{boost}'],log)
        execute([CMAKE,'--build',rime,'--parallel','2'],log);execute([CMAKE,'--install',rime],log)
        tsf=ROOT/'build/windows-tsf'/args.arch
        execute([CMAKE,'-S',ROOT/'windows','-B',tsf,*common,f'-DPRIVATE_RIME_PREFIX={prefix}',f'-DPRIVATE_SODIUM_PREFIX={sodium_prefix}'],log)
        execute([CMAKE,'--build',tsf,'--parallel','2'],log)
    print(json.dumps({'arch':args.arch,'status':'built','runtime_validation':False,'log':str(logpath.relative_to(ROOT))}))

if __name__=='__main__':main()
