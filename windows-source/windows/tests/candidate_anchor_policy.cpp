#include "../src/CandidateAnchorPolicy.h"
#include <cstdlib>
#include <iostream>
static unsigned checks=0;
#define CHECK(x) do{++checks;if(!(x))std::abort();}while(false)
using namespace private_input;
int main(){CandidateAnchorPolicy policy;CandidateAnchorIdentity key{1,2,3,4,1,192,20,30};CandidateAnchorRect caret{1040,300,1042,324};
 CHECK(!policy.resolve(key,CandidateAnchorObservation::TemporaryUnavailable,{},10,true,true));
 auto r=policy.resolve(key,CandidateAnchorObservation::Verified,caret,100,true,true);CHECK(r&&r->left==1040&&r->top==300);CHECK(policy.leaseRemaining(100)==200);
 CHECK(policy.resolve(key,CandidateAnchorObservation::TemporaryUnavailable,{},299,true,true));CHECK(policy.leaseRemaining(299)==1);
 CHECK(!policy.resolve(key,CandidateAnchorObservation::TemporaryUnavailable,{},301,true,true));CHECK(!policy.resolve(key,CandidateAnchorObservation::TemporaryUnavailable,{},302,true,true));
 for(int field=0;field<9;++field){policy.resolve(key,CandidateAnchorObservation::Verified,caret,100,true,true);auto changed=key;switch(field){case 0:++changed.context;break;case 1:++changed.view;break;case 2:++changed.composition;break;case 3:++changed.host;break;case 4:++changed.epoch;break;case 5:changed.dpi=144;break;case 6:++changed.hostX;break;case 7:++changed.hostY;break;case 8:changed.host=0;break;}CHECK(!policy.resolve(changed,CandidateAnchorObservation::TemporaryUnavailable,{},101,true,true));}
 policy.resolve(key,CandidateAnchorObservation::Verified,caret,100,true,true);CHECK(!policy.resolve(key,CandidateAnchorObservation::Invalid,{},101,true,true));
 policy.resolve(key,CandidateAnchorObservation::Verified,caret,100,true,true);CHECK(!policy.resolve(key,CandidateAnchorObservation::Verified,{0,0,0,0},101,true,true));
 policy.resolve(key,CandidateAnchorObservation::Verified,caret,100,true,true);CHECK(!policy.resolve(key,CandidateAnchorObservation::TemporaryUnavailable,{},99,true,true));
 policy.resolve(key,CandidateAnchorObservation::Verified,caret,100,true,true);CHECK(!policy.resolve(key,CandidateAnchorObservation::TemporaryUnavailable,{},101,false,true));
 policy.resolve(key,CandidateAnchorObservation::Verified,caret,100,true,true);CHECK(!policy.resolve(key,CandidateAnchorObservation::TemporaryUnavailable,{},101,true,false));
 // Collapsed carets may have zero width. Negative monitor coordinates are valid.
 CHECK(policy.resolve(key,CandidateAnchorObservation::Verified,{-900,-300,-900,-276},200,true,true));
 // Long wrapped composition follows the newest verified line, never its first
 // line/host corner; no string length or arbitrary frame geometry enters policy.
 CHECK(policy.resolve(key,CandidateAnchorObservation::Verified,{400,700,402,724},210,true,true)->top==700);
 CHECK(policy.resolve(key,CandidateAnchorObservation::Verified,{110,724,112,748},220,true,true)->left==110);
 policy.clear();CHECK(!policy.resolve(key,CandidateAnchorObservation::TemporaryUnavailable,{},221,true,true));
 CHECK(candidateViewAction(CandidateViewEvent::Create,2,2,1)==CandidateViewAction::Restart);
 CHECK(candidateViewAction(CandidateViewEvent::Destroy,1,2,2)==CandidateViewAction::Refresh);
 CHECK(candidateViewAction(CandidateViewEvent::Destroy,1,0,2)==CandidateViewAction::Refresh);
 CHECK(candidateViewAction(CandidateViewEvent::Destroy,2,2,2)==CandidateViewAction::Retire);
 CHECK(candidateViewAction(CandidateViewEvent::Create,1,2,2)==CandidateViewAction::Ignore);
 CHECK(candidateViewAction(CandidateViewEvent::Change,1,2,2)==CandidateViewAction::Ignore);
 CHECK(candidateViewAction(CandidateViewEvent::Destroy,0,0,0)==CandidateViewAction::Retire);
 CHECK(candidateViewMayRecover(true,1,2)); // existing new active view, CHANGE/key without CREATE
 CHECK(!candidateViewMayRecover(true,1,1));CHECK(!candidateViewMayRecover(true,0,2));
 CandidateAnchorLease lease;CHECK(!lease.timer(100));lease.arm(100,200);CHECK(lease.timer(150)&&*lease.timer(150)==150);lease.clear();CHECK(!lease.timer(350)); // stale timer after a fresh verified caret
 lease.arm(400,200);CHECK(lease.timer(450)&&*lease.timer(450)==150); // old queued event cannot expire new lease
 CHECK(lease.timer(600)&&*lease.timer(600)==0);lease.arm(800,200);CHECK(lease.timer(799)&&*lease.timer(799)==0);
 std::cout<<"PASS "<<checks<<" anchor identity/200ms lease/DPI/negative-monitor/wrapped-line/focus/empty-rect checks\n";
}
