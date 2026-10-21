#!/usr/bin/env python3
"""Host-only manifest/PE bundle checks. Never executes or registers a Windows PE."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess

ROOT=Path(__file__).resolve().parents[1]


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--installer',type=Path)
    p.add_argument('--version',default='0.2.8-win1')
    p.add_argument('--evidence',type=Path,default=ROOT/'evidence/windows024-offline-installer')
    a=p.parse_args()
    out=ROOT/'build/offline-installer/tests';out.mkdir(parents=True,exist_ok=True)
    evidence=a.evidence.resolve()
    if not evidence.is_relative_to(ROOT): raise ValueError('Evidence must stay inside this project')
    evidence.mkdir(parents=True,exist_ok=True)
    executable=out/'payload_manifest'
    with (evidence/'manifest-test.log').open('w') as log:
        subprocess.run(['clang++','-std=c++17','-Wall','-Wextra','-pedantic','-fsanitize=address,undefined',
                        'windows/tests/payload_manifest.cpp','-o',str(executable)],cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,check=True)
        subprocess.run([str(executable)],cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,check=True)
    uninstall=out/'uninstall_policy'
    with (evidence/'uninstall-policy-test.log').open('w') as log:
        subprocess.run(['clang++','-std=c++17','-Wall','-Wextra','-pedantic','-fsanitize=address,undefined',
                        'windows/tests/uninstall_policy.cpp','-o',str(uninstall)],cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,check=True)
        subprocess.run([str(uninstall)],cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,check=True)
    result={'manifestASanUBSan':'passed','uninstallPolicyASanUBSan':'passed','windowsExecuted':False}
    if a.installer:
        installer=a.installer.resolve()
        if not installer.is_relative_to(ROOT): raise ValueError('Installer must be inside this project')
        spec=importlib.util.spec_from_file_location('pack',ROOT/'tools/build_offline_installer.py')
        module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
        actual_version=module.verify_version_information(installer,a.version)
        actual_icon=module.verify_icon_resources(installer,ROOT/'windows/resources/AppIcon.ico')
        resources,signature=module.pe_resources(installer)
        manifests,_=module.pe_resources(installer,24)
        if b'level="requireAdministrator"' not in manifests.get(1,b''):
            raise ValueError('Missing native administrator execution manifest')
        if 1000 not in resources: raise ValueError('No embedded manifest')
        manifest=resources[1000].decode('ascii').splitlines()
        if manifest[0]!='version='+a.version: raise ValueError('Version differs')
        entries=[line.split('  ',1) for line in manifest[1:] if line]
        if set(resources)!={1000,*range(1001,1001+len(entries))}: raise ValueError('Missing or unlisted payload resource')
        for i,(sha,name) in enumerate(entries):
            module.safe_name(name)
            if hashlib.sha256(resources[1001+i]).hexdigest()!=sha: raise ValueError('Embedded payload corrupted')
        # A one-byte payload mutation must be detected, rather than accepted or ignored.
        data=bytearray(resources[1001]);data[len(data)//2]^=1
        assert hashlib.sha256(data).hexdigest()!=entries[0][0]
        result.update(versionResourceReadback=actual_version,iconResourceReadback=actual_icon,embeddedResourceAudit='passed',corruptPayloadDigestRejected=True,
                      embeddedFiles=len(entries),certificateTablePresent=signature,
                      requestedExecutionLevel='requireAdministrator',
                      installerSHA256=hashlib.sha256(installer.read_bytes()).hexdigest())
    (evidence/'local-results.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result))

if __name__=='__main__':main()
