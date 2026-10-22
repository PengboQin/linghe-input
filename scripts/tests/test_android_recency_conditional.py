#!/usr/bin/env python3
"""Pure JVM cadence/slot tests + all product Java SDK compile. No network/APK/device."""
from pathlib import Path
import hashlib,json,os,subprocess
ROOT=Path(__file__).resolve().parents[2]
SDK=ROOT/'.tools/android';BUILD=ROOT/'build/android-recency-conditional';EVIDENCE=ROOT/'evidence/android-recency-conditional-20261021'

def main():
    BUILD.mkdir(exist_ok=True);EVIDENCE.mkdir(exist_ok=True)
    product=ROOT/'android/app/src/main/java/live/linghe/privateinput'
    sources=sorted((ROOT/'android/app/src/main/java').rglob('*.java'))
    tracked=[product/(name+'.java') for name in ['RecentLearningSync','RecentLearningSlot','RecentLearningExchangeState','RecentCompatibilityCadence','AutomaticSyncCadence','SyncClient','AutoClipboardBridge']]
    before={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in tracked}
    rows=[]
    def run(name,command):
        result=subprocess.run(list(map(str,command)),cwd=ROOT,text=True,capture_output=True,timeout=120)
        (EVIDENCE/(name+'.log')).write_text(result.stdout+result.stderr)
        rows.append({'name':name,'exitCode':result.returncode})
        if result.returncode:raise RuntimeError(name+' failed: '+(result.stdout+result.stderr)[-2500:])
        if result.stdout:print(result.stdout.strip())
    classes=BUILD/'classes';classes.mkdir(exist_ok=True)
    pure=['RecentLearning','RecentLearningWire','RecentLearningSlot','RecentLearningExchangeState','RecentCompatibilityCadence','AutomaticSyncCadence','ClipboardRefreshPolicy','ClipboardCandidateState','ActivityArchiveRules']
    cases=['android/tests/host/RecentLearningSlotTest.java','android/tests/host/RecentLearningExchangeTest.java','android/tests/host/RecentCompatibilityCadenceTest.java','scripts/tests/java/live/linghe/privateinput/AutomaticClipboardLiveCheck.java']
    run('pure-compile',[SDK/'jdk/bin/javac','--release','8','-encoding','UTF-8','-d',classes,*[product/(name+'.java') for name in pure],*[ROOT/p for p in cases]])
    for name in ['RecentLearningSlotTest','RecentLearningExchangeTest','RecentCompatibilityCadenceTest','AutomaticClipboardLiveCheck']:
        run(name,[SDK/'jdk/bin/java','-cp',classes,'live.linghe.privateinput.'+name])
    generated=BUILD/'generated/live/linghe/privateinput';generated.mkdir(parents=True,exist_ok=True)
    (generated/'SyncBuildConfig.java').write_text('package live.linghe.privateinput; final class SyncBuildConfig {static final String DEFAULT_ENDPOINT="";}\n')
    (generated/'R.java').write_text('package live.linghe.privateinput; public final class R {public static final class drawable {public static final int app_icon=0;}}\n')
    target=BUILD/'sdk-classes';target.mkdir(exist_ok=True)
    cp=os.pathsep.join(map(str,[SDK/'platforms/android-36/android.jar',ROOT/'vendor/bouncycastle/bcprov-android.jar',ROOT/'vendor/zxing/core-3.5.3.jar']))
    run('all-sdk-java-compile',[SDK/'jdk/bin/javac','--release','8','-encoding','UTF-8','-classpath',cp,'-d',target,*sources,*sorted(generated.glob('*.java'))])
    stable=all(hashlib.sha256((ROOT/name).read_bytes()).hexdigest()==digest for name,digest in before.items())
    result={'passed':stable,'commands':rows,'productJavaCount':len(sources),'sourceStable':stable,'sourceSHA256':before,'realNetwork':False,'apkBuilt':False,'installed':False,'windowsChanged':False}
    (EVIDENCE/'result.json').write_text(json.dumps(result,indent=2)+'\n')
    if not stable:raise RuntimeError('Source changed during validation')
    print('PASS SDK Java compilation; no real RPC, device, APK or installation')

if __name__=='__main__':main()
