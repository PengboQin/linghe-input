#!/usr/bin/env python3
"""Real local Rime regression, synthetic old build/userdb only; no real device."""
from pathlib import Path
import hashlib,json,subprocess,tempfile,shutil
ROOT=Path(__file__).resolve().parents[2];BUILD=ROOT/'build/core-prebuilt-selection';EVIDENCE=ROOT/'evidence/core-prebuilt-selection-20261021';PREFIX=ROOT/'build/rime/macos-arm64'

def main():
 BUILD.mkdir(exist_ok=True);EVIDENCE.mkdir(exist_ok=True)
 before=BUILD/'before.cpp';source=ROOT/'core/src/private_input.cpp';checks=[]
 text=source.read_text()
 start=text.index('  // Installed packages ship complete public tables.')
 end=text.index('  traits.distribution_name',start)
 baseline=text[:start]+text[end:]
 if before.exists() and before.read_text()!=baseline:raise RuntimeError('Existing negative control differs; preserve and review before replacement')
 before.write_text(baseline)
 wanted=hashlib.sha256(source.read_bytes()).hexdigest()
 def run(name,args):
  result=subprocess.run(list(map(str,args)),cwd=ROOT,capture_output=True,text=True,timeout=120)
  (EVIDENCE/(name+'.log')).write_text(result.stdout+result.stderr);checks.append({'name':name,'exitCode':result.returncode})
  if result.returncode:raise RuntimeError(name+' failed: '+(result.stdout+result.stderr)[-3000:])
  if result.stdout:print(result.stdout.strip())
 include=['-Icore/include','-Ivendor/librime/src','-I'+str(PREFIX/'include')]
 for mode,src in [('before',before),('after',source)]:
  run(mode+'-compile',['xcrun','clang++','-std=c++17','-O1',*include,'-c',src,'-o',BUILD/(mode+'.o')])
  run(mode+'-link',['xcrun','clang++','-std=c++17','-O1',*include,'core/tests/packaged_prebuilt_selection.cpp',BUILD/(mode+'.o'),'-Wl,-force_load,'+str(PREFIX/'lib/librime.a'),'-L'+str(PREFIX/'lib'),'-lyaml-cpp','-lleveldb','-lmarisa','-lopencc','-o',BUILD/(mode+'-check')])
  with tempfile.TemporaryDirectory(prefix=mode+'-synthetic-',dir=BUILD) as temp:
   old_fixture=Path(temp)/'old-fixture'
   shutil.copytree(ROOT/'fixtures/rime-p1',old_fixture,ignore=shutil.ignore_patterns('build'))
   run(mode+'-old-build-switch',[BUILD/(mode+'-check'),old_fixture,ROOT/'resources/rime',Path(temp)/'data','expect-stale' if mode=='before' else 'expect-fresh'])
 for case,resources,args in [('engine_smoke','fixtures/rime-p1',[]),('engine_smoke','fixtures/rime-p1',['NO_DEPLOY']),('nine_filter_smoke','resources/rime',['NO_DEPLOY'])]:
  name=case+('-nodeploy' if args else '-deploy')
  run(name+'-link',['xcrun','clang++','-std=c++17','-O1',*include,ROOT/'core/tests'/(case+'.cpp'),BUILD/'after.o','-Wl,-force_load,'+str(PREFIX/'lib/librime.a'),'-L'+str(PREFIX/'lib'),'-lyaml-cpp','-lleveldb','-lmarisa','-lopencc','-o',BUILD/'smoke'])
  with tempfile.TemporaryDirectory(prefix='smoke-synthetic-',dir=BUILD) as temp:run(name,[BUILD/'smoke',ROOT/resources,Path(temp)/'data',*args])
 stable=hashlib.sha256(source.read_bytes()).hexdigest()==wanted
 result={'passed':stable,'commands':checks,'negativeControlOldBuildMasksTaobao':True,'fixedNoDeployRecallsTaobao':True,'oldUserdbCountPreserved':True,'oldUserBuildByteIdentical':True,'defaultDeploy1Regression':True,'sourceStable':stable,'coreSHA256':wanted,'realUserDataRead':False,'deviceAccess':False,'productionChanged':False,'installed':False}
 (EVIDENCE/'result.json').write_text(json.dumps(result,indent=2)+'\n')
 if not stable:raise RuntimeError('core source changed during verification')
 print('PASS packaged prebuilt selection and deploy compatibility, synthetic users only')

if __name__=='__main__':main()
