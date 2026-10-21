#!/usr/bin/env python3
"""046 bounded local clipboard safety checks; no PC, real clipboard, user data, install or download."""
from pathlib import Path
import argparse, hashlib, json, os, subprocess
ROOT=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--toolchain',type=Path,help='Existing LLVM-MinGW root; syntax-only check of modified Windows units')
a=p.parse_args()
evidence=ROOT/'evidence/windows046-clipboard-safety'
build=ROOT/'build/windows-input-tests/clipboard046'
temp=ROOT/'build/tmp'
for directory in [evidence,build,temp]:directory.mkdir(parents=True,exist_ok=True)
env=os.environ.copy();env['TMPDIR']=str(temp)
def run(command,name):
 with (evidence/(name+'.log')).open('w') as output:
  subprocess.run(list(map(str,command)),cwd=ROOT,env=env,stdout=output,stderr=subprocess.STDOUT,check=True)
base=['clang++','-std=c++17','-Wall','-Wextra','-fsanitize=address,undefined']
run([*base,'-pedantic','-Iwindows/src','windows/tests/clipboard_candidate.cpp','-o',build/'policy'],'policy-build')
run([build/'policy'],'candidate-policy')
run([*base,'-DSODIUM_STATIC','-Ibuild/sodium-membership/native/include','windows/tests/activity/clipboard_candidate_archive.cpp','windows/activity/ArchiveCore.cpp','windows/activity/ArchiveQueue.cpp','windows/activity/Json.cpp','build/sodium-membership/native/lib/libsodium.a','-o',build/'archive'],'archive-build')
run([build/'archive',build/'paste-fixture.sqlite'],'archive')
run([*base,'-DSODIUM_STATIC','-Ibuild/sodium-membership/native/include','windows/tests/activity/clipboard_read_safety.cpp','windows/activity/AutomaticClipboard.cpp','windows/activity/ArchiveCore.cpp','windows/activity/Json.cpp','build/sodium-membership/native/lib/libsodium.a','-o',build/'read-safety'],'read-safety-build')
run([build/'read-safety'],'read-safety')
run([*base,'-DSODIUM_STATIC','-Ibuild/sodium-membership/native/include','windows/tests/activity/clipboard_rejection_before.cpp','artifacts/LingheInput-Windows-0.4.5-review-source/windows/activity/AutomaticClipboard.cpp','artifacts/LingheInput-Windows-0.4.5-review-source/windows/activity/ArchiveCore.cpp','artifacts/LingheInput-Windows-0.4.5-review-source/windows/activity/Json.cpp','build/sodium-membership/native/lib/libsodium.a','-o',build/'repro-before'],'production045-counterexample-build')
run([build/'repro-before'],'production045-counterexample')
units=['windows/src/TextService.cpp','windows/src/CandidateWindow.cpp','windows/activity/CaptureIPC.cpp','windows/activity/Worker.cpp','windows/activity/ArchiveQueue.cpp']
if a.toolchain:
 compiler=a.toolchain.resolve()/'bin/x86_64-w64-mingw32-clang++'
 flags=['-std=c++17','-fsyntax-only','-DUNICODE','-D_UNICODE','-DNOMINMAX','-D_WIN32_WINNT=0x0A00','-DWINVER=0x0A00','-DNTDDI_VERSION=0x0A000003','-DRIME_IMPORTS','-DSODIUM_STATIC','-Iwindows/src','-Icore/include','-Ibuild/rime/windows-x64/include','-Ibuild/sodium-membership/x64/include']
 for unit in units:run([compiler,*flags,unit],Path(unit).name+'.syntax')
files=units+['windows/src/ClipboardCandidatePolicy.h','windows/src/CandidateWindow.h','windows/activity/ClipboardCandidateIPC.h','windows/activity/CaptureIPC.h','windows/activity/CaptureWire.h','windows/activity/AutomaticClipboardWorker.inc','windows/activity/CMakeLists.txt','windows/tests/activity/CMakeLists.txt','windows/tests/clipboard_candidate.cpp','windows/tests/activity/clipboard_candidate_archive.cpp','windows/activity/ClipboardReadSafety.h','windows/tests/activity/clipboard_read_safety.cpp','windows/tests/activity/clipboard_rejection_before.cpp','windows/activity/AutomaticClipboard.h','windows/activity/SourceContextWin.h','windows/installer/Setup.cpp','windows/installer/PayloadManifest.h','windows/tests/uninstall_policy.cpp','tools/test_windows_clipboard_safety046.py']
result={'sourceOnly':True,'policyASanUBSan':'passed','realSQLiteSyntheticQueueASanUBSan':'passed','stickyReadSafetyASanUBSan':'passed','frozen045ProductionCounterexample':'confirmed','windowsX64SyntaxOnly':bool(a.toolchain),'windowsExecuted':False,'realClipboardRead':False,'installed':False,'files':{file:hashlib.sha256((ROOT/file).read_bytes()).hexdigest() for file in files}}
(evidence/'result.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps({key:value for key,value in result.items() if key!='files'}))
