#include "CandidateWindow.h"
#include "NativeWindowTheme.h"
#include <algorithm>
#include <limits>
#include <windowsx.h>
namespace {constexpr wchar_t ClassName[]=L"PrivateInput.Candidates";}
CandidateWindow::~CandidateWindow(){if(window)DestroyWindow(window);if(font)DeleteObject(font);}
void CandidateWindow::hide(){if(window)ShowWindow(window,SW_HIDE);labels.clear();layout={};pressed.reset();}
void CandidateWindow::show(HINSTANCE instance,const RECT &anchor,const std::vector<std::wstring>& candidates,unsigned long long version,UINT dpi,const private_input::DesktopCandidates& state){
 if(candidates.empty()){hide();return;}
 if(!window){systemDark=desktopSystemDark();WNDCLASSEXW cls{};cls.cbSize=sizeof(cls);cls.lpfnWndProc=procedure;cls.hInstance=instance;cls.lpszClassName=ClassName;cls.hCursor=LoadCursor(nullptr,IDC_ARROW);RegisterClassExW(&cls);window=CreateWindowExW(WS_EX_NOACTIVATE|WS_EX_TOOLWINDOW|WS_EX_TOPMOST,ClassName,L"灵鹤输入法候选",WS_POPUP,0,0,0,0,nullptr,nullptr,instance,this);}
 if(!window)return;labels=candidates;revision=version;navigation=state;displayDpi=std::clamp(dpi,48u,768u);
 if(font)DeleteObject(font);font=CreateFontW(-MulDiv(12,int(displayDpi),72),0,0,0,FW_NORMAL,FALSE,FALSE,FALSE,DEFAULT_CHARSET,OUT_DEFAULT_PRECIS,CLIP_DEFAULT_PRECIS,CLEARTYPE_QUALITY,DEFAULT_PITCH,L"Microsoft YaHei UI");
 MONITORINFO monitor{};monitor.cbSize=sizeof(monitor);
 if(!GetMonitorInfoW(MonitorFromRect(&anchor,MONITOR_DEFAULTTONEAREST),&monitor)){hide();return;}
 std::vector<int> widths(labels.size());HDC dc=GetDC(window);if(!dc){hide();return;}auto old=SelectObject(dc,font);
 const auto first=std::min(navigation.first(),labels.size()),end=first+std::min(navigation.pageSize(),labels.size()-first);
 for(auto i=first;i<end;++i){SIZE size{};GetTextExtentPoint32W(dc,labels[i].c_str(),int(std::min(labels[i].size(),std::size_t(std::numeric_limits<int>::max()))),&size);widths[i]=int(size.cx);}
 SelectObject(dc,old);ReleaseDC(window,dc);
 const auto& work=monitor.rcWork;
 const private_input::CandidateRect caretRect{int(anchor.left),int(anchor.top),int(anchor.right),int(anchor.bottom)};
 const private_input::CandidateRect workRect{int(work.left),int(work.top),int(work.right),int(work.bottom)};
 const int availableWidth=private_input::candidateWidthAtCaret(caretRect,workRect,navigation.width(),displayDpi);
 layout=private_input::candidateLayout(widths,navigation,availableWidth,int(work.bottom-work.top),displayDpi);
 if(layout.slots.empty()){hide();return;}
 // Native accessible name mirrors only visible choices. Painting remains unchanged.
 std::wstring accessible=L"灵鹤候选";for(const auto&slot:layout.slots){auto line=L"\n"+std::to_wstring(slot.index+1)+L". "+labels[slot.index];if(accessible.size()+line.size()>8192)break;accessible+=line;}SetWindowTextW(window,accessible.c_str());
 auto position=private_input::candidatePosition(caretRect,workRect,layout.width,layout.height,private_input::candidateScale(4,displayDpi));
 SetWindowPos(window,HWND_TOPMOST,position.x,position.y,layout.width,layout.height,SWP_NOACTIVATE|SWP_SHOWWINDOW);InvalidateRect(window,nullptr,TRUE);
}
void CandidateWindow::paint(){
 PAINTSTRUCT ps;HDC dc=BeginPaint(window,&ps);RECT client;GetClientRect(window,&client);auto palette=theme.palette(systemDark);auto color=[](const private_input::ThemeRGB&c){return RGB(int(c.red*255+.5),int(c.green*255+.5),int(c.blue*255+.5));};HBRUSH background=CreateSolidBrush(color(palette.background)),selection=CreateSolidBrush(color(palette.selection)),border=CreateSolidBrush(color(palette.border));FillRect(dc,&client,background);
 RECT edge=client;for(int i=0;i<layout.border;++i){FrameRect(dc,&edge,border);InflateRect(&edge,-1,-1);}
 SetBkMode(dc,TRANSPARENT);auto old=SelectObject(dc,font);
 const int inset=private_input::candidateScale(5,displayDpi),numberWidth=private_input::candidateScale(16,displayDpi),gutter=private_input::candidateScale(24,displayDpi);
 for(const auto& item:layout.slots){const auto i=item.index;const auto& r=item.rect;RECT slot{r.left,r.top,r.right,r.bottom};bool selected=i==navigation.selected;
  if(selected)FillRect(dc,&slot,selection);SetTextColor(dc,color(palette.text));
  const int saved=SaveDC(dc);IntersectClipRect(dc,slot.left,slot.top,slot.right,slot.bottom);
  RECT number=slot;number.left+=inset;number.right=std::min(slot.right,number.left+numberWidth);
  RECT text=slot;text.left+=gutter;text.right-=inset;
  const auto shortcut=navigation.shortcut(i);if(shortcut&&number.right>number.left){auto digit=std::to_wstring(shortcut);DrawTextW(dc,digit.c_str(),int(digit.size()),&number,DT_LEFT|DT_VCENTER|DT_SINGLELINE|DT_NOPREFIX);}
  if(text.right>text.left)DrawTextW(dc,labels[i].c_str(),int(std::min(labels[i].size(),std::size_t(std::numeric_limits<int>::max()))),&text,DT_LEFT|DT_VCENTER|DT_SINGLELINE|DT_END_ELLIPSIS|DT_NOPREFIX);
  RestoreDC(dc,saved);
 }
 SelectObject(dc,old);DeleteObject(background);DeleteObject(selection);DeleteObject(border);EndPaint(window,&ps);
}
LRESULT CALLBACK CandidateWindow::procedure(HWND hwnd,UINT message,WPARAM w,LPARAM l){auto*self=reinterpret_cast<CandidateWindow*>(GetWindowLongPtrW(hwnd,GWLP_USERDATA));if(message==WM_NCCREATE){self=static_cast<CandidateWindow*>(reinterpret_cast<CREATESTRUCTW*>(l)->lpCreateParams);SetWindowLongPtrW(hwnd,GWLP_USERDATA,reinterpret_cast<LONG_PTR>(self));}if(!self)return DefWindowProcW(hwnd,message,w,l);
 switch(message){case WM_SETTINGCHANGE:self->systemDark=desktopSystemDark();InvalidateRect(hwnd,nullptr,TRUE);return 0;case WM_MOUSEACTIVATE:return MA_NOACTIVATE;case WM_PAINT:self->paint();return 0;case WM_ERASEBKGND:return 1;
 case WM_RBUTTONUP:{auto index=self->layout.hit(GET_X_LPARAM(l),GET_Y_LPARAM(l));if(!index||!self->manage||!self->managementEnabled)return 0;bool pinned=self->pinned&&self->pinned(*index);HMENU menu=CreatePopupMenu();if(!menu)return 0;AppendMenuW(menu,MF_STRING,100,pinned?L"取消置顶":L"置顶候选");AppendMenuW(menu,MF_STRING,101,L"恢复默认词频");POINT point{GET_X_LPARAM(l),GET_Y_LPARAM(l)};ClientToScreen(hwnd,&point);auto result=TrackPopupMenuEx(menu,TPM_RETURNCMD|TPM_NONOTIFY|TPM_RIGHTBUTTON,point.x,point.y,hwnd,nullptr);DestroyMenu(menu);if(result==100||result==101)self->manage(*index,self->revision,result==101?5:(pinned?7:6));return 0;}
 case WM_LBUTTONDOWN:self->pressed=self->layout.hit(GET_X_LPARAM(l),GET_Y_LPARAM(l));self->pressedRevision=self->revision;if(self->observe&&self->pressed)self->observe(*self->pressed,self->revision,false,true);return 0;
 case WM_LBUTTONUP:{const auto index=self->layout.hit(GET_X_LPARAM(l),GET_Y_LPARAM(l));auto pressed=self->pressed;auto version=self->pressedRevision;self->pressed.reset();const bool valid=index&&pressed&&*index==*pressed&&version==self->revision;if(self->observe)self->observe(index?*index:SIZE_MAX,self->revision,true,valid);if(valid)self->choose(*index,version);return 0;}
 case WM_MOUSEWHEEL:if(self->wheel)self->wheel(GET_WHEEL_DELTA_WPARAM(w)>0?-1:1);return 0;case WM_DESTROY:self->window=nullptr;return 0;default:return DefWindowProcW(hwnd,message,w,l);}
}
