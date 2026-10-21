from pathlib import Path
import subprocess,os,zipfile,shutil
R=Path(__file__).resolve().parents[1];T=R/'.tools/android';B=R/'build/android-tests';B.mkdir(exist_ok=True);tool=T/'build-tools/36.0.0';jdk=T/'jdk';sdk=T/'platforms/android-36/android.jar';env=os.environ.copy();env['JAVA_HOME']=str(jdk);env['PATH']=str(jdk/'bin')+os.pathsep+env['PATH']
def run(args):subprocess.run(list(map(str,args)),env=env,check=True)
classes=B/'classes'
if classes.exists():shutil.rmtree(classes)
classes.mkdir()
app_java=[p for p in (R/'android/app/src/main/java').rglob('*.java') if p.name!='MainActivity.java']
run([jdk/'bin/javac','--release','8','-encoding','UTF-8','-classpath',str(sdk)+os.pathsep+os.pathsep.join(map(str,[R/'build/android-app/classes',R/'vendor/zxing/core-3.5.3.jar',R/'vendor/bouncycastle/bcprov-android.jar'])),'-d',classes,*[p for p in (R/'android/tests/java').rglob('*.java') if p.name!='DataSnapshot.java'],*app_java,R/'build/android-app/generated/live/linghe/privateinput/SyncBuildConfig.java'])
jar=B/'classes.jar'
with zipfile.ZipFile(jar,'w') as z:
 for p in classes.rglob('*.class'):z.write(p,str(p.relative_to(classes)))
dex=B/'dex';dex.mkdir(exist_ok=True);run([tool/'d8','--min-api','26','--lib',sdk,'--output',dex,jar,R/'vendor/zxing/core-3.5.3.jar',R/'vendor/bouncycastle/bcprov-android.jar'])
run([tool/'aapt2','compile','--dir',R/'android/app/src/main/res','-o',B/'test-resources.zip'])
run([tool/'aapt2','compile','--dir',R/'android/tests/res','-o',B/'test-only-resources.zip'])
extra=B/'extra-assets';extra.mkdir(exist_ok=True);shutil.copy2(R/'shared/contracts/personal-lexicon-fixture-v1.json',extra/'personal-lexicon-fixture-v1.json')
run([tool/'aapt2','link','-o',B/'unsigned.apk','-I',sdk,'--manifest',R/'android/tests/AndroidManifest.xml','-A',R/'build/android-app/assets','-A',extra,B/'test-resources.zip',B/'test-only-resources.zip'])
with zipfile.ZipFile(B/'unsigned.apk','a',compression=zipfile.ZIP_DEFLATED) as z:
 for item in dex.glob('classes*.dex'):z.write(item,item.name)
 z.write(R/'build/android-app/native/liblinghe.so','lib/arm64-v8a/liblinghe.so')
run([tool/'zipalign','-f','4',B/'unsigned.apk',B/'aligned.apk'])
run([tool/'apksigner','sign','--ks',T/'signing/linghe-dev.jks','--ks-key-alias','linghe-dev','--ks-pass','file:'+str(T/'signing/storepass'),'--out',B/'signed-tests.apk',B/'aligned.apk'])

run([tool/"apksigner","verify",B/"signed-tests.apk"])
os.replace(B/"signed-tests.apk",B/"LingheInput-tests.apk")
if (B/"signed-tests.apk.idsig").exists():os.replace(B/"signed-tests.apk.idsig",B/"LingheInput-tests.apk.idsig")
