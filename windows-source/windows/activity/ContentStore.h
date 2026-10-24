#pragma once
#include "ContentModel.h"
#include "GroupProtocol.h"
#include "LearningIntent.h"
namespace private_input::activity {
class ContentStore {
 Json state;std::function<void(const Json&)>persist;const LearningCapacity*reader;
 uint64_t retryRevision=1,lastRetryRevision=0,retryAfter=0;bool reloadRequired=false,configured=false;
 void save(const Json&,bool retryChange=false,bool learningCommit=false);void enqueue(const Data&,uint8_t,const protocol::VerifiedMembership&,const GroupIdentity&,const Key&,uint64_t,bool automatic=false,const Id*fixedEvent=nullptr,uint64_t fixedExpiry=0,const Json*learningPublication=nullptr);
public:
 ContentStore(Json,std::function<void(const Json&)>,const LearningCapacity& supported=CurrentLearningCapacity);
 const Json& current()const{return state;}
 bool learningEnabled()const{return state.at("learningEnabled").boolean();}bool clipboardEnabled()const{return state.at("clipboardEnabled").boolean();}
 void configure(const Id&,uint64_t,bool learning,bool clipboard,bool preserveLocal=false);void record(const std::string&reading,const std::string&text,const std::string&device);
 void bindLearningOwner(const LearningOwner&);void setLocalLearningEnabled(bool);
 Json learningAuthority()const;LearningIntentResult acceptLearningIntent(const LearningIntent&,uint64_t now);
 size_t retryLearningIntents(uint64_t now,size_t budget=16);
 void upgradeLearningCapacity(const std::string&id,uint64_t version);
 bool mustReload()const{return reloadRequired;}
 void changeWord(const std::string&reading,const std::string&text,const std::string&device,unsigned action);
 void mergeRemoteLearning(const Json&);
 void publishLearning(const protocol::VerifiedMembership&,const GroupIdentity&,const Key&,uint64_t);
 void sendText(const std::string&,const protocol::VerifiedMembership&,const GroupIdentity&,const Key&,uint64_t,bool automatic=false);
 void sendCompatibility(const std::string&,const Id&,uint64_t,const protocol::VerifiedMembership&,const GroupIdentity&,const Key&,uint64_t);
 void cancelAutomaticText();bool automaticEvent(const std::string&event)const{return state.at("automaticOutgoing").has(event);}
 std::vector<Json>pending(uint64_t);void sent(const Json&);bool receive(const Json&,const protocol::VerifiedMembership&,const Key&,uint64_t);
 static Json initial(const LearningCapacity& profile=CurrentLearningCapacity);
};
}
