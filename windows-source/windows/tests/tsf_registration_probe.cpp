// Read-only native acceptance helper. No registration, source switching, worker,
// clipboard, user text, security-policy changes or network access.
#include "../src/PrivateInputTSF.h"
#include <wrl/client.h>
#include <iostream>
using Microsoft::WRL::ComPtr;
int main(){
 HRESULT initialized=CoInitializeEx(nullptr,COINIT_APARTMENTTHREADED);
 if(FAILED(initialized))return 2;
 bool present=false,description=false,enabled=false,category=false;
 HRESULT result=E_FAIL;
 {
  ComPtr<ITfInputProcessorProfiles> profiles;
  result=CoCreateInstance(CLSID_TF_InputProcessorProfiles,nullptr,CLSCTX_INPROC_SERVER,IID_PPV_ARGS(&profiles));
  if(SUCCEEDED(result)){
   const LANGID language=MAKELANGID(LANG_CHINESE,SUBLANG_CHINESE_SIMPLIFIED);
   BSTR name=nullptr;
   auto hr=profiles->GetLanguageProfileDescription(CLSID_PrivateInput,language,GUID_PrivateInputProfile,&name);
   description=SUCCEEDED(hr)&&name&&std::wstring(name)==L"灵鹤输入法";
   if(name)SysFreeString(name);
   BOOL value=FALSE;hr=profiles->IsEnabledLanguageProfile(CLSID_PrivateInput,language,GUID_PrivateInputProfile,&value);
   enabled=SUCCEEDED(hr)&&value;
   ComPtr<ITfInputProcessorProfileMgr> manager;
   TF_INPUTPROCESSORPROFILE profile{};
   hr=profiles.As(&manager);
   if(SUCCEEDED(hr))hr=manager->GetProfile(TF_PROFILETYPE_INPUTPROCESSOR,language,CLSID_PrivateInput,GUID_PrivateInputProfile,nullptr,&profile);
   present=SUCCEEDED(hr)&&profile.clsid==CLSID_PrivateInput&&profile.guidProfile==GUID_PrivateInputProfile&&profile.langid==language;
   ComPtr<ITfCategoryMgr> categories;
   hr=CoCreateInstance(CLSID_TF_CategoryMgr,nullptr,CLSCTX_INPROC_SERVER,IID_PPV_ARGS(&categories));
   if(SUCCEEDED(hr)){
    ComPtr<IEnumGUID> list;hr=categories->EnumCategoriesInItem(CLSID_PrivateInput,&list);
    GUID item{};ULONG fetched=0;
    if(SUCCEEDED(hr))while(list->Next(1,&item,&fetched)==S_OK&&fetched)if(item==GUID_TFCAT_TIP_KEYBOARD)category=true;
   }
  }
 }
 CoUninitialize();
 std::cout<<"{\"readOnly\":true,\"profilePresent\":"<<(present?"true":"false")
          <<",\"descriptionMatches\":"<<(description?"true":"false")
          <<",\"enabled\":"<<(enabled?"true":"false")
          <<",\"keyboardCategory\":"<<(category?"true":"false")<<"}\n";
 return present&&description&&category?0:1;
}
