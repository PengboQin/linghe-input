#include "LearningIPC.h"
#include "CaptureIPC.h"
#include "CloudRankIPC.h"
#include <atomic>
#include <cmath>
#include <algorithm>
namespace private_input::activity {
LearningReader::~LearningReader(){stop();}
void LearningReader::stop(){{std::lock_guard<std::mutex>guard(lock);stopping=true;}wake.notify_one();if(worker.joinable())worker.join();}
void LearningReader::start(std::filesystem::path model,std::function<void()>prepare,std::function<void()>settings){if(!worker.joinable())try{stopping=false;publicPath=std::move(model);preparePublic=std::move(prepare);refreshSettings=std::move(settings);worker=std::thread([this]{try{run();}catch(...) {}});}catch(...) {}}
namespace {
struct View{HANDLE handle=nullptr;const LearningMapping*data=nullptr;LONG previous=-1;bool valid=false;std::shared_ptr<const LearningSnapshot>cached=std::make_shared<LearningSnapshot>();~View(){if(data)UnmapViewOfFile(data);if(handle)CloseHandle(handle);}void open(const std::wstring&name){if(data)return;handle=OpenFileMappingW(FILE_MAP_READ,FALSE,name.c_str());if(handle)data=static_cast<const LearningMapping*>(MapViewOfFile(handle,FILE_MAP_READ,0,0,sizeof(LearningMapping)));if(!data&&handle){CloseHandle(handle);handle=nullptr;}}
 void refresh(){if(!data)return;auto revision=data->revision;MemoryBarrier();auto now=GetTickCount64();bool stale=now<data->updatedTick||now-data->updatedTick>90000;if((revision==previous&&!stale)||(revision&1))return;auto next=std::make_shared<LearningSnapshot>();next->scopeGeneration=data->generation;bool enabled=!stale&&data->version==1&&data->enabled&&data->count<=LearningRowLimit;if(enabled)for(uint32_t i=0;i<data->count;++i){LearningRow row;memcpy(&row,&data->rows[i],sizeof(row));if(!memchr(row.reading,0,sizeof(row.reading))||!memchr(row.text,0,sizeof(row.text))||row.frequency>1000000000||row.pinned>1||row.kind>2||!std::isfinite(row.recent)||row.recent< -1||row.recent>1)continue;if(row.kind){next->personal.push_back(row);next->explicitKeys.insert(canonicalLearningReading(row.reading)+char(31)+row.text);}else{auto reading=canonicalLearningReading(row.reading);next->scores[reading+char(31)+row.text]={row.frequency,row.pinned!=0,row.recent};auto compact=reading;compact.erase(std::remove(compact.begin(),compact.end(),' '),compact.end());next->spelling[compact].push_back({reading,row.text});}}MemoryBarrier();if(data->revision!=revision||(revision&1))return;previous=revision;cached=next;valid=enabled;}
};
}
void LearningReader::run(){if(refreshSettings)refreshSettings();if(preparePublic)preparePublic();if(!publicPath.empty()){auto model=std::make_shared<private_input::PublicContextModel>();if(model->load(publicPath)){std::shared_ptr<const private_input::PublicContextModel>frozen=model;std::atomic_store(&publicModel,std::move(frozen));}}uint64_t lastSettings=GetTickCount64();View legacy,cloud;HANDLE permissionHandle=nullptr;const CloudRankPermission*permission=nullptr;std::shared_ptr<const LearningSnapshot>published,previousCloud,previousLegacy;std::string previousToken;
 for(;;){{std::unique_lock<std::mutex>guard(lock);if(wake.wait_for(guard,std::chrono::milliseconds(250),[&]{return stopping;}))break;}if(refreshSettings&&GetTickCount64()-lastSettings>=1000){lastSettings=GetTickCount64();refreshSettings();}legacy.open(learningName());cloud.open(learningName()+L".cloud-v1");legacy.refresh();cloud.refresh();if(!permission){permissionHandle=OpenFileMappingW(FILE_MAP_READ,FALSE,cloudRankPermissionName().c_str());if(permissionHandle)permission=static_cast<const CloudRankPermission*>(MapViewOfFile(permissionHandle,FILE_MAP_READ,0,0,sizeof(CloudRankPermission)));if(!permission&&permissionHandle){CloseHandle(permissionHandle);permissionHandle=nullptr;}}
  std::string token;std::shared_ptr<const LearningSnapshot>chosen=legacy.cached;if(cloud.valid&&legacy.valid&&cloud.cached->scopeGeneration==legacy.cached->scopeGeneration&&cloudRankPermission(permission,token)){if(previousCloud!=cloud.cached||previousLegacy!=legacy.cached||previousToken!=token||!published||!published->cloudActive){auto next=std::make_shared<LearningSnapshot>(*cloud.cached);next->cloudActive=true;next->cloudToken=token;next->fallback=legacy.cached;chosen=next;previousCloud=cloud.cached;previousLegacy=legacy.cached;previousToken=token;}else chosen=published;}
  if(chosen!=published){published=chosen;std::atomic_store(&snapshot,std::move(chosen));}
 }
 if(permission)UnmapViewOfFile(permission);if(permissionHandle)CloseHandle(permissionHandle);
}
}
