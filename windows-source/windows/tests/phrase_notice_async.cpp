#include <windows.h>
static bool failCompletionTimer=false;
static UINT_PTR testNoticeTimer(HWND h,UINT_PTR id,UINT ms,TIMERPROC proc){return failCompletionTimer&&id==2?0 : ::SetTimer(h,id,ms,proc);}
#define PRIVATE_INPUT_PHRASE_NOTICE_TEST_HOOKS 1
#define SetTimer testNoticeTimer
#include "../src/PhraseNotice.h"
#undef SetTimer
#include <chrono>
#include <thread>
#include <iostream>
static void pump(unsigned ms){const auto end=GetTickCount64()+ms;while(GetTickCount64()<end){MSG m;while(PeekMessageW(&m,nullptr,0,0,PM_REMOVE)){TranslateMessage(&m);DispatchMessageW(&m);}Sleep(5);}}
int main(){
 const DWORD owner=GetCurrentThreadId();int failures=0,completed=0;
 auto instance=GetModuleHandleW(nullptr);
 {PhraseNotice notice;notice.prepare(instance,[]{Sleep(30);return true;},[&]{if(GetCurrentThreadId()!=owner)++failures;++completed;});pump(150);if(completed!=1)++failures;}
 {PhraseNotice notice;notice.prepare(instance,[]{Sleep(60);return true;},[&]{++failures;});notice.hide();pump(150);}
 // Only synthetic popup instances. No installed input profile or worker.
 DWORD session=0;ProcessIdToSessionId(GetCurrentProcessId(),&session);std::cout<<"session="<<session<<"\n";
 auto check=[&](const char*label,bool okay,PhraseNotice&n,int calls){auto h=n.testWindow();DWORD pid=0;if(h)GetWindowThreadProcessId(h,&pid);std::cout<<(okay?"PASS ":"FAIL ")<<label<<" calls="<<calls<<" visible="<<n.visible()<<" owned="<<(h&&pid==GetCurrentProcessId())<<" styleVisible="<<(h&&(GetWindowLongPtrW(h,GWL_STYLE)&WS_VISIBLE)!=0)<<"\n";if(!okay)++failures;};
 auto click=[&](PhraseNotice&notice){auto h=notice.testWindow();DWORD pid=0;if(h)GetWindowThreadProcessId(h,&pid);if(!h||pid!=GetCurrentProcessId()){++failures;std::cout<<"FAIL exact owned test card unavailable\n";return;}RECT r{};GetClientRect(h,&r);SendMessageW(h,WM_LBUTTONUP,0,MAKELPARAM(r.right-3,(r.bottom-r.top)/2));};
 using Status=private_input::activity::LearningIntentStatus;
 {PhraseNotice notice;auto d=std::make_shared<private_input::activity::LearningDelivery>();int calls=0;notice.show(instance,{100,100,100,100},96,L"合成",[&]{++calls;return d;});click(notice);pump(80);check("pending request remains visible",notice.visible()&&calls==1,notice,calls);d->finish(Status::Pending);pump(80);check("durable Pending is not Applied",notice.visible(),notice,calls);click(notice);check("Pending does not resubmit",calls==1,notice,calls);}
 {PhraseNotice notice;auto d=std::make_shared<private_input::activity::LearningDelivery>();int calls=0;notice.show(instance,{100,100,100,100},96,L"合成",[&]{++calls;return d;});d->finish(Status::Retry);click(notice);SendMessageW(notice.testWindow(),WM_TIMER,2,0);check("Retry consumed before next click",notice.visible()&&calls==1,notice,calls);d->complete=false;click(notice);d->finish(Status::Applied);pump(80);check("Applied hides after explicit retry",!notice.visible()&&calls==2,notice,calls);}
 {PhraseNotice notice;auto d=std::make_shared<private_input::activity::LearningDelivery>();int calls=0;notice.show(instance,{100,100,100,100},96,L"合成",[&]{++calls;return d;});d->finish(Status::Stale);click(notice);click(notice);check("Stale stays visible without resending",notice.visible()&&calls==1,notice,calls);}
 {PhraseNotice notice;auto d=std::make_shared<private_input::activity::LearningDelivery>();int calls=0;notice.show(instance,{100,100,100,100},96,L"合成",[&]{++calls;return d;});d->finish(Status::Expired);click(notice);pump(80);check("Expired does not auto-create action",notice.visible()&&calls==1,notice,calls);click(notice);check("Expired new action requires click",calls==2,notice,calls);}
 {PhraseNotice notice;auto d=std::make_shared<private_input::activity::LearningDelivery>();int calls=0;notice.show(instance,{100,100,100,100},96,L"合成",[&]{++calls;return d;});failCompletionTimer=true;click(notice);click(notice);check("Timer failure leaves visible retry",notice.visible()&&calls==2,notice,calls);failCompletionTimer=false;notice.hide();d->finish(Status::Applied);pump(80);check("Hidden owner never resurrected by ACK",!notice.visible(),notice,calls);}
 std::atomic<bool> started{false},released{false};
 auto notice=std::make_unique<PhraseNotice>();notice->prepare(instance,[&]{started=true;while(!released.load())Sleep(2);return true;},[&]{++failures;});
 for(int i=0;i<100&&!started.load();++i)Sleep(2);
 if(!started.load())++failures;
 const auto before=GetTickCount64();notice.reset();if(GetTickCount64()-before>100)++failures;
 released=true;pump(150);
 std::cout<<"phrase_notice_async failures="<<failures<<" completed="<<completed<<std::endl;return failures?1:0;
}
