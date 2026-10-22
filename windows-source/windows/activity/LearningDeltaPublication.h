#pragma once
#include "ContentModel.h"

namespace private_input::activity {
struct LearningDeltaPublication {
 Json payload,checkpoint;bool hasPayload=false,bootstrap=false,fullRepair=false;
 size_t changedEntries=0,changedPersonalRecords=0;
};

// Keep the existing LearningArchive/MAX-counter wire. This checkpoint is local
// delivery metadata and is advanced only with the encrypted durable outbox.
inline LearningDeltaPublication prepareLearningDelta(const Json&archive,const Id&group,uint64_t epoch,uint64_t now,const Json*previous){
 validateLearning(archive);require(epoch>0,"learning delta epoch");
 Json prior;bool valid=false;
 if(previous)try{
  const auto&p=*previous;require(p.at("version").num()==1&&parseId(p.at("group").str())==group&&p.at("epoch").num()==epoch,"learning delta scope");
  require(p.at("entries").kind==Json::Kind::object&&p.at("entries").fields.size()<=5000&&p.at("personal").kind==Json::Kind::object&&p.at("personal").fields.size()<=4000,"learning delta checkpoint bounds");
  (void)p.at("lastFullAt").num();(void)p.at("personalPresent").boolean();
  for(const auto*name:{"entries","personal"})for(const auto&row:p.at(name).fields){(void)unbase64(row.second.str(),32);if(std::string(name)=="entries")(void)unbase64(row.first,32);}
  prior=p;valid=true;
 }catch(const JsonError&){valid=false;}
 auto digest=[](const Json&value){const auto hash=sha256(bytes(value.dump()));return base64(Data(hash.begin(),hash.end()));};
 auto hashes=Json::object(),personalHashes=Json::object(),changed=Json::array(),personalDelta=Json::object();
 for(const auto&entry:archive.at("entries").items){
  // The semantic ID remains reading + US + text. Only its local lookup key is
  // hashed, because an allowed 1024-byte word exceeds Json's 256-byte key bound.
  const auto identity=sha256(bytes(entry.at("reading").str()+char(31)+entry.at("text").str()));auto id=base64(Data(identity.begin(),identity.end()));
  auto hash=digest(entry);require(!hashes.has(id),"learning delta identifier collision");hashes[id]=hash;if(!valid||!prior.at("entries").has(id)||prior.at("entries").at(id).str()!=hash)changed.items.push_back(entry);
 }
 const bool hasPersonal=archive.has("personalLexicon")&&archive.at("personalLexicon").kind!=Json::Kind::null;
 if(hasPersonal)for(const auto&row:archive.at("personalLexicon").at("records").fields){auto hash=digest(row.second);personalHashes[row.first]=hash;if(!valid||!prior.at("personal").has(row.first)||prior.at("personal").at(row.first).str()!=hash)personalDelta[row.first]=row.second;}
 if(valid){
  for(const auto&row:prior.at("entries").fields)require(hashes.has(row.first),"learning entry disappeared without tombstone");
  for(const auto&row:prior.at("personal").fields)require(personalHashes.has(row.first),"personal record disappeared without tombstone");
  require(!prior.at("personalPresent").boolean()||hasPersonal,"personal archive disappeared without tombstones");
 }
 const bool full=!valid||now<prior.at("lastFullAt").num()||now-prior.at("lastFullAt").num()>=86400;
 LearningDeltaPublication result;result.bootstrap=!valid;result.fullRepair=full;result.changedEntries=changed.items.size();result.changedPersonalRecords=personalDelta.fields.size();
 result.checkpoint=Json::object({{"version",1},{"group",uuidText(group)},{"epoch",epoch},{"entries",hashes},{"personal",personalHashes},{"personalPresent",hasPersonal},{"lastFullAt",full?now:prior.at("lastFullAt").num()}});
 if(full){result.payload=archive;result.hasPayload=true;return result;}
 const bool personalChanged=!personalDelta.fields.empty()||hasPersonal!=prior.at("personalPresent").boolean();
 if(changed.items.empty()&&!personalChanged)return result;
 result.payload=emptyLearning();result.payload["entries"]=changed;
 if(personalChanged&&hasPersonal)result.payload["personalLexicon"]=Json::object({{"version",1},{"records",personalDelta}});
 validateLearning(result.payload);result.hasPayload=true;return result;
}
}
