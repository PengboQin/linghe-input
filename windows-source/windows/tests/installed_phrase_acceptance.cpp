// Explicitly authorized synthetic phrase check in its own blank RichEdit.
// OS profile + SendInput only. No private store, capture IPC, clipboard, registry
// edits, product hooks, candidate ordinals guessed from a historical ordering.
// A visible card/click is NOT a durable Worker or cloud receipt.
// Both named cases require an external exact-target absence check. In particular
// the brand word linghe is not assumed disposable; this tool never removes an
// existing-word guard, scans user stores, or automatically chooses another word.
// A retry may use confirmed-test-created-target only with preserved pre-test
// absence evidence and readback proving the test created this exact term.
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
// Observe only native messages on our own visible card; never read its C++
// object or call product methods. Preserve the original window procedure.
HWND tracedCard=nullptr;WNDPROC cardProcedure=nullptr;unsigned cardDown=0,cardUp=0,cardHideBeforeUp=0,cardHideAfterUp=0;LRESULT mouseActivation=-1;bool inCompletionTimer=false;unsigned completionTimerMessages=0,hideFromCompletionTimer=0;
LRESULT CALLBACK observeCard(HWND h,UINT m,WPARAM w,LPARAM l){
 const bool outerTimer=inCompletionTimer;if(m==WM_TIMER&&w==2){inCompletionTimer=true;++completionTimerMessages;}
 if(m==WM_LBUTTONDOWN)++cardDown;if(m==WM_LBUTTONUP)++cardUp;
 if(m==WM_WINDOWPOSCHANGING&&l&&(reinterpret_cast<WINDOWPOS*>(l)->flags&SWP_HIDEWINDOW)){if(inCompletionTimer)++hideFromCompletionTimer;if(cardUp)++cardHideAfterUp;else ++cardHideBeforeUp;}
 auto result=CallWindowProcW(cardProcedure,h,m,w,l);if(m==WM_MOUSEACTIVATE)mouseActivation=result;inCompletionTimer=outerTimer;return result;
}
HRESULT setScope(HWND window,InputScope value){static HMODULE module=LoadLibraryExW(L"msctf.dll",nullptr,LOAD_LIBRARY_SEARCH_SYSTEM32);auto function=module?reinterpret_cast<HRESULT(WINAPI*)(HWND,InputScope)>(GetProcAddress(module,"SetInputScope")):nullptr;return function?function(window,value):E_NOTIMPL;}
void pump(int milliseconds){auto until=GetTickCount64()+milliseconds;MSG msg{};while(GetTickCount64()<until){while(PeekMessageW(&msg,nullptr,0,0,PM_REMOVE)){TranslateMessage(&msg);DispatchMessageW(&msg);}Sleep(10);}}
bool ownFocus(HWND window,HWND edit){return GetForegroundWindow()==window&&GetFocus()==edit;}
bool keys(HWND window,HWND edit,const std::vector<std::pair<WORD,bool>>& sequence){if(!ownFocus(window,edit))return false;std::vector<INPUT>events;for(auto key:sequence){INPUT in{};in.type=INPUT_KEYBOARD;in.ki.wVk=key.first;in.ki.dwFlags=key.second?KEYEVENTF_KEYUP:0;events.push_back(in);}return SendInput(UINT(events.size()),events.data(),sizeof(INPUT))==events.size();}
std::wstring text(HWND edit){int n=GetWindowTextLengthW(edit);std::wstring value(n+1,0);GetWindowTextW(edit,value.data(),n+1);value.resize(n);return value;}
LRESULT CALLBACK procedure(HWND hwnd,UINT m,WPARAM w,LPARAM l){if(m==WM_CLOSE){DestroyWindow(hwnd);return 0;}return DefWindowProcW(hwnd,m,w,l);}
}
int wmain(int argc,wchar_t**argv){Json result=Json::object({{"operator",true},{"directArchiveIPC",false},{"directKeySink",false},{"defaultInputRegistryChanged",false}});HWND window=nullptr,edit=nullptr;HMODULE rich=nullptr;bool com=false,threadActive=false,profileChanged=false,languageChanged=false,cursorMoved=false;POINT savedCursor{};LANGID savedLanguage=0;TF_INPUTPROCESSORPROFILE savedProfile{};ComPtr<ITfThreadMgr>manager;ComPtr<ITfInputProcessorProfiles>profiles;ComPtr<ITfInputProcessorProfileMgr>profileManager;
 try{require(argc==5&&std::wstring(argv[1])==L"--authorized-phrase"&&(std::wstring(argv[4])==L"--confirmed-absent-in-archive-and-personal"||std::wstring(argv[4])==L"--confirmed-test-created-target"),"operator must first confirm exact target absent in archive and personal lexicon");result["operatorConfirmedTargetAbsent"]=std::wstring(argv[4])==L"--confirmed-absent-in-archive-and-personal";result["operatorConfirmedOwnedSynthetic"]=true;require(SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)!=FALSE,"physical mouse DPI context");DWORD session=0;require(ProcessIdToSessionId(GetCurrentProcessId(),&session)&&session!=0,"normal desktop session required");require(SUCCEEDED(CoInitializeEx(nullptr,COINIT_APARTMENTTHREADED)),"COM");com=true;
 WNDCLASSW cls{};cls.lpfnWndProc=procedure;cls.hInstance=GetModuleHandleW(nullptr);cls.lpszClassName=L"LingheInput.InstalledPhraseHost";cls.hbrBackground=GetSysColorBrush(COLOR_WINDOW);cls.hCursor=LoadCursor(nullptr,IDC_ARROW);require(RegisterClassW(&cls)!=0,"native window class");window=CreateWindowExW(0,cls.lpszClassName,L"Linghe synthetic new phrase check",WS_OVERLAPPEDWINDOW,80,80,640,220,nullptr,nullptr,cls.hInstance,nullptr);require(window!=nullptr,"native host window");rich=LoadLibraryExW(L"Msftedit.dll",nullptr,LOAD_LIBRARY_SEARCH_SYSTEM32);require(rich!=nullptr,"system RichEdit");edit=CreateWindowExW(WS_EX_CLIENTEDGE,L"RICHEDIT50W",L"",WS_CHILD|WS_VISIBLE|WS_TABSTOP|ES_MULTILINE,16,24,590,110,window,nullptr,cls.hInstance,nullptr);require(edit!=nullptr,"native RichEdit control");setScope(edit,IS_TEXT);ShowWindow(window,SW_SHOWNORMAL);SetForegroundWindow(window);SetFocus(edit);pump(600);result["ownForeground"]=ownFocus(window,edit);
 SetWindowTextW(edit,L"");SendMessageW(edit,EM_SETSEL,0,0);SetFocus(edit);pump(200);require(ownFocus(window,edit),"native foreground unavailable; no keyboard injected");for(WORD key:{WORD(VK_CONTROL),WORD(VK_SHIFT),WORD(VK_MENU),WORD(VK_LWIN),WORD(VK_RWIN)})require((GetAsyncKeyState(key)&0x8000)==0,"physical modifier active; no keyboard injected");require(SUCCEEDED(CoCreateInstance(CLSID_TF_ThreadMgr,nullptr,CLSCTX_INPROC_SERVER,IID_PPV_ARGS(&manager))),"OS thread manager");TfClientId client=0;require(SUCCEEDED(manager->Activate(&client)),"OS app thread activation");threadActive=true;require(SUCCEEDED(CoCreateInstance(CLSID_TF_InputProcessorProfiles,nullptr,CLSCTX_INPROC_SERVER,IID_PPV_ARGS(&profiles))),"OS profiles");require(SUCCEEDED(profiles.As(&profileManager)),"OS profile manager");require(SUCCEEDED(profiles->GetCurrentLanguage(&savedLanguage)),"save input language");require(SUCCEEDED(profileManager->GetActiveProfile(GUID_TFCAT_TIP_KEYBOARD,&savedProfile))&&savedProfile.dwProfileType,"save input profile");if(savedLanguage!=0x0804){require(SUCCEEDED(profiles->ChangeCurrentLanguage(0x0804)),"process input language");languageChanged=true;}auto activation=profileManager->ActivateProfile(TF_PROFILETYPE_INPUTPROCESSOR,0x0804,CLSID_PrivateInput,GUID_PrivateInputProfile,nullptr,TF_IPPMF_FORPROCESS);result["osActivationHRESULT"]=uint64_t(uint32_t(activation));require(activation==S_OK,"installed profile activation failed");profileChanged=true;pump(800);result["installedModuleLoaded"]=GetModuleHandleW(L"PrivateInputTSF.dll")!=nullptr;wchar_t loaded[32768]{};require(GetModuleFileNameW(GetModuleHandleW(L"PrivateInputTSF.dll"),loaded,32768)>0,"installed module path");require(_wcsicmp(std::filesystem::path(argv[2]).lexically_normal().make_preferred().c_str(),loaded)==0,"wrong installed DLL version");result["exactInstalledModuleVerified"]=true;
 auto tap=[&](WORD k){require(keys(window,edit,{{k,false},{k,true}}),"quality key focus");pump(90);};
 auto type=[&](const std::string&s){for(char c:s)tap(WORD(c-'a'+'A'));pump(150);};
 auto clear=[&]{tap(VK_ESCAPE);tap(VK_ESCAPE);SetWindowTextW(edit,L"");SendMessageW(edit,EM_SETSEL,0,0);SetFocus(edit);pump(100);};
 auto candidate=[&]()->HWND{HWND h=nullptr;while((h=FindWindowExW(nullptr,h,L"PrivateInput.Candidates",nullptr))){DWORD pid=0;GetWindowThreadProcessId(h,&pid);if(pid==GetCurrentProcessId()&&IsWindowVisible(h))return h;}return nullptr;};
 // Match visible candidate text from this installed version's accessible name.
 // The number is used only after text equality; navigation follows the normal
 // right-arrow selection path, and final host output is checked independently.
 auto visibleIndex=[&](HWND h,const std::wstring&wanted)->int{
  std::wistringstream lines(text(h));std::wstring line;
  while(std::getline(lines,line)){auto dot=line.find(L". ");if(dot==std::wstring::npos||line.substr(dot+2)!=wanted)continue;auto number=line.substr(0,dot);if(number.empty()||number.find_first_not_of(L"0123456789")!=std::wstring::npos)continue;auto value=std::stoul(number);if(value>=1&&value<=256)return int(value)-1;}
  return -1;
 };
 auto chooseText=[&](const std::wstring&wanted){
  require(candidate()!=nullptr,"synthetic candidate panel unavailable");unsigned selected=0;
  for(unsigned step=0;step<128;++step){auto h=candidate();require(h!=nullptr,"synthetic composition disappeared");int found=visibleIndex(h,wanted);
   if(found>=0){require(unsigned(found)>=selected,"candidate order changed during synthetic selection");while(selected<unsigned(found)){tap(VK_RIGHT);++selected;}require(candidate()&&visibleIndex(candidate(),wanted)==found,"synthetic candidate changed before selection");tap(VK_SPACE);return;}
   tap(VK_RIGHT);++selected;
  }
  throw JsonError("named synthetic candidate not available in bounded visible search");
 };
 const auto caseName=std::wstring(argv[3]);require(caseName==L"linghe"||caseName==L"lingduo","allowed synthetic case required");
 const std::string spelling=caseName==L"linghe"?"linghe":"lingduo";
 const std::wstring phrase=caseName==L"linghe"?L"灵鹤":L"另朵";
 result["syntheticCase"]=caseName==L"linghe"?"linghe":"lingduo";
 result["workerDurableVerified"]=false;result["cloudConfirmed"]=false;result["clipboardUntouched"]=true;
 clear();type(spelling);if(!candidate()){clear();tap(VK_SHIFT);type(spelling);}require(candidate(),"Chinese candidate unavailable");
 if(caseName==L"linghe")chooseText(L"灵鹤");else{chooseText(L"另");require(candidate()!=nullptr,"segmented synthetic remainder unavailable");chooseText(L"朵");}
 require(text(edit)==phrase,"final synthetic text mismatch");result["namedCandidateSelection"]=true;result["exactSyntheticCommit"]=true;
 auto notice=[&]()->HWND{HWND h=nullptr;while((h=FindWindowExW(nullptr,h,L"LingheInput.PhraseNotice",nullptr))){DWORD pid=0;GetWindowThreadProcessId(h,&pid);if(pid==GetCurrentProcessId()&&IsWindowVisible(h))return h;}return nullptr;};
 const auto deadline=GetTickCount64()+5000;while(!notice()&&GetTickCount64()<deadline){require(ownFocus(window,edit),"focus changed while awaiting synthetic notice");pump(50);}
 auto card=notice();require(card!=nullptr,"synthetic notice not shown; possibly previously announced or ineligible");result["ownPhraseNoticeVisible"]=true;tracedCard=card;SetLastError(0);cardProcedure=reinterpret_cast<WNDPROC>(SetWindowLongPtrW(card,GWLP_WNDPROC,reinterpret_cast<LONG_PTR>(observeCard)));require(cardProcedure!=nullptr,"own card message observer");
 // Use the owned card's actual screen rectangle. The rightmost padded area is
 // inside its Undo hit region; WindowFromPoint is checked before mouse down.
 RECT rect{};require(GetWindowRect(card,&rect)!=FALSE,"synthetic notice rectangle");UINT dpi=GetDpiForWindow(card);POINT point{rect.right-MulDiv(8,int(dpi?dpi:96),96),(rect.top+rect.bottom)/2};require(GetCursorPos(&savedCursor)!=FALSE,"save pointer position");
 require(ownFocus(window,edit),"focus changed before synthetic undo");require(SetCursorPos(point.x,point.y)!=FALSE,"synthetic undo pointer position");cursorMoved=true;pump(50);require(WindowFromPoint(point)==card&&ownFocus(window,edit),"synthetic undo target no longer owned");
 INPUT mouse[2]{};mouse[0].type=mouse[1].type=INPUT_MOUSE;mouse[0].mi.dwFlags=MOUSEEVENTF_LEFTDOWN;mouse[1].mi.dwFlags=MOUSEEVENTF_LEFTUP;require(SendInput(2,mouse,sizeof(INPUT))==2,"synthetic undo mouse dispatch");const auto undoStarted=GetTickCount64();pump(300);SetCursorPos(savedCursor.x,savedCursor.y);cursorMoved=false;
 // 070 keeps the card while awaiting a local durable ACK. Observe that state
 // with a bounded message pump instead of requiring the old immediate hide.
 while(notice()&&GetTickCount64()-undoStarted<35000){require(ownFocus(window,edit),"focus changed while awaiting synthetic undo");pump(50);}
 result["undoCompletionMilliseconds"]=uint64_t(GetTickCount64()-undoStarted);
 result["undoMouseDispatched"]=true;require(!notice(),"synthetic notice awaiting ACK or retry after bounded wait");result["noticeHiddenAfterUndo"]=true;require(text(edit)==phrase,"undo changed committed host text");result["syntheticHostTextPreserved"]=true;
 // Keep this host alive for ordinary CaptureEmitter/Worker processing. There
 // is intentionally no private-state inspection or direct learning IPC here.
 pump(5000);result["normalWorkerDeliveryGraceMs"]=5000;result["osKeyDispatch"]=true;
 result["passed"]=true;
 }catch(const std::exception&e){result["passed"]=false;result["errorClass"]=std::string(e.what());}
 result["completionTimerMessages"]=int(completionTimerMessages);result["hideFromCompletionTimer"]=int(hideFromCompletionTimer);
 result["cardMouseDownMessages"]=int(cardDown);result["cardMouseUpMessages"]=int(cardUp);result["cardHideBeforeMouseUp"]=int(cardHideBeforeUp);result["cardHideAfterMouseUp"]=int(cardHideAfterUp);result["cardMouseActivateNoActivate"]=mouseActivation==MA_NOACTIVATE;
 if(tracedCard&&cardProcedure&&IsWindow(tracedCard)&&reinterpret_cast<WNDPROC>(GetWindowLongPtrW(tracedCard,GWLP_WNDPROC))==observeCard)SetWindowLongPtrW(tracedCard,GWLP_WNDPROC,reinterpret_cast<LONG_PTR>(cardProcedure));
 if(cursorMoved)SetCursorPos(savedCursor.x,savedCursor.y);
 if(profileChanged&&profileManager&&savedProfile.dwProfileType){auto restored=profileManager->ActivateProfile(savedProfile.dwProfileType,savedProfile.langid,savedProfile.clsid,savedProfile.guidProfile,savedProfile.hkl,TF_IPPMF_FORPROCESS);result["profileRestored"]=SUCCEEDED(restored);if(FAILED(restored))result["passed"]=false;}if(languageChanged&&profiles){auto restored=profiles->ChangeCurrentLanguage(savedLanguage);result["languageRestored"]=SUCCEEDED(restored);if(FAILED(restored))result["passed"]=false;}if(edit)setScope(edit,IS_DEFAULT);if(window)DestroyWindow(window);if(threadActive&&manager)manager->Deactivate();profileManager.Reset();profiles.Reset();manager.Reset();if(rich)FreeLibrary(rich);if(com)CoUninitialize();std::cout<<result.dump()<<'\n';return result.at("passed").boolean()?0:1;}
