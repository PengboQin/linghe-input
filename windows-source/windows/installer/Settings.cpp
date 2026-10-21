#include <windows.h>
#include <shellapi.h>
#include <shlobj.h>
#include <filesystem>
#include <string>
#include <stdexcept>
#include "DesktopPreferences.h"
#include "NativeWindowTheme.h"
namespace fs=std::filesystem;
namespace {
HWND fields[5]{}, labels[5]{}, pairBox=nullptr, insideBox=nullptr, saveButton=nullptr, statusLabel=nullptr, archiveButton=nullptr;
HFONT font=nullptr; UINT dpi=96; fs::path file; bool fixture=false;
NativeWindowTheme windowTheme;constexpr int SaveId=1;
int px(int value) { return MulDiv(value,int(dpi),96); }
fs::path folder(REFKNOWNFOLDERID id) {
 PWSTR path=nullptr; if(FAILED(SHGetKnownFolderPath(id,0,nullptr,&path)))throw std::runtime_error("folder");
 fs::path result(path); CoTaskMemFree(path); return result;
}
void normalPath(const fs::path& path) {
 for(auto p=fs::absolute(path).lexically_normal();!p.empty();p=p.parent_path()) {
  DWORD flags=GetFileAttributesW(p.c_str());
  if(flags!=INVALID_FILE_ATTRIBUTES&&(flags&FILE_ATTRIBUTE_REPARSE_POINT))throw std::runtime_error("reparse point");
  if(p==p.parent_path())break;
 }
}
bool inside(const fs::path& path,const fs::path& root) {
 auto p=fs::absolute(path).lexically_normal().wstring(),r=fs::absolute(root).lexically_normal().wstring()+L"\\";
 return p.size()>r.size()&&CompareStringOrdinal(p.data(),int(r.size()),r.data(),int(r.size()),TRUE)==CSTR_EQUAL;
}
void layout(HWND window) {
 dpi=GetDpiForWindow(window); if(!dpi)dpi=96;
 NONCLIENTMETRICSW metrics{}; metrics.cbSize=sizeof(metrics);
 HFONT replacement=nullptr;
 if(SystemParametersInfoForDpi(SPI_GETNONCLIENTMETRICS,sizeof(metrics),&metrics,0,dpi))replacement=CreateFontIndirectW(&metrics.lfMessageFont);
 if(!replacement)replacement=CreateFontW(-px(12),0,0,0,FW_NORMAL,FALSE,FALSE,FALSE,DEFAULT_CHARSET,OUT_DEFAULT_PRECIS,CLIP_DEFAULT_PRECIS,CLEARTYPE_QUALITY,DEFAULT_PITCH,L"Segoe UI");
 for(int i=0;i<5;i++) {
  SetWindowPos(labels[i],nullptr,px(20),px(23+i*44),px(180),px(24),SWP_NOZORDER);
  SetWindowPos(fields[i],nullptr,px(214),px(20+i*44),px(92),px(220),SWP_NOZORDER);
  SendMessageW(labels[i],WM_SETFONT,reinterpret_cast<WPARAM>(replacement),TRUE);
  SendMessageW(fields[i],WM_SETFONT,reinterpret_cast<WPARAM>(replacement),TRUE);
 }
 SetWindowPos(saveButton,nullptr,px(214),px(314),px(92),px(30),SWP_NOZORDER);
 SetWindowPos(statusLabel,nullptr,px(20),px(355),px(286),px(26),SWP_NOZORDER);
 SendMessageW(saveButton,WM_SETFONT,reinterpret_cast<WPARAM>(replacement),TRUE);
 SendMessageW(statusLabel,WM_SETFONT,reinterpret_cast<WPARAM>(replacement),TRUE);
 SetWindowPos(archiveButton,nullptr,px(20),px(394),px(286),px(30),SWP_NOZORDER);
 SendMessageW(archiveButton,WM_SETFONT,reinterpret_cast<WPARAM>(replacement),TRUE);
 SetWindowPos(pairBox,nullptr,px(20),px(244),px(286),px(24),SWP_NOZORDER);SetWindowPos(insideBox,nullptr,px(20),px(276),px(286),px(24),SWP_NOZORDER);SendMessageW(pairBox,WM_SETFONT,reinterpret_cast<WPARAM>(replacement),TRUE);SendMessageW(insideBox,WM_SETFONT,reinterpret_cast<WPARAM>(replacement),TRUE);
 if(font)DeleteObject(font); font=replacement;
}
void save() {
 int values[3]; for(int i=0;i<3;i++) { auto index=SendMessageW(fields[i],CB_GETCURSEL,0,0); if(index<0||index>6)throw std::runtime_error("selection"); values[i]=int(index)+3; }
 normalPath(file); fs::create_directories(file.parent_path());
 // An exclusive app-specific lock prevents two settings windows losing each other's writes.
 auto lockPath=file; lockPath+=L".save-lock"; normalPath(lockPath);
 HANDLE lock=CreateFileW(lockPath.c_str(),GENERIC_READ|GENERIC_WRITE,0,nullptr,OPEN_ALWAYS,FILE_ATTRIBUTE_TEMPORARY|FILE_FLAG_DELETE_ON_CLOSE,nullptr);
 if(lock==INVALID_HANDLE_VALUE)throw std::runtime_error("busy");
 fs::path temporary; HANDLE output=INVALID_HANDLE_VALUE; bool created=false;
 try {
  temporary=file; temporary+=L"."+std::to_wstring(GetCurrentProcessId())+L"."+std::to_wstring(GetTickCount64())+L".tmp"; normalPath(temporary);
  output=CreateFileW(temporary.c_str(),GENERIC_WRITE,0,nullptr,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,nullptr);
  if(output==INVALID_HANDLE_VALUE)throw std::runtime_error("temporary file"); created=true;
  const char*modes[]={"system","light","dark"};const char*accents[]={"rose","amber","violet","graphite"};auto mode=SendMessageW(fields[3],CB_GETCURSEL,0,0),accent=SendMessageW(fields[4],CB_GETCURSEL,0,0);if(mode<0||mode>2||accent<0||accent>3)throw std::runtime_error("theme selection");auto json=std::string("{\"collapsedCount\":")+std::to_string(values[0])+",\"expandedColumns\":"+std::to_string(values[1])+",\"expandedRows\":"+std::to_string(values[2])+",\"themeMode\":\""+modes[mode]+"\",\"themeAccent\":\""+accents[accent]+"\",\"pairSymbols\":"+(SendMessageW(pairBox,BM_GETCHECK,0,0)==BST_CHECKED?"true":"false")+",\"caretInside\":"+(SendMessageW(insideBox,BM_GETCHECK,0,0)==BST_CHECKED?"true":"false")+"}\n";
  DWORD written=0; bool ok=WriteFile(output,json.data(),DWORD(json.size()),&written,nullptr)&&written==json.size()&&FlushFileBuffers(output);
  CloseHandle(output); output=INVALID_HANDLE_VALUE; if(!ok)throw std::runtime_error("write");
  normalPath(file);
  if(!MoveFileExW(temporary.c_str(),file.c_str(),MOVEFILE_REPLACE_EXISTING|MOVEFILE_WRITE_THROUGH))throw std::runtime_error("replace");
 } catch(...) { if(output!=INVALID_HANDLE_VALUE)CloseHandle(output); if(created)DeleteFileW(temporary.c_str()); CloseHandle(lock); throw; }
 CloseHandle(lock);
}
LRESULT CALLBACK procedure(HWND window,UINT message,WPARAM w,LPARAM l) {
 switch(message) {
 case WM_CREATE: {
  auto state=fixture?private_input::DesktopCandidates{}:readDesktopLayout(file);
  auto preferences=fixture?DesktopInputPreferences{}:readDesktopInputPreferences(file);const wchar_t* names[]={L"单行候选数(&C)",L"展开列数(&L)",L"展开行数(&R)",L"明暗外观",L"主题色"}; int values[]={state.collapsed,state.columns,state.rows,preferences.theme.mode+3,preferences.theme.accent+3};
  for(int i=0;i<5;i++) {
   labels[i]=CreateWindowW(L"STATIC",names[i],WS_CHILD|WS_VISIBLE|SS_LEFT,0,0,0,0,window,nullptr,nullptr,nullptr);
   fields[i]=CreateWindowExW(0,L"COMBOBOX",L"",WS_CHILD|WS_VISIBLE|WS_TABSTOP|CBS_DROPDOWNLIST|WS_VSCROLL,0,0,0,0,window,reinterpret_cast<HMENU>(INT_PTR(100+i)),nullptr,nullptr);
   if(i<3){for(int n=3;n<=9;n++)SendMessageW(fields[i],CB_ADDSTRING,0,reinterpret_cast<LPARAM>(std::to_wstring(n).c_str()));}else{const wchar_t*modes[]={L"跟随系统",L"浅色",L"深色"};const wchar_t*accents[]={L"胭脂",L"琥珀",L"紫藤",L"石墨"};for(int n=0;n<(i==3?3:4);++n)SendMessageW(fields[i],CB_ADDSTRING,0,reinterpret_cast<LPARAM>(i==3?modes[n]:accents[n]));}
   SendMessageW(fields[i],CB_SETCURSEL,values[i]-3,0);
  }
  saveButton=CreateWindowW(L"BUTTON",L"保存(&S)",WS_CHILD|WS_VISIBLE|WS_TABSTOP|BS_DEFPUSHBUTTON,0,0,0,0,window,reinterpret_cast<HMENU>(SaveId),nullptr,nullptr);
  statusLabel=CreateWindowW(L"STATIC",L"",WS_CHILD|WS_VISIBLE|SS_LEFT,0,0,0,0,window,nullptr,nullptr,nullptr);
  archiveButton=CreateWindowW(L"BUTTON",L"设备组与活动归档…",WS_CHILD|WS_VISIBLE|WS_TABSTOP,0,0,0,0,window,reinterpret_cast<HMENU>(9),nullptr,nullptr);
  pairBox=CreateWindowW(L"BUTTON",L"自动输入成对符号",WS_CHILD|WS_VISIBLE|WS_TABSTOP|BS_AUTOCHECKBOX,0,0,0,0,window,reinterpret_cast<HMENU>(110),nullptr,nullptr);insideBox=CreateWindowW(L"BUTTON",L"输入成对符号后光标居中",WS_CHILD|WS_VISIBLE|WS_TABSTOP|BS_AUTOCHECKBOX,0,0,0,0,window,reinterpret_cast<HMENU>(111),nullptr,nullptr);SendMessageW(pairBox,BM_SETCHECK,preferences.pairSymbols?BST_CHECKED:BST_UNCHECKED,0);SendMessageW(insideBox,BM_SETCHECK,preferences.caretInside?BST_CHECKED:BST_UNCHECKED,0);
  windowTheme.apply(window,preferences.theme);layout(window); EnableWindow(saveButton,fixture?TRUE:FALSE); return 0;
 }
 case WM_DPICHANGED: {
  const auto* bounds=reinterpret_cast<const RECT*>(l);
  SetWindowPos(window,nullptr,bounds->left,bounds->top,bounds->right-bounds->left,bounds->bottom-bounds->top,SWP_NOZORDER|SWP_NOACTIVATE); layout(window); return 0;
 }
 case WM_ERASEBKGND:{RECT area;GetClientRect(window,&area);auto dc=reinterpret_cast<HDC>(w);FillRect(dc,&area,windowTheme.paint(dc));return 1;}
 case WM_CTLCOLORSTATIC:case WM_CTLCOLOREDIT:case WM_CTLCOLORLISTBOX:case WM_CTLCOLORBTN:return reinterpret_cast<LRESULT>(windowTheme.paint(reinterpret_cast<HDC>(w)));
 case WM_SETTINGCHANGE:windowTheme.apply(window,readDesktopInputPreferences(file).theme);layout(window); return 0;
 case WM_COMMAND:
  if(LOWORD(w)==9) {wchar_t path[32768];DWORD n=GetModuleFileNameW(nullptr,path,32768);if(!n||n>=32768)return 0;auto exe=fs::path(path).parent_path()/L"LingheInputActivity.exe";if(!fixture&&reinterpret_cast<INT_PTR>(ShellExecuteW(window,L"open",exe.c_str(),L"--settings",exe.parent_path().c_str(),SW_SHOWNORMAL))<=32)MessageBoxW(window,L"活动归档组件未安装。请更新到包含该组件的版本。",L"灵鹤输入法",MB_OK|MB_ICONINFORMATION);return 0;}
  if(LOWORD(w)>=100&&LOWORD(w)<105&&HIWORD(w)==CBN_SELCHANGE) { EnableWindow(saveButton,TRUE); SetWindowTextW(statusLabel,L""); return 0; }
  if(LOWORD(w)==110||LOWORD(w)==111){EnableWindow(saveButton,TRUE);SetWindowTextW(statusLabel,L"");return 0;}
  if(LOWORD(w)==SaveId&&IsWindowEnabled(saveButton)) {
   try { save();windowTheme.apply(window,readDesktopInputPreferences(file).theme); SetWindowTextW(statusLabel,L"已保存，下次输入时生效。"); EnableWindow(saveButton,FALSE); SetFocus(fields[0]); }
   catch(...) { MessageBoxW(window,L"设置未能保存。请关闭其他设置窗口后重试。",L"灵鹤输入法",MB_OK|MB_ICONERROR); }
   return 0;
  }
  break;
 case WM_DESTROY:if(font) { DeleteObject(font); font=nullptr; } PostQuitMessage(0); return 0;
 }
 return DefWindowProcW(window,message,w,l);
}
}
int WINAPI wWinMain(HINSTANCE instance,HINSTANCE,PWSTR,int) {
 try {
  SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
  int count=0; auto arguments=CommandLineToArgvW(GetCommandLineW(),&count); if(!arguments)return 2;
  bool valid=count==1;
  if(count==3&&std::wstring(arguments[1])==L"--fixture") { file=arguments[2]; fixture=true; valid=true; }
  LocalFree(arguments); if(!valid)return 2;
  if(fixture) {
   auto root=folder(FOLDERID_LocalAppData)/L"PrivateInputDev/fixtures";
   if(!file.is_absolute()||file.extension()!=L".json"||!inside(file,root))return 2;
   normalPath(file); if(fs::exists(file))return 2;
  } else file=folder(FOLDERID_LocalAppData)/L"PrivateInput/desktop-candidate-layout-v1.json";
  WNDCLASSW cls{}; cls.lpfnWndProc=procedure; cls.hInstance=instance; cls.lpszClassName=L"LingheInput.Settings"; cls.hCursor=LoadCursor(nullptr,IDC_ARROW); cls.hbrBackground=GetSysColorBrush(COLOR_WINDOW);
  if(!RegisterClassW(&cls))return 1;
  dpi=GetDpiForSystem(); if(!dpi)dpi=96;
  DWORD style=WS_OVERLAPPED|WS_CAPTION|WS_SYSMENU; RECT bounds{0,0,px(326),px(440)}; AdjustWindowRectExForDpi(&bounds,style,FALSE,WS_EX_CONTROLPARENT,dpi);
  HWND window=CreateWindowExW(WS_EX_CONTROLPARENT,cls.lpszClassName,fixture?L"灵鹤输入法 · 输入设置 · 测试":L"灵鹤输入法 · 输入设置",style,CW_USEDEFAULT,CW_USEDEFAULT,bounds.right-bounds.left,bounds.bottom-bounds.top,nullptr,nullptr,instance,nullptr);
  if(!window)return 1; ShowWindow(window,SW_SHOWNORMAL); UpdateWindow(window); SetFocus(fields[0]);
  MSG message{}; int result;
  while((result=GetMessageW(&message,nullptr,0,0))>0) {
   if(message.message==WM_KEYDOWN&&message.wParam==VK_ESCAPE) { DestroyWindow(window); continue; }
   if(message.message==WM_KEYDOWN&&message.wParam==VK_RETURN) {
    // Preserve Enter's normal selection behavior while a dropdown is open.
    bool dropped=false; for(HWND field:fields)if(SendMessageW(field,CB_GETDROPPEDSTATE,0,0))dropped=true;
    if(!dropped) { SendMessageW(window,WM_COMMAND,SaveId,0); continue; }
   }
   if(!IsDialogMessageW(window,&message)) { TranslateMessage(&message); DispatchMessageW(&message); }
  }
  return result<0?1:0;
 } catch(...) { return 1; }
}
