#include "../../activity/ContentStore.h"
#include <iostream>
#include <algorithm>
#include <sodium.h>
using namespace private_input::activity;
namespace {
const std::string actor="11111111-1111-4111-8111-111111111111";
Json word(unsigned i){return Json::object({{"reading","he cheng"},{"text","合成"+std::to_string(i)},{"generation",0},{"deleted",false},{"counts",Json::object({{actor,1}})},{"pinned",false},{"pinVersion",Json::object({{"sequence",0},{"device",""}})}});}
const Json& atWord(const Json& state,const std::string& text){const auto&rows=state.at("archive").at("entries").items;auto at=std::find_if(rows.begin(),rows.end(),[&](const Json&j){return j.at("text").str()==text;});if(at==rows.end())throw std::runtime_error("fixture word missing");return *at;}
}
int main(){try{require(sodium_init()>=0,"fixture sodium");
 auto initial=ContentStore::initial(LegacyLearningCapacity);initial["group"]=actor;initial["epoch"]=1;auto archive=emptyLearning(LegacyLearningCapacity);for(unsigned i=0;i<5000;++i)archive["entries"].items.push_back(word(i));
 archive["entries"].items[0]["pinned"]=true;archive["entries"].items[0]["pinVersion"]=Json::object({{"sequence",3},{"device",actor}});archive["entries"].items[1]["deleted"]=true;archive["entries"].items[2]["generation"]=2;archive["entries"].items[2]["counts"]=Json::object();
 initial["archive"]=validateLearning(archive,LegacyLearningCapacity);Json disk=initial;unsigned writes=0;ContentStore store(initial,[&](const Json&next){disk=next;++writes;},LegacyLearningCapacity);store.bindLearningOwner({"22222222-2222-4222-8222-222222222222",actor,"33333333-3333-4333-8333-333333333333",true});
 LearningIntent existing{newId(),parseId(store.learningAuthority().at("token").str()),1000,"he cheng","合成0"};require(store.acceptLearningIntent(existing,1000).status==LearningIntentStatus::Applied,"existing word still applies at cap");
 LearningIntent confirmed{newId(),existing.token,1000,"rong liang","容量新词"};auto before=writes;require(store.acceptLearningIntent(confirmed,1000).status==LearningIntentStatus::Pending&&writes==before+1,"new confirmed word persists pending in one owner commit");
 ContentStore restarted(disk,[&](const Json&next){disk=next;++writes;},LegacyLearningCapacity);require(restarted.current().at("learningInbox").at("pending").has(uuidText(confirmed.event)),"confirmed choice recoverable from reopened saved state");restarted.upgradeLearningCapacity("expanded-10000",2);require(restarted.retryLearningIntents(2000)==1,"known real profile expands and replays once");ContentStore final(disk,[](const Json&){});require(final.acceptLearningIntent(confirmed,2001).status==LearningIntentStatus::Duplicate,"same event after reopen cannot increment twice");
 require(atWord(final.current(),"合成0").at("pinned").boolean()&&atWord(final.current(),"合成1").at("deleted").boolean()&&atWord(final.current(),"合成2").at("generation").num()==2,"old controls retained");
 std::cout<<"{\"modelEntries\":5001,\"existingWordStillUpdates\":true,\"confirmedChoicePersistedPending\":true,\"knownExpandedProfileReplayedExactlyOnce\":true,\"oldStateAndControlsPreserved\":true,\"actualProductionStoreExecuted\":true,\"actualDPAPIOrWorkerExecuted\":false,\"allDataSynthetic\":true}\n";return 0;
 }catch(const std::exception&e){std::cerr<<"fixture failure: "<<e.what()<<'\n';return 2;}}
