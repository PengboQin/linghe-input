#!/usr/bin/env python3
"""Pure delta tests + SDK compile; optional registered vivo tmp/Keystore CLI only."""
from pathlib import Path
import hashlib,json,os,re,secrets,subprocess,zipfile
ROOT=Path(__file__).resolve().parents[2];SDK=ROOT/'.tools/android';BUILD=ROOT/'build/android-learning-delta';EVIDENCE=ROOT/'evidence/android-learning-delta-20261021'
SERIAL='10AG2230Q7003KZ'

def main():
 import argparse
 parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--vivo-cli',action='store_true');args=parser.parse_args()
 BUILD.mkdir(exist_ok=True);EVIDENCE.mkdir(exist_ok=True);commands=[]
 env=os.environ.copy();env['JAVA_HOME']=str(SDK/'jdk');env['PATH']=str(SDK/'jdk/bin')+os.pathsep+env.get('PATH','')
 def run(name,command,timeout=90):
  result=subprocess.run(list(map(str,command)),cwd=ROOT,env=env,text=True,capture_output=True,timeout=timeout)
  (EVIDENCE/(name+'.log')).write_text(result.stdout+result.stderr);commands.append({'name':name,'exitCode':result.returncode})
  if result.returncode:raise RuntimeError(name+' failed: '+(result.stdout+result.stderr)[-2000:])
  return result.stdout
 sources=sorted((ROOT/'android/app/src/main/java').rglob('*.java'));tracked=sources+[ROOT/'android/tests/cli/CliLearningDeltaPublicationCheck.java',ROOT/'android/tests/host/LearningDeltaIndexTest.java'];before={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in tracked}
 classes=BUILD/'host';classes.mkdir(exist_ok=True)
 run('host-compile',[SDK/'jdk/bin/javac','--release','8','-encoding','UTF-8','-d',classes,ROOT/'android/app/src/main/java/live/linghe/privateinput/LearningDeltaIndex.java',ROOT/'android/tests/host/LearningDeltaIndexTest.java'])
 print(run('pure-delta-index',[SDK/'jdk/bin/java','-cp',classes,'live.linghe.privateinput.LearningDeltaIndexTest']).strip(),flush=True)
 generated=BUILD/'generated/live/linghe/privateinput';generated.mkdir(parents=True,exist_ok=True)
 (generated/'SyncBuildConfig.java').write_text('package live.linghe.privateinput; final class SyncBuildConfig {static final String DEFAULT_ENDPOINT="";}\n')
 (generated/'R.java').write_text('package live.linghe.privateinput; public final class R {public static final class drawable {public static final int app_icon=0;}}\n')
 product=BUILD/'product';product.mkdir(exist_ok=True);cp=os.pathsep.join(map(str,[SDK/'platforms/android-36/android.jar',ROOT/'vendor/bouncycastle/bcprov-android.jar',ROOT/'vendor/zxing/core-3.5.3.jar']))
 run('sdk-java-compile',[SDK/'jdk/bin/javac','--release','8','-encoding','UTF-8','-classpath',cp,'-d',product,*sources,*sorted(generated.glob('*.java')),ROOT/'android/tests/cli/CliLearningDeltaPublicationCheck.java'])
 evidence={'pureIndex':True,'sdkJavaCount':len(sources),'actualStore':False,'network':False,'apkBuilt':False,'installed':False,'existingAppDataRead':False,'uiTouched':False}
 if args.vivo_cli:
  adb=[SDK/'platform-tools/adb','-s',SERIAL]
  inventory=run('adb-inventory',[SDK/'platform-tools/adb','devices','-l'],timeout=8)
  if not re.search('^'+re.escape(SERIAL)+r'\s+device\s+.*model:V2527A\b',inventory,re.M):evidence['deviceBlocked']='registered vivo absent'
  else:
   model=run('vivo-model',adb+['shell','getprop','ro.product.model'],timeout=8).strip();brand=run('vivo-brand',adb+['shell','getprop','ro.product.manufacturer'],timeout=8).strip()
   policy=subprocess.run(list(map(str,adb+['shell','dumpsys','window','policy'])),text=True,capture_output=True,timeout=8);unlocked=policy.returncode==0 and re.search(r'\bshowing=false\b',policy.stdout)
   evidence['vivoModel']=model;evidence['unlocked']=bool(unlocked)
   if model!='V2527A' or brand.lower()!='vivo' or not unlocked:evidence['deviceBlocked']='model or unlock not verified'
   else:
    jar=BUILD/'runner-classes.jar'
    with zipfile.ZipFile(jar,'w') as archive:
     for p in sorted(product.rglob('*.class')):archive.write(p,p.relative_to(product).as_posix())
    dex=BUILD/'dex';dex.mkdir(exist_ok=True)
    run('d8-cli',[SDK/'build-tools/36.0.0/d8','--min-api','26','--lib',SDK/'platforms/android-36/android.jar','--classpath',ROOT/'vendor/bouncycastle/bcprov-android.jar','--classpath',ROOT/'vendor/zxing/core-3.5.3.jar','--output',dex,jar])
    runner=BUILD/'runner.jar'
    with zipfile.ZipFile(runner,'w') as archive:
     for p in sorted(dex.glob('classes*.dex')):archive.write(p,p.name)
    token=secrets.token_hex(8);remote='/data/local/tmp/linghe-delta-'+token;alias='live.linghe.fixture.delta.'+token
    (EVIDENCE/'active-fixture.json').write_text(json.dumps({'remoteTmp':remote,'alias':alias,'scope':'new synthetic test only'},indent=2)+'\n')
    run('tmp-create',adb+['shell','mkdir','-m','700',remote],timeout=8)
    try:
     run('tmp-push',adb+['push',runner,remote+'/runner.jar'],timeout=15)
     output=run('actual-syncstore',adb+['shell','env','CLASSPATH='+remote+'/runner.jar','app_process','/system/bin','live.linghe.privateinput.CliLearningDeltaPublicationCheck',remote+'/data',alias],timeout=45)
     evidence['actualStore']='actual Android SyncStore/Keystore/AtomicFile delta checks' in output and 'CLEANUP aliasRemoved=true fixtureDataRemoved=true' in output
     print(output.strip(),flush=True)
    except Exception as blocked:
     evidence['deviceBlocked']='isolated app_process/Keystore unavailable; stopped after one attempt'
     evidence['actualStoreFailure']=str(blocked)[-1000:]
     evidence['dedicatedAliasCleanupVerified']=False
    finally:
     cleanup=subprocess.run(list(map(str,adb+['shell','rm','-rf',remote])),text=True,capture_output=True,timeout=8)
     absent=subprocess.run(list(map(str,adb+['shell','test','!','-e',remote])),text=True,capture_output=True,timeout=8)
     evidence['ownRemoteTmpRemoved']=cleanup.returncode==0 and absent.returncode==0
 evidence['commands']=commands;evidence['sourceSHA256']=before;evidence['sourceStable']=all(hashlib.sha256((ROOT/name).read_bytes()).hexdigest()==digest for name,digest in before.items());(EVIDENCE/'result.json').write_text(json.dumps(evidence,indent=2)+'\n')
 print(json.dumps({k:v for k,v in evidence.items() if k not in ['commands','sourceSHA256']}))
 if not evidence['sourceStable']:raise RuntimeError('sources changed during checks')

if __name__=='__main__':main()
