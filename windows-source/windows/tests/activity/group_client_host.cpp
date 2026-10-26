#include "../../activity/GroupClient.h"
#include <sodium.h>
#include <fstream>
#include <iostream>
#include <map>
#include <cstdio>
#include <cstdlib>
#include <functional>
#include <algorithm>
#ifdef _WIN32
#define popen _popen
#define pclose _pclose
#endif
using namespace private_input::activity;
namespace fs=std::filesystem;

namespace {fs::path fixtureRoot;
std::map<std::string,private_input::DeviceIdentity>identities;
bool offline=false,recency=true,legacyConditional=false,failLegacyLearning=false;
unsigned recentRequests=0,recentOwnEnvelopes=0,recentPeerEnvelopes=0;uint64_t recentDownloadJSONBytes=0;Json lastRecentHello,lastRecentPull;
std::string loseAck,lastPushedEvent;GroupClient* raceSource=nullptr;bool supersedeAck=false;
uint64_t tick=100000;
std::function<void()> afterPull,afterAdmission,afterCloudResponse;
unsigned afterCloudOperation=0;
fs::path failSavePath;bool failSave=false;
std::function<void()> afterContentSave;
unsigned ackAttempts=0,pushAttempts=0,pullAttempts=0;
bool loseBeforeAck=false;bool corruptPull=false;
std::vector<std::string> requestTrace;
}
namespace private_input {
void eraseIdentityMemory(void*p,size_t n)noexcept{sodium_memzero(p,n);
}
DeviceIdentityVault::DeviceIdentityVault(fs::path p):root_(std::move(p)){fs::create_directories(root_);
}
DeviceIdentity DeviceIdentityVault::create(){DeviceIdentity i;
randombytes_buf(i.device.data(),16);
randombytes_buf(i.owner.data(),16);
i.device[6]=(i.device[6]&15)|64;
i.device[8]=(i.device[8]&63)|128;
i.owner[6]=(i.owner[6]&15)|64;
i.owner[8]=(i.owner[8]&63)|128;
randombytes_buf(i.signingSeed.data(),32);
randombytes_buf(i.ownerSeed.data(),32);
randombytes_buf(i.exchangeSecret.data(),32);
identities[root_.string()]=i;
std::ofstream(root_/"identity.dpapi")<<"synthetic identity marker only";
return i;
}
DeviceIdentity DeviceIdentityVault::resetForDeparture(){return create();}
DeviceIdentity DeviceIdentityVault::load(){return identities.at(root_.string());
}
}
namespace private_input::activity {
PersonalDataLock::PersonalDataLock(const fs::path&p):root(p){}
PersonalDataLock::~PersonalDataLock(){}
std::filesystem::path userRoot(){return fixtureRoot/L"nonproduction-user";}
uint64_t monotonicMilliseconds(){return tick++;
}
std::string protect(const std::string&s){return s;
}std::string unprotect(const std::string&s){return s;
}
std::wstring wide(std::string_view s){return {s.begin(),s.end()};
}std::string utf8(std::wstring_view s){return {s.begin(),s.end()};
}
std::string endpoint(const std::string&s){require(s=="https://relay.example.invalid","fixture endpoint only");
return s;
}
void savePrivate(const fs::path&p,const Json&j){require(p.lexically_normal().generic_string().find(fixtureRoot.lexically_normal().generic_string()+"/")==0,"fixture storage only");
if(failSave&&p==failSavePath){failSave=false;throw JsonError("fixture disk full");}
fs::create_directories(p.parent_path());
auto temp=p;
temp+=".tmp";
{std::ofstream out(temp);
out<<j.dump();
if(!out)throw JsonError("fixture save");
}
#ifdef _WIN32
require(MoveFileExW(temp.c_str(),p.c_str(),MOVEFILE_REPLACE_EXISTING|MOVEFILE_WRITE_THROUGH)!=FALSE,"fixture atomic replace");
#else
fs::rename(temp,p);
#endif
if(afterContentSave&&p==failSavePath){auto callback=std::move(afterContentSave);afterContentSave={};callback();}
}
Json loadPrivate(const fs::path&p){require(p.lexically_normal().generic_string().find(fixtureRoot.lexically_normal().generic_string()+"/")==0,"fixture storage only");
std::ifstream in(p);
return Json::parse(std::string((std::istreambuf_iterator<char>(in)),{}),8388608);
}
Json post(const std::string&origin,const std::string&path,const Json&body){endpoint(origin);
if(offline)throw JsonError("HTTPS request unavailable");
if(failLegacyLearning&&(path.find("/recency")!=std::string::npos||path.find("/events")!=std::string::npos))throw JsonError("synthetic legacy learning outage");
if(!recency&&path.find("/recency")!=std::string::npos)throw HTTPError(404,"not_found");
if(path.find("/recency")!=std::string::npos){++recentRequests;auto raw=unbase64(body.at("body").str());auto payload=Json::parse(std::string(raw.begin(),raw.end()),8388608);auto op=body.at("operation").num();if(legacyConditional)require(!payload.has("knownEvent")&&!payload.has("knownSnapshots"),"old server received conditional fields");if(op==1)lastRecentHello=payload;if(op==3)lastRecentPull=payload;}
const bool isPull=path.rfind("/v1/groups/",0)==0&&path.size()>4&&path.substr(path.size()-4)=="/rpc"&&body.at("operation").num()==2;
const bool isAck=path.rfind("/v1/groups/",0)==0&&path.size()>4&&path.substr(path.size()-4)=="/rpc"&&body.at("operation").num()==3;
const bool isPush=path.size()>7&&path.substr(path.size()-7)=="/events";
if(isPull){++pullAttempts;requestTrace.push_back("pull");}if(isAck){++ackAttempts;requestTrace.push_back("ack");if(loseBeforeAck){loseBeforeAck=false;throw JsonError("HTTPS request unavailable");}}if(isPush){++pushAttempts;requestTrace.push_back("push");}
auto request=fixtureRoot/"request.json";
{std::ofstream out(request);
out<<Json::object({{"now",unixTime()},{"path",path},{"body",body}}).dump();
}auto python=std::getenv("PRIVATE_INPUT_FIXTURE_PYTHON");std::string command=std::string("\"")+(python?python:"python3")+"\" -B tools/windows_group_fixture_server.py build/windows-activity/group-fixture/request.json";
FILE*pipe=popen(command.c_str(),"r");
require(pipe!=nullptr,"fixture runner");
std::string value;
char data[4096];
while(auto n=fread(data,1,sizeof(data),pipe))value.append(data,n);
auto status=pclose(pipe);
require(status==0,"fixture server process");
auto wrapper=Json::parse(value,8388608);
if(wrapper.at("status").num()!=200){std::cerr<<"fixture HTTP "<<path<<" status="<<wrapper.at("status").num()<<" code="<<wrapper.at("error").str()<<"\n";throw HTTPError(unsigned(wrapper.at("status").num()),wrapper.at("error").str());}
if(path.find("/recency")!=std::string::npos&&body.at("operation").num()==2){auto decoded=unbase64(body.at("body").str());auto content=Json::parse(std::string(decoded.begin(),decoded.end()),8388608);lastPushedEvent=content.at("envelope").at("event").str();if(supersedeAck){supersedeAck=false;require(raceSource!=nullptr,"race source");raceSource->recordContent("xin xi","新习");raceSource->syncContent();wrapper["result"]["publishedEvent"]=lastPushedEvent;}}
if(path.size()>10&&path.substr(path.size()-10)=="/admission"&&afterAdmission){auto callback=std::move(afterAdmission);afterAdmission={};callback();}
if(path=="/v1/learning/rpc"&&afterCloudResponse&&body.at("operation").num()==afterCloudOperation){auto callback=std::move(afterCloudResponse);afterCloudResponse={};callback();}
bool lose=!loseAck.empty()&&path.find(loseAck)!=std::string::npos;
if(lose){loseAck.clear();
throw JsonError("HTTPS request unavailable");
}if(isPull&&!wrapper.at("result").at("events").items.empty()){
if(corruptPull){corruptPull=false;auto &wire=wrapper["result"]["events"].items[0];auto cipher=unbase64(wire.at("ciphertext").str());cipher.back()^=1;wire["ciphertext"]=base64(cipher);}
if(afterPull){auto callback=std::move(afterPull);afterPull={};callback();}
}if(path.find("/recency")!=std::string::npos){auto op=body.at("operation").num();auto&result=wrapper["result"];if(result.has("envelope")&&result.at("envelope").kind!=Json::Kind::null){if(op==1)++recentOwnEnvelopes;if(op==3)++recentPeerEnvelopes;}if(legacyConditional)result.fields.erase("conditionalSnapshots");if(op==1||op==3)recentDownloadJSONBytes+=result.dump().size();}return wrapper.at("result");
}
}
void checked(bool b,int line){if(!b)throw std::runtime_error("GroupClient product integration check at line "+std::to_string(line));
}
#define check(value) checked((value),__LINE__)
template<class F>void lost(F f){bool b=false;
try{f();
}catch(const JsonError&e){b=std::string(e.what())=="HTTPS request unavailable";
}check(b);
}
void queueRecoveryTests();
void automaticPublicationTests();
void conditionalRecencyTests();
void clipboardDuringLearningDeferralTests();void recentBatchPersistenceTests();void cloudLearningTests();void cloudRemoteRelearnTests();
void fixturePathBoundaryChecks(){
 auto inside=[](const fs::path&p){return p.lexically_normal().generic_string().find(fixtureRoot.lexically_normal().generic_string()+"/")==0;};
 check(inside(fixtureRoot/"owner"/"content-v1.dpapi"));
 check(inside(fixtureRoot/"owner"/".."/"content-v1.dpapi"));
 const auto sibling=fs::path(fixtureRoot.generic_string()+"-sibling")/"content-v1.dpapi";
 const auto escaped=fixtureRoot/".."/"outside"/"content-v1.dpapi";
 for(const auto&p:{fixtureRoot,sibling,escaped}){
  check(!inside(p));
  for(bool save:{false,true}){bool rejected=false;try{if(save)savePrivate(p,Json::object());else(void)loadPrivate(p);}catch(const JsonError&e){rejected=std::string(e.what())=="fixture storage only";}check(rejected);}
 }
}
int main(int argc,char**argv){check(sodium_init()>=0);
fixtureRoot=fs::absolute("build/windows-activity/group-fixture");
fixturePathBoundaryChecks();
if(argc==2&&std::string(argv[1])=="--path-boundary-only"){std::cout<<"fixture paths: native separators, lexical normalization, own-root children, sibling-prefix and dot-dot escapes passed\n";return 0;}
const bool clipboardOnly=argc==2&&std::string(argv[1])=="--clipboard-only";
const bool batchOnly=argc==2&&std::string(argv[1])=="--recent-batch-only";
const bool cloudOnly=argc==2&&std::string(argv[1])=="--cloud-only";
const bool conditionalOnly=argc==2&&std::string(argv[1])=="--recency-conditional-only";
check(argc==1||clipboardOnly||conditionalOnly||cloudOnly||batchOnly);
check(!fs::exists(fixtureRoot));
fs::create_directories(fixtureRoot);
try{if(batchOnly){recentBatchPersistenceTests();clipboardDuringLearningDeferralTests();fs::remove_all(fixtureRoot);return 0;}if(cloudOnly){cloudLearningTests();cloudRemoteRelearnTests();fs::remove_all(fixtureRoot);return 0;}if(conditionalOnly){conditionalRecencyTests();fs::remove_all(fixtureRoot);return 0;}if(clipboardOnly){automaticPublicationTests();fs::remove_all(fixtureRoot);return 0;}auto aPath=fixtureRoot/"owner",bPath=fixtureRoot/"new",cPath=fixtureRoot/"third";
GroupClient a(aPath),b(bPath),c(cPath);
a.recordContent("ni hao","你好");
check(!a.contentSnapshot().at("learningEnabled").boolean()&&a.contentSnapshot().at("archive").at("entries").items.size()==1);
auto legacy=std::string("# native fixture\n你好\tni hao \t7\r\n灵鹤造词\tling he zao ci \t3\r\n");
a.importLegacyLearning(legacy,a.personalEpoch());
auto seeded=a.contentSnapshot().at("archive").dump();
a.importLegacyLearning(legacy,a.personalEpoch());
check(a.contentSnapshot().at("archive").dump()==seeded);
a.create("https://relay.example.invalid");
a.consentContent(true,true);
auto ticket=a.makeTicket();
loseAck="/pairing/claim";
lost([&]{b.join("https://relay.example.invalid",ticket.at("code").str());
});
b.join("https://relay.example.invalid",ticket.at("code").str());
check(a.pollAdmissions());
b.pollJoin();
check(b.connected());
b.consentContent(true,true);
tick+=600001;a.syncContent();
tick+=600001;b.syncContent();
tick+=600001;a.syncContent();
a.recordContent("ni hao","你好");
a.sendSharedText("产品调用完整往返");
loseAck="/events";
lost([&]{tick+=600001;a.syncContent();
});
GroupClient restartA(aPath);
tick+=600001;restartA.syncContent();
tick+=600001;b.syncContent();
auto received=b.contentSnapshot();
check(received.at("archive").at("entries").items.size()==2&&received.at("texts").items.size()==1&&received.at("texts").items[0].at("text").str()=="产品调用完整往返");
check(received.has("recentScores")&&!received.at("recentScores").fields.empty());

 // Non-founder node admits a third device;
 // Founder need not be running.
 auto second=b.makeTicket();
c.join("https://relay.example.invalid",second.at("code").str());
loseAck="/admission";
lost([&]{b.pollAdmissions();
});
check(loadPrivate(bPath/"group.dpapi").has("pendingAdmission")&&loadPrivate(bPath/"group.dpapi").has("ticketRequest"));
GroupClient restartB(bPath);
check(restartB.pollAdmissions());
check(!loadPrivate(bPath/"group.dpapi").has("ticketRequest")&&!loadPrivate(bPath/"group.dpapi").has("ticket"));
c.pollJoin();
check(c.connected());
c.consentContent(true,true);
tick+=600001;c.syncContent();
tick+=600001;restartB.syncContent();
tick+=600001;restartA.syncContent();
restartA.recordContent("dou xian","都先");
offline=true;
restartA.recordContent("dou xian","都先");
offline=false;
tick+=600001;restartA.syncContent();
tick+=600001;c.syncContent();
auto current=c.contentSnapshot();
check(current.at("archive").at("entries").items.size()==3);

 // Old relay compatibility remains cumulative and doesn't disable v1 content.
 restartA.changeCandidate("ni hao","你好",5);auto resetArchive=restartA.contentSnapshot().at("archive");auto resetWord=std::find_if(resetArchive.at("entries").items.begin(),resetArchive.at("entries").items.end(),[](const auto&e){return e.at("text").str()=="你好";});check(resetWord!=resetArchive.at("entries").items.end()&&resetWord->at("counts").fields.empty()&&resetWord->at("generation").num()==1);restartA.changeCandidate("ni hao","你好",6);tick+=600001;restartA.syncContent();
recency=false;
tick+=600001;restartA.syncContent();
restartA.recordContent("ni hao","你好");
tick+=600001;restartA.syncContent();
check(restartA.contentSnapshot().at("recentScores").fields.empty());
recency=true;
tick+=600001;restartA.syncContent();

 // A newer same-identity session advances the server slot before the older
 // exact receipt arrives. Never record its digest as the current publication.
 GroupClient concurrentA(aPath);raceSource=&concurrentA;supersedeAck=true;restartA.recordContent("ci xu","词序");tick+=600001;restartA.syncContent();check(!supersedeAck);auto collision=loadPrivate(aPath/"recent-v2.dpapi");check(collision.at("publishedDigest").str().empty()&&!collision.has("pending"));GroupClient afterCollision(aPath);tick+=600001;afterCollision.syncContent();auto recovered=afterCollision.contentSnapshot().at("archive");check(std::any_of(recovered.at("entries").items.begin(),recovered.at("entries").items.end(),[](const auto&e){return e.at("text").str()=="新习";}));check(!loadPrivate(aPath/"recent-v2.dpapi").at("publishedDigest").str().empty());raceSource=nullptr;
 auto oldEpoch=c.personalEpoch();auto oldDevice=c.keys().device;c.leave();
check(!c.connected()&&!fs::exists(cPath/"content-v1.dpapi")&&!fs::exists(cPath/"recent-v2.dpapi")&&c.keys().device!=oldDevice&&c.personalEpoch()!=oldEpoch&&c.legacyRetired());bool staleRejected=false;try{c.importLegacyLearning(legacy,oldEpoch);}catch(...){staleRejected=true;}check(staleRejected);GroupClient afterDeparture(cPath);afterDeparture.create("https://relay.example.invalid");check(afterDeparture.contentSnapshot().at("archive").at("entries").items.empty());staleRejected=false;try{afterDeparture.importLegacyLearning(legacy,afterDeparture.personalEpoch());}catch(...){staleRejected=true;}check(staleRejected);
queueRecoveryTests();
std::cout<<"GroupClient product path: create, lost-ACK claim retry, owner/independent admission restart recovery, consent, v1 learning/shared text, trusted recency+offline/404 fallback, exact persisted retries, confirmed departure reset, superseded receipt and next-hello MAX recovery passed\n";
fs::remove_all(fixtureRoot);
}catch(...){fs::remove_all(fixtureRoot);
throw;
}}

#include "queue_recovery_cases.inc"
#include "recent_conditional_cases.inc"

#include "cloud_learning_cases.inc"

#include "recent_batch_cases.inc"
