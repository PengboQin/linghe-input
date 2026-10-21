#include "PrivateInputTSF.h"
#include "SyntheticTextStore.h"
#include "private_input.h"
#include <wrl/client.h>
#include <iostream>
#include <fstream>
#include <stdexcept>
#include <cstring>
#include <shlobj.h>
using Microsoft::WRL::ComPtr;
namespace {
constexpr DWORD LocalProcess=0x00000004,ForProcess=0x10000000,DontCareLanguage=0x00000004;
constexpr DWORD InputProcessor=1;
constexpr DWORD HiddenInSettings=1;
constexpr LANGID Chinese=MAKELANGID(LANG_CHINESE,SUBLANG_CHINESE_SIMPLIFIED);
void check(HRESULT hr,const char *operation){if(FAILED(hr)){std::cerr<<operation<<" HRESULT=0x"<<std::hex<<unsigned(hr)<<std::dec<<"\n";throw std::runtime_error(operation);}}
void require(bool value,const char *operation){if(!value)throw std::runtime_error(operation);}
unsigned creations=0;
class Factory final:public IClassFactory {
  std::atomic<ULONG> refs{1};PrivateInputEnginePaths paths;
public:
  explicit Factory(PrivateInputEnginePaths value):paths(std::move(value)){}
  STDMETHODIMP QueryInterface(REFIID iid,void **out)override{if(!out)return E_POINTER;*out=nullptr;if(iid!=IID_IUnknown&&iid!=IID_IClassFactory)return E_NOINTERFACE;*out=static_cast<IClassFactory*>(this);AddRef();return S_OK;}
  STDMETHODIMP_(ULONG) AddRef()override{return ++refs;}
  STDMETHODIMP_(ULONG) Release()override{auto n=--refs;if(!n)delete this;return n;}
  STDMETHODIMP CreateInstance(IUnknown *outer,REFIID iid,void **out)override{if(outer)return CLASS_E_NOAGGREGATION;++creations;return CreatePrivateInput(iid,out,&paths);}
  STDMETHODIMP LockServer(BOOL)override{return S_OK;}
};
struct Host {ComPtr<ITfKeystrokeMgr> keys;ComPtr<SyntheticTextStore> store;};
bool key(Host &host,WPARAM value){BOOL eaten=FALSE;check(host.keys->TestKeyDown(value,1,&eaten),"OS TestKeyDown");if(eaten){BOOL delivered=FALSE;check(host.keys->KeyDown(value,1,&delivered),"OS KeyDown");require(delivered,"OS routed key was not consumed");}return eaten!=FALSE;}
LRESULT CALLBACK windowProcedure(HWND hwnd,UINT message,WPARAM w,LPARAM l){
  auto *host=reinterpret_cast<Host*>(GetWindowLongPtrW(hwnd,GWLP_USERDATA));
  if(message==WM_PAINT){PAINTSTRUCT ps;HDC dc=BeginPaint(hwnd,&ps);RECT r;GetClientRect(hwnd,&r);FillRect(dc,&r,GetSysColorBrush(COLOR_WINDOW));if(host&&host->store){r.left=16;r.top=45;DrawTextW(dc,host->store->text.c_str(),int(host->store->text.size()),&r,DT_LEFT|DT_WORDBREAK|DT_NOPREFIX);}EndPaint(hwnd,&ps);return 0;}
  if(message==WM_KEYDOWN&&host&&host->keys){try{if(key(*host,w))return 0;}catch(...){return 0;}}
  if(message==WM_CHAR&&host&&host->store){host->store->appInsert(WCHAR(w));return 0;}
  if(message==WM_DESTROY){PostQuitMessage(0);return 0;}
  return DefWindowProcW(hwnd,message,w,l);
}
void pump(){MSG message;for(int attempt=0;attempt<8;++attempt){while(PeekMessageW(&message,nullptr,0,0,PM_REMOVE)){TranslateMessage(&message);DispatchMessageW(&message);}Sleep(10);}}
bool candidateVisible(){HWND window=nullptr;while((window=FindWindowExW(nullptr,window,L"PrivateInput.Candidates",nullptr))){DWORD pid=0;GetWindowThreadProcessId(window,&pid);if(pid==GetCurrentProcessId()&&IsWindowVisible(window))return true;}return false;}
}

int wmain(int argc,wchar_t **argv){
  ComPtr<ITfThreadMgr> manager;ComPtr<ITfInputProcessorProfileMgr> profiles;ComPtr<ITfCategoryMgr> categories;ComPtr<ITfDocumentMgr> document;ComPtr<ITfContext> context;
  Host host;HWND hwnd=nullptr;DWORD factoryCookie=0;bool active=false,registered=false,addedCategory=false,addedService=false,restoreEnabled=false;BOOL previousEnabled=FALSE;TfClientId client=0;LANGID profileLanguage=Chinese;
  int exitCode=1;BYTE originalKeyboard[256]{};GetKeyboardState(originalKeyboard);
  try {
    require(argc==4&&std::wstring(argv[3])==L"--synthetic-fixture","tsf_host SHARED NEW_OWNED_USER --synthetic-fixture");
    DWORD desktopSession=0;require(ProcessIdToSessionId(GetCurrentProcessId(),&desktopSession)&&desktopSession!=0,"SYSTEM/session 0 cannot validate desktop TSF");
    PWSTR localData=nullptr;check(SHGetKnownFolderPath(FOLDERID_LocalAppData,0,nullptr,&localData),"Own user test root");auto testRoot=std::filesystem::path(localData)/L"PrivateInputDev"/L"fixtures";CoTaskMemFree(localData);
    auto shared=std::filesystem::absolute(argv[1]).lexically_normal(),user=std::filesystem::absolute(argv[2]).lexically_normal();
    require(user.wstring().find(testRoot.wstring()+L"\\")==0&&!std::filesystem::exists(user),"Refusing existing or unrelated data directory");
    require(std::filesystem::exists(shared/L"build/private_pinyin.table.bin"),"Compiled dictionary absent");
    check(CoInitializeEx(nullptr,COINIT_APARTMENTTHREADED),"COM initialize");g_instance=GetModuleHandleW(nullptr);
    check(CoCreateInstance(CLSID_TF_InputProcessorProfiles,nullptr,CLSCTX_INPROC_SERVER,IID_PPV_ARGS(&profiles)),"OS profile manager");
    ComPtr<ITfInputProcessorProfiles> legacy;check(profiles.As(&legacy),"Legacy profile interface");
    ComPtr<IEnumGUID> services;check(legacy->EnumInputProcessorInfo(&services),"Own service snapshot");GUID service{};ULONG serviceFetched=0;bool servicePresent=false;
    while(services->Next(1,&service,&serviceFetched)==S_OK&&serviceFetched)if(service==CLSID_PrivateInput)servicePresent=true;
    if(!servicePresent){check(legacy->Register(CLSID_PrivateInput),"Own base text-service registration");addedService=true;}
    // Install our category before the thread/profile managers build their
    // category caches. Keep and restore any pre-existing app-owned mapping.
    check(CoCreateInstance(CLSID_TF_CategoryMgr,nullptr,CLSCTX_INPROC_SERVER,IID_PPV_ARGS(&categories)),"OS category manager");
    ComPtr<IEnumGUID> categoryList;check(categories->EnumCategoriesInItem(CLSID_PrivateInput,&categoryList),"Own category snapshot");GUID category{};ULONG fetched=0;bool keyboardCategory=false;
    while(categoryList->Next(1,&category,&fetched)==S_OK&&fetched)if(category==GUID_TFCAT_TIP_KEYBOARD)keyboardCategory=true;
    if(!keyboardCategory){check(categories->RegisterCategory(CLSID_PrivateInput,GUID_TFCAT_TIP_KEYBOARD,CLSID_PrivateInput),"Own keyboard category registration");addedCategory=true;}
    categoryList.Reset();check(categories->EnumCategoriesInItem(CLSID_PrivateInput,&categoryList),"Own category readback");bool categoryReadback=false;
    while(categoryList->Next(1,&category,&fetched)==S_OK&&fetched)if(category==GUID_TFCAT_TIP_KEYBOARD)categoryReadback=true;
    require(categoryReadback,"Own category registration did not persist");
    BYTE syntheticKeyboard[256]{};SetKeyboardState(syntheticKeyboard);
    WNDCLASSW cls{};cls.lpfnWndProc=windowProcedure;cls.hInstance=g_instance;cls.lpszClassName=L"PrivateInput.TSF.SyntheticHost";cls.hCursor=LoadCursor(nullptr,IDC_ARROW);RegisterClassW(&cls);
    hwnd=CreateWindowExW(WS_EX_NOACTIVATE,cls.lpszClassName,L"PrivateInput TSF Synthetic Host",WS_OVERLAPPEDWINDOW,20,20,650,340,nullptr,nullptr,g_instance,nullptr);require(hwnd,"Own window failed");
    host.store.Attach(new SyntheticTextStore(hwnd));SetWindowLongPtrW(hwnd,GWLP_USERDATA,reinterpret_cast<LONG_PTR>(&host));ShowWindow(hwnd,SW_SHOWNOACTIVATE);
    check(CoCreateInstance(CLSID_TF_ThreadMgr,nullptr,CLSCTX_INPROC_SERVER,IID_PPV_ARGS(&manager)),"OS thread manager");
    check(manager->Activate(&client),"OS thread manager activate");active=true;
    check(manager.As(&host.keys),"OS keystroke manager");
    check(manager->CreateDocumentMgr(&document),"OS document manager");TfEditCookie edit=0;
    check(document->CreateContext(client,0,host.store.Get(),&context,&edit),"OS ACP context");
    check(document->Push(context.Get()),"OS context push");check(manager->SetFocus(document.Get()),"OS document focus");
    ComPtr<ITfDocumentMgr> previousFocus;check(manager->AssociateFocus(hwnd,document.Get(),&previousFocus),"Associate own host focus");SetFocus(hwnd);
    ComPtr<Factory> factory;factory.Attach(new Factory({shared,user}));
    check(CoRegisterClassObject(CLSID_PrivateInput,factory.Get(),CLSCTX_INPROC_SERVER,REGCLS_MULTIPLEUSE,&factoryCookie),"Local COM class factory");
    LANGID currentLanguage=0;check(legacy->GetCurrentLanguage(&currentLanguage),"Current language query");
    // Keep this isolated process's current language. The installed product's
    // Chinese-language profile selection remains a separate acceptance gate.
    profileLanguage=currentLanguage;
    CLSID defaultClassBefore{};GUID defaultProfileBefore{};HRESULT defaultBefore=legacy->GetDefaultLanguageProfile(currentLanguage,GUID_TFCAT_TIP_KEYBOARD,&defaultClassBefore,&defaultProfileBefore);
    const wchar_t description[]=L"PrivateInput process-only acceptance";
    BSTR previousDescription=nullptr;HRESULT previousProfile=legacy->GetLanguageProfileDescription(CLSID_PrivateInput,profileLanguage,GUID_PrivateInputProfile,&previousDescription);
    bool existingOwnedFixture=previousProfile==S_OK&&previousDescription&&std::wstring(previousDescription)==description;
    if(previousDescription)SysFreeString(previousDescription);
    require(previousProfile!=S_OK||existingOwnedFixture,"Refusing to replace an existing installed profile");
    require(existingOwnedFixture,"Own hidden acceptance profile must be prepared by the installer context");
    check(legacy->IsEnabledLanguageProfile(CLSID_PrivateInput,profileLanguage,GUID_PrivateInputProfile,&previousEnabled),"Own enable-state snapshot");
    check(legacy->EnableLanguageProfile(CLSID_PrivateInput,profileLanguage,GUID_PrivateInputProfile,TRUE),"Enable own acceptance profile");restoreEnabled=true;
    HRESULT registration=S_OK;
    TF_INPUTPROCESSORPROFILE registeredProfile{};HRESULT readback=profiles->GetProfile(InputProcessor,profileLanguage,CLSID_PrivateInput,GUID_PrivateInputProfile,nullptr,&registeredProfile);check(readback,"Registered profile readback");
    HRESULT activation=profiles->ActivateProfile(InputProcessor,profileLanguage,CLSID_PrivateInput,GUID_PrivateInputProfile,nullptr,ForProcess);check(activation,"OS process profile activation");pump();
    TF_INPUTPROCESSORPROFILE profile{};
    check(profiles->GetActiveProfile(GUID_TFCAT_TIP_KEYBOARD,&profile),"OS keyboard profile readback");
    if(profile.clsid!=CLSID_PrivateInput||profile.guidProfile!=GUID_PrivateInputProfile){std::cerr<<"profile diagnostic language="<<currentLanguage<<" registration="<<registration<<" readback="<<readback<<" readbackOwn="<<(registeredProfile.clsid==CLSID_PrivateInput)<<" categoryMatches="<<(registeredProfile.catid==GUID_TFCAT_TIP_KEYBOARD)<<" activation="<<activation<<" creations="<<creations<<"\n";throw std::runtime_error("OS did not activate this keyboard");}
    for(auto letter:std::wstring(L"NIHAO")){require(key(host,letter),"Chinese key was not routed to service");pump();}
    require(creations>0,"OS did not instantiate service through COM");
    require(candidateVisible(),"Actual candidate window not visible");
    require(host.store->text.find(L"ni")!=std::wstring::npos,"ACP preedit missing");
    require(key(host,VK_SPACE),"Space selection not consumed");pump();
    require(host.store->text==L"你好","Actual ACP commit differs from selected phrase");
    require(!candidateVisible(),"Candidate window remained after commit");
    for(auto letter:std::wstring(L"SHI")){require(key(host,letter),"Second composition failed");pump();}
    require(key(host,VK_NEXT),"Next page not routed");pump();require(candidateVisible(),"Candidate window missing after page change");
    require(key(host,VK_ESCAPE),"Escape not routed");pump();require(host.store->text==L"你好","Cancel damaged committed text");
    host.store->setReadOnly(true);pump();require(!key(host,'N'),"Readonly field consumed key");host.store->setReadOnly(false);pump();
    auto writes=host.store->writes,locks=host.store->locks;require(writes>0&&locks>0,"TSF did not use native edit locks");
    check(profiles->DeactivateProfile(InputProcessor,profileLanguage,CLSID_PrivateInput,GUID_PrivateInputProfile,nullptr,ForProcess),"Deactivate local profile");
    check(legacy->EnableLanguageProfile(CLSID_PrivateInput,profileLanguage,GUID_PrivateInputProfile,previousEnabled),"Restore own enable state");restoreEnabled=false;
    if(addedCategory){check(categories->UnregisterCategory(CLSID_PrivateInput,GUID_TFCAT_TIP_KEYBOARD,CLSID_PrivateInput),"Restore own category registration");addedCategory=false;}
    if(addedService){check(legacy->Unregister(CLSID_PrivateInput),"Restore own base service registration");addedService=false;}
    CLSID defaultClassAfter{};GUID defaultProfileAfter{};HRESULT defaultAfter=legacy->GetDefaultLanguageProfile(currentLanguage,GUID_TFCAT_TIP_KEYBOARD,&defaultClassAfter,&defaultProfileAfter);
    require(defaultBefore==defaultAfter&&defaultClassBefore==defaultClassAfter&&defaultProfileBefore==defaultProfileAfter,"Default input profile changed");
    document->Pop(TF_POPF_ALL);context.Reset();document.Reset();manager->Deactivate();active=false;host.keys.Reset();manager.Reset();profiles.Reset();
    CoRevokeClassObject(factoryCookie);factoryCookie=0;factory.Reset();pump();
    require(pi_active_session_count()==0&&g_objects==0,"Service/COM references leaked");pi_finalize();
    std::cout<<"{\"result\":\"passed\",\"processOnlyActivation\":true,\"profileEnableStateRestored\":true,\"fixtureUsesInitialLanguage\":true,\"defaultProfilePreserved\":true,\"osActivatedKeyboard\":true,\"osCOMCreations\":"<<creations<<",\"osEditLocks\":"<<locks<<",\"actualACPCommit\":true,\"candidateWindow\":true,\"pagination\":true,\"cancelPreservesCommittedText\":true,\"readonlyPassThrough\":true,\"shippingDLLLoaded\":false}\n";
    exitCode=0;
  }catch(const std::exception &e){std::cerr<<"FAIL: "<<e.what()<<"\n";}
  if(registered&&profiles){profiles->DeactivateProfile(InputProcessor,profileLanguage,CLSID_PrivateInput,GUID_PrivateInputProfile,nullptr,ForProcess);profiles->UnregisterProfile(CLSID_PrivateInput,profileLanguage,GUID_PrivateInputProfile,0);}
  if(restoreEnabled&&profiles){ComPtr<ITfInputProcessorProfiles> cleanup;if(SUCCEEDED(profiles.As(&cleanup))){profiles->DeactivateProfile(InputProcessor,profileLanguage,CLSID_PrivateInput,GUID_PrivateInputProfile,nullptr,ForProcess);cleanup->EnableLanguageProfile(CLSID_PrivateInput,profileLanguage,GUID_PrivateInputProfile,previousEnabled);}}
  if(addedCategory&&categories)categories->UnregisterCategory(CLSID_PrivateInput,GUID_TFCAT_TIP_KEYBOARD,CLSID_PrivateInput);
  if(addedService&&profiles){ComPtr<ITfInputProcessorProfiles> cleanup;if(SUCCEEDED(profiles.As(&cleanup)))cleanup->Unregister(CLSID_PrivateInput);}
  if(document)document->Pop(TF_POPF_ALL);context.Reset();document.Reset();if(active&&manager)manager->Deactivate();host.keys.Reset();manager.Reset();profiles.Reset();if(factoryCookie)CoRevokeClassObject(factoryCookie);
  categories.Reset();host.store.Reset();if(hwnd)DestroyWindow(hwnd);SetKeyboardState(originalKeyboard);CoUninitialize();return exitCode;
}
