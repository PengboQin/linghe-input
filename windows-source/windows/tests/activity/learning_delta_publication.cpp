#include "../../activity/ContentStore.h"
#include "../../activity/LearningDeltaPublication.h"
#include "../../activity/PairAdmission.h"
#include <sodium.h>
#include <iostream>
#include <stdexcept>
using namespace private_input::activity;
namespace protocol=private_input::protocol;
namespace {
unsigned checks=0;
void check(bool value){if(!value)throw std::runtime_error("learning delta publication check");++checks;}
template<class F>void rejects(F f){bool failed=false;try{f();}catch(const JsonError&){failed=true;}check(failed);}
GroupIdentity makeIdentity(){GroupIdentity i;i.device=newId();i.owner=newId();randombytes_buf(i.signingSeed.data(),32);randombytes_buf(i.ownerSeed.data(),32);randombytes_buf(i.exchangeSecret.data(),32);return i;}
}
int main(){
 check(sodium_init()>=0);auto a=makeIdentity(),b=makeIdentity();auto admission=prepareAdmission(initialMembership(a),a,pairRequest(b,1000),1000);
 auto membership=anchorOf(admission.bundle.at("membership")).verify(protocol::decodeMembershipJSON(admission.bundle.at("membership").dump()));
 Json disk;unsigned saves=0;int fail=0;
 ContentStore store({},[&](const Json&value){if(fail==1||(fail==2&&!value.at("outgoing").items.empty())){fail=0;throw JsonError("synthetic durable failure");}disk=value;++saves;});
 Json receiverDisk;ContentStore receiver({},[&](const Json&value){receiverDisk=value;});
 store.configure(membership.anchor().group,2,true,true);receiver.configure(membership.anchor().group,2,true,true);
 for(const auto&pair:{std::pair{"ni hao","你好"},std::pair{"tao bao","淘宝"},std::pair{"tian mao","天猫"}})store.record(pair.first,pair.second,uuidText(a.device));
 auto open=[&](const Json&wire,uint64_t now){auto result=protocol::openOpaquePayload(decodeContentEnvelope(wire),admission.localKey,membership.trust(protocol::MembershipDomain::learning),{},now);return Json::parse(std::string(result.payload.begin(),result.payload.end()),2097152,32,262144);};
 auto take=[&](uint64_t now){auto rows=store.pending(now);check(rows.size()==1);return rows[0];};
 store.publishLearning(membership,a,admission.localKey,1000);auto wire=take(1000);auto payload=open(wire,1001);check(payload.at("entries").items.size()==3);
 check(store.current().at("learningPublication").at("lastFullAt").num()==1000);check(receiver.receive(wire,membership,admission.localKey,1001));store.sent(wire);
 store.record("ni hao","你好",uuidText(a.device));store.publishLearning(membership,a,admission.localKey,1001);wire=take(1001);payload=open(wire,1002);
 check(payload.at("entries").items.size()==1&&payload.at("entries").items[0].at("text").str()=="你好");
 check(store.current().at("learningPublication").at("entries").fields.size()==3&&store.current().at("learningPublication").at("lastFullAt").num()==1000);
 check(receiver.receive(wire,membership,admission.localKey,1002));check(receiver.current().at("archive").at("entries").items.size()==3);store.sent(wire);
 auto before=saves;store.publishLearning(membership,a,admission.localKey,1002);check(saves==before&&store.pending(1002).empty());
 auto personal=emptyLearning(),records=Json::object();auto first=uuidText(newId()),second=uuidText(newId());
 for(const auto&id:{first,second}){auto version=Json::object({{"sequence",1},{"device",uuidText(a.device)}});records[id]=Json::object({{"entry",Json::object({{"id",id},{"kind","phrase"},{"text",id==first?"共享短语一":"共享短语二"},{"trigger",id==first?"csa":"csb"}})},{"deleted",false},{"revision",version},{"created",version}});}
 personal["personalLexicon"]=Json::object({{"version",1},{"records",records}});store.mergeRemoteLearning(personal);store.publishLearning(membership,a,admission.localKey,1003);wire=take(1003);payload=open(wire,1004);
 check(payload.at("entries").items.empty()&&payload.at("personalLexicon").at("records").fields.size()==2);check(receiver.receive(wire,membership,admission.localKey,1004));store.sent(wire);
 personal["personalLexicon"]["records"][first]["deleted"]=true;personal["personalLexicon"]["records"][first]["revision"]=Json::object({{"sequence",2},{"device",uuidText(a.device)}});
 store.mergeRemoteLearning(personal);store.publishLearning(membership,a,admission.localKey,1004);wire=take(1004);payload=open(wire,1005);
 check(payload.at("entries").items.empty()&&payload.at("personalLexicon").at("records").fields.size()==1&&payload.at("personalLexicon").at("records").at(first).at("deleted").boolean());
 check(receiver.receive(wire,membership,admission.localKey,1005)&&materializePersonal(receiver.current().at("archive")).size()==1);store.sent(wire);
 store.record("xin ci","新词",uuidText(a.device));store.publishLearning(membership,a,admission.localKey,87399);wire=take(87399);check(open(wire,87400).at("entries").items.size()==1);store.sent(wire);
 check(store.current().at("learningPublication").at("lastFullAt").num()==1000);
 store.publishLearning(membership,a,admission.localKey,87400);wire=take(87400);payload=open(wire,87401);
 check(payload.at("entries").items.size()==4&&payload.at("personalLexicon").at("records").fields.size()==2);check(store.current().at("learningPublication").at("lastFullAt").num()==87400);
 // An expired, undelivered delta/full wire invalidates its baseline. A later
 // repair sends the full state rather than pretending the lost wire arrived.
 check(store.pending(692200).empty()&&!store.current().has("learningPublication"));store.publishLearning(membership,a,admission.localKey,692200);wire=take(692200);check(open(wire,692201).at("entries").items.size()==4);store.sent(wire);
 auto repairedAt=store.current().at("learningPublication").at("lastFullAt").num();store.sendText("clipboard must not reset the daily repair",membership,a,admission.localKey,692201);
 check(store.pending(692801).empty()&&store.current().at("learningPublication").at("lastFullAt").num()==repairedAt);store.publishLearning(membership,a,admission.localKey,692801);check(store.pending(692801).empty());
 // Both allocation failure and final outbox persistence failure leave the old
 // digest baseline. A harmless reserved sequence gap is not an acknowledgement.
 store.record("xin ci","新词",uuidText(a.device));auto baseline=store.current().at("learningPublication").dump();fail=1;rejects([&]{store.publishLearning(membership,a,admission.localKey,692802);});
 check(store.current().at("learningPublication").dump()==baseline&&disk.at("learningPublication").dump()==baseline&&store.pending(692802).empty());
 fail=2;rejects([&]{store.publishLearning(membership,a,admission.localKey,692803);});check(store.current().at("learningPublication").dump()==baseline&&disk.at("learningPublication").dump()==baseline&&store.pending(692803).empty());
 store.publishLearning(membership,a,admission.localKey,692804);wire=take(692804);check(open(wire,692805).at("entries").items.size()==1);check(disk.at("learningPublication").dump()!=baseline&&disk.at("outgoing").items.size()==1);store.sent(wire);
 auto prior=store.current().at("learningPublication");auto missing=store.current().at("archive");missing["entries"].items.pop_back();rejects([&]{prepareLearningDelta(missing,membership.anchor().group,2,692805,&prior);});
 check(prepareLearningDelta(store.current().at("archive"),newId(),2,692805,&prior).bootstrap);check(prepareLearningDelta(store.current().at("archive"),membership.anchor().group,3,692805,&prior).bootstrap);
 auto migrated=store.current();migrated.fields.erase("learningPublication");ContentStore legacy(migrated,[](const Json&){});legacy.publishLearning(membership,a,admission.localKey,692805);check(legacy.pending(692805).size()==1&&open(legacy.pending(692805)[0],692806).at("entries").items.size()==4);
 store.configure(membership.anchor().group,3,true,true);check(!store.current().has("learningPublication"));
 // A valid long word cannot become an overlong JSON object key in the local
 // delivery ledger. Exercise actual persisted ContentStore JSON restoration.
 Json longDisk;ContentStore longWord({},[&](const Json&value){longDisk=Json::parse(value.dump(),8388608);});longWord.configure(membership.anchor().group,2,true,true);
 longWord.record("chang ci",std::string(900,'x'),uuidText(a.device));longWord.publishLearning(membership,a,admission.localKey,1000);
 check(longDisk.at("learningPublication").at("entries").fields.begin()->first.size()==44);
 ContentStore longRestart(longDisk,[&](const Json&value){longDisk=Json::parse(value.dump(),8388608);});check(longRestart.current().at("archive").at("entries").items[0].at("text").str().size()==900);
 std::cout<<"PASS "<<checks<<" actual ContentStore encrypted delta/full-repair/atomic-outbox/old-wire checks; nativeSessions=false network=false\n";
}
