#include "BackgroundTask.h"
#include "../activity/LearningIPC.h"
#include "../activity/CaptureIPC.h"
#include <iostream>
#include <memory>
#include <stdexcept>

namespace {
void check(bool value,const char*message){if(!value)throw std::runtime_error(message);}
struct Events {
 HANDLE entered=CreateEventW(nullptr,TRUE,FALSE,nullptr);
 HANDLE release=CreateEventW(nullptr,TRUE,FALSE,nullptr);
 HANDLE destroyed=CreateEventW(nullptr,TRUE,FALSE,nullptr);
 ~Events(){CloseHandle(entered);CloseHandle(release);CloseHandle(destroyed);}
};
struct Lifetime {
 std::shared_ptr<Events> events;
 ~Lifetime(){SetEvent(events->destroyed);}
};
}
// No production IPC: the reader is stopped inside its injected public-resource
// prepare callback, before any mapping/file access. All handshakes are events.
int main(){
 try{
  auto events=std::make_shared<Events>();
  auto lifetime=std::make_shared<Lifetime>();lifetime->events=events;
  std::weak_ptr<Lifetime> weak=lifetime;
  auto reader=std::make_unique<private_input::activity::LearningReader>();
  reader->start({},[lifetime]{SetEvent(lifetime->events->entered);WaitForSingleObject(lifetime->events->release,INFINITE);});
  lifetime.reset();
  check(WaitForSingleObject(events->entered,5000)==WAIT_OBJECT_0,"resource callback did not start");
  auto begin=GetTickCount64();reader.reset();auto elapsed=GetTickCount64()-begin;
  check(elapsed<250,"TSF owner waited for blocked background callback");
  check(!weak.expired(),"background state was freed while callback was active");
  SetEvent(events->release);
  check(WaitForSingleObject(events->destroyed,5000)==WAIT_OBJECT_0,"retired callback was not reclaimed");

  auto retired=std::make_shared<Events>();auto retiredLifetime=std::make_shared<Lifetime>();retiredLifetime->events=retired;
  private_input::activity::LearningReader restarting;
  restarting.start({},[retiredLifetime]{SetEvent(retiredLifetime->events->entered);WaitForSingleObject(retiredLifetime->events->release,INFINITE);});
  retiredLifetime.reset();check(WaitForSingleObject(retired->entered,5000)==WAIT_OBJECT_0,"first reader start");
  restarting.stop();
  auto replacement=std::make_shared<Events>();
  restarting.start({},[replacement]{SetEvent(replacement->entered);WaitForSingleObject(replacement->release,INFINITE);});
  check(WaitForSingleObject(replacement->entered,5000)==WAIT_OBJECT_0,"stopped reader could not restart independently");
  restarting.stop();SetEvent(replacement->release);SetEvent(retired->release);
  check(WaitForSingleObject(retired->destroyed,5000)==WAIT_OBJECT_0,"old reader callback leaked on restart");
  // A never-started emitter has no wait, handles, or production transport.
  {private_input::activity::CaptureEmitter emitter(L"isolated-lifecycle-unused");}
  std::cout<<"{\"passed\":true,\"blockedPrepareOwnerReleaseMs\":"<<elapsed<<",\"backgroundStateRetainedAndReclaimed\":true,\"independentRestart\":true,\"productionIPCUsed\":false,\"installedTSF\":false}\n";
  return 0;
 }catch(const std::exception&error){std::cerr<<"FAIL: "<<error.what()<<'\n';return 1;}
}
