#!/usr/bin/env python3
"""Fetch hash-pinned public weights; convert with the tested isolated environment.
Use --verify for a read-only audit of the currently bundled resources.
No model-provided Python or installer is executed.
"""
import argparse,pathlib,json,hashlib,urllib.request,subprocess,sys,tempfile,shutil,time
root=pathlib.Path(__file__).resolve().parents[1];lock=json.loads((root/'docs/stages/P2/dictionary/semantic.lock.json').read_text());out=root/'resources/semantic'
def sha(path):
 h=hashlib.sha256()
 with path.open('rb') as f:
  for block in iter(lambda:f.read(1024*1024),b''):h.update(block)
 return h.hexdigest()
def verify():
 manifest=json.loads((out/'MODEL.json').read_text())
 assert manifest['upstream']==lock['model'] and manifest['revision']==lock['revision']
 for name,digest in manifest['files'].items():assert sha(out/name)==digest,'Bundled semantic resource mismatch: '+name
 assert sha(out/'MODEL-LICENSE.txt')==lock['licenseSHA256']
 print(json.dumps({'verifiedFiles':len(manifest['files']),'revision':lock['revision']}))
parser=argparse.ArgumentParser();parser.add_argument('--verify',action='store_true');args=parser.parse_args()
if args.verify:verify();raise SystemExit(0)
if (out/'MODEL.json').exists():verify()
source=root/'vendor/semantic/electra-small';source.mkdir(parents=True,exist_ok=True)
for record in lock['files']:
 path=source/record['path']
 if not path.exists() or sha(path)!=record['sha256']:
  with urllib.request.urlopen(record['url'],timeout=120) as response:data=response.read()
  assert len(data)==record['bytes'] and hashlib.sha256(data).hexdigest()==record['sha256'],'Upstream hash mismatch'
  path.write_bytes(data)
license=urllib.request.urlopen(lock['licenseURL'],timeout=30).read();assert hashlib.sha256(license).hexdigest()==lock['licenseSHA256']
subprocess.run([sys.executable,str(root/lock['conversion']['script'])],cwd=root,check=True)
subprocess.run([sys.executable,str(root/'scripts/build_semantic_lexicon.py')],cwd=root,check=True)
subprocess.run([sys.executable,str(root/'scripts/build_continuation_lexicon.py')],cwd=root,check=True)
subprocess.run([sys.executable,str(root/'scripts/build_pinyin_syllables.py')],cwd=root,check=True)
out.mkdir(parents=True,exist_ok=True)
with tempfile.TemporaryDirectory(prefix='semantic-compile-',dir=root/'artifacts') as temp:
 subprocess.run(['xcrun','coremlcompiler','compile',str(root/'artifacts/semantic/SemanticDiscriminator-int8.mlpackage'),temp],check=True)
 candidate=pathlib.Path(temp)/'SemanticDiscriminator-int8.mlmodelc';assert candidate.is_dir()
 current=out/'SemanticDiscriminator.mlmodelc'
 if current.exists():current.rename(root/'artifacts'/('semantic-previous-'+str(time.time_ns())+'.mlmodelc'))
 shutil.copytree(candidate,current)
shutil.copy2(source/'README.md',out/'MODEL-README.md');shutil.copy2(source/'vocab.txt',out/'vocab.txt');(out/'MODEL-LICENSE.txt').write_bytes(license)
manifest={'upstream':lock['model'],'revision':lock['revision'],'license':lock['license'],'conversion':lock['conversion'],'files':{str(p.relative_to(out)):sha(p) for p in out.rglob('*') if p.is_file() and p.name!='MODEL.json'}}
(out/'MODEL.json').write_text(json.dumps(manifest,indent=2)+'\n');verify()
