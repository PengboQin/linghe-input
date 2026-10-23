#pragma once
#include <cstdint>
#include <optional>
namespace private_input {
struct CandidateAnchorRect {long left=0,top=0,right=0,bottom=0;bool valid()const{return right>=left&&bottom>top;}};
struct CandidateAnchorIdentity {
 uintptr_t context=0,view=0,composition=0,host=0;uint64_t epoch=0;unsigned dpi=0;long hostX=0,hostY=0;
 bool operator==(const CandidateAnchorIdentity&o)const{return context==o.context&&view==o.view&&composition==o.composition&&host==o.host&&epoch==o.epoch&&dpi==o.dpi&&hostX==o.hostX&&hostY==o.hostY;}
 bool valid()const{return context&&view&&composition&&host&&dpi;}
};
enum class CandidateAnchorObservation {Verified,TemporaryUnavailable,Invalid};
inline bool candidateViewMayRecover(bool destroyed,uintptr_t blocked,uintptr_t active){return !destroyed||(blocked&&active&&blocked!=active);}
enum class CandidateViewEvent {Create,Change,Destroy};
enum class CandidateViewAction {Ignore,Refresh,Retire,Restart};
inline CandidateViewAction candidateViewAction(CandidateViewEvent event,uintptr_t notified,uintptr_t active,uintptr_t known){
 auto current=active?active:known;
 if(event==CandidateViewEvent::Destroy)return notified&&current&&notified!=current?CandidateViewAction::Refresh:CandidateViewAction::Retire;
 if(event==CandidateViewEvent::Create)return notified&&active&&notified!=active?CandidateViewAction::Ignore:CandidateViewAction::Restart;
 return notified&&current&&notified!=current?CandidateViewAction::Ignore:CandidateViewAction::Refresh;
}
// KillTimer does not remove an already posted WM_TIMER. A current lease deadline
// fences old queued events, including events arriving after a new verified caret.
class CandidateAnchorLease {
 bool waiting=false;uint64_t armedAt=0,deadline=0;
public:
 void clear(){waiting=false;armedAt=deadline=0;}
 void arm(uint64_t now,uint64_t remaining){waiting=remaining>0;armedAt=now;deadline=now+remaining;}
 std::optional<uint64_t> timer(uint64_t now)const{if(!waiting)return {};if(now<armedAt||now>=deadline)return uint64_t(0);return deadline-now;}
};
// A failed layout lookup never creates geometry. Only an unrenewed, <=200ms
// lease on a recently verified caret may cover temporary NOLAYOUT/E_FAIL.
class CandidateAnchorPolicy {
 CandidateAnchorIdentity identity{};CandidateAnchorRect rect{};uint64_t verifiedAt=0;bool present=false;
public:
 static constexpr uint64_t LeaseMS=200;
 uint64_t leaseRemaining(uint64_t now)const{return present&&now>=verifiedAt&&now-verifiedAt<LeaseMS?LeaseMS-(now-verifiedAt):0;}
 void clear(){present=false;identity={};rect={};verifiedAt=0;}
 std::optional<CandidateAnchorRect> resolve(const CandidateAnchorIdentity&key,CandidateAnchorObservation observation,CandidateAnchorRect incoming,uint64_t now,bool validComposition,bool focused){
  if(!validComposition||!focused||!key.valid()){clear();return {};}
  if(present&&!(identity==key))clear();
  if(observation==CandidateAnchorObservation::Verified&&incoming.valid()){identity=key;rect=incoming;verifiedAt=now;present=true;return rect;}
  if(observation==CandidateAnchorObservation::TemporaryUnavailable&&present&&now>=verifiedAt&&now-verifiedAt<=LeaseMS)return rect;
  clear();return {};
 }
};
}
