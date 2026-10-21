#!/usr/bin/env python3
"""Bounded native protocol/store/thread tests; synthetic keys, no device or live relay."""
from pathlib import Path
import argparse,hashlib,json,os,subprocess
ROOT=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--toolchain',type=Path);p.add_argument('--server-source',type=Path);a=p.parse_args()
build=ROOT/'build/windows-input-tests/clipboard047';evidence=ROOT/'evidence/windows047-live-clipboard';build.mkdir(parents=True,exist_ok=True);evidence.mkdir(parents=True,exist_ok=True)
base=['ClipboardLiveProtocol.cpp','ArchiveCore.cpp','Json.cpp','GroupProtocol.cpp','ContentModel.cpp']
common=[ROOT/'windows/activity'/n for n in base]+[ROOT/'windows/sync'/n for n in ['SecureProtocol.cpp','Membership.cpp','MembershipWire.cpp']]
env=os.environ.copy();env['TMPDIR']=str(ROOT/'build/tmp')
def run(cmd,name):
 r=subprocess.run(list(map(str,cmd)),cwd=ROOT,env=env,capture_output=True,text=True);(evidence/(name+'.log')).write_text(r.stdout+r.stderr);r.check_returncode();return r.stdout
flags=['clang++','-std=c++17','-O0','-g','-Wall','-Wextra','-fsanitize=address,undefined','-DSODIUM_STATIC','-Ibuild/sodium-membership/native/include']
for name,extra in [('protocol',[]),('store_worker',['ClipboardLiveStore.cpp','ClipboardLiveWorker.cpp'])]:
 exe=build/name;run([*flags,ROOT/'windows/tests/activity'/('clipboard_live_'+name+'.cpp'),*common,*[ROOT/'windows/activity'/n for n in extra],ROOT/'build/sodium-membership/native/lib/libsodium.a','-o',exe],name+'-build');print(run([exe,evidence/'cpp-vectors.json',*([ROOT/'windows/tests/activity/fixtures/clipboard-live-v1.json'] if name=='protocol' else [])],name),end='')
units=['Worker.cpp','Platform.cpp','GroupClient.cpp','ContentStore.cpp','ClipboardLiveProtocol.cpp','ClipboardLiveStore.cpp','ClipboardLiveWorker.cpp']
if a.toolchain:
 compiler=a.toolchain/'bin/x86_64-w64-mingw32-clang++'
 for unit in units:run([compiler,'-std=c++17','-fsyntax-only','-DUNICODE','-D_UNICODE','-DNOMINMAX','-D_WIN32_WINNT=0x0A00','-DSODIUM_STATIC','-Ibuild/sodium-membership/x64/include','-Icore/include',ROOT/'windows/activity'/unit],unit+'.syntax')
files=units+['ClipboardLiveWorkerBridge.inc','AutomaticClipboardWorker.inc','ClipboardLiveProtocol.h','ClipboardLiveStore.h','ClipboardLiveWorker.h','ContentStore.h','GroupClient.h','ClipboardPolicy.h','CMakeLists.txt']
record={'nativeASanUBSan':True,'windowsX64Syntax':bool(a.toolchain),'realClipboard':False,'network':False,'installedOrExecutedWindows':False,'sources':{n:hashlib.sha256((ROOT/'windows/activity'/n).read_bytes()).hexdigest() for n in files}}
(evidence/'live-result.json').write_text(json.dumps(record,indent=2)+'\n');print(json.dumps({k:v for k,v in record.items() if k!='sources'}))
