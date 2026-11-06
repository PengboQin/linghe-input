#pragma once
#include <windows.h>
#include <msctf.h>
#include <wrl/client.h>
#include <string>
#include "../src/PrivateInputTSF.h"
#include "../src/TsfBranding.h"
#include "../src/RegistrationEnumeration.h"

namespace linghe::installer {
inline constexpr wchar_t ProfileProbe[] = L"--verify-owned-tsf-profile";
inline constexpr wchar_t KeyboardProbe[] = L"--verify-owned-tsf-keyboard";
inline constexpr wchar_t SystrayProbe[] = L"--verify-owned-tsf-systray";

inline HRESULT verifyOwnedProfileDescription(LANGID language) {
 Microsoft::WRL::ComPtr<ITfInputProcessorProfiles> profiles;
 auto hr=CoCreateInstance(CLSID_TF_InputProcessorProfiles,nullptr,CLSCTX_INPROC_SERVER,IID_PPV_ARGS(&profiles));
 if(FAILED(hr))return hr;
 BSTR description=nullptr;
 hr=profiles->GetLanguageProfileDescription(CLSID_PrivateInput,language,GUID_PrivateInputProfile,&description);
 const bool owned=hr==S_OK&&description&&std::wstring(description)==L"灵鹤输入法";
 SysFreeString(description);
 return owned?S_OK:FAILED(hr)?hr:HRESULT_FROM_WIN32(ERROR_NOT_FOUND);
}

// Read-only probes run in new processes so TSF can see the updated registration.
inline HRESULT ownedRegistrationProfileStatus() {
 Microsoft::WRL::ComPtr<ITfInputProcessorProfileMgr> profiles;
 HRESULT hr=CoCreateInstance(CLSID_TF_InputProcessorProfiles,nullptr,CLSCTX_INPROC_SERVER,IID_PPV_ARGS(&profiles));
 if(FAILED(hr))return hr;
 const LANGID language=MAKELANGID(LANG_CHINESE,SUBLANG_CHINESE_SIMPLIFIED);
 const auto ownsProfile=[&](const TF_INPUTPROCESSORPROFILE& profile){
  return profile.dwProfileType==TF_PROFILETYPE_INPUTPROCESSOR&&profile.clsid==CLSID_PrivateInput&&
         profile.guidProfile==GUID_PrivateInputProfile&&profile.langid==language;
 };
 TF_INPUTPROCESSORPROFILE profile{};
 hr=profiles->GetProfile(TF_PROFILETYPE_INPUTPROCESSOR,language,CLSID_PrivateInput,GUID_PrivateInputProfile,nullptr,&profile);
 if(SUCCEEDED(hr))return ownsProfile(profile)?S_OK:E_UNEXPECTED;
 if(hr!=E_FAIL&&hr!=HRESULT_FROM_WIN32(ERROR_NOT_FOUND))return hr;
 Microsoft::WRL::ComPtr<IEnumTfInputProcessorProfiles> entries;
 hr=profiles->EnumProfiles(language,&entries);
 if(hr==E_FAIL)return verifyOwnedProfileDescription(language);
 if(FAILED(hr))return hr;
 if(!entries)return E_UNEXPECTED;
 for(;;){
  ULONG fetched=0;
  hr=entries->Next(1,&profile,&fetched);
  if(FAILED(hr))return hr;
  if(hr==S_FALSE&&fetched==0)return verifyOwnedProfileDescription(language);
  if(hr!=S_OK||fetched!=1)return E_UNEXPECTED;
  if(ownsProfile(profile))return S_OK;
 }
}

inline HRESULT ownedRegistrationCategoryStatus(const GUID& expected) {
 Microsoft::WRL::ComPtr<ITfCategoryMgr> categories;
 HRESULT hr=CoCreateInstance(CLSID_TF_CategoryMgr,nullptr,CLSCTX_INPROC_SERVER,IID_PPV_ARGS(&categories));
 if(FAILED(hr))return hr;
 GUID match{};
 const GUID* allowed[]={&expected};
 hr=categories->FindClosestCategory(CLSID_PrivateInput,&match,allowed,1);
 if(SUCCEEDED(hr)&&match==expected)return S_OK;
 if(FAILED(hr)&&hr!=E_FAIL&&hr!=HRESULT_FROM_WIN32(ERROR_NOT_FOUND))return hr;
 Microsoft::WRL::ComPtr<IEnumGUID> items;
 hr=categories->EnumCategoriesInItem(CLSID_PrivateInput,&items);
 auto observed=private_input::registration::enumerateGuids<GUID>(14,static_cast<std::int32_t>(hr),items!=nullptr,
  [&](GUID&item,std::uint32_t&fetched){ULONG count=0;auto next=items->Next(1,&item,&count);fetched=count;return static_cast<std::int32_t>(next);},
  [&](const GUID&item){return item==expected?1u:0u;});
 hr=static_cast<HRESULT>(observed.result());
  if(SUCCEEDED(hr)&&observed.matches==1)return S_OK;
  if(FAILED(hr)&&hr!=E_FAIL&&hr!=HRESULT_FROM_WIN32(ERROR_NOT_FOUND))return hr;
  // The category API also exposes the reverse index. Require an exact owned
  // CLSID there if the item-to-category view is unavailable or incomplete.
  items.Reset();
  hr=categories->EnumItemsInCategory(expected,&items);
  auto reverse=private_input::registration::enumerateGuids<GUID>(14,static_cast<std::int32_t>(hr),items!=nullptr,
   [&](GUID&item,std::uint32_t&fetched){ULONG count=0;auto next=items->Next(1,&item,&count);fetched=count;return static_cast<std::int32_t>(next);},
   [](const GUID&item){return item==CLSID_PrivateInput?1u:0u;});
  hr=static_cast<HRESULT>(reverse.result());
  return FAILED(hr)?hr:reverse.matches==1?S_OK:HRESULT_FROM_WIN32(ERROR_NOT_FOUND);
}

inline HRESULT runRegistrationProbe(const std::wstring& executable,const wchar_t* probe) {
  std::wstring command=L"\""+executable+L"\" "+probe;
  STARTUPINFOW startup{};startup.cb=sizeof(startup);startup.dwFlags=STARTF_USESHOWWINDOW;startup.wShowWindow=SW_HIDE;
  PROCESS_INFORMATION process{};
  if(!CreateProcessW(executable.c_str(),command.data(),nullptr,nullptr,FALSE,CREATE_NO_WINDOW,nullptr,nullptr,&startup,&process))return HRESULT_FROM_WIN32(GetLastError());
  CloseHandle(process.hThread);
  const auto wait=WaitForSingleObject(process.hProcess,5000);
  DWORD code=static_cast<DWORD>(E_FAIL);
  if(wait==WAIT_OBJECT_0){if(!GetExitCodeProcess(process.hProcess,&code)){const auto error=GetLastError();CloseHandle(process.hProcess);return HRESULT_FROM_WIN32(error);}}
  else {TerminateProcess(process.hProcess,ERROR_TIMEOUT);WaitForSingleObject(process.hProcess,1000);CloseHandle(process.hProcess);return HRESULT_FROM_WIN32(ERROR_TIMEOUT);}
  CloseHandle(process.hProcess);
  return static_cast<HRESULT>(private_input::registration::catalogChildExitResult(code));
}
}
