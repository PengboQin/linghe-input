#pragma once
// Non-activating “新词 X　撤销” card shown under the last caret anchor after a
// new phrase is remembered. Next key, focus change or undo hides it.
#include <windows.h>
#include <functional>
#include <atomic>
#include <memory>
#include "BackgroundTask.h"
#include "../activity/LearningIntentWire.h"
#include <string>
#include "DesktopTheme.h"
#include "NativeWindowTheme.h"

class PhraseNotice {
 HWND window=nullptr;HFONT font=nullptr;std::wstring text,baseText;RECT undoArea{};UINT dpi=96;
 struct Preparation {std::atomic<bool> done{false};bool eligible=false;};
 std::shared_ptr<Preparation> pending,working;
 std::function<void()> present;
 std::function<std::shared_ptr<private_input::activity::LearningDelivery>()> undo;
 std::shared_ptr<private_input::activity::LearningDelivery> delivery;std::wstring actionText=L"撤销";bool retryAllowed=true;private_input::DesktopTheme theme;
 static constexpr const wchar_t *ClassName=L"LingheInput.PhraseNotice";
 static LRESULT CALLBACK procedure(HWND hwnd,UINT message,WPARAM wparam,LPARAM lparam){
  auto self=reinterpret_cast<PhraseNotice*>(GetWindowLongPtrW(hwnd,GWLP_USERDATA));
  if(message==WM_NCCREATE){auto create=reinterpret_cast<CREATESTRUCTW*>(lparam);SetWindowLongPtrW(hwnd,GWLP_USERDATA,reinterpret_cast<LONG_PTR>(create->lpCreateParams));return DefWindowProcW(hwnd,message,wparam,lparam);}
  if(!self)return DefWindowProcW(hwnd,message,wparam,lparam);
  switch(message){
   case WM_MOUSEACTIVATE:return MA_NOACTIVATE;
   case WM_SETCURSOR:{POINT p{};GetCursorPos(&p);ScreenToClient(hwnd,&p);SetCursor(LoadCursor(nullptr,PtInRect(&self->undoArea,p)?IDC_HAND:IDC_ARROW));return TRUE;}
   case WM_LBUTTONUP:{POINT p{GET_X_LPARAM_SAFE(lparam),GET_Y_LPARAM_SAFE(lparam)};if(PtInRect(&self->undoArea,p)&&self->retryAllowed&&self->undo){self->retryAllowed=false;self->text=self->baseText;self->actionText=L"撤销中";self->delivery=self->undo();if(!self->delivery){self->actionText=L"重试撤销";self->retryAllowed=true;}else if(self->delivery->complete.load())self->updateDelivery();else if(!SetTimer(hwnd,2,50,nullptr)){self->actionText=L"重试撤销";self->retryAllowed=true;}InvalidateRect(hwnd,nullptr,TRUE);}return 0;}
   case WM_TIMER:
    if(wparam==2&&self->delivery&&self->delivery->complete.load()){
     self->updateDelivery();return 0;
    }
    if(wparam==1&&self->pending&&self->pending->done.load()){
     KillTimer(hwnd,1);const bool eligible=self->pending->eligible;
     self->pending.reset();auto action=std::move(self->present);self->present=nullptr;
     if(eligible&&action)action();
    }return 0;
   case WM_PAINT:self->paint();return 0;
  }
  return DefWindowProcW(hwnd,message,wparam,lparam);
 }
 static int GET_X_LPARAM_SAFE(LPARAM l){return static_cast<short>(LOWORD(l));}
 static int GET_Y_LPARAM_SAFE(LPARAM l){return static_cast<short>(HIWORD(l));}
 void updateDelivery(){
  if(!delivery||!delivery->complete.load())return;KillTimer(window,2);using Status=private_input::activity::LearningIntentStatus;auto status=delivery->status.load();
  if(status==Status::Applied||status==Status::Duplicate){hide();return;}
  retryAllowed=status==Status::Retry||status==Status::Quota||status==Status::Expired;if(status==Status::Expired)text=L"请求已过期";actionText=status==Status::Expired?L"重新撤销":retryAllowed?L"重试撤销":status==Status::Pending?L"等待处理":L"状态变化";InvalidateRect(window,nullptr,TRUE);
 }
 int scale(int value)const{return MulDiv(value,static_cast<int>(dpi),96);}
 void paint(){
  PAINTSTRUCT ps{};HDC dc=BeginPaint(window,&ps);RECT client{};GetClientRect(window,&client);
  auto palette=theme.palette(desktopSystemDark());auto color=[](const private_input::ThemeRGB&c){return RGB(int(c.red*255+.5),int(c.green*255+.5),int(c.blue*255+.5));};
  HBRUSH background=CreateSolidBrush(color(palette.background));FillRect(dc,&client,background);DeleteObject(background);
  HPEN border=CreatePen(PS_SOLID,1,color(palette.border));auto oldPen=SelectObject(dc,border);auto oldBrush=SelectObject(dc,GetStockObject(NULL_BRUSH));Rectangle(dc,client.left,client.top,client.right,client.bottom);SelectObject(dc,oldBrush);SelectObject(dc,oldPen);DeleteObject(border);
  auto old=SelectObject(dc,font);SetBkMode(dc,TRANSPARENT);
  RECT label=client;label.left+=scale(12);label.right=undoArea.left-scale(8);SetTextColor(dc,color(palette.text));
  DrawTextW(dc,text.c_str(),-1,&label,DT_SINGLELINE|DT_VCENTER|DT_END_ELLIPSIS|DT_NOPREFIX);
  RECT action=undoArea;SetTextColor(dc,color(palette.text));SetBkMode(dc,OPAQUE);SetBkColor(dc,color(palette.selection));{HBRUSH chip=CreateSolidBrush(color(palette.selection));FillRect(dc,&action,chip);DeleteObject(chip);}DrawTextW(dc,actionText.c_str(),-1,&action,DT_SINGLELINE|DT_VCENTER|DT_CENTER|DT_NOPREFIX);
  SelectObject(dc,old);EndPaint(window,&ps);
 }
public:
 ~PhraseNotice(){hide();if(window)DestroyWindow(window);if(font)DeleteObject(font);}
 void setTheme(private_input::DesktopTheme value){theme=value;}
 bool visible()const{return window&&IsWindowVisible(window);}
#ifdef PRIVATE_INPUT_PHRASE_NOTICE_TEST_HOOKS
 HWND testWindow()const{return window;}
#endif
 // Only immutable phrase data enters the worker. The result is polled on
 // this window's thread; hide/deactivation drops it without joining.
 void prepare(HINSTANCE instance,std::function<bool()> classify,std::function<void()> ready){
  hide();
  if(working&&!working->done.load())return; // One optional lookup at a time.
  if(!window){WNDCLASSEXW cls{};cls.cbSize=sizeof(cls);cls.lpfnWndProc=procedure;cls.hInstance=instance;cls.lpszClassName=ClassName;cls.hCursor=LoadCursor(nullptr,IDC_ARROW);RegisterClassExW(&cls);
   window=CreateWindowExW(WS_EX_NOACTIVATE|WS_EX_TOOLWINDOW|WS_EX_TOPMOST,ClassName,L"灵鹤输入法提示",WS_POPUP,0,0,0,0,nullptr,nullptr,instance,this);if(!window)return;}
  auto result=std::make_shared<Preparation>();working=result;pending=result;present=std::move(ready);
  if(!private_input::BackgroundTask::start([result,classify=std::move(classify)]{try{result->eligible=classify();}catch(...){result->eligible=false;}result->done.store(true);})) {result->done.store(true);hide();return;}
  if(!SetTimer(window,1,50,nullptr))hide();
 }
 void show(HINSTANCE instance,const RECT &anchor,UINT anchorDpi,const std::wstring &phrase,std::function<std::shared_ptr<private_input::activity::LearningDelivery>()> onUndo){
  if(!window){WNDCLASSEXW cls{};cls.cbSize=sizeof(cls);cls.lpfnWndProc=procedure;cls.hInstance=instance;cls.lpszClassName=ClassName;cls.hCursor=LoadCursor(nullptr,IDC_ARROW);RegisterClassExW(&cls);
   window=CreateWindowExW(WS_EX_NOACTIVATE|WS_EX_TOOLWINDOW|WS_EX_TOPMOST,ClassName,L"灵鹤输入法提示",WS_POPUP,0,0,0,0,nullptr,nullptr,instance,this);if(!window)return;}
  if(dpi!=anchorDpi||!font){dpi=anchorDpi?anchorDpi:96;if(font)DeleteObject(font);font=CreateFontW(-scale(14),0,0,0,FW_NORMAL,0,0,0,DEFAULT_CHARSET,0,0,CLEARTYPE_QUALITY,0,L"Microsoft YaHei UI");}
  text=baseText=L"新词 "+phrase;undo=std::move(onUndo);delivery.reset();actionText=L"撤销";retryAllowed=true;
  HDC dc=GetDC(window);auto old=SelectObject(dc,font);SIZE label{},action{};GetTextExtentPoint32W(dc,text.c_str(),static_cast<int>(text.size()),&label);GetTextExtentPoint32W(dc,L"重试撤销",4,&action);SelectObject(dc,old);ReleaseDC(window,dc);
  const int height=scale(32),width=scale(12)+label.cx+scale(14)+action.cx+scale(14);
  undoArea={width-action.cx-scale(14)-scale(4),0,width,height};
  int x=anchor.left,y=anchor.bottom+scale(4);HMONITOR monitor=MonitorFromRect(&anchor,MONITOR_DEFAULTTONEAREST);MONITORINFO info{sizeof(info)};
  if(GetMonitorInfoW(monitor,&info)){x=(std::min)((std::max)(x,static_cast<int>(info.rcWork.left)),static_cast<int>(info.rcWork.right)-width);if(y+height>info.rcWork.bottom)y=anchor.top-height-scale(4);}
  SetWindowPos(window,HWND_TOPMOST,x,y,width,height,SWP_NOACTIVATE|SWP_SHOWWINDOW);InvalidateRect(window,nullptr,TRUE);
 }
 // Delete as the first key after a remembered phrase: it was a typo or a wrong
 // pick, so send the same durable forget intent as the undo button (no retry UI).
 void rejectByDelete(){if(!visible()||!undo){hide();return;}auto action=undo;hide();try{(void)action();}catch(...){}}
 void hide(){pending.reset();present=nullptr;undo=nullptr;delivery.reset();if(window){KillTimer(window,1);KillTimer(window,2);ShowWindow(window,SW_HIDE);}}
};
