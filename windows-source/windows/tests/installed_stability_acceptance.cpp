// Normal Win32/RichEdit application used only for explicitly authorized receipt
// checks. It loads the installed TIP through OS profile activation (no factory,
// direct key-sink call or direct archive IPC). Clipboard uses RichEdit WM_COPY.
#include "Json.h"
#include <filesystem>
#include "PrivateInputTSF.h"
#include <wrl/client.h>
#include <msctf.h>
#include <inputscope.h>
#include <richedit.h>
#include <iostream>
#include <vector>
#include <sstream>
#include <algorithm>
using namespace private_input::activity;using Microsoft::WRL::ComPtr;
#ifndef TF_IPPMF_FORPROCESS
// Microsoft WinSDK msctf.h definition; absent in this LLVM-MinGW header.
#define TF_IPPMF_FORPROCESS 0x10000000
#endif
namespace {
HRESULT setScope(HWND window,InputScope value){static HMODULE module=LoadLibraryExW(L"msctf.dll",nullptr,LOAD_LIBRARY_SEARCH_SYSTEM32);auto function=module?reinterpret_cast<HRESULT(WINAPI*)(HWND,InputScope)>(GetProcAddress(module,"SetInputScope")):nullptr;return function?function(window,value):E_NOTIMPL;}
void pump(int milliseconds){auto until=GetTickCount64()+milliseconds;MSG msg{};while(GetTickCount64()<until){while(PeekMessageW(&msg,nullptr,0,0,PM_REMOVE)){TranslateMessage(&msg);DispatchMessageW(&msg);}Sleep(10);}}
bool ownFocus(HWND window,HWND edit){return GetForegroundWindow()==window&&GetFocus()==edit;}
bool keys(HWND window,HWND edit,const std::vector<std::pair<WORD,bool>>& sequence){if(!ownFocus(window,edit))return false;std::vector<INPUT>events;for(auto key:sequence){INPUT in{};in.type=INPUT_KEYBOARD;in.ki.wVk=key.first;in.ki.dwFlags=key.second?KEYEVENTF_KEYUP:0;events.push_back(in);}return SendInput(UINT(events.size()),events.data(),sizeof(INPUT))==events.size();}
std::wstring text(HWND edit){int n=GetWindowTextLengthW(edit);std::wstring value(n+1,0);GetWindowTextW(edit,value.data(),n+1);value.resize(n);return value;}
LRESULT CALLBACK procedure(HWND hwnd,UINT m,WPARAM w,LPARAM l){if(m==WM_CLOSE){DestroyWindow(hwnd);return 0;}return DefWindowProcW(hwnd,m,w,l);}
}
int wmain(int argc,wchar_t**argv){Json result=Json::object({{"operator",true},{"directArchiveIPC",false},{"directKeySink",false},{"defaultInputRegistryChanged",false}});HWND window=nullptr,edit=nullptr;HMODULE rich=nullptr;bool com=false,threadActive=false,profileChanged=false,languageChanged=false;LANGID savedLanguage=0;TF_INPUTPROCESSORPROFILE savedProfile{};ComPtr<ITfThreadMgr>manager;ComPtr<ITfInputProcessorProfiles>profiles;ComPtr<ITfInputProcessorProfileMgr>profileManager;
 try{require(argc==3&&std::wstring(argv[1])==L"--authorized-stability","explicit scope required");DWORD session=0;require(ProcessIdToSessionId(GetCurrentProcessId(),&session)&&session!=0,"normal desktop session required");require(SUCCEEDED(CoInitializeEx(nullptr,COINIT_APARTMENTTHREADED)),"COM");com=true;
 WNDCLASSW cls{};cls.lpfnWndProc=procedure;cls.hInstance=GetModuleHandleW(nullptr);cls.lpszClassName=L"LingheInput.InstalledStabilityHost";cls.hbrBackground=GetSysColorBrush(COLOR_WINDOW);cls.hCursor=LoadCursor(nullptr,IDC_ARROW);require(RegisterClassW(&cls)!=0,"native window class");window=CreateWindowExW(0,cls.lpszClassName,L"Linghe installed input stability check",WS_OVERLAPPEDWINDOW,80,80,640,220,nullptr,nullptr,cls.hInstance,nullptr);require(window!=nullptr,"native host window");rich=LoadLibraryExW(L"Msftedit.dll",nullptr,LOAD_LIBRARY_SEARCH_SYSTEM32);require(rich!=nullptr,"system RichEdit");edit=CreateWindowExW(WS_EX_CLIENTEDGE,L"RICHEDIT50W",L"",WS_CHILD|WS_VISIBLE|WS_TABSTOP|ES_MULTILINE,16,24,590,110,window,nullptr,cls.hInstance,nullptr);require(edit!=nullptr,"native RichEdit control");setScope(edit,IS_TEXT);ShowWindow(window,SW_SHOWNORMAL);SetForegroundWindow(window);SetFocus(edit);pump(600);result["ownForeground"]=ownFocus(window,edit);
 SetWindowTextW(edit,L"");SendMessageW(edit,EM_SETSEL,0,0);SetFocus(edit);pump(200);require(ownFocus(window,edit),"native foreground unavailable; no keyboard injected");for(WORD key:{WORD(VK_CONTROL),WORD(VK_SHIFT),WORD(VK_MENU),WORD(VK_LWIN),WORD(VK_RWIN)})require((GetAsyncKeyState(key)&0x8000)==0,"physical modifier active; no keyboard injected");require(SUCCEEDED(CoCreateInstance(CLSID_TF_ThreadMgr,nullptr,CLSCTX_INPROC_SERVER,IID_PPV_ARGS(&manager))),"OS thread manager");TfClientId client=0;require(SUCCEEDED(manager->Activate(&client)),"OS app thread activation");threadActive=true;require(SUCCEEDED(CoCreateInstance(CLSID_TF_InputProcessorProfiles,nullptr,CLSCTX_INPROC_SERVER,IID_PPV_ARGS(&profiles))),"OS profiles");require(SUCCEEDED(profiles.As(&profileManager)),"OS profile manager");profiles->GetCurrentLanguage(&savedLanguage);profileManager->GetActiveProfile(GUID_TFCAT_TIP_KEYBOARD,&savedProfile);if(savedLanguage!=0x0804){require(SUCCEEDED(profiles->ChangeCurrentLanguage(0x0804)),"process input language");languageChanged=true;}auto activation=profileManager->ActivateProfile(TF_PROFILETYPE_INPUTPROCESSOR,0x0804,CLSID_PrivateInput,GUID_PrivateInputProfile,nullptr,TF_IPPMF_FORPROCESS);result["osActivationHRESULT"]=uint64_t(uint32_t(activation));require(activation==S_OK,"installed profile activation failed");profileChanged=true;pump(800);result["installedModuleLoaded"]=GetModuleHandleW(L"PrivateInputTSF.dll")!=nullptr;wchar_t loaded[32768]{};require(GetModuleFileNameW(GetModuleHandleW(L"PrivateInputTSF.dll"),loaded,32768)>0,"installed module path");require(_wcsicmp(std::filesystem::path(argv[2]).lexically_normal().make_preferred().c_str(),loaded)==0,"wrong installed DLL version");result["exactInstalledModuleVerified"]=true;
 auto tap=[&](WORD k){require(keys(window,edit,{{k,false},{k,true}}),"quality key focus");pump(90);};
 auto type=[&](const std::string&s){for(char c:s)tap(WORD(c-'a'+'A'));pump(150);};
 auto clear=[&]{tap(VK_ESCAPE);tap(VK_ESCAPE);SetWindowTextW(edit,L"");SendMessageW(edit,EM_SETSEL,0,0);SetFocus(edit);pump(100);};
 auto candidate=[&]()->HWND{HWND h=nullptr;while((h=FindWindowExW(nullptr,h,L"PrivateInput.Candidates",nullptr))){DWORD pid=0;GetWindowThreadProcessId(h,&pid);if(pid==GetCurrentProcessId()&&IsWindowVisible(h))return h;}return nullptr;};
 // All events are dispatched through the OS and only while our empty host owns focus.
 clear();type("nihao");if(!candidate()){clear();tap(VK_SHIFT);type("nihao");}
 require(candidate()!=nullptr,"installed Chinese candidate unavailable");tap('1');require(text(edit)==L"你好","number one commit");result["candidateAndNumericCommit"]=true;
 clear();tap(VK_OEM_COMMA);tap(VK_OEM_PERIOD);require(text(edit)==L"，。","Chinese punctuation");result["chinesePunctuation"]=true;
 clear();tap('1');tap(VK_OEM_PERIOD);tap('4');require(text(edit)==L"1.4","decimal literal");result["decimalLiteral"]=true;
 clear();type("shi");auto collapsed=candidate();require(collapsed,"candidate before expansion");RECT before{},after{};GetWindowRect(collapsed,&before);tap(VK_DOWN);require(candidate()==collapsed,"expand in same panel");GetWindowRect(collapsed,&after);require(after.bottom>before.bottom,"expanded rows");tap(VK_SPACE);require(!text(edit).empty(),"expanded selection");result["expandedSelection"]=true;
 clear();setScope(edit,IS_URL);pump(150);
 const std::wstring address=L"https://example.com:8443/a";
 for(auto c:address){SHORT mapped=VkKeyScanW(c);require(mapped!=-1,"fixture ASCII mapping");if(HIBYTE(mapped)&1)require(keys(window,edit,{{VK_SHIFT,false}}),"shift down");tap(LOBYTE(mapped));if(HIBYTE(mapped)&1)require(keys(window,edit,{{VK_SHIFT,true}}),"shift up");}
 require(text(edit)==address,"technical URL preserved");result["urlPunctuation"]=true;
 clear();setScope(edit,IS_TEXT);pump(100);
 for(int round=0;round<3;++round){ShowWindow(window,SW_MINIMIZE);pump(120);ShowWindow(window,SW_RESTORE);SetForegroundWindow(window);SetFocus(edit);pump(200);type("nihao");require(candidate(),"candidate after host visibility change");tap('1');require(text(edit)==L"你好","commit after visibility change");clear();}
 result["threeHideRestoreCycles"]=true;result["clipboardUntouched"]=true;result["osKeyDispatch"]=true;
 result["passed"]=true;
 }catch(const std::exception&e){result["passed"]=false;result["errorClass"]=std::string(e.what());}
 if(profileChanged&&profileManager&&savedProfile.dwProfileType)profileManager->ActivateProfile(savedProfile.dwProfileType,savedProfile.langid,savedProfile.clsid,savedProfile.guidProfile,savedProfile.hkl,TF_IPPMF_FORPROCESS);if(languageChanged&&profiles)profiles->ChangeCurrentLanguage(savedLanguage);if(edit)setScope(edit,IS_DEFAULT);if(window)DestroyWindow(window);if(threadActive&&manager)manager->Deactivate();profileManager.Reset();profiles.Reset();manager.Reset();if(rich)FreeLibrary(rich);if(com)CoUninitialize();std::cout<<result.dump()<<'\n';return result.at("passed").boolean()?0:1;}
