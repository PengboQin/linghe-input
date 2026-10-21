#!/usr/bin/env python3
"""Small production GroupClient phase test; synthetic one-shot relay, no PC/service/listener."""
from pathlib import Path
import os,sys,subprocess,json,hashlib,argparse
ROOT=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--before',action='store_true');a=p.parse_args();version='before' if a.before else 'after'
build=ROOT/'build/windows-input-tests/clipboard047';evidence=ROOT/'evidence/windows047-live-clipboard';build.mkdir(parents=True,exist_ok=True);evidence.mkdir(parents=True,exist_ok=True)
producer=ROOT/'artifacts/LingheInput-Windows-0.4.6-review-source' if a.before else ROOT
host=(ROOT/'windows/tests/activity/group_client_host.cpp').read_text();host=host.replace('#include "../../activity/GroupClient.h"','#include "'+str(producer/'windows/activity/GroupClient.h')+'"\n#include "'+str(producer/'windows/activity/AutomaticClipboard.h')+'"')
host=host.replace('std::function<void()> afterPull,afterAdmission;', 'std::function<void()> afterPull,afterAdmission;std::function<void(const std::string&)>phaseProbe;')
host=host.replace('if(offline)throw JsonError("HTTPS request unavailable");', 'if(offline)throw JsonError("HTTPS request unavailable");if(phaseProbe)phaseProbe(path);')
host=host.replace('int main(int argc,char**argv)', 'int inherited_full_suite_main(int argc,char**argv)')
host=host.replace('#include "queue_recovery_cases.inc"','#include "'+str(ROOT/'windows/tests/activity/queue_recovery_cases.inc')+'"')
host+=r'''
int main(){check(sodium_init()>=0);fixtureRoot=fs::absolute("build/windows-activity/group-fixture");check(!fs::exists(fixtureRoot));fs::create_directories(fixtureRoot);try{
 RecoveryPair pair("immediate-transport");recency=true;pair.text("durable copy while input remains active");Json disk;AutomaticClipboard automatic({},[&](const Json&j){disk=j;});automatic.configure(uuidText(pair.receiver->group()),pair.receiver->current().at("membership").at("epoch").num(),pair.receiver->personalEpoch(),true);automatic.setEnabled(true);automatic.observe({},true,false,uuidText(pair.receiver->keys().device));
 bool applied=false,atLearning=false,hadDurableClip=false,early=false;
 auto publish=[&]{auto&observation=pair.receiver->lastContentSyncObservation;auto value=automatic.observe(observation.newShared,observation.drained&&observation.received==0,false,uuidText(pair.receiver->keys().device));if(value){check(value->at("text").str()=="durable copy while input remains active");applied=true;}};
 phaseProbe=[&](const std::string&path){if(path.find("/recency")==std::string::npos||atLearning)return;atLearning=true;auto&observation=pair.receiver->lastContentSyncObservation;hadDurableClip=observation.newShared.size()==1&&loadPrivate(pair.receiverPath/"content-v1.dpapi").at("texts").items.size()==1;early=applied;};
#ifdef LINGHE_EXPECT_PHASE_CALLBACK
 pair.receiver->syncContent(publish);
#else
 pair.receiver->syncContent();
#endif
 publish();check(atLearning&&hadDurableClip&&applied);
#ifdef LINGHE_EXPECT_PHASE_CALLBACK
 check(early);
#else
 check(!early);
#endif

#ifdef LINGHE_EXPECT_PHASE_CALLBACK
 auto reject=[](auto work){bool failed=false;try{work();}catch(...){failed=true;}check(failed);};auto autoFile=pair.receiverPath/"auto-clipboard-v1.dpapi";AutomaticClipboard permission({},[&](const Json&j){savePrivate(autoFile,j);});permission.configure(uuidText(pair.receiver->group()),pair.receiver->current().at("membership").at("epoch").num(),pair.receiver->personalEpoch(),true);permission.setEnabled(true);auto delegated=pair.receiver->clipboardLiveAuthority("synthetic-parent-scope",unixTime());check(pair.receiver->clipboardLiveAuthorityMatches(delegated));check(!delegated.has("master")&&!delegated.has("signingSeed")&&!delegated.has("ownerSeed")&&!delegated.has("exchangeSecret"));auto event=newId();auto beforeCount=pair.receiver->contentSnapshot().at("outgoing").items.size();pair.receiver->sendClipboardCompatibility("same compatibility UUID",event,unixTime()+300);auto once=pair.receiver->contentSnapshot().at("outgoing");pair.receiver->sendClipboardCompatibility("same compatibility UUID",event,unixTime()+300);check(once.dump()==pair.receiver->contentSnapshot().at("outgoing").dump()&&once.items.size()==beforeCount+1&&once.items.back().at("event").str()==uuidText(event)&&once.items.back().at("expiresAt").num()<=unixTime()+300);reject([&]{pair.receiver->sendClipboardCompatibility("changed body",event,unixTime()+300);});reject([&]{pair.receiver->sendClipboardCompatibility("expired",newId(),unixTime());});permission.setEnabled(false);check(!pair.receiver->clipboardLiveAuthorityMatches(delegated));reject([&]{pair.receiver->clipboardLiveAuthority("synthetic-parent-scope",unixTime()+1);});
#endif
 std::cout<<Json::object({{"producerClipboardDurableBeforeLearning",hadDurableClip},{"appliedBeforeLearningMaintenance",early},{"eventuallyApplied",applied},{"realClipboardRead",false},{"realClipboardWrite",false},{"noActivationNeededByModel",true}}).dump()<<'\n';phaseProbe={};fs::remove_all(fixtureRoot);
 }catch(...){phaseProbe={};fs::remove_all(fixtureRoot);throw;}return 0;}
'''
source=build/(version+'-transport.cpp');source.write_text(host);exe=build/(version+'-transport')
cpp=['GroupClient.cpp','AutomaticClipboard.cpp','Json.cpp','ArchiveCore.cpp','ArchiveQueue.cpp','GroupProtocol.cpp','PairAdmission.cpp','ContentModel.cpp','ContentStore.cpp','LegacyLearning.cpp','RecentModel.cpp','RecentProtocol.cpp']
files=[producer/'windows/activity'/name for name in cpp]+([] if a.before else [ROOT/'windows/activity/ClipboardLiveProtocol.cpp'])+[producer/'windows/sync'/name for name in ['SecureProtocol.cpp','Membership.cpp','MembershipWire.cpp']]
env=os.environ.copy();env['TMPDIR']=str(ROOT/'build/tmp');env['PRIVATE_INPUT_FIXTURE_PYTHON']=os.environ.get('PRIVATE_INPUT_FIXTURE_PYTHON',sys.executable)
flags=[] if a.before else ['-DLINGHE_EXPECT_PHASE_CALLBACK']
with (evidence/(version+'-transport-build.log')).open('w') as log:subprocess.run(['clang++','-std=c++17','-O0','-DSODIUM_STATIC','-Ibuild/sodium-membership/native/include',*flags,str(source),*map(str,files),'build/sodium-membership/native/lib/libsodium.a','-o',str(exe)],cwd=ROOT,env=env,stdout=log,stderr=subprocess.STDOUT,check=True)
result=subprocess.run([str(exe)],cwd=ROOT,env=env,capture_output=True,text=True,check=True)
(evidence/(version+'-transport.log')).write_text(result.stdout+result.stderr)
record=json.loads(result.stdout.strip().splitlines()[-1]);record['sourceGroupClientSHA256']=hashlib.sha256((producer/'windows/activity/GroupClient.cpp').read_bytes()).hexdigest();(evidence/(version+'-transport.json')).write_text(json.dumps(record,indent=2)+'\n');print(json.dumps(record))
