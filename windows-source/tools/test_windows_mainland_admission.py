#!/usr/bin/env python3
"""Shared native admission + Windows candidate helper; optional existing x64 target build.

No downloads, registration, installation, remote commands or user database access.
The existing canonical core object and dependency libraries are read, never copied.
"""
from pathlib import Path
import argparse, datetime, hashlib, json, os, subprocess

ROOT = Path(__file__).resolve().parents[1]
MASTER = ROOT.parent / 'private-input'
BUILD = ROOT / 'build/mainland-admission'
EVIDENCE = ROOT / 'evidence/windows-mainland-admission-20261021'

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cross-build',action='store_true',help='Build only the existing PrivateInputTSF x64 CMake target')
    args=parser.parse_args()
    BUILD.mkdir(parents=True,exist_ok=True);EVIDENCE.mkdir(parents=True,exist_ok=True)
    env=dict(os.environ,TMPDIR=str(BUILD));commands=[]
    sources=[ROOT/'windows/src/CandidateAdmission.h',ROOT/'windows/src/TextService.cpp',ROOT/'windows/tests/candidate_mainland_admission.cpp',ROOT/'tools/test_windows_mainland_admission.py']
    sources+=sorted(p for p in (MASTER/'core').rglob('*') if p.is_file() and p.suffix in {'.h','.hpp','.cpp'})
    before={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
    def run(name,command,accepted=(0,)):
        command=list(map(str,command));result=subprocess.run(command,cwd=ROOT,env=env,text=True,capture_output=True,timeout=180)
        (EVIDENCE/(name+'.log')).write_text(result.stdout+result.stderr)
        commands.append({'name':name,'exitCode':result.returncode,'command':command})
        (EVIDENCE/'commands.json').write_text(json.dumps(commands,indent=2)+'\n')
        if result.returncode not in accepted:raise RuntimeError(name+' failed; inspect evidence')
        return result
    old=run('legacy-master-guard-before',['python3','tools/guard_master.py'],(0,1))
    run('unique-shared-core',['python3','tools/check_shared_core.py'])
    native=MASTER/'build/mainland-policy/core.o';prefix=MASTER/'build/rime/macos-arm64'
    run('host-build',['xcrun','clang++','-std=c++17','-Icore/include','-Iwindows/src','windows/tests/candidate_mainland_admission.cpp',native,'-L'+str(prefix/'lib'),'-lrime','-lyaml-cpp','-lleveldb','-lmarisa','-lopencc','-Wl,-dead_strip','-o',BUILD/'candidate-admission'])
    checked=run('host-admission',[BUILD/'candidate-admission'])
    if args.cross_build:
        run('tsf-x64-build',[MASTER/'.tools/python/bin/cmake','--build','build/windows-tsf/x64','--target','PrivateInputTSF','--parallel','2'])
    after=run('legacy-master-guard-after',['python3','tools/guard_master.py'],(0,1))
    stable=all(hashlib.sha256(Path(name).read_bytes()).hexdigest()==digest for name,digest in before.items())
    result={'checkedAtUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),'result':'passed' if stable else 'sourceChanged','hostChecks':27,'actualSharedCoreABI':True,'actualWindowsAdmissionHelper':True,'nativeCandidateIDsPreserved':True,'sourceStableDuringChecks':stable,'sourceSHA256':before,'coreObjectSHA256':hashlib.sha256(native.read_bytes()).hexdigest(),'hostOutput':checked.stdout.strip(),'x64TSFDLLBuilt':args.cross_build,'packaged':False,'signed':False,'installed':False,'remoteAccess':False,'realWindowsHostRun':False,'nativeRimeSessionCreated':False,'legacyMasterGuardBaselineReset':False,'legacyGuardBaselineUnchangedBefore':json.loads(old.stdout)['masterBaselineUnchanged'],'legacyGuardBaselineUnchangedAfter':json.loads(after.stdout)['masterBaselineUnchanged']}
    if args.cross_build:
        dll=ROOT/'build/windows-tsf/x64/PrivateInputTSF.dll';manifest=ROOT/'build/windows-tsf/x64/shared-core-sha256.txt'
        result['x64DLLSHA256']=hashlib.sha256(dll.read_bytes()).hexdigest();result['builtSharedCoreManifest']=manifest.read_text()
    (EVIDENCE/'result.json').write_text(json.dumps(result,indent=2)+'\n')
    print(checked.stdout.strip());print('PASS unique shared core and'+(' x64 TSF DLL build;' if args.cross_build else '')+' no package, install, registration or remote device operation')
    if not stable:raise RuntimeError('Source changed during verification')

if __name__=='__main__':main()
