#pragma once
#include "LearningIntent.h"
#include <algorithm>
#include <limits>

namespace private_input::activity::learning_inbox {
inline Json initial(){return Json::object({{"version",1},{"scope",Json()},{"token",""},{"pending",Json::object()},{"processed",Json::object()},{"wordFences",Json::object()},{"clockFloor",0}});}
inline std::string canonical(std::string reading){std::transform(reading.begin(),reading.end(),reading.begin(),[](unsigned char c){return c>='A'&&c<='Z'?char(c+32):char(c);});return reading;}
inline std::string key(const std::string&r,const std::string&t){return canonical(r)+char(31)+t;}
inline std::string wordHash(const std::string&r,const std::string&t){auto h=sha256(bytes(key(r,t)));return base64(Data(h.begin(),h.end()));}
inline const Json*word(const Json&archive,const std::string&r,const std::string&t){auto id=key(r,t);for(const auto&e:archive.at("entries").items)if(key(e.at("reading").str(),e.at("text").str())==id)return &e;return nullptr;}
inline uint64_t generation(const Json&state,const std::string&r,const std::string&t){uint64_t value=0;if(auto e=word(state.at("archive"),r,t))value=e->at("generation").num();const auto&fences=state.at("learningInbox").at("wordFences");auto id=wordHash(r,t);if(fences.has(id))value=std::max(value,fences.at(id).at("generation").num());return value;}
inline void rotate(Json&state){state["learningInbox"]["token"]=uuidText(newId());}
inline Json scope(const Json&state,const LearningOwner&o){(void)parseId(o.personal);(void)parseId(o.device);(void)parseId(o.installation);(void)parseId(state.at("group").str());return Json::object({{"personal",o.personal},{"device",o.device},{"installation",o.installation},{"group",state.at("group")},{"local",o.local},{"consent",state.at("localLearningConsentRevision")}});}
inline Json payload(const LearningIntent&i){auto p=Json::object({{"token",uuidText(i.token)},{"createdAt",i.createdAt},{"reading",canonical(i.reading)},{"text",i.text}});if(i.action!=3)p["action"]=int(i.action);return p;}
inline std::string digest(const Json&value){auto h=sha256(bytes(value.dump()));return base64(Data(h.begin(),h.end()));}
inline void validateWord(const std::string&r,const std::string&t,const std::string&actor,const LearningCapacity&p){(void)recordLearning(emptyLearning(p),r,t,actor,p);}
inline void validate(const Json&state,const LearningCapacity&p){
 const auto&in=state.at("learningInbox");require(in.kind==Json::Kind::object&&in.fields.size()==7&&in.at("version").num()==1,"learning inbox version/shape");
 const auto&pending=in.at("pending"),&processed=in.at("processed"),&fences=in.at("wordFences");
 require(pending.kind==Json::Kind::object&&pending.fields.size()<=LearningPendingRows&&pending.dump().size()<=LearningPendingBytes,"learning pending quota");
 require(processed.kind==Json::Kind::object&&processed.fields.size()<=LearningReceiptRows&&processed.dump().size()<=LearningReceiptBytes,"learning receipt quota");
 require(fences.kind==Json::Kind::object&&fences.fields.size()<=p.term_rows,"learning generation fence quota");(void)in.at("clockFloor").num();
 if(in.at("scope").kind==Json::Kind::null){require(pending.fields.empty()&&processed.fields.empty()&&fences.fields.empty()&&in.at("token").str().empty(),"unbound learning inbox");return;}
 const auto&s=in.at("scope");require(s.kind==Json::Kind::object&&s.fields.size()==6,"learning owner shape");for(const auto*n:{"personal","device","installation","group"})(void)parseId(s.at(n).str());
 require(s.at("group").str()==state.at("group").str()&&s.at("consent").num()==state.at("localLearningConsentRevision").num(),"learning owner scope");(void)s.at("local").boolean();(void)parseId(in.at("token").str());
 for(const auto&x:pending.fields){(void)parseId(x.first);const auto&v=x.second;require(v.fields.size()==(v.has("relearnGeneration")?8:7),"learning pending shape");if(v.has("relearnGeneration"))require(v.at("relearnGeneration").num()>v.at("wordGeneration").num(),"learning pending restore generation");(void)parseId(v.at("token").str());(void)v.at("createdAt").num();(void)v.at("acceptedAt").num();(void)v.at("wordGeneration").num();(void)unbase64(v.at("digest").str(),32);validateWord(v.at("reading").str(),v.at("text").str(),s.at("device").str(),p);auto body=Json::object({{"token",v.at("token")},{"createdAt",v.at("createdAt")},{"reading",v.at("reading")},{"text",v.at("text")}});require(v.at("digest").str()==digest(body)&&v.at("createdAt").num()<=v.at("acceptedAt").num(),"learning pending immutable payload");}
 for(const auto&x:processed.fields){require(x.second.fields.size()==(x.second.has("forget")?4:3),"learning receipt shape");if(x.second.has("forget"))require(x.second.at("forget").boolean(),"learning receipt action");(void)parseId(x.first);(void)unbase64(x.second.at("digest").str(),32);(void)x.second.at("createdAt").num();(void)x.second.at("acceptedAt").num();}
 for(const auto&x:fences.fields){const auto&v=x.second;require(x.first==wordHash(v.at("reading").str(),v.at("text").str())&&v.at("generation").num()>0,"learning word fence");validateWord(v.at("reading").str(),v.at("text").str(),s.at("device").str(),p);}
}
inline void pruneReceipts(Json&state,uint64_t now){auto&receipts=state["learningInbox"]["processed"].fields;for(auto it=receipts.begin();it!=receipts.end();){auto a=it->second.at("acceptedAt").num(),c=it->second.at("createdAt").num();const bool forget=it->second.has("forget")&&it->second.at("forget").boolean();if(now>=a&&now-a>(forget?LearningForgetReceiptSeconds:LearningReceiptSeconds)&&now>=c&&now-c>(forget?LearningForgetAdmissionSeconds:LearningAdmissionSeconds))it=receipts.erase(it);else ++it;}}
inline Json receipt(const Json&intent,uint64_t now){auto out=Json::object({{"digest",intent.at("digest")},{"createdAt",intent.at("createdAt")},{"acceptedAt",now}});if(intent.has("action")&&intent.at("action").num()==12)out["forget"]=true;return out;}
inline bool receiptFits(const Json&state,const std::string&id,const Json&value){auto receipts=state.at("learningInbox").at("processed");receipts[id]=value;return receipts.fields.size()<=LearningReceiptRows&&receipts.dump().size()<=LearningReceiptBytes;}
inline bool applies(const Json&state,const Json&intent){const auto r=intent.at("reading").str(),t=intent.at("text").str();auto e=word(state.at("archive"),r,t);return (!e||!e->at("deleted").boolean()||intent.has("relearnGeneration"))&&generation(state,r,t)==intent.at("wordGeneration").num();}
inline Json apply(const Json&state,const Json&intent,const LearningCapacity&p){
 auto archive=state.at("archive");const auto r=intent.at("reading").str(),t=intent.at("text").str();auto gen=intent.has("relearnGeneration")?intent.at("relearnGeneration").num():intent.at("wordGeneration").num();
 if(!word(archive,r,t)&&gen){auto seed=recordLearning(emptyLearning(p),r,t,state.at("learningInbox").at("scope").at("device").str(),p).at("entries").items.front();seed["generation"]=gen;seed["counts"]=Json::object();archive["entries"].items.push_back(seed);}
 for(auto&e:archive["entries"].items)if(key(e.at("reading").str(),e.at("text").str())==key(r,t)&&intent.has("relearnGeneration")){e["generation"]=gen;e["deleted"]=false;e["counts"]=Json::object();}
 return recordLearning(archive,r,t,state.at("learningInbox").at("scope").at("device").str(),p);
}
inline void retireWordPending(Json&state,const std::string&r,const std::string&t){auto id=key(r,t);auto&pending=state["learningInbox"]["pending"].fields;for(auto it=pending.begin();it!=pending.end();)if(key(it->second.at("reading").str(),it->second.at("text").str())==id)it=pending.erase(it);else ++it;}
inline bool generationChanged(const Json&before,const Json&after){std::map<std::string,uint64_t>old;for(const auto&e:before.at("entries").items)old[key(e.at("reading").str(),e.at("text").str())]=e.at("generation").num();for(const auto&e:after.at("entries").items){auto id=key(e.at("reading").str(),e.at("text").str());if(e.at("generation").num()!=(old.count(id)?old.at(id):0))return true;}return false;}
}
