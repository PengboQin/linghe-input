#pragma once
#include "ClipboardLiveStore.h"
#include <thread>
#include <mutex>
#include <condition_variable>
#include <atomic>
#include <chrono>
#include <deque>
#include <optional>
namespace private_input::activity {
struct ClipboardLiveContext {uint64_t generation=0,serial=0;uint32_t sequence=0;bool authorized=false,boardReadable=false,localPending=false;};
struct ClipboardLiveAuthority {std::shared_ptr<const ClipboardLiveGrant>grant;uint64_t generation=0;std::string incarnation;};
struct ClipboardLiveCallbacks {
 std::function<ClipboardLiveContext()>context;
 std::function<bool(const ClipboardLiveGrant&)>authorize;
 std::function<Json()>load;std::function<void(const Json&)>save;
 std::function<Json(const ClipboardLiveGrant&)>status;
 std::function<Json(const ClipboardLiveGrant&,const Json&)>batch;
 std::function<void(const Json&,const ClipboardLiveContext&)>apply;
 std::function<void(uint64_t)>accepted;
 std::function<void(const Json&,const std::string&,uint64_t)>cache;
 std::function<void()>compatibilityReady;
 std::function<void(int)>health; // 1 supported, 0 unsupported, -1 transient, -2 denied
};
class ClipboardLiveWorker {
 struct Copy {std::string text;ClipboardLiveContext context;};
 struct Import {Json wire;bool mayApply=false;ClipboardLiveContext context;};
 std::shared_ptr<const ClipboardLiveAuthority>authority;
 std::shared_ptr<const Json>published=std::make_shared<Json>(ClipboardLiveStore::initial());
 ClipboardLiveCallbacks callbacks;std::thread thread;std::mutex mutex;std::condition_variable wake;
 std::optional<Copy>latest;std::deque<Import>imports;std::vector<Id>compatAcks;
 bool stopping=false;uint64_t revision=0;std::atomic<bool>pendingFlag{false};std::atomic<int>healthValue{-1};std::atomic<uint64_t>authorizationTick{0},authorizationGeneration{0};
 std::chrono::milliseconds poll;void run()noexcept;bool current(const std::shared_ptr<const ClipboardLiveAuthority>&)const;void publish(const ClipboardLiveStore&);
public:
 explicit ClipboardLiveWorker(ClipboardLiveCallbacks,std::chrono::milliseconds poll=std::chrono::milliseconds(3000));
 ~ClipboardLiveWorker();void stop();void setAuthority(std::shared_ptr<const ClipboardLiveAuthority>);
 bool offer(std::string,const ClipboardLiveContext&);void importLegacy(Json,bool,const ClipboardLiveContext&);void compatibilityQueued(const Id&);
 bool freshAuthority(uint64_t generation,uint64_t maxAgeMilliseconds=15000)const;
 bool pending()const{return pendingFlag.load();}int health()const{return healthValue.load();}
 std::shared_ptr<const Json>snapshot()const{return std::atomic_load(&published);}
 bool knows(const Id&sender,const Id&event)const;
};
}
