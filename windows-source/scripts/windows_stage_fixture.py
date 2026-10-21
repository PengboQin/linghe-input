#!/usr/bin/env python3
"""Stage a public synthetic test ZIP in an exclusive guest folder without shared folders or UI."""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import subprocess

ROOT=Path(__file__).resolve().parents[1]
VM='3668e39d-7614-4368-a9f9-558bce4d5567'
OWNER='live.linghe.privateinput.dev'

def execute(code, stdin=None, current_user=False):
    prefix="$ProgressPreference='SilentlyContinue';$ErrorActionPreference='Stop';"
    encoded=base64.b64encode((prefix+code).encode('utf-16le')).decode()
    command=['prlctl','exec',VM]
    if current_user:command.append('--current-user')
    try:
        result=subprocess.run(command+['powershell.exe','-NoProfile','-EncodedCommand',encoded],input=stdin,capture_output=True,timeout=60)
    except subprocess.TimeoutExpired:
        raise RuntimeError('Guest observation timed out; remote completion is unconfirmed. Inspect the existing owned process and fixture before retrying.') from None
    def decode(data):
        try:return data.decode('utf-8')
        except UnicodeError:return data.decode('gb18030',errors='replace')
    if result.returncode:
        raise RuntimeError('Guest transport returned '+str(result.returncode)+': '+decode(result.stderr)[:300])
    return decode(result.stdout).strip()

def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('zip',type=Path);parser.add_argument('--current-user',action='store_true');args=parser.parse_args()
    asset=args.zip.resolve()
    if not asset.is_relative_to((ROOT/'artifacts').resolve()):raise SystemExit('Only project-owned fixture artifacts can be staged')
    data=asset.read_bytes();digest=hashlib.sha256(data).hexdigest();job=digest[:16]
    root=r'C:\PrivateInputDev'
    context={'system':True,'interactiveAcceptance':False}
    if args.current_user:
        context=json.loads(execute("@{root=(Join-Path $env:LOCALAPPDATA 'PrivateInputDev');system=[Security.Principal.WindowsIdentity]::GetCurrent().IsSystem;session=(Get-Process -Id $PID).SessionId}|ConvertTo-Json -Compress",current_user=True))
        if context['system'] or context['session']==0:raise SystemExit('Interactive user transport required; refusing SYSTEM/session 0')
        root=context['root'];context['interactiveAcceptance']=True
    quoted_root=root.replace("'","''")
    # Refuse an unrelated directory instead of adopting or deleting it.
    execute("$r='"+quoted_root+"';$m=Join-Path $r 'owner.json';if(Test-Path $r){if(!(Test-Path $m)){throw 'Unowned project folder'};$o=Get-Content -Raw $m|ConvertFrom-Json;if($o.owner -ne '"+OWNER+"'){throw 'Different folder owner'}}else{New-Item -ItemType Directory -Path $r|Out-Null;@{owner='"+OWNER+"'}|ConvertTo-Json|Set-Content -Encoding UTF8 $m}",current_user=args.current_user)
    stage=root+'\\fixtures\\'+job;quoted_stage=stage.replace("'","''")
    execute("New-Item -ItemType Directory -Force -Path '"+quoted_stage+"'|Out-Null",current_user=args.current_user)
    # The verified CLI stdin path avoids a new guest login for every byte chunk.
    # Repeated logins can exhaust Parallels sessions; do not alter guest settings.
    code="$r='"+quoted_stage+"';$z=Join-Path $r 'fixture.zip';$line=[Console]::In.ReadLine();[IO.File]::WriteAllBytes($z,[Convert]::FromBase64String($line));if((Get-FileHash -Algorithm SHA256 $z).Hash.ToLower() -ne '"+digest+"'){throw 'ZIP digest mismatch'};$out=Join-Path $r ('runtime-'+[Guid]::NewGuid().ToString('N'));Expand-Archive $z $out;@{job='"+job+"';digest='"+digest+"';runtime=$out}|ConvertTo-Json -Compress"
    payload=base64.b64encode(data)+b'\n'
    try:
        result=execute(code,payload,current_user=args.current_user)
    except RuntimeError as error:
        # A specific Parallels pre-dispatch failure has occurred with large
        # stdin. Do not create a second runtime if the first outcome is unknown.
        if '255' not in str(error) or 'Invalid argument' not in str(error):raise
        state=json.loads(execute("$r='"+quoted_stage+"';@{zip=(Test-Path (Join-Path $r 'fixture.zip'));runtimes=@(Get-ChildItem -Path $r -Directory -Filter 'runtime-*').Count}|ConvertTo-Json -Compress",current_user=args.current_user))
        if state['zip'] or state['runtimes']:
            raise RuntimeError('Stage outcome requires recovery from existing owned files; refusing duplicate transfer') from error
        (ROOT/'evidence/development-20261010-round2'/('guest-stage-'+job+'-transport-retry.json')).write_text(json.dumps({'initial_error':str(error),'readback':state,'same_artifact_sha256':digest,'retry_count':1},indent=2)+'\n')
        result=execute(code,payload,current_user=args.current_user)
    remote=json.loads(result)
    evidence={'asset':asset.name,'sha256':digest,'transport':'verified stdin','runtime':remote['runtime'],'execution_context':context,'registered':False,'input_ui_changed':False}
    (ROOT/'evidence/development-20261010-round2'/('guest-stage-'+job+'.json')).write_text(json.dumps(evidence,indent=2)+'\n')
    print(result)

if __name__=='__main__':main()
