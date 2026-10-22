#!/usr/bin/env python3
"""Small reproducible Java/JNI APK build using official SDK tools, no Gradle daemon."""
from pathlib import Path
import subprocess,os,shutil,zipfile,json,secrets,hashlib,re,xml.etree.ElementTree as ET,argparse,html
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--unsigned',action='store_true',help='Build and verify an aligned unsigned APK; never read or create signing keys')
parser.add_argument('--evidence-dir',type=Path,help='Project-local build evidence directory')
args=parser.parse_args()
R=Path(__file__).resolve().parents[1];T=R/'.tools/android';jdk=T/'jdk';sdk=T/'platforms/android-36/android.jar';tools=T/'build-tools/36.0.0';B=R/'build/android-app';B.mkdir(parents=True,exist_ok=True)
manifest=ET.parse(R/'android/app/src/main/AndroidManifest.xml').getroot();ns='{http://schemas.android.com/apk/res/android}'
VERSION=manifest.attrib[ns+'versionName'];BUILD=int(manifest.attrib[ns+'versionCode'])
assert manifest.attrib['package']=='live.linghe.privateinput' and BUILD>0 and re.fullmatch(r'[0-9A-Za-z][0-9A-Za-z.+-]{0,63}',VERSION)
E=(R/args.evidence_dir).resolve() if args.evidence_dir else R/'build/evidence'/('android-release-'+str(BUILD))
assert R in E.parents and str(E.relative_to(R)).startswith('build/'),'Evidence must stay within project build/'
E.mkdir(parents=True,exist_ok=True)
A=(E/('LingheInput-Android-arm64-'+VERSION+'-unsigned.apk')) if args.unsigned else R/'artifacts'/('LingheInput-Android-arm64-'+VERSION+'.apk')
if A.exists():raise SystemExit('Candidate APK already exists. Select a fresh version; never replace an installed artifact.')
env=os.environ.copy();env['JAVA_HOME']=str(jdk);env['PATH']=str(jdk/'bin')+os.pathsep+env.get('PATH','')
def run(args):subprocess.run(list(map(str,args)),cwd=R,env=env,check=True)
run([R/'.tools/python/bin/cmake','-S',R/'android/app/src/main/cpp','-B',B/'native',f'-DCMAKE_TOOLCHAIN_FILE={T}/ndk/28.2.13676358/build/cmake/android.toolchain.cmake','-DANDROID_ABI=arm64-v8a','-DANDROID_PLATFORM=android-26','-DANDROID_STL=c++_static','-DCMAKE_BUILD_TYPE=Release'])
run([R/'.tools/python/bin/cmake','--build',B/'native','--parallel','3'])
if (B/'assets').exists():shutil.rmtree(B/'assets')
assets=B/'assets/rime';assets.mkdir(parents=True,exist_ok=True)
for p in (R/'resources/rime').rglob('*'):
 if p.is_file():
  q=assets/p.relative_to(R/'resources/rime');q.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(p,q)
shutil.copytree(R/'docs/stages/P1/licenses',B/'assets/licenses',dirs_exist_ok=True)
shutil.copy2(R/'vendor/librime-octagram/LICENSE',B/'assets/licenses/librime-octagram-LICENSE')
# Derive public assets without mutating shared source contracts during a build.
english=(R/'shared/PrivateInputKit/Sources/PrivateInputKit/MixedEnglishLexicon.swift').read_text().split('"""')[1].split()
assert 100<=len(english)<=1000 and all(re.fullmatch('[A-Za-z]{2,32}',v) for v in english)
(B/'assets/mixed-english.txt').write_text('\n'.join(english)+'\n')
categories=[]
for m in re.finditer(r'category\("([^\"]+)",\s*"([^\"]+)",\s*"((?:\\.|[^"\\])*)"\)',(R/'apple/iOS/Keyboard/SymbolCatalog.swift').read_text()):
 categories.append({'id':m[1],'title':m[2],'symbols':list(dict.fromkeys(json.loads('"'+m[3]+'"')))})
assert len(categories)==12
(B/'assets/symbols.json').write_text(json.dumps({'version':1,'source':'apple/iOS/Keyboard/SymbolCatalog.swift','categories':categories},ensure_ascii=False,indent=2))
for name in ['pinyin-syllables.txt','nine-lexicon.bin','continuation.bin']:shutil.copy2(R/'resources/semantic'/name,B/'assets'/name)
for name in ['LEXICON.json','CONTINUATION.json','PINYIN.json']:shutil.copy2(R/'resources/semantic'/name,B/'assets/licenses'/name)
shutil.copy2(R/'android/tests/fixtures/cloud-component-v1.json',B/'assets/cloud-component-fixture-v1.json')
shutil.copy2(R/'vendor/zxing/LICENSE',B/'assets/licenses/ZXing-LICENSE')
import re,html
(B/'assets/licenses/BouncyCastle-LICENSE.txt').write_text(html.unescape(re.sub('<[^>]+>','',(R/'vendor/bouncycastle/LICENSE.html').read_text())))
compiled=B/'resources.zip';run([tools/'aapt2','compile','--dir',R/'android/app/src/main/res','-o',compiled])
classes=B/'classes'
if classes.exists():shutil.rmtree(classes)
classes.mkdir()
run([tools/'aapt2','link','-o',B/'resources.apk','-I',sdk,'--manifest',R/'android/app/src/main/AndroidManifest.xml','--java',B/'generated','-A',B/'assets',compiled])
relay=''
private_config=None # One release; endpoint is saved by the user or read from QR.
config_java=B/'generated/live/linghe/privateinput/SyncBuildConfig.java';config_java.parent.mkdir(parents=True,exist_ok=True);fingerprint=lambda rows:hashlib.sha256('\n'.join(sorted(str(p.relative_to(R))+':'+hashlib.sha256(p.read_bytes()).hexdigest() for p in rows)).encode()).hexdigest()
core_hash=fingerprint([p for p in (R/'core').rglob('*') if p.is_file() and p.suffix in ['.h','.hpp','.c','.cpp']])
resource_hash=fingerprint([p for p in (R/'resources/rime').rglob('*') if p.is_file()]+[R/('resources/semantic/'+name) for name in ['pinyin-syllables.txt','nine-lexicon.bin','continuation.bin']])
policy_hash=fingerprint([R/('android/app/src/main/java/live/linghe/privateinput/'+name+'.java') for name in ['InputQuality','PinyinMatch','PinyinCorrector','CommonExpressionOrder']])
config_java.write_text('package live.linghe.privateinput; final class SyncBuildConfig {static final String DEFAULT_ENDPOINT='+json.dumps(relay)+';static final String CORE_HASH='+json.dumps(core_hash)+';static final String RESOURCE_HASH='+json.dumps(resource_hash)+';static final String POLICY_HASH='+json.dumps(policy_hash)+';}')
qr=R/'vendor/zxing/core-3.5.3.jar';bc=R/'vendor/bouncycastle/bcprov-android.jar'
java=list((R/'android/app/src/main/java').rglob('*.java'))+list((B/'generated').rglob('*.java'))
run([jdk/'bin/javac','-encoding','UTF-8','--release','8','-classpath',str(sdk)+os.pathsep+str(qr)+os.pathsep+str(bc),'-d',classes,*java])
jar=B/'classes.jar'
with zipfile.ZipFile(jar,'w') as z:
 for p in classes.rglob('*.class'):z.write(p,str(p.relative_to(classes)))
dex=B/'dex';dex.mkdir(exist_ok=True)
for stale in dex.glob('classes*.dex'):stale.unlink()
run([tools/'d8','--min-api','26','--lib',sdk,'--output',dex,jar,qr,bc])
shutil.copy2(B/'resources.apk',B/'unsigned.apk')
lib=B/'native/liblinghe.so';run([T/'ndk/28.2.13676358/toolchains/llvm/prebuilt/darwin-x86_64/bin/llvm-strip','--strip-unneeded',lib])
with zipfile.ZipFile(B/'unsigned.apk','a',compression=zipfile.ZIP_DEFLATED) as z:
 for item in dex.glob('classes*.dex'):z.write(item,item.name)
 z.write(lib,'lib/arm64-v8a/liblinghe.so')
run([tools/'zipalign','-f','-P','16','4',B/'unsigned.apk',B/'aligned.apk'])
run([tools/'zipalign','-c','-P','16','4',B/'aligned.apk'])
if args.unsigned:
 os.replace(B/'aligned.apk',A)
else:
 keys=T/'signing';keys.mkdir(mode=0o700,exist_ok=True);secret=keys/'storepass';store=keys/'linghe-dev.jks'
 if not secret.exists():secret.write_text(secrets.token_urlsafe(32));secret.chmod(0o600)
 env['LINGHE_ANDROID_KEYSTORE_PASSWORD']=secret.read_text()
 if not store.exists():
  run([jdk/'bin/keytool','-genkeypair','-noprompt','-keystore',store,'-storepass:env','LINGHE_ANDROID_KEYSTORE_PASSWORD','-keypass:env','LINGHE_ANDROID_KEYSTORE_PASSWORD','-alias','linghe-dev','-keyalg','RSA','-keysize','3072','-validity','3650','-dname','CN=Linghe Input Development']);store.chmod(0o600)
 run([tools/'apksigner','sign','--ks',store,'--ks-key-alias','linghe-dev','--ks-pass','file:'+str(secret),'--out',B/'signed.apk',B/'aligned.apk'])
 run([tools/'apksigner','verify','--verbose',B/'signed.apk'])
 os.replace(B/'signed.apk',A)
 if (B/'signed.apk.idsig').exists():os.replace(B/'signed.apk.idsig',Path(str(A)+'.idsig'))
files={str(p.relative_to(R/'resources/rime')):hashlib.sha256(p.read_bytes()).hexdigest() for p in (R/'resources/rime').rglob('*') if p.is_file()}
(E/'android-candidate-audit.json').write_text(json.dumps({'applicationId':'live.linghe.privateinput','version':VERSION,'build':BUILD,'abi':'arm64-v8a','minApi':26,'targetApi':36,'apkSHA256':hashlib.sha256(A.read_bytes()).hexdigest(),'rimeResources':files,'publicLanguageAssets':{name:hashlib.sha256((R/'resources/semantic'/name).read_bytes()).hexdigest() for name in ['pinyin-syllables.txt','nine-lexicon.bin','continuation.bin']},'model':'same public compact n-gram as Apple, local frequency and continuations; no neural model','networkPermission':True,'cameraOnlyOnExplicitScan':True,'relayPrivateConfiguration':bool(private_config),'signing':'UNSIGNED; signing keys never opened' if args.unsigned else 'stable local development key; private keystore excluded'},indent=2))
print('Android APK verified:',A.name)
