#!/usr/bin/env python3
"""Build/run the isolated GroupClient fixture with existing local dependencies.

No download, live relay, product profile, clipboard, keyboard or deployment.
Requires an existing C++ compiler, CMake, libsodium prefix and Python crypto.
"""
import argparse,json,os,subprocess,sys
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--sodium-prefix',type=Path,required=True)
p.add_argument('--cmake',default='cmake')
p.add_argument('--python',default=sys.executable)
p.add_argument('--compiler')
p.add_argument('--build-only',action='store_true')
a=p.parse_args()
build=ROOT/'build/group-client-fixture'
command=[a.cmake,'-S',str(ROOT/'windows/tests/activity'),'-B',str(build),'-DPRIVATE_SODIUM_PREFIX='+str(a.sodium_prefix.resolve()),'-DPython3_EXECUTABLE='+a.python]
if a.compiler:command.append('-DCMAKE_CXX_COMPILER='+a.compiler)
subprocess.run(command,cwd=ROOT,check=True)
subprocess.run([a.cmake,'--build',str(build),'--config','Release','--parallel','2'],cwd=ROOT,check=True)
if not a.build_only:
    ctest=str(Path(a.cmake).with_name('ctest')) if Path(a.cmake).parent!=Path('.') else 'ctest'
    subprocess.run([ctest,'--test-dir',str(build),'-C','Release','--output-on-failure'],cwd=ROOT,check=True)
