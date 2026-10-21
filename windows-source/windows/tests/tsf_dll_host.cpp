#include "PrivateInputTSF.h"
#include "SyntheticTextStore.h"
#include <wrl/client.h>
#include <shlobj.h>
#include <iostream>
#include <stdexcept>
using Microsoft::WRL::ComPtr;
namespace {
constexpr LANGID Language=MAKELANGID(LANG_CHINESE,SUBLANG_CHINESE_SIMPLIFIED);
constexpr DWORD ForProcess=0x10000000;
void check(HRESULT hr,const char *message){if(FAILED(hr)){std::cerr<<message<<" hr="<<unsigned(hr)<<"\n";throw std::runtime_error(message);}}
void require(bool value,const char *message){if(!value)throw std::runtime_error(message);}
LRESULT CALLBACK procedure(HWND window,UINT message,WPARAM w,LPARAM l){
  if(message==WM_PAINT){PAINTSTRUCT ps;auto dc=BeginPaint(window,&ps);RECT rect;GetClientRect(window,&rect);FillRect(dc,&rect,GetSysColorBrush(COLOR_WINDOW));auto store=reinterpret_cast<SyntheticTextStore*>(GetWindowLongPtrW(window,GWLP_USERDATA));if(store){rect.left=16;rect.top=45;DrawTextW(dc,store->text.c_str(),int(store->text.size()),&rect,DT_LEFT|DT_WORDBREAK|DT_NOPREFIX);}EndPaint(window,&ps);return 0;}
  return DefWindowProcW(window,message,w,l);
}
void pump(){MSG message;for(int i=0;i<8;++i){while(PeekMessageW(&message,nullptr,0,0,PM_REMOVE)){TranslateMessage(&message);DispatchMessageW(&message);}Sleep(10);}}
bool candidates(){HWND window=nullptr;while((window=FindWindowExW(nullptr,window,L"PrivateInput.Candidates",nullptr))){DWORD process=0;GetWindowThreadProcessId(window,&process);if(process==GetCurrentProcessId()&&IsWindowVisible(window))return true;}return false;}
}
int wmain(int argc,wchar_t **argv){
  if(argc!=3||std::wstring(argv[2])!=L"--fresh-synthetic-product-store")return 2;
  DWORD session=0;require(ProcessIdToSessionId(GetCurrentProcessId(),&session)&&session!=0,"Desktop user required");
  PWSTR local=nullptr;check(SHGetKnownFolderPath(FOLDERID_LocalAppData,0,nullptr,&local),"Product path");auto product=std::filesystem::path(local)/L"PrivateInput";CoTaskMemFree(local);
  if(std::filesystem::exists(product)){std::cerr<<"Refusing existing product data; preserve it before a separate acceptance run\n";return 3;}
  check(CoInitializeEx(nullptr,COINIT_APARTMENTTHREADED),"COM");
  ComPtr<ITfThreadMgr> manager;ComPtr<ITfDocumentMgr> document;ComPtr<ITfContext> context;ComPtr<ITfKeystrokeMgr> keys;ComPtr<ITfInputProcessorProfileMgr> profiles;ComPtr<ITfInputProcessorProfiles> legacy;ComPtr<SyntheticTextStore> store;
  BOOL enabledBefore=FALSE;bool restore=false,activated=false;HWND window=nullptr;int result=1;
  try {
    check(CoCreateInstance(CLSID_TF_InputProcessorProfiles,nullptr,CLSCTX_INPROC_SERVER,IID_PPV_ARGS(&profiles)),"Profile manager");check(profiles.As(&legacy),"Profile interface");
    LANGID language=0;check(legacy->GetCurrentLanguage(&language),"Current language");require(language==Language,"Chinese input language required in this host process");
    CLSID defaultBefore{};GUID defaultProfileBefore{};HRESULT baseline=legacy->GetDefaultLanguageProfile(Language,GUID_TFCAT_TIP_KEYBOARD,&defaultBefore,&defaultProfileBefore);
    check(legacy->IsEnabledLanguageProfile(CLSID_PrivateInput,Language,GUID_PrivateInputProfile,&enabledBefore),"Enable-state snapshot");
    ComPtr<IUnknown> probe;check(CoCreateInstance(CLSID_PrivateInput,nullptr,CLSCTX_INPROC_SERVER,IID_IUnknown,reinterpret_cast<void**>(probe.GetAddressOf())),"Installed DLL COM creation");
    auto module=GetModuleHandleW(L"PrivateInputTSF.dll");require(module,"Actual installed DLL not loaded");wchar_t loaded[32768];require(GetModuleFileNameW(module,loaded,32768)>0,"Loaded path unavailable");
    require(_wcsicmp(std::filesystem::absolute(argv[1]).c_str(),loaded)==0,"Wrong DLL path loaded");probe.Reset();
    WNDCLASSW cls{};cls.lpfnWndProc=procedure;cls.hInstance=GetModuleHandleW(nullptr);cls.lpszClassName=L"PrivateInput.RegisteredDLL.Host";cls.hCursor=LoadCursor(nullptr,IDC_ARROW);RegisterClassW(&cls);
    window=CreateWindowExW(WS_EX_NOACTIVATE,cls.lpszClassName,L"PrivateInput Registered DLL Host",WS_OVERLAPPEDWINDOW,20,20,650,340,nullptr,nullptr,cls.hInstance,nullptr);require(window,"Host window");
    store.Attach(new SyntheticTextStore(window));SetWindowLongPtrW(window,GWLP_USERDATA,reinterpret_cast<LONG_PTR>(store.Get()));ShowWindow(window,SW_SHOWNOACTIVATE);
    check(CoCreateInstance(CLSID_TF_ThreadMgr,nullptr,CLSCTX_INPROC_SERVER,IID_PPV_ARGS(&manager)),"Thread manager");TfClientId client=0;check(manager->Activate(&client),"Thread activate");activated=true;check(manager.As(&keys),"Key manager");check(manager->CreateDocumentMgr(&document),"Document");TfEditCookie cookie=0;check(document->CreateContext(client,0,store.Get(),&context,&cookie),"ACP context");check(document->Push(context.Get()),"Push context");check(manager->SetFocus(document.Get()),"Context focus");ComPtr<ITfDocumentMgr> old;check(manager->AssociateFocus(window,document.Get(),&old),"Own window focus");SetFocus(window);
    check(legacy->EnableLanguageProfile(CLSID_PrivateInput,Language,GUID_PrivateInputProfile,TRUE),"Enable own profile");restore=true;HRESULT activation=profiles->ActivateProfile(1,Language,CLSID_PrivateInput,GUID_PrivateInputProfile,nullptr,ForProcess);require(activation==S_OK,"Profile activation must return S_OK");pump();
    TF_INPUTPROCESSORPROFILE profile{};check(profiles->GetActiveProfile(GUID_TFCAT_TIP_KEYBOARD,&profile),"Active profile");require(profile.clsid==CLSID_PrivateInput&&profile.guidProfile==GUID_PrivateInputProfile,"Wrong active profile");
    auto key=[&](WPARAM value){BOOL eaten=FALSE;check(keys->TestKeyDown(value,1,&eaten),"OS key preflight");require(eaten,"OS did not dispatch key to installed service");eaten=FALSE;check(keys->KeyDown(value,1,&eaten),"OS key delivery");require(eaten,"Installed service did not consume key");pump();};
    for(auto letter:std::wstring(L"NIHAO"))key(letter);
    require(candidates(),"Native candidate window missing");key(VK_SPACE);require(store->text==L"你好","Actual ACP commit mismatch");require(!candidates(),"Candidate remained after commit");
    for(auto letter:std::wstring(L"SHI"))key(letter);key(VK_NEXT);require(candidates(),"Pagination missing candidates");key(VK_ESCAPE);require(store->text==L"你好","Cancel damaged prior text");
    store->setReadOnly(true);BOOL eaten=TRUE;check(keys->TestKeyDown('N',1,&eaten),"Readonly preflight");require(!eaten,"Readonly consumed key");
    require(store->writes>0&&store->locks>0,"No OS text-store editing");
    check(profiles->DeactivateProfile(1,Language,CLSID_PrivateInput,GUID_PrivateInputProfile,nullptr,ForProcess),"Deactivate");check(legacy->EnableLanguageProfile(CLSID_PrivateInput,Language,GUID_PrivateInputProfile,enabledBefore),"Restore enable state");restore=false;
    CLSID after{};GUID afterProfile{};HRESULT afterResult=legacy->GetDefaultLanguageProfile(Language,GUID_TFCAT_TIP_KEYBOARD,&after,&afterProfile);require(afterResult==baseline&&after==defaultBefore&&afterProfile==defaultProfileBefore,"Default profile changed");
    std::cout<<"{\"passed\":true,\"actualRegisteredDLL\":true,\"actualOSKeyDispatch\":true,\"actualACPCommit\":true,\"candidateWindow\":true,\"pagination\":true,\"cancelPreservesText\":true,\"readonlyPassThrough\":true,\"defaultPreserved\":true,\"enableStateRestored\":true,\"editLocks\":"<<store->locks<<"}\n";result=0;
  }catch(const std::exception &error){std::cerr<<"FAIL: "<<error.what()<<"\n";}
  if(restore){profiles->DeactivateProfile(1,Language,CLSID_PrivateInput,GUID_PrivateInputProfile,nullptr,ForProcess);legacy->EnableLanguageProfile(CLSID_PrivateInput,Language,GUID_PrivateInputProfile,enabledBefore);}
  if(document)document->Pop(TF_POPF_ALL);context.Reset();document.Reset();if(activated)manager->Deactivate();keys.Reset();manager.Reset();profiles.Reset();legacy.Reset();store.Reset();if(window)DestroyWindow(window);CoUninitialize();return result;
}
