#!/usr/bin/env python3
"""Synthetic JVM filesystem recovery + Android SDK compile; no device/network/APK."""
from pathlib import Path
import hashlib,json,os,subprocess
ROOT=Path(__file__).resolve().parents[2]
SDK=ROOT/'.tools/android';BUILD=ROOT/'build/android-rime-installer';EVIDENCE=ROOT/'evidence/android-rime-installer-20261021'

def main():
    BUILD.mkdir(exist_ok=True);EVIDENCE.mkdir(exist_ok=True)
    product=ROOT/'android/app/src/main/java/live/linghe/privateinput'
    tracked=[product/'RimeResourceInstaller.java',product/'LingheInputService.java',ROOT/'android/tests/host/RimeResourceInstallerTest.java']
    before={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in tracked}
    commands=[]
    def run(name,args):
        result=subprocess.run(list(map(str,args)),cwd=ROOT,text=True,capture_output=True,timeout=120)
        (EVIDENCE/(name+'.log')).write_text(result.stdout+result.stderr)
        commands.append({'name':name,'exitCode':result.returncode})
        if result.returncode:raise RuntimeError(name+' failed: '+(result.stdout+result.stderr)[-2400:])
        if result.stdout:print(result.stdout.strip())
    classes=BUILD/'classes';classes.mkdir(exist_ok=True)
    run('host-compile',[SDK/'jdk/bin/javac','--release','8','-encoding','UTF-8','-d',classes,*[p for p in tracked if p.name!='LingheInputService.java']])
    run('filesystem-recovery',[SDK/'jdk/bin/java','-cp',classes,'live.linghe.privateinput.RimeResourceInstallerTest'])
    generated=BUILD/'generated/live/linghe/privateinput';generated.mkdir(parents=True,exist_ok=True)
    (generated/'SyncBuildConfig.java').write_text('package live.linghe.privateinput; final class SyncBuildConfig {static final String DEFAULT_ENDPOINT="";}\n')
    (generated/'R.java').write_text('package live.linghe.privateinput; public final class R {public static final class drawable {public static final int app_icon=0;}}\n')
    output=BUILD/'sdk-classes';output.mkdir(exist_ok=True)
    cp=os.pathsep.join(map(str,[SDK/'platforms/android-36/android.jar',ROOT/'vendor/bouncycastle/bcprov-android.jar',ROOT/'vendor/zxing/core-3.5.3.jar']))
    sources=sorted((ROOT/'android/app/src/main/java').rglob('*.java'))
    run('all-sdk-java-compile',[SDK/'jdk/bin/javac','--release','8','-encoding','UTF-8','-classpath',cp,'-d',output,*sources,*sorted(generated.glob('*.java'))])
    stable=all(hashlib.sha256((ROOT/name).read_bytes()).hexdigest()==digest for name,digest in before.items())
    result={'passed':stable,'commands':commands,'filesystemAssertions':61,'productJavaCount':len(sources),'sourceStable':stable,'sourceSHA256':before,'actualAndroidFilesystemRun':False,'realUserFilesRead':False,'realNetwork':False,'nativeSessionCreated':False,'apkBuilt':False,'installed':False,'productionChanged':False}
    (EVIDENCE/'result.json').write_text(json.dumps(result,indent=2)+'\n')
    if not stable:raise RuntimeError('Owned source changed during validation')
    print('PASS JVM filesystem recovery and SDK Java compilation; no real device/APK/data')

if __name__=='__main__':main()
