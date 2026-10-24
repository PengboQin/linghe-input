#ifdef NDEBUG
#undef NDEBUG
#endif
#include "../../activity/AutomaticClipboard.h"
#include "../../activity/ClipboardReadSafety.h"
#include <cassert>
#include <iostream>
using namespace private_input::activity;
int main(){
 using O=ClipboardReadSafety::Observation;ClipboardReadSafety safety;Json disk;bool failSave=false;AutomaticClipboard policy({},[&](const Json&j){if(failSave)throw JsonError("synthetic persistence denied");disk=j;});auto group=uuidText(newId()),personal=uuidText(newId()),self=uuidText(newId()),peer=uuidText(newId());
 policy.configure(group,1,personal,true);policy.setEnabled(true);policy.observe({},true,false,self);assert(policy.ready());
 auto message=[&](const char*text){return Json::object({{"event",uuidText(newId())},{"sender",peer},{"text",text}});};uint32_t seq=101;uint64_t gen=7,serial=1,lastSerial=0;
 assert(!safety.allows(seq,gen));assert(safety.observe(seq,seq,gen,gen,O::metadataBaseline));assert(safety.allows(seq,gen));safety.begin();assert(!safety.observe(seq,seq,gen,gen,O::denied));
 auto first=message("first denied");auto second=message("second same-sequence denied");
 auto round=[&](const Json&item){bool blocked=serial!=lastSerial||!safety.allows(seq,gen);auto result=policy.observe({item},true,blocked,self);lastSerial=serial;return result;};
 assert(!round(first));assert(!round(second));assert(safety.blocked(seq)); // No next-pass bypass.
 assert(!safety.observe(seq,seq,gen,gen,O::metadataBaseline));assert(!safety.allows(seq,gen));
 // Stable successful read at the same sequence is the only nonempty recovery.
 assert(!safety.observe(seq,seq+1,gen,gen,O::stableText));assert(!safety.allows(seq,gen));
 assert(!safety.observe(seq,seq,gen,gen+1,O::stableText));assert(!safety.allows(seq,gen));
 assert(safety.observe(seq,seq,gen,gen,O::stableText));assert(!safety.blocked(seq)&&safety.allows(seq,gen));
 assert(!round(second)); // Already-seen blocked event is never replayed.
 assert(round(message("fresh after stable success")));
 // A genuine new copy can recover; old denied remote remains seen.
 safety.observe(seq,seq,gen,gen,O::denied);auto old=message("blocked before new copy");assert(!round(old));++seq;++serial;safety.begin();assert(safety.observe(seq,seq,gen,gen,O::stableText));assert(!round(old));assert(round(message("fresh after new copy")));
 // Unknown clipboard owner does not occur in this policy and cannot be treated
 // as sensitivity. Actual platform/password/read refusal does block receive.
 safety.invalidate();++seq;assert(!safety.observe(seq,seq,gen,gen,O::denied));assert(!round(message("initial platform read refusal")));
 // A truly verified empty clipboard (including sequence zero) is safe. An
 // inaccessible empty clipboard must have been denied before this observation.
 safety.invalidate();seq=0;assert(safety.observe(seq,seq,gen,gen,O::verifiedEmpty));assert(safety.allows(0,gen));assert(clipboardApplyFence(true,gen,gen,serial,serial,0,0,false,true));assert(!clipboardApplyFence(true,gen,gen,serial,serial,0,0,false));
 auto allowed=round(message("fresh into verified empty"));assert(allowed);
 // Consent/epoch invalidation blocks old tokens and baseline cannot remove a
 // same-sequence denial. Existing configure/cold-drain/seen stay authoritative.
 safety.observe(seq,seq,gen,gen,O::denied);++gen;safety.invalidate(gen);assert(!safety.observe(seq,seq,gen-1,gen-1,O::stableText));assert(!safety.allows(seq,gen));assert(!safety.observe(seq,seq,gen,gen,O::metadataBaseline));
 policy.setEnabled(false);assert(!policy.observe({message("disabled")},true,false,self));policy.setEnabled(true);assert(!policy.ready());assert(!policy.observe({message("cold on reenable")},true,false,self));policy.observe({},true,false,self);assert(policy.ready());
 policy.configure(group,2,personal,true);assert(!policy.ready());auto epochBacklog=message("old epoch backlog");assert(!policy.observe({epochBacklog},true,false,self));policy.observe({},true,false,self);assert(policy.ready());assert(!policy.observe({epochBacklog},true,false,self));assert(!clipboardApplyFence(true,gen,gen-1,serial,serial,seq,seq,false,true));
 safety.observe(seq,seq,gen,gen,O::verifiedEmpty);auto failed=message("must persist before apply");auto before=disk.dump();failSave=true;bool threw=false;try{round(failed);}catch(...){threw=true;}assert(threw&&disk.dump()==before);failSave=false;assert(round(failed));
 std::cout<<"production policy: sticky same-sequence refusal, stable read recovery, inaccessible/empty, new copy, no blocked replay, revoke/epoch/cold drain/persistence: passed\n";
}
