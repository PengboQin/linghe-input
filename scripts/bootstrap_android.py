#!/usr/bin/env python3
"""Pinned, project-owned Android tools; no emulator, global install or device action."""
from pathlib import Path
import urllib.request,hashlib,json,xml.etree.ElementTree as ET,zipfile,tarfile,os,stat,shutil
R=Path(__file__).resolve().parents[1];T=R/'.tools/android';T.mkdir(parents=True,exist_ok=True)
E=R/'evidence/cross-platform47-mac37-20261016';E.mkdir(exist_ok=True)
def get(url):
 with urllib.request.urlopen(urllib.request.Request(url,headers={'User-Agent':'LingheInput-Build'}),timeout=90) as f:return f.read()
def download(url,target,algorithm,expected):
 h=hashlib.new(algorithm)
 with urllib.request.urlopen(urllib.request.Request(url,headers={'User-Agent':'LingheInput-Build'}),timeout=90) as f,target.open('wb') as out:
  while True:
   chunk=f.read(1024*1024)
   if not chunk:break
   h.update(chunk);out.write(chunk)
 assert h.hexdigest().lower()==expected.lower(),'Upstream checksum differs'
 return hashlib.sha256(target.read_bytes()).hexdigest()
record=[]
meta=json.loads(get('https://api.adoptium.net/v3/assets/latest/17/hotspot?architecture=aarch64&image_type=jdk&os=mac&vendor=eclipse'))[0]
p=meta['binary']['package'];archive=T/'jdk.download.tar.gz'
if not (T/'jdk').exists():
 sha=download(p['link'],archive,'sha256',p['checksum'])
 stage=T/'jdk-stage';stage.mkdir()
 with tarfile.open(archive) as tar:
  for m in tar:
   parts=Path(m.name).parts;assert not Path(m.name).is_absolute() and '..' not in parts
  tar.extractall(stage)
 home=next(stage.glob('*/Contents/Home'));shutil.move(str(home),T/'jdk');shutil.rmtree(stage);archive.unlink()
else:sha=p['checksum']
record.append({'name':'Temurin17','url':p['link'],'upstreamSHA256':sha,'version':meta['version']['semver']})
root=ET.fromstring(get('https://dl.google.com/android/repository/repository2-1.xml'))
for package,destination in [('platform-tools','platform-tools'),('platforms;android-36','platforms/android-36'),('build-tools;36.0.0','build-tools/36.0.0'),('ndk;28.2.13676358','ndk/28.2.13676358')]:
 entry=next(x for x in root.iter('remotePackage') if x.attrib['path']==package)
 archives=list(entry.find('archives'));chosen=next(x for x in archives if x.findtext('host-os') in (None,'macosx'))
 data=chosen.find('complete');url='https://dl.google.com/android/repository/'+data.findtext('url');checksum=data.findtext('checksum');algo=data.find('checksum').attrib.get('type','sha1')
 target=T/destination
 if target.exists():continue
 archive=T/'package.download.zip';sha=download(url,archive,algo,checksum);target.mkdir(parents=True)
 with zipfile.ZipFile(archive) as z:
  names=z.namelist();prefix=names[0].split('/')[0]+'/'
  for item in z.infolist():
   if not item.filename.startswith(prefix):continue
   rel=item.filename[len(prefix):]
   if not rel:continue
   assert not Path(rel).is_absolute() and '..' not in Path(rel).parts
   if package.startswith('ndk;'):
    # Keep public CMake/metadata, native host compiler and only the arm64
    # sysroot. Drop other target APIs, LLDB and unrelated host tools.
    pre='toolchains/llvm/prebuilt/darwin-x86_64/'
    wanted=not rel.startswith(('toolchains/','simpleperf/','shader-tools/'))
    if rel.startswith(pre):
     tail=rel[len(pre):]
     wanted=(tail.startswith(('lib/','lib64/','sysroot/usr/include/','share/')) or tail in ['AndroidVersion.txt','NOTICE'])
     if tail.startswith('sysroot/usr/lib/'):wanted=tail.startswith('sysroot/usr/lib/aarch64-linux-android/')
     if tail.startswith('bin/'):
      wanted=Path(tail).name in ['clang','clang++','clang-19','clang-20','clang-21','lld','ld.lld','llvm-ar','llvm-ranlib','llvm-strip','llvm-objcopy','llvm-readelf','llvm-nm','llvm-objdump','aarch64-linux-android26-clang','aarch64-linux-android26-clang++']
    if rel.startswith('toolchains/llvm/prebuilt/darwin-x86_64/lib/') and Path(rel).name in ['libclang-cpp.dylib','libclang.dylib','liblldb.dylib','libsimpleperf_readelf.a','libpython3.11.dylib','LLVMPolly.so']:wanted=False
    if any('/lib/clang/19/lib/linux/'+abi+'/' in rel for abi in ['arm','i386','x86_64','riscv64']):wanted=False
    if not wanted:continue
   path=target/rel
   if item.is_dir():path.mkdir(parents=True,exist_ok=True);continue
   path.parent.mkdir(parents=True,exist_ok=True);mode=item.external_attr>>16
   if stat.S_ISLNK(mode):
    link=z.read(item).decode();assert (path.parent/link).resolve().is_relative_to(target.resolve());path.symlink_to(link)
   else:
    with z.open(item) as src,path.open('wb') as out:shutil.copyfileobj(src,out)
    path.chmod((mode&0o777) or 0o644)
 archive.unlink();record.append({'name':package,'url':url,'upstreamChecksum':checksum,'checksumAlgorithm':algo,'downloadSHA256':sha,'thinNdkArm64Only':package.startswith('ndk;')})
 (E/'android-toolchain-downloads.json').write_text(json.dumps(record,indent=2))
 print(package,'ready',flush=True)
(E/'android-toolchain-downloads.json').write_text(json.dumps(record,indent=2))
