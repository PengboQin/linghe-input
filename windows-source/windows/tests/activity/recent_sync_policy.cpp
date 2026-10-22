#include "../../activity/RecentSyncPolicy.h"
#include <iostream>
#include <stdexcept>
using namespace private_input::activity;
int main(){unsigned count=0;auto check=[&](bool value){if(!value)throw std::runtime_error("recent sync policy check");++count;};
 RecentSyncBudget budget;check(budget.begin("endpoint/group/epoch/revision/personal",1000));budget.conditional=true;budget.finish(1010,true);
 check(!budget.begin("endpoint/group/epoch/revision/personal",601009));check(budget.begin("endpoint/group/epoch/revision/personal",601010));check(budget.conditional);
 budget.finish(601020,false);check(!budget.begin("endpoint/group/epoch/revision/personal",631019));check(budget.begin("endpoint/group/epoch/revision/personal",631020));
 budget.finish(631030,true);check(budget.begin("different-epoch",631031)&&!budget.conditional);budget.conditional=true;budget.finish(631040,true);
 check(budget.begin("different-epoch",10)&&!budget.conditional);budget.conditional=true;budget.reset();check(budget.scope.empty()&&!budget.conditional);
 const std::string self="11111111-2222-4333-8444-555555555555",peer="aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",event="bbbbbbbb-cccc-4ddd-8eee-ffffffffffff";
 RecentSnapshotHints hints("scope-a");hints.own=recentHintID(self);hints.rememberPeer(peer,event);
 auto state=Json::object({{"snapshotHints",hints.encoded()},{"receipts",Json::object({{uuidText(parseId(event)),"authenticated-digest"}})}});
 auto valid=RecentSnapshotHints::restore(state,"scope-a",true);check(valid.own==recentHintID(self)&&valid.peers.fields.size()==1);
 check(RecentSnapshotHints::restore(state,"scope-a",false).own.empty());check(RecentSnapshotHints::restore(state,"scope-b",true).own.empty());
 state["receipts"]=Json::object();check(RecentSnapshotHints::restore(state,"scope-a",true).peers.fields.empty());
 state["snapshotHints"]["own"]="invalid";check(RecentSnapshotHints::restore(state,"scope-a",true).own.empty());
 for(unsigned i=0;i<65;++i){Id actor{};actor[0]=uint8_t(i);hints.rememberPeer(uuidText(actor),event);}check(hints.peers.fields.size()==64);
 std::cout<<"PASS "<<count<<" recent budget/durable-cache policy checks\n";
}
