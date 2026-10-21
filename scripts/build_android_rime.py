#!/usr/bin/env python3
"""Build our pinned Rime and adapter for arm64 Android, no emulator/device writes."""
from pathlib import Path
import subprocess,shutil
R=Path(__file__).resolve().parents[1];ndk=R/'.tools/android/ndk/28.2.13676358';prefix=R/'build/rime/android-arm64';prefix.mkdir(parents=True,exist_ok=True)
cmake=R/'.tools/python/bin/cmake';E=R/'evidence/cross-platform47-mac37-20261016'
E.mkdir(parents=True,exist_ok=True)
common=[f'-DCMAKE_TOOLCHAIN_FILE={ndk}/build/cmake/android.toolchain.cmake','-DANDROID_ABI=arm64-v8a','-DANDROID_PLATFORM=android-26','-DANDROID_STL=c++_static',f'-DCMAKE_INSTALL_PREFIX={prefix}',f'-DCMAKE_PREFIX_PATH={prefix}','-DCMAKE_BUILD_TYPE=Release','-DBUILD_SHARED_LIBS=OFF','-DCMAKE_POSITION_INDEPENDENT_CODE=ON','-DCMAKE_CXX_STANDARD=17']
with (E/'android-rime-build.log').open('w') as log:
 def run(args):subprocess.run(list(map(str,args)),cwd=R,stdout=log,stderr=subprocess.STDOUT,check=True)
 deps=R/'vendor/librime/deps'
 for name,flags in [('yaml-cpp',['-DYAML_CPP_BUILD_TESTS=OFF','-DYAML_CPP_BUILD_TOOLS=OFF','-DYAML_CPP_BUILD_CONTRIB=OFF']),('leveldb',['-DLEVELDB_BUILD_TESTS=OFF','-DLEVELDB_BUILD_BENCHMARKS=OFF']),('marisa-trie',['-DBUILD_TESTING=OFF','-DENABLE_TOOLS=OFF']),('opencc',['-DENABLE_GTEST=OFF','-DBUILD_TESTING=OFF','-DUSE_SYSTEM_MARISA=ON',f'-DLIBMARISA={prefix}/lib/libmarisa.a','-DENABLE_DARTS=OFF',f'-DCMAKE_CXX_FLAGS=-I{prefix}/include'])]:
  build=R/'build/android-deps'/name;run([cmake,'-S',deps/name,'-B',build,*common,*flags])
  if name=='opencc':
   run([cmake,'--build',build,'--parallel','3','--target','libopencc']);(prefix/'include/opencc').mkdir(parents=True,exist_ok=True)
   for p in list((deps/name/'src').glob('*.hpp'))+list((deps/name/'src').glob('*.h'))+list((build/'src').glob('*.h')):shutil.copy2(p,prefix/'include/opencc'/p.name)
   shutil.copy2(next(build.rglob('libopencc.a')),prefix/'lib/libopencc.a')
  else:run([cmake,'--build',build,'--parallel','3']);run([cmake,'--install',build])
 build=R/'build/android-librime';boost=R/'vendor/boost_1_85_0';paths=[]
 for name,library in [('YamlCpp','yaml-cpp'),('LevelDb','leveldb'),('Marisa','marisa'),('Opencc','opencc')]:paths += [f'-D{name}_INCLUDE_PATH={prefix}/include',f'-D{name}_LIBRARY={prefix}/lib/lib{library}.a']
 run([cmake,'-S',R/'vendor/librime','-B',build,*common,*paths,f'-DYamlCpp_NEW_API={prefix}/include','-DBUILD_TEST=OFF','-DENABLE_LOGGING=OFF','-DENABLE_EXTERNAL_PLUGINS=OFF','-DBUILD_STATIC=ON','-DENABLE_TIMESTAMP=OFF',f'-DBOOST_ROOT={boost}','-DBoost_NO_BOOST_CMAKE=TRUE','-DBoost_NO_SYSTEM_PATHS=TRUE',f'-DCMAKE_CXX_FLAGS=-I{boost}'])
 run([cmake,'--build',build,'--parallel','3']);run([cmake,'--install',build])
print('Pinned Android arm64 Rime built')
