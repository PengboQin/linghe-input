"""Bounded package refresh using one verified public-resource base; no device I/O."""
from pathlib import Path
import argparse,xml.etree.ElementTree as ET
import subprocess,zipfile,shutil,os,json,hashlib
r=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--base-apk',type=Path,required=True,help='Existing reviewed APK providing unchanged public resources')
parser.add_argument('--output',type=Path,required=True)
parser.add_argument('--source-release-url',default='https://github.com/PengboQin/linghe-input')
parser.add_argument('--unsigned',action='store_true')
parser.add_argument('--expected-signer-sha256')
parser.add_argument('--reuse-native-from-base',action='store_true',help='Reuse the reviewed base JNI without invoking native build tools')
parser.add_argument('--expected-base-sha256',help='Required immutable APK identity when reusing its native binary')
args=parser.parse_args()
manifest=ET.parse(r/'android/app/src/main/AndroidManifest.xml').getroot();ns='{http://schemas.android.com/apk/res/android}'
version=manifest.attrib[ns+'versionName'];build=int(manifest.attrib[ns+'versionCode'])
b=r/'build/android-app/package-refresh';e=r/'build/evidence/android-incremental';b.mkdir(parents=True,exist_ok=True);e.mkdir(parents=True,exist_ok=True)
t=r/'.tools/android';tools=t/'build-tools/36.0.0';base=args.base_apk.resolve();out=args.output.resolve();assert not out.exists()
assert out.parent in [r/'artifacts',r/'build'], 'Write a new project-owned candidate only'
assert args.source_release_url.startswith('https://') and '\n' not in args.source_release_url
baseDigest=hashlib.sha256(base.read_bytes()).hexdigest()
if args.reuse_native_from_base:assert args.expected_base_sha256 and baseDigest==args.expected_base_sha256,'Reviewed native base identity changed'
sourcePaths=sorted((r/'android/app/src/main/java').rglob('*.java'))+sorted((r/'android/app/src/main/res').rglob('*'))+[r/'android/app/src/main/AndroidManifest.xml']
sourceFreeze={str(p.relative_to(r)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sourcePaths if p.is_file()}

env=os.environ.copy();env["JAVA_HOME"]=str(t/"jdk");env["PATH"]=str(t/"jdk/bin")+os.pathsep+env.get("PATH","")
def run(cmd,name):
 with (e/(name+'.log')).open('w') as log:subprocess.run(list(map(str,cmd)),cwd=r,env=env,stdout=log,stderr=subprocess.STDOUT,check=True)
# No data/model duplication. Every original Rime resource must still match.
with zipfile.ZipFile(base) as z:
 for f in (r/'resources/rime').rglob('*'):
  if f.is_file():assert hashlib.sha256(z.read('assets/rime/'+f.relative_to(r/'resources/rime').as_posix())).digest()==hashlib.sha256(f.read_bytes()).digest()
lib=b/'liblinghe.so'
if args.reuse_native_from_base:
 with zipfile.ZipFile(base) as z:lib.write_bytes(z.read('lib/arm64-v8a/liblinghe.so'))
else:
 cmake=r/'.tools/python/lib/python3.9/site-packages/cmake/data/bin/cmake';native=r/'build/android-app/native'
 if not (native/'CMakeCache.txt').exists():
  run([cmake,'-S',r/'android/app/src/main/cpp','-B',native,'-DCMAKE_TOOLCHAIN_FILE='+str(t/'ndk/28.2.13676358/build/cmake/android.toolchain.cmake'),'-DANDROID_ABI=arm64-v8a','-DANDROID_PLATFORM=android-26','-DANDROID_STL=c++_static','-DCMAKE_BUILD_TYPE=Release'],'native-configure')
 run([cmake,'--build',native,'--parallel','2'],'native')
 shutil.copyfile(native/'liblinghe.so',lib);run([t/'ndk/28.2.13676358/toolchains/llvm/prebuilt/darwin-x86_64/bin/llvm-strip','--strip-unneeded',lib],'strip')
run([tools/'aapt2','compile','--dir',r/'android/app/src/main/res','-o',b/'res.zip'],'android37-res-compile')
generated=b/'generated'
if generated.exists():shutil.rmtree(generated)
generated.mkdir()
run([tools/'aapt2','link','-o',b/'resources.apk','-I',t/'platforms/android-36/android.jar','--manifest',r/'android/app/src/main/AndroidManifest.xml','--java',generated,b/'res.zip'],'android37-res-link')
config=generated/'live/linghe/privateinput/SyncBuildConfig.java';config.parent.mkdir(exist_ok=True,parents=True);config.write_text('package live.linghe.privateinput; final class SyncBuildConfig { static final String DEFAULT_ENDPOINT=""; }\n')
classes=b/'classes'
if classes.exists():shutil.rmtree(classes)
classes.mkdir();jars=[r/'vendor/zxing/core-3.5.3.jar',r/'vendor/bouncycastle/bcprov-android.jar'];sources=list((r/'android/app/src/main/java').rglob('*.java'))+list(generated.rglob('*.java'))
run([t/'jdk/bin/javac','-encoding','UTF-8','--release','8','-classpath',os.pathsep.join(map(str,[t/'platforms/android-36/android.jar',*jars])),'-d',classes,*sources],'android37-javac')
jar=b/'classes.jar'
with zipfile.ZipFile(jar,'w',zipfile.ZIP_DEFLATED) as z:
 for f in classes.rglob('*.class'):z.write(f,f.relative_to(classes).as_posix())
dex=b/'dex'
if dex.exists():shutil.rmtree(dex)
dex.mkdir();run([tools/'d8','--min-api','26','--lib',t/'platforms/android-36/android.jar','--output',dex,jar,*jars],'android37-d8')
unsigned=b/'unsigned.apk';aligned=b/'aligned.apk'
with zipfile.ZipFile(base) as old,zipfile.ZipFile(b/'resources.apk') as resources,zipfile.ZipFile(unsigned,'x',zipfile.ZIP_DEFLATED,compresslevel=6) as new:
 # Keep aapt2's compression flags. Android R+ rejects compressed resources.arsc
 # even when apksigner and aapt2 dump otherwise accept the archive.
 for item in resources.infolist():new.writestr(item,resources.read(item.filename))
 for item in old.infolist():
  if item.filename.startswith('assets/') and item.filename not in ['assets/licenses/LingheInput-GPL-3.0.txt','assets/licenses/SOURCE-REFERENCE.txt']:new.writestr(item,old.read(item.filename))
 for f in dex.glob('classes*.dex'):new.write(f,f.name)
 new.write(lib,'lib/arm64-v8a/liblinghe.so');new.write(r/'LICENSE','assets/licenses/LingheInput-GPL-3.0.txt');new.writestr('assets/licenses/SOURCE-REFERENCE.txt','Corresponding source: GPL-3.0-only.\n'+args.source_release_url+'\nUse the complete product source ZIP and pinned dependency source attachments.\n')
run([tools/'zipalign','-f','-P','16','4',unsigned,aligned],'android37-align');unsigned.unlink()
if args.unsigned:
 aligned.replace(out);signerMatched=None
else:
 run([tools/'apksigner','sign','--ks',t/'signing/linghe-dev.jks','--ks-key-alias','linghe-dev','--ks-pass','file:'+str(t/'signing/storepass'),'--out',out,aligned],'sign');aligned.unlink()
 run([tools/'apksigner','verify','--verbose','--print-certs',out],'verify')
 cert=(e/'verify.log').read_text();signerMatched=args.expected_signer_sha256 in cert if args.expected_signer_sha256 else None
 if args.expected_signer_sha256:assert signerMatched
run([tools/'zipalign','-c','-P','16','4',out],'align-check')
with zipfile.ZipFile(out) as z,zipfile.ZipFile(base) as old:
 assert z.testzip() is None;assert all(not any(s in name.lower() for s in ['.sqlite','keystore','storepass','group-key','profile.json']) for name in z.namelist())
 assert z.getinfo('resources.arsc').compress_type==zipfile.ZIP_STORED,'Android R+ requires a stored resource table'
 stable={n:hashlib.sha256(old.read(n)).hexdigest() for n in old.namelist() if n.startswith('assets/') and n not in ['assets/licenses/LingheInput-GPL-3.0.txt','assets/licenses/SOURCE-REFERENCE.txt']}
 if args.reuse_native_from_base:stable['lib/arm64-v8a/liblinghe.so']=hashlib.sha256(old.read('lib/arm64-v8a/liblinghe.so')).hexdigest()
 assert all(hashlib.sha256(z.read(n)).hexdigest()==d for n,d in stable.items())
assert all(hashlib.sha256((r/n).read_bytes()).hexdigest()==d for n,d in sourceFreeze.items()),'Product source changed during packaging'
run([tools/'aapt2','dump','badging',out],'android37-badging');badging=(e/'android37-badging.log').read_text();assert ("versionCode='"+str(build)+"'") in badging and ("versionName='"+version+"'") in badging
result={'package':out.name,'bytes':out.stat().st_size,'sha256':hashlib.sha256(out.read_bytes()).hexdigest(),'build':build,'version':version,'originalCertificateMatched':signerMatched,'sourceFiles':len(sources),'nativeRebuiltFromUnifiedCore':not args.reuse_native_from_base,'nativeReusedFromReviewedBase':args.reuse_native_from_base,'baseSha256':baseDigest,'unchangedEntrySha256':stable,'sourceSha256':sourceFreeze,'privateDefaultEndpointEmbedded':False,'installed':False,'physicalKeyboardTested':False}
(e/('android'+str(build)+'-package.json')).write_text(json.dumps(result,indent=2)+'\n');print(json.dumps({k:v for k,v in result.items() if k not in ['sourceSha256','unchangedEntrySha256']}))
