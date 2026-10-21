#!/usr/bin/env python3
"""Synthetic bounded Membership wire tests; no remote, SDK/library download or keys.

Use an existing Python with cryptography for --reference-server. Reference files
are read-only inputs, copied under this independent project's build directory.
"""
import argparse
import ast
import base64
import copy
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]

def corpus(directory):
    root=json.loads((directory/'swift-v1.json').read_text())
    v2=json.loads((directory/'swift-v2.json').read_text())
    cases=[]
    def add(name,value,kind='reject'):
        data=value if isinstance(value,bytes) else (value if isinstance(value,str) else json.dumps(value,separators=(',',':'))).encode()
        file='case-'+name+'.json';(directory/file).write_bytes(data);cases.append((kind,file))
    def field(name,value):
        v=copy.deepcopy(root);v[name]=value;return v
    raw=json.dumps(root,separators=(',',':'))
    add('standard-whitespace',' \t\r\n'+json.dumps(root,indent=2)+'\r\n\t ','verify')
    add('escaped-keys-uuid-base64',raw.replace('"version"','"\\u0076ersion"').replace('"00000000','"\\u00300000000').replace('/','\\/'),'verify')
    for name in ['issuer','parent','history']:add('null-'+name,field(name,None),'verify')
    nullable=copy.deepcopy(root);nullable.update(issuer=None,parent=None,history=None);add('all-optionals-null',nullable,'verify')
    nullable=copy.deepcopy(v2);nullable['history'][0].update(issuer=None,parent=None,history=None);add('predecessor-nulls',nullable,'verify')
    upper=raw.replace('00000000-0000-4000-8000-000000000001','ABCDEF12-ABCD-4DEF-8ABC-ABCDEF123456');add('uppercase-uuid',upper,'accept')
    add('lowercase-uuid',upper.lower().replace('"ownerid"','"ownerID"').replace('"ownerpublic"','"ownerPublic"').replace('"signingpublic"','"signingPublic"').replace('"exchangepublic"','"exchangePublic"'),'accept')
    # Preserve actual public key base64 case in this independently changed UUID.
    lower=copy.deepcopy(root);lower['group']='abcdef12-abcd-4def-8abc-abcdef123456';add('lowercase-uuid-valid',lower,'accept')
    for name in list(root):
        v=copy.deepcopy(root);del v[name];add('missing-'+name,v)
        add('null-required-'+name,field(name,None))
    add('unknown-top',field('unexpected',1))
    v=copy.deepcopy(root);v['members'][0]['unknown']=0;add('unknown-member',v)
    add('duplicate-version',raw[:-1]+',"version":1}')
    add('escaped-duplicate',raw[:-1]+',"\\u0076ersion":1}')
    add('duplicate-member',raw.replace('"permissions": 3','"permissions":3').replace('"permissions":3','"permissions":3,"permissions":3'))
    for name,value in [('float','1.0'),('exponent','1e0'),('negative','-1'),('negative-zero','-0'),('plus','+1'),('leading-zero','01'),('nan','NaN'),('infinity','Infinity'),('bool','true'),('quoted','"1"'),('overflow','18446744073709551616'),('huge','9'*10000)]:
        add('integer-'+name,raw.replace('"revision":1','"revision":'+value))
    for name,value in [('zero',0),('version-3',3),('version-256',256)]:add(name,field('version',value))
    add('epoch-mismatch',field('epoch',2));add('zero-revision',dict(root,revision=0,epoch=0))
    for name,value in [('short','00000000'),('braces','{'+root['group']+'}'),('no-hyphens',root['group'].replace('-','')),('bad-digit',root['group'][:-1]+'G'),('bad-separator',root['group'].replace('-','_',1)),('unicode','é'*18)]:add('uuid-'+name,field('group',value))
    for name,value in [('short',root['ownerPublic'][:-1]),('invalid','!'*44),('url',root['ownerPublic'].replace('/','_')),('space',root['ownerPublic'][:5]+' '+root['ownerPublic'][6:]),('trailing','A'*43+'='+'AAAA'),('nonzero-pad-bits','A'*42+'B='),('decoded31',base64.b64encode(bytes(31)).decode()),('decoded33',base64.b64encode(bytes(33)).decode())]:add('base64-'+name,field('ownerPublic',value))
    for size in [1,63,65]:add('signature-'+str(size),field('signature',base64.b64encode(bytes(size)).decode()))
    add('unsigned-template',field('signature',''),'untrusted')
    for name,value in [('empty',[]),('65',[root['members'][0]]*65),('null',None),('object',{})]:add('members-'+name,field('members',value))
    for permission in [0,4,256,-1,True,{},None]:
        v=copy.deepcopy(root);v['members'][0]['permissions']=permission;add('permissions-'+str(permission),v)
    v=copy.deepcopy(root);v['members']*=2;add('members-duplicate',v)
    for name in ['device','signingPublic','exchangePublic','permissions']:
        v=copy.deepcopy(root);del v['members'][0][name];add('member-missing-'+name,v)
    add('v1-nonnull-issuer',field('issuer',root['ownerID']));add('v1-nonnull-parent',field('parent',root['ownerPublic']));add('v1-empty-history',field('history',[]))
    for name in ['issuer','parent']:
        v=copy.deepcopy(v2);v[name]=None;add('v2-null-'+name,v)
    v=copy.deepcopy(v2);v['history']=[];add('v2-empty-history',v,'untrusted')
    v=copy.deepcopy(v2);v['history']=None;add('v2-null-history',v,'untrusted')
    v=copy.deepcopy(v2);del v['history'];add('v2-absent-history',v,'untrusted')
    for value in [[],[root],None]:
        v=copy.deepcopy(v2);v['history'][0]['history']=value;add('nested-history-'+str(len(value) if value is not None else 'null'),v,'verify' if value is None else 'reject')
    v=copy.deepcopy(v2);v['history']=[root]*1025;add('history-1025',v)
    v=copy.deepcopy(v2);v['history'][0]['unknown']=1;add('history-unknown',v)
    for name,value in [('empty',b''),('array',b'[]'),('null',b'null'),('bom',b'\xef\xbb\xbf'+raw.encode()),('nul',raw.encode()+b'\0'),('trailing',raw.encode()+b'{}'),('truncated',raw[:-1].encode()),('trailing-comma',raw[:-1].encode()+b',}'),('comment',b'/*x*/'+raw.encode()),('vertical-tab',b'\x0b'+raw.encode()),('formfeed',b'\x0c'+raw.encode()),('deep',b'['*10000+b']'*10000),('over2mib',b' '*2097153)]:add('json-'+name,value)
    for name,value in [('overlong',b'\xc0\x80'),('truncated',b'\xe2\x82'),('continuation',b'\x80'),('surrogate',b'\xed\xa0\x80'),('out-of-range',b'\xf4\x90\x80\x80'),('five-byte',b'\xf8\x88\x80\x80\x80')]:add('utf8-'+name,raw.encode().replace(b'"group":"',b'"group":"'+value))
    for name,value in [('high','\\uD800'),('low','\\uDC00'),('bad-pair','\\uD800\\u0041'),('truncated','\\u00'),('badhex','\\u00XX'),('bad-escape','\\x41'),('raw-control','\n'),('valid-pair-wrong-uuid','\\uD83D\\uDE00')]:add('unicode-'+name,raw.replace('"group":"','"group":"'+value))
    (directory/'manifest.txt').write_text(''.join(kind+' '+file+'\n' for kind,file in cases))
    return {'accepted':sum(k!='reject' for k,_ in cases),'rejected':sum(k=='reject' for k,_ in cases),'total':len(cases)}

def server_compare(source,directory,evidence):
    # Load exact public validation functions using AST, never execute imports,
    # server startup, database code, production config or any real environment.
    import struct,uuid
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
    from cryptography.exceptions import InvalidSignature
    names={'RelayError','reject','strict_json','encoded','shape','identifier','number','b64','integer_bytes','verify_signature','membership_canonical','membership_bytes'}
    tree=ast.parse(source.read_text());selected=[n for n in tree.body if isinstance(n,(ast.ClassDef,ast.FunctionDef)) and n.name in names]
    assert {n.name for n in selected}==names
    space=dict(base64=base64,hashlib=hashlib,json=json,struct=struct,uuid=uuid,Ed25519PublicKey=Ed25519PublicKey,InvalidSignature=InvalidSignature)
    exec(compile(ast.Module(body=selected,type_ignores=[]),str(source),'exec'),space)
    tested=[]
    for name in ['cpp-swift-v1','cpp-swift-paired','cpp-swift-v2']:
        data=(directory/(name+'.json')).read_bytes();value=space['strict_json'](data);_,_,digest=space['membership_bytes'](value)
        (directory/('server-'+name+'.json')).write_bytes(space['encoded'](value));tested.append({'fixture':name,'sha256Canonical':digest.hex()})
    null=space['strict_json']((directory/'case-all-optionals-null.json').read_bytes())
    try:space['membership_bytes'](null)
    except space['RelayError']:pass
    else:raise AssertionError('Server unexpectedly accepts extra v1 null fields')
    template=space['strict_json']((directory/'case-unsigned-template.json').read_bytes());space['membership_bytes'](template,require_signature=False)
    try:space['membership_bytes'](template)
    except space['RelayError']:pass
    else:raise AssertionError('Server trusted unsigned template')
    result={'exactServerPublicFunctions':sorted(names),'signedOutputsVerified':tested,'optionalNullDifferenceConfirmed':True,'unsignedChallengeOnlyConfirmed':True,'serverStarted':False,'network':False,'database':False}
    (evidence/'server-reference-results.json').write_text(json.dumps(result,indent=2)+'\n')

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--reference-membership',type=Path);p.add_argument('--reference-server',type=Path);p.add_argument('--toolchain',type=Path);a=p.parse_args()
    evidence=ROOT/'evidence/windows-membership-wire-20261018';out=ROOT/'build/membership-wire-tests';fixtures=ROOT/'windows/tests/fixtures/public-membership-wire';temp=ROOT/'build/tmp'
    for d in (evidence,out,fixtures,temp):d.mkdir(parents=True,exist_ok=True)
    env=os.environ.copy();env['TMPDIR']=str(temp);env['CLANG_MODULE_CACHE_PATH']=str(temp/'wire-module-cache');env['SWIFT_MODULECACHE_PATH']=str(temp/'wire-module-cache')
    def run(cmd,name):
        with (evidence/(name+'.log')).open('w') as log:subprocess.run(list(map(str,cmd)),cwd=ROOT,env=env,stdout=log,stderr=subprocess.STDOUT,check=True)
    package=ROOT/'artifacts/LingheInput-Windows11-x64-0.2.2-preview.zip';package_hash=hashlib.sha256(package.read_bytes()).hexdigest()
    guard=subprocess.run(['python3','tools/guard_master.py'],cwd=ROOT,capture_output=True,text=True);before=json.loads(guard.stdout);(evidence/'guard-before.json').write_text(guard.stdout)
    reference=out/'reference';reference.mkdir(exist_ok=True)
    if a.reference_membership:
        source=a.reference_membership.read_bytes();(reference/'Membership.swift').write_bytes(source);shutil.copy2(ROOT/'windows/tests/fixtures/membership-wire-main.swift',reference/'main.swift')
        (evidence/'swift-source.json').write_text(json.dumps({'path':str(a.reference_membership.resolve()),'sha256':hashlib.sha256(source).hexdigest(),'readOnly':True},indent=2)+'\n')
        run(['swiftc','-module-cache-path',temp/'wire-module-cache',ROOT/'windows/tests/fixtures/membership-reference-stubs.swift',reference/'Membership.swift',reference/'main.swift','-o',reference/'membership-wire-reference'],'swift-build')
        run([reference/'membership-wire-reference','generate',fixtures,ROOT/'windows/tests/fixtures/public-membership-v1.json'],'swift-generate')
    counts=corpus(fixtures)
    def build(compiler,arch,suffix,flags):
        prefix=ROOT/'build/sodium-membership'/arch;exe=out/('membership_wire'+suffix)
        run([compiler,'-std=c++17','-Wall','-Wextra','-Werror','-DSODIUM_STATIC','-I'+str(prefix/'include'),'windows/sync/Membership.cpp','windows/sync/MembershipWire.cpp','windows/tests/membership_wire.cpp',prefix/'lib/libsodium.a',*flags,'-o',exe],'wire-'+arch+'-build');return exe
    exe=build('clang++','native','',[]);run([exe,fixtures],'wire-native-results')
    # Sanitizers exercise identical bounded parsing and output on the host.
    sanitizer=build('clang++','native','-asan',['-fsanitize=address,undefined','-fno-omit-frame-pointer']);run([sanitizer,fixtures],'wire-native-sanitizers')
    if a.reference_membership:
        run([reference/'membership-wire-reference','verify',fixtures],'swift-verify-cpp-output')
        # The same native reader must accept and verify Swift's reencoded output.
        for name in ['v1','paired','v2']:shutil.copy2(fixtures/('swift-roundtrip-swift-'+name+'.json'),fixtures/('case-swift-roundtrip-'+name+'.json'))
        with (fixtures/'manifest.txt').open('a') as f:
            for name in ['v1','paired','v2']:f.write('verify case-swift-roundtrip-'+name+'.json\n')
    if a.reference_server:
        source=a.reference_server.read_bytes();(reference/'private_input_relay.py').write_bytes(source)
        (evidence/'server-source.json').write_text(json.dumps({'path':str(a.reference_server.resolve()),'sha256':hashlib.sha256(source).hexdigest(),'readOnly':True},indent=2)+'\n')
        server_compare(reference/'private_input_relay.py',fixtures,evidence)
        with (fixtures/'manifest.txt').open('a') as f:
            for name in ['v1','paired','v2']:f.write('verify server-cpp-swift-'+name+'.json\n')
    run([exe,fixtures],'wire-native-final');run([sanitizer,fixtures],'wire-native-sanitizers-final')
    prefix=ROOT/'build/sodium-membership/native';mutation=out/'membership_wire-mutations'
    run(['clang++','-std=c++17','-Wall','-Wextra','-Werror','-DSODIUM_STATIC','-I'+str(prefix/'include'),'-fsanitize=address,undefined','-fno-omit-frame-pointer','windows/sync/Membership.cpp','windows/sync/MembershipWire.cpp','windows/tests/membership_wire_fuzz.cpp',prefix/'lib/libsodium.a','-o',mutation],'wire-mutation-build')
    run([mutation,fixtures],'wire-mutation-results')
    result={'module':'strict bounded Membership wire v1/v2 only','corpus':counts,'nativePassed':True,'ASanUBSanPassed':True,'deterministicMutationASanUBSanPassed':True,'swiftBidirectionalWireAndVerifier':bool(a.reference_membership),'serverExactFunctionVerification':bool(a.reference_server),'windowsExecuted':False,'windowsCrossBuilt':False,'newDependencyDownloaded':False,'networkUIKeyStoreIntegration':False,'productionSigningAPI':False,'packageSHA256Before':package_hash,'packageSHA256After':hashlib.sha256(package.read_bytes()).hexdigest()}
    if a.toolchain:
        cross=build(a.toolchain/'bin/x86_64-w64-mingw32-clang++','x64','-x64.exe',['-static','-lbcrypt','-ladvapi32']);result.update(windowsCrossBuilt=True,windowsArtifact=str(cross.relative_to(ROOT)),windowsArtifactSHA256=hashlib.sha256(cross.read_bytes()).hexdigest())
    guard=subprocess.run(['python3','tools/guard_master.py'],cwd=ROOT,capture_output=True,text=True);after=json.loads(guard.stdout);(evidence/'guard-after.json').write_text(guard.stdout)
    assert before['changedPaths']==after['changedPaths'];assert result['packageSHA256Before']==result['packageSHA256After'];result['guardChangedPathCount']=len(after['changedPaths']);result['guardPathSetUnchanged']=True
    (evidence/'results.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
if __name__=='__main__':main()
