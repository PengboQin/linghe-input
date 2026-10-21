#include "PrivateInputTSF.h"
#include <wrl/client.h>
#include <iostream>
using Microsoft::WRL::ComPtr;
namespace {
void status(const char* stage,HRESULT hr) {
  std::cout<<"{\"stage\":\""<<stage<<"\",\"hresult\":"<<static_cast<unsigned long>(hr)<<"}\n";
}
void categories(ITfCategoryMgr* manager,REFGUID id,const char* stage) {
  ComPtr<IEnumGUID> list;HRESULT hr=manager->EnumCategoriesInItem(id,&list);status(stage,hr);
  if(SUCCEEDED(hr)&&list){GUID value{};ULONG fetched=0;unsigned count=0;bool keyboard=false;
    do{hr=list->Next(1,&value,&fetched);if(hr==S_OK&&fetched){++count;if(value==GUID_TFCAT_TIP_KEYBOARD)keyboard=true;}}while(hr==S_OK&&fetched);
    std::cout<<"{\"stage\":\""<<stage<<".items\",\"hresult\":"<<static_cast<unsigned long>(hr)<<",\"count\":"<<count<<",\"keyboard\":"<<(keyboard?"true":"false")<<"}\n";
  }
}
}
int main() {
  DWORD session=0;ProcessIdToSessionId(GetCurrentProcessId(),&session);
  std::cout<<"{\"readOnly\":true,\"session\":"<<session<<",\"registrationWrites\":false,\"securityChanges\":false}\n";
  HRESULT hr=CoInitializeEx(nullptr,COINIT_APARTMENTTHREADED);status("CoInitializeEx",hr);if(FAILED(hr))return 2;
  {
    ComPtr<ITfInputProcessorProfiles> profiles;hr=CoCreateInstance(CLSID_TF_InputProcessorProfiles,nullptr,CLSCTX_INPROC_SERVER,IID_PPV_ARGS(&profiles));status("createProfiles",hr);
    if(SUCCEEDED(hr)){
      ComPtr<IEnumGUID> services;hr=profiles->EnumInputProcessorInfo(&services);status("enumServices",hr);
      if(SUCCEEDED(hr)&&services){GUID value{};ULONG fetched=0;bool own=false;do{hr=services->Next(1,&value,&fetched);if(hr==S_OK&&fetched&&value==CLSID_PrivateInput)own=true;}while(hr==S_OK&&fetched);
        std::cout<<"{\"stage\":\"enumServices.items\",\"hresult\":"<<static_cast<unsigned long>(hr)<<",\"ownRegistered\":"<<(own?"true":"false")<<"}\n";
      }
      BSTR description=nullptr;hr=profiles->GetLanguageProfileDescription(CLSID_PrivateInput,MAKELANGID(LANG_CHINESE,SUBLANG_CHINESE_SIMPLIFIED),GUID_PrivateInputProfile,&description);status("getOwnProfile",hr);if(description)SysFreeString(description);
    }
    ComPtr<ITfCategoryMgr> manager;hr=CoCreateInstance(CLSID_TF_CategoryMgr,nullptr,CLSCTX_INPROC_SERVER,IID_PPV_ARGS(&manager));status("createCategories",hr);
    if(SUCCEEDED(hr)){categories(manager.Get(),CLSID_PrivateInput,"enumOwnCategories");categories(manager.Get(),GUID_PrivateInputProfile,"enumAbsentCategories");}
  }
  CoUninitialize();return 0;
}
