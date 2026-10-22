#include "../installer/RecoveryTransaction.h"
#include "../installer/PayloadManifest.h"
#include "../installer/UpgradeState.h"
#ifdef NDEBUG
#undef NDEBUG
#endif
#include <cassert>
#include <vector>
using namespace linghe::installer::recovery;
struct Fake : Adapter {
 Image live; Journal disk; bool saved=false;
 int faultStep=-1; bool failRestore=false, badHealth=false, faultCommit=false;
 unsigned writes=0;
 void preflight(const Journal&)override{if(badHealth)throw std::runtime_error("worker fence");}
 void store(const Journal&j)override{
  if(faultCommit&&j.phase==Phase::Committed){faultCommit=false;throw std::runtime_error("disk full");}
  disk=j;saved=true;++writes;
 }
 void apply(Slot s,const Image&i)override{
  auto n=static_cast<std::size_t>(s);live.slots[n]=i.slots[n];
  if(static_cast<int>(n)==faultStep){faultStep=-1;throw std::runtime_error("after-write failure");}
 }
 bool matches(const Image&i)override{return live.slots==i.slots;}
 void restore(Slot s,const Image&i)override{
  if(failRestore)throw std::runtime_error("restore denied");
  auto n=static_cast<std::size_t>(s);
  if(live.slots[n]!=i.slots[n]&&live.slots[n]!=disk.desired.slots[n])throw std::runtime_error("external edit");
  live.slots[n]=i.slots[n];
 }
};
Journal sample(){Journal j;j.transaction="synthetic";j.ownerSid="synthetic-sid";
 j.before.slots={"047-tip","047-arp","043-run","047-link"};
 j.desired.slots={"043-tip","043-arp","043-run","043-link"};return j;}
int main(){
 {using U=linghe::installer::UpgradeState;using linghe::installer::upgradeState;
  assert(upgradeState(false,false,false,false,false,false,false)==U::Ready);
  assert(upgradeState(true,true,true,true,true,true,true)==U::Ready);
  assert(upgradeState(true,true,true,false,false,false,false)==U::Ready);
  assert(upgradeState(true,false,false,false,false,false,false)==U::RegistrationArpMismatch);
  assert(upgradeState(false,true,false,false,false,false,false)==U::RegistrationArpMismatch);
  assert(upgradeState(true,true,false,true,true,true,true)==U::ArpVersionMismatch);
  assert(upgradeState(true,true,true,true,false,true,true)==U::WorkerMismatch);
  assert(upgradeState(true,true,true,true,true,true,false)==U::StartupMismatch);
  assert(upgradeState(false,false,false,true,false,false,false)==U::WorkerMismatch);
  assert(upgradeState(false,false,false,false,false,true,false)==U::StartupMismatch);
 }

 {linghe::installer::PayloadEntry p{std::string(64,'a'),"AMD64/owned.bin"};
  using P=linghe::installer::PayloadPurpose;
  assert(!linghe::installer::validOwnedPayload(p,false,false,"",P::InstallOrRepair));
  assert(linghe::installer::validOwnedPayload(p,false,false,"",P::CleanupRetry));
  assert(!linghe::installer::validOwnedPayload(p,true,false,p.sha256,P::InstallOrRepair));
  assert(!linghe::installer::validOwnedPayload(p,true,true,std::string(64,'b'),P::CleanupRetry));
  assert(linghe::installer::validOwnedPayload(p,true,true,p.sha256,P::InstallOrRepair));}
 for(int n=0;n<4;++n){auto j=sample();Fake f;f.live=j.before;f.faultStep=n;
  auto r=execute(j,f);assert(!r.committed&&r.restored&&!r.retryRequired);assert(f.matches(j.before));}
 {auto j=sample();Fake f;f.live=j.before;auto r=execute(j,f);assert(r.committed&&f.matches(j.desired));}
 {auto j=sample();Fake f;f.live=j.before;f.faultCommit=true;auto r=execute(j,f);assert(!r.committed&&r.restored);}
 {auto j=sample();Fake f;f.live=j.before;f.faultStep=2;f.failRestore=true;auto r=execute(j,f);
  assert(r.retryRequired&&f.disk.phase==Phase::RecoveryRequired);f.failRestore=false;
  auto resumed=f.disk;r=execute(resumed,f);assert(r.restored&&!r.retryRequired&&f.matches(j.before));}
 // Crash after registration write but before success acknowledgement: replay
 // uses persisted Applying intent and restores the entire original mixed state.
 {auto j=sample();Fake f;f.live=j.before;j.phase=Phase::Applying;j.intent=0;f.store(j);
  f.live.slots[0]=j.desired.slots[0];auto resumed=f.disk;auto r=execute(resumed,f);assert(r.restored&&f.matches(j.before));}
 {auto j=sample();Fake f;f.live=j.before;f.badHealth=true;bool denied=false;
  try{execute(j,f);}catch(...){denied=true;}assert(denied&&!f.saved&&f.matches(j.before));}
 {auto j=sample();Fake f;f.live=j.before;j.phase=Phase::Committed;
  auto r=execute(j,f);assert(!r.committed&&r.retryRequired);}
 {auto j=sample();Fake f;f.live=j.before;j.phase=Phase::Applying;f.store(j);
  f.live.slots[2]="user-edited-command";auto r=execute(j,f);
  assert(r.retryRequired&&f.live.slots[2]=="user-edited-command");}
}
