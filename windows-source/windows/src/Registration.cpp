#include "PrivateInputTSF.h"
#include "TsfBranding.h"
#include "RegistrationEnumeration.h"
#include <wrl/client.h>
#include <string>
#include <iterator>
using Microsoft::WRL::ComPtr;
namespace {
// Numeric stage only: no typed text, file paths or account details are exposed.
thread_local unsigned registrationStage=0;
thread_local private_input::registration::EnumerationDiagnostic registrationEnumeration;
template<class Match>HRESULT observeGuids(unsigned stage,HRESULT enumerationHR,IEnumGUID*items,Match match){
  registrationEnumeration=private_input::registration::enumerateGuids<GUID>(stage,static_cast<std::int32_t>(enumerationHR),items!=nullptr,
    [&](GUID&item,std::uint32_t&fetched){ULONG count=0;auto hr=items->Next(1,&item,&count);fetched=count;return static_cast<std::int32_t>(hr);},match);
  return static_cast<HRESULT>(registrationEnumeration.result());
}
constexpr LANGID Language = MAKELANGID(LANG_CHINESE, SUBLANG_CHINESE_SIMPLIFIED);
std::wstring classKey() {
  wchar_t id[64]; StringFromGUID2(CLSID_PrivateInput, id, 64);
  return std::wstring(L"Software\\Classes\\CLSID\\") + id;
}
HRESULT setValue(const std::wstring &path, const wchar_t *name, const std::wstring &value) {
  HKEY key = nullptr;
  LONG error = RegCreateKeyExW(HKEY_LOCAL_MACHINE, path.c_str(), 0, nullptr, 0, KEY_SET_VALUE | KEY_WOW64_64KEY, nullptr, &key, nullptr);
  if (error != ERROR_SUCCESS) return HRESULT_FROM_WIN32(error);
  error = RegSetValueExW(key, name, 0, REG_SZ, reinterpret_cast<const BYTE *>(value.c_str()), DWORD((value.size() + 1) * sizeof(wchar_t)));
  RegCloseKey(key); return HRESULT_FROM_WIN32(error);
}
bool hasKey(const std::wstring &path) {
  HKEY key=nullptr;LONG error=RegOpenKeyExW(HKEY_LOCAL_MACHINE,path.c_str(),0,KEY_READ|KEY_WOW64_64KEY,&key);
  if(error==ERROR_SUCCESS)RegCloseKey(key);
  return error==ERROR_SUCCESS;
}
HRESULT verifyExistingServer(const std::wstring &base,const std::wstring &path) {
  HKEY key=nullptr;LONG error=RegOpenKeyExW(HKEY_LOCAL_MACHINE,(base+L"\\InprocServer32").c_str(),0,KEY_QUERY_VALUE|KEY_WOW64_64KEY,&key);
  if(error!=ERROR_SUCCESS)return HRESULT_FROM_WIN32(error);
  wchar_t value[32768];DWORD type=0,size=sizeof(value);
  error=RegQueryValueExW(key,nullptr,nullptr,&type,reinterpret_cast<BYTE*>(value),&size);RegCloseKey(key);
  if(error!=ERROR_SUCCESS||type!=REG_SZ||size<sizeof(wchar_t)||value[size/sizeof(wchar_t)-1]!=0)return E_ACCESSDENIED;
  // Win32's module path normalizes separators, whereas a filesystem path
  // assembled by an installer may contain '/'. Compare normalized path syntax
  // while retaining the same exact server identity requirement.
  auto stored=std::filesystem::path(value).lexically_normal().make_preferred().wstring();
  auto expected=std::filesystem::path(path).lexically_normal().make_preferred().wstring();
  return _wcsicmp(stored.c_str(),expected.c_str())==0?S_OK:E_ACCESSDENIED;
}
void deleteNewClass(const std::wstring &base) {
  HKEY classes=nullptr;if(RegOpenKeyExW(HKEY_LOCAL_MACHINE,L"Software\\Classes\\CLSID",0,KEY_WRITE|KEY_WOW64_64KEY,&classes)==ERROR_SUCCESS){RegDeleteTreeW(classes,base.substr(base.find_last_of(L'\\')+1).c_str());RegCloseKey(classes);}
}
class Factory final : public IClassFactory {
  std::atomic<ULONG> refs{1};
public:
  Factory() { ++g_objects; } ~Factory() { --g_objects; }
  STDMETHODIMP QueryInterface(REFIID iid, void **out) override {
    if (!out) return E_POINTER; *out = nullptr;
    if (iid != IID_IUnknown && iid != IID_IClassFactory) return E_NOINTERFACE;
    *out = static_cast<IClassFactory *>(this); AddRef(); return S_OK;
  }
  STDMETHODIMP_(ULONG) AddRef() override { return ++refs; }
  STDMETHODIMP_(ULONG) Release() override { auto n = --refs; if (!n) delete this; return n; }
  STDMETHODIMP CreateInstance(IUnknown *outer, REFIID iid, void **result) override {
    if (outer) return CLASS_E_NOAGGREGATION; return CreatePrivateInput(iid, result);
  }
  STDMETHODIMP LockServer(BOOL lock) override { if (lock) ++g_serverLocks; else if (g_serverLocks > 0) --g_serverLocks; return S_OK; }
};
}
extern "C" HRESULT __stdcall DllCanUnloadNow() { return g_objects == 0 && g_serverLocks == 0 ? S_OK : S_FALSE; }
extern "C" HRESULT __stdcall DllGetClassObject(REFCLSID clsid, REFIID iid, void **result) {
  if (clsid != CLSID_PrivateInput) return CLASS_E_CLASSNOTAVAILABLE;
  auto *factory = new Factory; auto hr = factory->QueryInterface(iid, result); factory->Release(); return hr;
}
extern "C" HRESULT __stdcall DllRegisterServer() {
  registrationEnumeration={};
  registrationStage=1;
  wchar_t path[32768];DWORD length=GetModuleFileNameW(g_instance,path,32768);if(!length||length>=32768)return HRESULT_FROM_WIN32(ERROR_FILENAME_EXCED_RANGE);
  // Registration must not advertise branding without its actual DLL resource.
  auto icon=static_cast<HICON>(LoadImageW(g_instance,MAKEINTRESOURCEW(linghe::tsf::BrandingIconResource),IMAGE_ICON,16,16,0));
  if(!icon)return HRESULT_FROM_WIN32(GetLastError()?GetLastError():ERROR_RESOURCE_NAME_NOT_FOUND);DestroyIcon(icon);
  const auto base = classKey();
  const bool existingClass=hasKey(base);
  registrationStage=2;
  if(existingClass){HRESULT verified=verifyExistingServer(base,path);if(FAILED(verified))return verified;}
  ComPtr<ITfInputProcessorProfiles> profiles;
  registrationStage=3;
  HRESULT hr = CoCreateInstance(CLSID_TF_InputProcessorProfiles, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&profiles));
  if (FAILED(hr)) return hr;
  registrationStage=4;
  ComPtr<IEnumGUID> services;hr=profiles->EnumInputProcessorInfo(&services);
  hr=observeGuids(4,hr,services.Get(),[](const GUID&item){return item==CLSID_PrivateInput?1u:0u;});if(FAILED(hr))return hr;
  const bool serviceBefore=(registrationEnumeration.matches&1)!=0;
  registrationStage=5;
  BSTR description=nullptr;HRESULT found=profiles->GetLanguageProfileDescription(CLSID_PrivateInput,Language,GUID_PrivateInputProfile,&description);
  bool profileBefore=found==S_OK;
  bool ownDescription=!profileBefore||(description&&(std::wstring(description)==L"灵鹤输入法"||std::wstring(description)==L"私享输入"));if(description)SysFreeString(description);
  if(!ownDescription)return E_ACCESSDENIED;
  // Preserve the calling original user's enabled choice before any mutation.
  // Installer orchestration must bind this context to the captured user SID;
  // an alternate administrator's preferences are not the installing user's.
  BOOL profileEnabledBefore=TRUE;
  if(profileBefore){
    hr=profiles->IsEnabledLanguageProfile(CLSID_PrivateInput,Language,GUID_PrivateInputProfile,&profileEnabledBefore);
    if(FAILED(hr))return hr;
  }
  ComPtr<ITfCategoryMgr> categories;
  registrationStage=6;
  hr = CoCreateInstance(CLSID_TF_CategoryMgr, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&categories));
  if(FAILED(hr))return hr;
  registrationStage=7;
  ComPtr<IEnumGUID> list;hr=categories->EnumCategoriesInItem(CLSID_PrivateInput,&list);
  hr=observeGuids(7,hr,list.Get(),[](const GUID&item){return (item==GUID_TFCAT_TIP_KEYBOARD?1u:0u)|(item==linghe::tsf::SystrayCategory?2u:0u);});if(FAILED(hr))return hr;
  const bool categoryBefore=(registrationEnumeration.matches&1)!=0,systrayBefore=(registrationEnumeration.matches&2)!=0;
  bool addedService=false,addedCategory=false,addedSystray=false,addedProfile=false;
  auto rollback=[&]{if(addedProfile){ComPtr<ITfInputProcessorProfileMgr> mgr;if(SUCCEEDED(profiles.As(&mgr)))mgr->UnregisterProfile(CLSID_PrivateInput,Language,GUID_PrivateInputProfile,0);}if(addedSystray)categories->UnregisterCategory(CLSID_PrivateInput,linghe::tsf::SystrayCategory,CLSID_PrivateInput);if(addedCategory)categories->UnregisterCategory(CLSID_PrivateInput,GUID_TFCAT_TIP_KEYBOARD,CLSID_PrivateInput);if(addedService)profiles->Unregister(CLSID_PrivateInput);if(!existingClass)deleteNewClass(base);};
  registrationStage=8;
  if(!existingClass){hr=setValue(base,nullptr,L"灵鹤输入法");if(SUCCEEDED(hr))hr=setValue(base+L"\\InprocServer32",nullptr,path);if(SUCCEEDED(hr))hr=setValue(base+L"\\InprocServer32",L"ThreadingModel",L"Apartment");if(FAILED(hr)){rollback();return hr;}}
  registrationStage=9;
  if(!serviceBefore){addedService=true;hr=profiles->Register(CLSID_PrivateInput);if(FAILED(hr)){rollback();return hr;}}
  registrationStage=10;
  if(!categoryBefore){addedCategory=true;hr=categories->RegisterCategory(CLSID_PrivateInput,GUID_TFCAT_TIP_KEYBOARD,CLSID_PrivateInput);if(FAILED(hr)){rollback();return hr;}}
  registrationStage=13;
  if(!systrayBefore){addedSystray=true;hr=categories->RegisterCategory(CLSID_PrivateInput,linghe::tsf::SystrayCategory,CLSID_PrivateInput);if(FAILED(hr)){rollback();return hr;}}
  registrationStage=11;
  {
    // An owned existing profile also needs refreshed description/icon metadata.
    // Skipping it forever left IconFile pointing at a historical version.
    ComPtr<ITfInputProcessorProfileMgr> mgr;hr=profiles.As(&mgr);const wchar_t name[]=L"灵鹤输入法";
    if(SUCCEEDED(hr)){
      addedProfile=!profileBefore;
      hr=mgr->RegisterProfile(CLSID_PrivateInput,Language,GUID_PrivateInputProfile,
                             name,UINT(std::size(name)-1),path,length,linghe::tsf::BrandingProfileIconIndex,nullptr,0,
                             profileEnabledBefore,0);
    }
    // Only a newly created profile is removed by local rollback. The installer's
    // full owned snapshot remains responsible for existing-metadata rollback.
    if(FAILED(hr)){rollback();return hr;}
  }
  // Treat COM success as provisional until the profile is readable through
  // the same public TSF APIs used by the system language configuration.
  registrationStage=12;
  BSTR verifiedDescription=nullptr;
  hr=profiles->GetLanguageProfileDescription(CLSID_PrivateInput,Language,GUID_PrivateInputProfile,&verifiedDescription);
  const bool exactDescription=SUCCEEDED(hr)&&verifiedDescription&&std::wstring(verifiedDescription)==L"灵鹤输入法";
  if(verifiedDescription)SysFreeString(verifiedDescription);
  if(!exactDescription){rollback();return FAILED(hr)?hr:E_FAIL;}
  BOOL verifiedEnabled=FALSE;
  hr=profiles->IsEnabledLanguageProfile(CLSID_PrivateInput,Language,GUID_PrivateInputProfile,&verifiedEnabled);
  if(FAILED(hr)||verifiedEnabled!=profileEnabledBefore){rollback();return FAILED(hr)?hr:E_FAIL;}
  ComPtr<ITfInputProcessorProfileMgr> verifiedManager;hr=profiles.As(&verifiedManager);
  TF_INPUTPROCESSORPROFILE verifiedProfile{};
  if(SUCCEEDED(hr))hr=verifiedManager->GetProfile(TF_PROFILETYPE_INPUTPROCESSOR,Language,CLSID_PrivateInput,GUID_PrivateInputProfile,nullptr,&verifiedProfile);
  if(FAILED(hr)||verifiedProfile.clsid!=CLSID_PrivateInput||verifiedProfile.guidProfile!=GUID_PrivateInputProfile||verifiedProfile.langid!=Language){rollback();return FAILED(hr)?hr:E_FAIL;}
  // Category registration, not a blanket Windows-app compatibility claim,
  // enables branding in the desktop input indicator. Read back exact own caps.
  registrationStage=14;ComPtr<IEnumGUID>verifiedCategories;hr=categories->EnumCategoriesInItem(CLSID_PrivateInput,&verifiedCategories);
  // On the target PC this process retains the pre-registration catalog view
  // even after a fresh COM object, while a new OS process sees the category.
  // Keep exact observation diagnostics, but do not turn successful mutations
  // into a false rollback based on this process's view. Setup performs a fresh
  // process catalog check inside its existing rollback transaction.
  (void)observeGuids(14,hr,verifiedCategories.Get(),[](const GUID&item){return item==linghe::tsf::SystrayCategory?2u:0u;});
  registrationStage=0;
  return S_OK; // User chooses this keyboard. Do not set the default input source.
}
extern "C" unsigned __stdcall DllGetRegistrationDiagnostic() { return registrationStage; }
extern "C" HRESULT __stdcall DllGetRegistrationEnumerationDiagnostic(private_input::registration::EnumerationDiagnostic*output) {
  return static_cast<HRESULT>(private_input::registration::copyEnumerationDiagnostic(registrationEnumeration,output));
}
extern "C" HRESULT __stdcall DllUnregisterServer() {
  registrationStage=0;registrationEnumeration={};
  wchar_t path[32768];DWORD length=GetModuleFileNameW(g_instance,path,32768);if(!length||length>=32768)return E_FAIL;
  const auto base=classKey();HRESULT verified=verifyExistingServer(base,path);if(FAILED(verified))return verified;
  ComPtr<ITfInputProcessorProfiles> profiles;
  HRESULT hr = CoCreateInstance(CLSID_TF_InputProcessorProfiles, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&profiles));
  if(FAILED(hr))return hr;
  ComPtr<ITfCategoryMgr> categories;
  hr=CoCreateInstance(CLSID_TF_CategoryMgr,nullptr,CLSCTX_INPROC_SERVER,IID_PPV_ARGS(&categories));if(FAILED(hr))return hr;
  ComPtr<IEnumGUID>ownedCategories;hr=categories->EnumCategoriesInItem(CLSID_PrivateInput,&ownedCategories);
  hr=observeGuids(15,hr,ownedCategories.Get(),[](const GUID&item){return item==linghe::tsf::SystrayCategory?2u:0u;});if(FAILED(hr))return hr;
  const bool hasSystray=(registrationEnumeration.matches&2)!=0;
  if(hasSystray){hr=categories->UnregisterCategory(CLSID_PrivateInput,linghe::tsf::SystrayCategory,CLSID_PrivateInput);if(FAILED(hr))return hr;}
  hr=categories->UnregisterCategory(CLSID_PrivateInput,GUID_TFCAT_TIP_KEYBOARD,CLSID_PrivateInput);if(FAILED(hr))return hr;
  hr=profiles->Unregister(CLSID_PrivateInput);if(FAILED(hr))return hr;
  deleteNewClass(base);return hasKey(base)?E_FAIL:S_OK;
}
