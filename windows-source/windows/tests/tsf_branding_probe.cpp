// Read-only icon/profile verification. Never registers, activates a TIP, changes
// input mode/defaults, opens user dictionaries/clipboard or starts a worker.
#include "../src/PrivateInputTSF.h"
#include "../src/TsfBranding.h"
#include <shellapi.h>
#include <wrl/client.h>
#include <iostream>
#include <filesystem>
using Microsoft::WRL::ComPtr;
int wmain(int argc,wchar_t**argv){
 if(argc!=3)return 2;const bool resourcesOnly=std::wstring(argv[1])==L"--resource-only";if(!resourcesOnly&&std::wstring(argv[1])!=L"--read-only")return 2;
 auto path=std::filesystem::absolute(argv[2]).lexically_normal().make_preferred();bool embedded=false,negativeIndex=false,ordinalZero=false,allSizes=true;
 HMODULE data=LoadLibraryExW(path.c_str(),nullptr,LOAD_LIBRARY_AS_DATAFILE_EXCLUSIVE|LOAD_LIBRARY_AS_IMAGE_RESOURCE);
 if(data){embedded=FindResourceW(data,MAKEINTRESOURCEW(linghe::tsf::BrandingIconResource),RT_GROUP_ICON)!=nullptr;for(int size:{16,20,24,32,40,48}){auto icon=static_cast<HICON>(LoadImageW(data,MAKEINTRESOURCEW(linghe::tsf::BrandingIconResource),IMAGE_ICON,size,size,0));allSizes=allSizes&&icon;if(icon)DestroyIcon(icon);}FreeLibrary(data);}else allSizes=false;
 // ExtractIconEx counts extracted handles, not requested groups. When both
 // large and small arrays are supplied, a successful group may return two.
 struct Extraction { UINT count; DWORD error; bool large; bool small; bool ok; };
 auto extract=[&](int index){HICON large=nullptr,small=nullptr;SetLastError(ERROR_SUCCESS);auto count=ExtractIconExW(path.c_str(),index,&large,&small,1);auto error=GetLastError();Extraction result{count,error,large!=nullptr,small!=nullptr,count>0&&count!=UINT_MAX&&large&&small};if(large)DestroyIcon(large);if(small)DestroyIcon(small);return result;};
 const auto negative=extract(static_cast<int>(static_cast<LONG>(linghe::tsf::BrandingProfileIconIndex))),ordinal=extract(0);negativeIndex=negative.ok;ordinalZero=ordinal.ok;
 bool profilePresent=false,systray=false,capsSystray=false,indexMatches=false,fileMatches=false;HRESULT initialized=E_FAIL;
 if(!resourcesOnly){initialized=CoInitializeEx(nullptr,COINIT_APARTMENTTHREADED);if(FAILED(initialized))return 2;
  {ComPtr<ITfInputProcessorProfileMgr>profiles;if(SUCCEEDED(CoCreateInstance(CLSID_TF_InputProcessorProfiles,nullptr,CLSCTX_INPROC_SERVER,IID_PPV_ARGS(&profiles)))){TF_INPUTPROCESSORPROFILE profile{};auto hr=profiles->GetProfile(TF_PROFILETYPE_INPUTPROCESSOR,MAKELANGID(LANG_CHINESE,SUBLANG_CHINESE_SIMPLIFIED),CLSID_PrivateInput,GUID_PrivateInputProfile,nullptr,&profile);profilePresent=SUCCEEDED(hr)&&profile.clsid==CLSID_PrivateInput&&profile.guidProfile==GUID_PrivateInputProfile;capsSystray=profilePresent&&(profile.dwCaps&linghe::tsf::SystrayProfileCapability);}
   ComPtr<ITfCategoryMgr>categories;if(SUCCEEDED(CoCreateInstance(CLSID_TF_CategoryMgr,nullptr,CLSCTX_INPROC_SERVER,IID_PPV_ARGS(&categories)))){ComPtr<IEnumGUID>items;if(SUCCEEDED(categories->EnumCategoriesInItem(CLSID_PrivateInput,&items))){GUID value{};ULONG fetched=0;while(items->Next(1,&value,&fetched)==S_OK&&fetched)if(value==linghe::tsf::SystrayCategory)systray=true;}}
  }
  wchar_t cls[39]{},profile[39]{};StringFromGUID2(CLSID_PrivateInput,cls,39);StringFromGUID2(GUID_PrivateInputProfile,profile,39);auto key=std::wstring(L"Software\\Microsoft\\CTF\\TIP\\")+cls+L"\\LanguageProfile\\0x00000804\\"+profile;HKEY h=nullptr;
  if(RegOpenKeyExW(HKEY_LOCAL_MACHINE,key.c_str(),0,KEY_QUERY_VALUE|KEY_WOW64_64KEY,&h)==ERROR_SUCCESS){DWORD index=0,type=0,size=sizeof(index);indexMatches=RegQueryValueExW(h,L"IconIndex",nullptr,&type,reinterpret_cast<BYTE*>(&index),&size)==ERROR_SUCCESS&&type==REG_DWORD&&size==sizeof(index)&&index==linghe::tsf::BrandingProfileIconIndex;wchar_t file[32768]{};size=sizeof(file);if(RegQueryValueExW(h,L"IconFile",nullptr,&type,reinterpret_cast<BYTE*>(file),&size)==ERROR_SUCCESS&&type==REG_SZ&&size>=sizeof(wchar_t)&&size%sizeof(wchar_t)==0&&file[size/sizeof(wchar_t)-1]==0){auto actual=std::filesystem::path(file).lexically_normal().make_preferred().wstring(),expected=path.wstring();fileMatches=CompareStringOrdinal(actual.data(),int(actual.size()),expected.data(),int(expected.size()),TRUE)==CSTR_EQUAL;}RegCloseKey(h);}
  CoUninitialize();
 }
 std::cout<<"{\"readOnly\":true,\"registrationWrites\":false,\"workerStarted\":false,\"resourceOnly\":"<<(resourcesOnly?"true":"false")<<",\"embeddedCraneResource\":"<<(embedded?"true":"false")<<",\"negativeResourceIndexExtracted\":"<<(negativeIndex?"true":"false")<<",\"ordinalZeroExtracted\":"<<(ordinalZero?"true":"false")<<",\"negativeRawCount\":"<<negative.count<<",\"negativeLastError\":"<<negative.error<<",\"negativeLargeHandle\":"<<(negative.large?"true":"false")<<",\"negativeSmallHandle\":"<<(negative.small?"true":"false")<<",\"ordinalRawCount\":"<<ordinal.count<<",\"ordinalLastError\":"<<ordinal.error<<",\"ordinalLargeHandle\":"<<(ordinal.large?"true":"false")<<",\"ordinalSmallHandle\":"<<(ordinal.small?"true":"false")<<",\"requestedSizesLoad\":"<<(allSizes?"true":"false")<<",\"profilePresent\":"<<(profilePresent?"true":"false")<<",\"systrayCategory\":"<<(systray?"true":"false")<<",\"profileCapsSystray\":"<<(capsSystray?"true":"false")<<",\"registeredIconIndexMatches\":"<<(indexMatches?"true":"false")<<",\"registeredIconFileMatchesArgument\":"<<(fileMatches?"true":"false")<<"}\n";
 return embedded&&negativeIndex&&allSizes&&(resourcesOnly||(profilePresent&&systray&&indexMatches&&fileMatches))?0:1;
}
