#include "PrivateInputTSF.h"
#include <wrl/client.h>
#include <string>
#include <iterator>
using Microsoft::WRL::ComPtr;
namespace {
// Numeric stage only: no typed text, file paths or account details are exposed.
thread_local unsigned registrationStage=0;
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
  registrationStage=1;
  wchar_t path[32768];DWORD length=GetModuleFileNameW(g_instance,path,32768);if(!length||length>=32768)return HRESULT_FROM_WIN32(ERROR_FILENAME_EXCED_RANGE);
  const auto base = classKey();
  const bool existingClass=hasKey(base);
  registrationStage=2;
  if(existingClass){HRESULT verified=verifyExistingServer(base,path);if(FAILED(verified))return verified;}
  ComPtr<ITfInputProcessorProfiles> profiles;
  registrationStage=3;
  HRESULT hr = CoCreateInstance(CLSID_TF_InputProcessorProfiles, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&profiles));
  if (FAILED(hr)) return hr;
  registrationStage=4;
  ComPtr<IEnumGUID> services;hr=profiles->EnumInputProcessorInfo(&services);if(FAILED(hr))return hr;
  bool serviceBefore=false;GUID item{};ULONG fetched=0;while(services->Next(1,&item,&fetched)==S_OK&&fetched)if(item==CLSID_PrivateInput)serviceBefore=true;
  registrationStage=5;
  BSTR description=nullptr;HRESULT found=profiles->GetLanguageProfileDescription(CLSID_PrivateInput,Language,GUID_PrivateInputProfile,&description);
  bool profileBefore=found==S_OK;
  bool ownDescription=!profileBefore||(description&&(std::wstring(description)==L"灵鹤输入法"||std::wstring(description)==L"私享输入"));if(description)SysFreeString(description);
  if(!ownDescription)return E_ACCESSDENIED;
  ComPtr<ITfCategoryMgr> categories;
  registrationStage=6;
  hr = CoCreateInstance(CLSID_TF_CategoryMgr, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&categories));
  if(FAILED(hr))return hr;
  registrationStage=7;
  ComPtr<IEnumGUID> list;hr=categories->EnumCategoriesInItem(CLSID_PrivateInput,&list);if(FAILED(hr))return hr;
  bool categoryBefore=false;while(list->Next(1,&item,&fetched)==S_OK&&fetched)if(item==GUID_TFCAT_TIP_KEYBOARD)categoryBefore=true;
  bool addedService=false,addedCategory=false,addedProfile=false;
  auto rollback=[&]{if(addedProfile){ComPtr<ITfInputProcessorProfileMgr> mgr;if(SUCCEEDED(profiles.As(&mgr)))mgr->UnregisterProfile(CLSID_PrivateInput,Language,GUID_PrivateInputProfile,0);}if(addedCategory)categories->UnregisterCategory(CLSID_PrivateInput,GUID_TFCAT_TIP_KEYBOARD,CLSID_PrivateInput);if(addedService)profiles->Unregister(CLSID_PrivateInput);if(!existingClass)deleteNewClass(base);};
  registrationStage=8;
  if(!existingClass){hr=setValue(base,nullptr,L"灵鹤输入法");if(SUCCEEDED(hr))hr=setValue(base+L"\\InprocServer32",nullptr,path);if(SUCCEEDED(hr))hr=setValue(base+L"\\InprocServer32",L"ThreadingModel",L"Apartment");if(FAILED(hr)){rollback();return hr;}}
  registrationStage=9;
  if(!serviceBefore){addedService=true;hr=profiles->Register(CLSID_PrivateInput);if(FAILED(hr)){rollback();return hr;}}
  registrationStage=10;
  if(!categoryBefore){addedCategory=true;hr=categories->RegisterCategory(CLSID_PrivateInput,GUID_TFCAT_TIP_KEYBOARD,CLSID_PrivateInput);if(FAILED(hr)){rollback();return hr;}}
  registrationStage=11;
  if(!profileBefore){ComPtr<ITfInputProcessorProfileMgr> mgr;hr=profiles.As(&mgr);const wchar_t name[]=L"灵鹤输入法";
    if(SUCCEEDED(hr)){addedProfile=true;hr=mgr->RegisterProfile(CLSID_PrivateInput,Language,GUID_PrivateInputProfile,name,UINT(std::size(name)-1),path,length,0,nullptr,0,TRUE,0);}
    if(FAILED(hr)){rollback();return hr;}
  }
  registrationStage=0;
  return S_OK; // User chooses this keyboard. Do not set the default input source.
}
extern "C" unsigned __stdcall DllGetRegistrationDiagnostic() { return registrationStage; }
extern "C" HRESULT __stdcall DllUnregisterServer() {
  wchar_t path[32768];DWORD length=GetModuleFileNameW(g_instance,path,32768);if(!length||length>=32768)return E_FAIL;
  const auto base=classKey();HRESULT verified=verifyExistingServer(base,path);if(FAILED(verified))return verified;
  ComPtr<ITfInputProcessorProfiles> profiles;
  HRESULT hr = CoCreateInstance(CLSID_TF_InputProcessorProfiles, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&profiles));
  if(FAILED(hr))return hr;
  ComPtr<ITfCategoryMgr> categories;
  hr=CoCreateInstance(CLSID_TF_CategoryMgr,nullptr,CLSCTX_INPROC_SERVER,IID_PPV_ARGS(&categories));if(FAILED(hr))return hr;
  hr=categories->UnregisterCategory(CLSID_PrivateInput,GUID_TFCAT_TIP_KEYBOARD,CLSID_PrivateInput);if(FAILED(hr))return hr;
  hr=profiles->Unregister(CLSID_PrivateInput);if(FAILED(hr))return hr;
  deleteNewClass(base);return hasKey(base)?E_FAIL:S_OK;
}
