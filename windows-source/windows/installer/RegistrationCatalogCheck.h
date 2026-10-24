#pragma once
#include <windows.h>
#include <msctf.h>
#include <wrl/client.h>
#include <string>
#include "../src/PrivateInputTSF.h"
#include "../src/TsfBranding.h"
#include "../src/RegistrationEnumeration.h"

namespace linghe::installer {
// Read only. The installer invokes this in a NEW process, before treating the
// product transaction as committed. No profile/default/source is changed here.
inline HRESULT ownedRegistrationCatalogStatus() {
 Microsoft::WRL::ComPtr<ITfInputProcessorProfileMgr> profiles;
 HRESULT hr=CoCreateInstance(CLSID_TF_InputProcessorProfiles,nullptr,CLSCTX_INPROC_SERVER,IID_PPV_ARGS(&profiles));
 if(FAILED(hr))return hr;
 const LANGID language=MAKELANGID(LANG_CHINESE,SUBLANG_CHINESE_SIMPLIFIED);
 TF_INPUTPROCESSORPROFILE profile{};
 hr=profiles->GetProfile(TF_PROFILETYPE_INPUTPROCESSOR,language,CLSID_PrivateInput,GUID_PrivateInputProfile,nullptr,&profile);
 if(FAILED(hr))return hr;
 if(profile.clsid!=CLSID_PrivateInput||profile.guidProfile!=GUID_PrivateInputProfile||profile.langid!=language)return E_UNEXPECTED;
 Microsoft::WRL::ComPtr<ITfCategoryMgr> categories;
 hr=CoCreateInstance(CLSID_TF_CategoryMgr,nullptr,CLSCTX_INPROC_SERVER,IID_PPV_ARGS(&categories));
 if(FAILED(hr))return hr;
 Microsoft::WRL::ComPtr<IEnumGUID> items;
 hr=categories->EnumCategoriesInItem(CLSID_PrivateInput,&items);
 auto observed=private_input::registration::enumerateGuids<GUID>(14,static_cast<std::int32_t>(hr),items!=nullptr,
  [&](GUID&item,std::uint32_t&fetched){ULONG count=0;auto next=items->Next(1,&item,&count);fetched=count;return static_cast<std::int32_t>(next);},
  [](const GUID&item){return (item==GUID_TFCAT_TIP_KEYBOARD?1u:0u)|(item==linghe::tsf::SystrayCategory?2u:0u);});
 hr=static_cast<HRESULT>(observed.result());
 if(FAILED(hr))return hr;
 return (observed.matches&3)==3?S_OK:HRESULT_FROM_WIN32(ERROR_NOT_FOUND);
}

// One fixed, read-only mode of this exact executable. No generic command,
// arbitrary DLL path, elevated shell or persistent helper is exposed.
inline HRESULT verifyRegistrationInFreshProcess(const std::wstring&executable) {
 for(unsigned attempt=0;attempt<2;++attempt){
  if(attempt)Sleep(1500);
  std::wstring command=L"\""+executable+L"\" --verify-owned-tsf-catalog";
  STARTUPINFOW startup{};startup.cb=sizeof(startup);startup.dwFlags=STARTF_USESHOWWINDOW;startup.wShowWindow=SW_HIDE;
  PROCESS_INFORMATION process{};
  if(!CreateProcessW(executable.c_str(),command.data(),nullptr,nullptr,FALSE,CREATE_NO_WINDOW,nullptr,nullptr,&startup,&process))return HRESULT_FROM_WIN32(GetLastError());
  CloseHandle(process.hThread);
  const auto wait=WaitForSingleObject(process.hProcess,5000);
  DWORD code=static_cast<DWORD>(E_FAIL);
  if(wait==WAIT_OBJECT_0){if(!GetExitCodeProcess(process.hProcess,&code)){const auto error=GetLastError();CloseHandle(process.hProcess);return HRESULT_FROM_WIN32(error);}}
  else {TerminateProcess(process.hProcess,ERROR_TIMEOUT);WaitForSingleObject(process.hProcess,1000);CloseHandle(process.hProcess);return HRESULT_FROM_WIN32(ERROR_TIMEOUT);}
  CloseHandle(process.hProcess);
  if(code==0)return S_OK;
  const auto status=static_cast<HRESULT>(private_input::registration::catalogChildExitResult(code));
  // A catalog miss gets one fixed follow-up. Process faults, policy denials
  // and actual API errors are failures, not reasons to relaunch the program.
  if(attempt||status!=HRESULT_FROM_WIN32(ERROR_NOT_FOUND))return status;
 }
 return E_FAIL;
}
}
