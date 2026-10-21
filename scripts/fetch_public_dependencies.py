#!/usr/bin/env python3
"""Explicit pinned public downloads only; no device, signing, server or user data access."""
import argparse, hashlib, json, pathlib, urllib.parse, urllib.request, zipfile
ROOT=pathlib.Path(__file__).resolve().parents[1]
def digest(p):
 h=hashlib.sha256()
 with p.open('rb') as f:
  for b in iter(lambda:f.read(1024*1024),b''):h.update(b)
 return h.hexdigest()
def fetch(url,sha256,target):
 if target.exists():
  if digest(target)!=sha256:raise ValueError('Existing public dependency differs; preserved: '+target.name)
  return
 if urllib.parse.urlsplit(url).scheme!='https':raise ValueError('HTTPS public source required')
 target.parent.mkdir(parents=True,exist_ok=True);tmp=target.with_name(target.name+'.download')
 if tmp.exists():raise ValueError('Existing partial download preserved: '+tmp.name)
 try:
  h=hashlib.sha256()
  with urllib.request.urlopen(url,timeout=90) as src,tmp.open('xb') as out:
   for b in iter(lambda:src.read(1024*1024),b''):h.update(b);out.write(b)
  if h.hexdigest()!=sha256:raise ValueError('Pinned public checksum mismatch: '+target.name)
  tmp.rename(target)
 except BaseException:
  if tmp.exists():tmp.unlink()
  raise

def android_jars():
 for label,name in [('zxing','core-3.5.3.jar'),('bouncycastle','bcprov-jdk18on-1.81.jar')]:
  folder=ROOT/'vendor'/label;m=json.loads((folder/'SOURCE.json').read_text());fetch(m['url'],m['sha256'],folder/name)
 target=ROOT/'vendor/bouncycastle/bcprov-android.jar'
 if target.exists():raise ValueError('Existing Android derivative is preserved; verify it before replacing')
 source=target.parent/'bcprov-jdk18on-1.81.jar'
 with zipfile.ZipFile(source) as inp,zipfile.ZipFile(target,'x',compression=zipfile.ZIP_DEFLATED) as out:
  for item in inp.infolist():
   upper=item.filename.upper()
   if upper.startswith('META-INF/VERSIONS/') or item.filename.endswith('module-info.class'):continue
   if upper.startswith('META-INF/') and upper.endswith(('.SF','.RSA','.DSA','.EC')):continue
   if item.is_dir():continue
   out.writestr(item.filename,inp.read(item))
 print(json.dumps({'android_derivative_sha256':digest(target),'note':'Derived base classes with multi-release entries and invalidated JAR signatures omitted; not a claim of byte-identical historical JAR.'}))

def models():
 for lock,folder in [('semantic.lock.json','electra-small'),('macbert.lock.json','macbert4csc')]:
  m=json.loads((ROOT/'docs/stages/P2/dictionary'/lock).read_text());base='https://huggingface.co/'+m['model']+'/resolve/'+m['revision']+'/'
  for f in m['files']:
   name=f.get('path',f.get('file'))
   if not name or pathlib.PurePosixPath(name).name!=name:raise ValueError('Invalid locked filename')
   fetch(f.get('url',base+urllib.parse.quote(name)),f['sha256'],ROOT/'vendor/semantic'/folder/name)
 print('Pinned public model files fetched; conversion and installation were not performed.')

def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--android-jars',action='store_true');p.add_argument('--models',action='store_true');a=p.parse_args()
 if not a.android_jars and not a.models:p.error('Choose an explicit public dependency download')
 if a.android_jars:android_jars()
 if a.models:models()
if __name__=='__main__':main()
