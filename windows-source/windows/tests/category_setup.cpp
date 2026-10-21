#include "PrivateInputTSF.h"
#include <wrl/client.h>
#include <iostream>
#include <string>
using Microsoft::WRL::ComPtr;
int wmain(int argc,wchar_t **argv){
  if(argc!=2)return 2;std::wstring action=argv[1];
  if(action!=L"register-own-category"&&action!=L"restore-own-category"&&action!=L"prepare-own-profile"&&action!=L"restore-own-profile")return 2;
  HRESULT hr=CoInitializeEx(nullptr,COINIT_APARTMENTTHREADED);if(FAILED(hr))return 3;
  int result=1;
  {
    if(action==L"prepare-own-profile"||action==L"restore-own-profile"){
      ComPtr<ITfInputProcessorProfileMgr> profiles;hr=CoCreateInstance(CLSID_TF_InputProcessorProfiles,nullptr,CLSCTX_INPROC_SERVER,IID_PPV_ARGS(&profiles));
      constexpr LANGID language=MAKELANGID(LANG_CHINESE,SUBLANG_CHINESE_SIMPLIFIED);
      if(SUCCEEDED(hr)&&action==L"prepare-own-profile"){
        ComPtr<ITfInputProcessorProfiles> legacy;hr=profiles.As(&legacy);BSTR previous=nullptr;
        if(SUCCEEDED(hr)){HRESULT old=legacy->GetLanguageProfileDescription(CLSID_PrivateInput,language,GUID_PrivateInputProfile,&previous);
          if(old==S_OK&&previous&&std::wstring(previous)!=L"PrivateInput process-only acceptance")hr=E_ACCESSDENIED;
          if(previous)SysFreeString(previous);
        }
        const wchar_t description[]=L"PrivateInput process-only acceptance";
        if(SUCCEEDED(hr))hr=profiles->RegisterProfile(CLSID_PrivateInput,language,GUID_PrivateInputProfile,description,UINT(std::size(description)-1),L"",0,0,nullptr,0,FALSE,1);
      }else if(SUCCEEDED(hr)){
        ComPtr<ITfInputProcessorProfiles> legacy;hr=profiles.As(&legacy);BSTR description=nullptr;
        if(SUCCEEDED(hr)){HRESULT read=legacy->GetLanguageProfileDescription(CLSID_PrivateInput,language,GUID_PrivateInputProfile,&description);
          if(read==S_OK&&description&&std::wstring(description)==L"PrivateInput process-only acceptance")hr=profiles->UnregisterProfile(CLSID_PrivateInput,language,GUID_PrivateInputProfile,0);
          else hr=read==S_OK?E_ACCESSDENIED:S_OK;
          if(description)SysFreeString(description);
        }
      }
    }else{
      ComPtr<ITfCategoryMgr> manager;
      hr=CoCreateInstance(CLSID_TF_CategoryMgr,nullptr,CLSCTX_INPROC_SERVER,IID_PPV_ARGS(&manager));
      if(SUCCEEDED(hr))hr=action==L"register-own-category"?manager->RegisterCategory(CLSID_PrivateInput,GUID_TFCAT_TIP_KEYBOARD,CLSID_PrivateInput):manager->UnregisterCategory(CLSID_PrivateInput,GUID_TFCAT_TIP_KEYBOARD,CLSID_PrivateInput);
    }
    std::cout<<"{\"hresult\":"<<unsigned(hr)<<",\"onlyOwnCLSID\":true,\"defaultInputChanged\":false}\n";
    if(SUCCEEDED(hr))result=0;
  }
  CoUninitialize();return result;
}
