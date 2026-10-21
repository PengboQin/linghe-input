#ifdef NDEBUG
#undef NDEBUG
#endif
#include "../../../artifacts/LingheInput-Windows-0.4.5-review-source/windows/activity/AutomaticClipboard.h"
#include <cassert>
#include <iostream>
using namespace private_input::activity;
int main(){
 Json disk;AutomaticClipboard policy({},[&](const Json&j){disk=j;});auto group=uuidText(newId()),personal=uuidText(newId()),self=uuidText(newId()),peer=uuidText(newId());policy.configure(group,1,personal,true);policy.setEnabled(true);policy.observe({},true,false,self);assert(policy.ready());
 auto incoming=[&](const char*text){return Json::object({{"event",uuidText(newId())},{"sender",peer},{"text",text}});};
 // Exact 045 Worker ordering: clipboardChanged records sequence+serial BEFORE
 // OpenClipboard fails. No text/exclusion value was read, no outbox was created.
 uint32_t sequence=101,handled=101;uint64_t serial=1,lastSyncSerial=0,generation=7;bool pending=false;
 auto sourceLoopLocalActivity=[&]{return sequence!=handled||serial!=lastSyncSerial||pending;};
 auto first=policy.observe({incoming("first remote after unreadable local copy")},true,sourceLoopLocalActivity(),self);assert(!first);lastSyncSerial=serial;
 // Same sequence is still unreadable/unverified, but the first pass consumed
 // the only local-serial fence. The product policy now returns fresh remote B.
 auto second=policy.observe({incoming("second remote can overwrite denied sequence")},true,sourceLoopLocalActivity(),self);assert(second);
 bool requestCurrent=sequence==handled&&clipboardApplyFence(true,generation,generation,serial,serial,sequence,sequence,pending);assert(requestCurrent);
 // If the later OpenClipboard succeeds and no exclusion format is present,
 // 045's apply path reaches EmptyClipboard without verifying the unread local
 // contents. This fixture executes product policy; no real clipboard is opened.
 std::cout<<Json::object({{"production045CounterexampleConfirmed",true},{"firstPassBlocked",!first.has_value()},{"secondPassReturnedRemote",second.has_value()},{"sameSequenceApplyFenceAllows",requestCurrent},{"realClipboardRead",false},{"realClipboardWrite",false}}).dump()<<'\n';
}
