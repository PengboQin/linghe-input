#!/usr/bin/env python3
"""049 bounded local checks. Never runs a Windows PE, accesses a device or user data."""
from pathlib import Path
import argparse, hashlib, json, os, subprocess
ROOT=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--toolchain',type=Path,required=True);a=p.parse_args()
b=ROOT/'build/windows-input-tests/review049';e=ROOT/'evidence/windows049/tests'
for d in (b,e):d.mkdir(parents=True,exist_ok=True)
env=dict(os.environ,TMPDIR=str(ROOT/'build/tmp'))
def run(cmd,name):
 with (e/(name+'.log')).open('w') as f:subprocess.run(list(map(str,cmd)),cwd=ROOT,env=env,stdout=f,stderr=subprocess.STDOUT,check=True)
flags=['clang++','-std=c++17','-Wall','-Wextra','-fsanitize=address,undefined']
for source,name in [('installer_recovery_transaction.cpp','recovery-contract'),('candidate_navigation.cpp','navigation'),('english_suggestions.cpp','english')]:
 run([*flags,'-Icore/include','-Iwindows/src','windows/tests/'+source,'-o',b/name],name+'-build')
 run([b/name],name)
run([*flags,'-DSODIUM_STATIC','-Ibuild/sodium-membership/native/include','windows/tests/activity/clipboard_read_safety.cpp','windows/activity/AutomaticClipboard.cpp','windows/activity/ArchiveCore.cpp','windows/activity/Json.cpp','build/sodium-membership/native/lib/libsodium.a','-o',b/'read-safety'],'read-safety-build')
run([b/'read-safety'],'read-safety')
compiler=a.toolchain/'bin/x86_64-w64-mingw32-clang++'
wf=['-std=c++17','-DUNICODE','-D_UNICODE','-DNOMINMAX','-D_WIN32_WINNT=0x0A00']
run([compiler,*wf,'-c','windows/tests/installer_journal_compile.cpp','-o',b/'journal.o'],'journal-cross-compile')
run([compiler,*wf,'-static','windows/tests/tsf_registration_probe.cpp','-Ibuild/rime/windows-x64/include','-lole32','-loleaut32','-luuid','-o',b/'tsf-registration-readonly.exe'],'tsf-probe-cross-build')
worker=(ROOT/'windows/activity/Worker.cpp').read_text();tsf=(ROOT/'windows/src/TextService.cpp').read_text();setup=(ROOT/'windows/installer/Setup.cpp').read_text();registration=(ROOT/'windows/src/Registration.cpp').read_text()
assert 'SetTimer(clipboardPollWindow' not in tsf
assert 'incomingText=add(' not in worker and '收到的共享文本' not in worker
start=worker.index('void publishClipboardCandidate(');end=worker.index('void refreshClipboardCandidatePermission',start)
assert 'memcpy' not in worker[start:end] and 'clearClipboardCandidate();' in worker[start:end]
assert setup.index('requireConsistentUpgrade(old,arpInstaller,report);')<setup.index('fs::create_directories(destination)')
assert 'registryString(key,L"DisplayVersion")!=installer.parent_path().filename().wstring()' in setup
assert 'requireInteractiveUser();' in setup and 'TokenUser' in setup and 'EqualSid(' in setup
assert 'verifiedEnabled!=profileEnabledBefore' in registration and 'verifiedManager->GetProfile(' in registration
assert 'SetDefaultLanguageProfile(' not in registration
incs=['windows/activity/AutomaticClipboardWorker.inc','windows/activity/ClipboardLiveWorkerBridge.inc','windows/tests/activity/queue_recovery_cases.inc']
assert all((ROOT/n).is_file() for n in incs)
record={'hostASanUBSanSuites':['recovery-contract','navigation','english','read-safety'],'windowsSDKCompile':['journal','tsf-registration-readonly'],'sourceGuards':9,'windowsExecuted':False,'installed':False,'realTSFVerified':False,'missingSourceSupplement':{n:hashlib.sha256((ROOT/n).read_bytes()).hexdigest() for n in incs}}
(e/'result.json').write_text(json.dumps(record,indent=2)+'\n');print(json.dumps(record))
