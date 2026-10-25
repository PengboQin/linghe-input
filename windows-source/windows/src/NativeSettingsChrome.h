#pragma once
#include <windows.h>
#include <uxtheme.h>
#include <commctrl.h>
#include <inputscope.h>
#include <algorithm>
#include <cstdlib>
#include <string>
#include "NativeWindowTheme.h"

// Native edit/button/combo behavior and accessibility; only navigation is painted.
inline void settingsControlTheme(HWND control){SetWindowTheme(control,L"Explorer",nullptr);}
inline const wchar_t*settingsSectionName(unsigned section){static constexpr const wchar_t*names[]={L"输入设置",L"外观",L"词库与学习",L"设备与同步",L"隐私与归档"};return section<5?names[section]:L"";}
inline int settingsScale(int value,UINT dpi){return MulDiv(value,int(dpi?dpi:96),96);}
inline HFONT settingsBodyFont(UINT dpi){
 NONCLIENTMETRICSW metrics{};metrics.cbSize=sizeof(metrics);
 if(SystemParametersInfoForDpi(SPI_GETNONCLIENTMETRICS,sizeof(metrics),&metrics,0,dpi)){
  metrics.lfMessageFont.lfHeight=-std::max<LONG>(std::abs(metrics.lfMessageFont.lfHeight),settingsScale(14,dpi));
  if(auto font=CreateFontIndirectW(&metrics.lfMessageFont))return font;
 }
 return CreateFontW(-settingsScale(14,dpi),0,0,0,FW_NORMAL,FALSE,FALSE,FALSE,DEFAULT_CHARSET,OUT_DEFAULT_PRECIS,CLIP_DEFAULT_PRECIS,CLEARTYPE_QUALITY,DEFAULT_PITCH,L"Segoe UI");
}
inline HFONT settingsHeadingFont(UINT dpi,bool pageTitle=false){return CreateFontW(-settingsScale(pageTitle?22:14,dpi),0,0,0,FW_SEMIBOLD,FALSE,FALSE,FALSE,DEFAULT_CHARSET,OUT_DEFAULT_PRECIS,CLIP_DEFAULT_PRECIS,CLEARTYPE_QUALITY,DEFAULT_PITCH,L"Segoe UI");}
inline void settingsFitWindow(HWND window,UINT dpi){
 // Both native hosts share the same client size, with a compact layout that
 // still fits a 1080p work area at 200 percent DPI. No font-size shrinking.
 RECT frame{0,0,settingsScale(732,dpi),settingsScale(520,dpi)};
 const auto style=DWORD(GetWindowLongPtrW(window,GWL_STYLE)),extended=DWORD(GetWindowLongPtrW(window,GWL_EXSTYLE));
 AdjustWindowRectExForDpi(&frame,style,FALSE,extended,dpi);
 MONITORINFO info{};info.cbSize=sizeof(info);if(GetMonitorInfoW(MonitorFromWindow(window,MONITOR_DEFAULTTONEAREST),&info)){
  const auto height=std::min(frame.bottom-frame.top,std::max(settingsScale(480,dpi)+(frame.bottom-frame.top-settingsScale(520,dpi)),info.rcWork.bottom-info.rcWork.top));
  SetWindowPos(window,nullptr,0,0,frame.right-frame.left,height,SWP_NOMOVE|SWP_NOZORDER|SWP_NOACTIVATE);
 }
}
inline HRESULT settingsInputScope(HWND window,InputScope scope){
 // Same public Msctf API; some cross SDKs omit its import library.
 static auto call=[] {auto module=LoadLibraryExW(L"msctf.dll",nullptr,LOAD_LIBRARY_SEARCH_SYSTEM32);return module?reinterpret_cast<HRESULT(WINAPI*)(HWND,InputScope)>(GetProcAddress(module,"SetInputScope")):nullptr;}();
 return call?call(window,scope):E_NOTIMPL;
}
struct NativeSettingsRuntime{
 HRESULT apartment=CoInitializeEx(nullptr,COINIT_APARTMENTTHREADED);
 NativeSettingsRuntime(){INITCOMMONCONTROLSEX init{sizeof(init),ICC_STANDARD_CLASSES};InitCommonControlsEx(&init);}
 ~NativeSettingsRuntime(){if(SUCCEEDED(apartment))CoUninitialize();}
};
inline void settingsDrawNavigation(const DRAWITEMSTRUCT& item,const NativeWindowTheme& theme,bool selected){
 RECT bounds=item.rcItem;SetDCBrushColor(item.hDC,theme.palette.background.red<.5?RGB(28,28,31):RGB(245,245,248));FillRect(item.hDC,&bounds,reinterpret_cast<HBRUSH>(GetStockObject(DC_BRUSH)));
 const auto& colors=theme.palette;
 const UINT dpi=GetDpiForWindow(item.hwndItem);const int inset=settingsScale(2,dpi),radius=settingsScale(10,dpi);
 if(selected){auto brush=CreateSolidBrush(desktopColor(colors.selection));auto old=SelectObject(item.hDC,brush);auto pen=SelectObject(item.hDC,GetStockObject(NULL_PEN));RoundRect(item.hDC,bounds.left+inset,bounds.top+inset,bounds.right-inset,bounds.bottom-inset,radius,radius);SelectObject(item.hDC,pen);SelectObject(item.hDC,old);DeleteObject(brush);}
 if(selected){RECT marker{bounds.left+settingsScale(4,dpi),bounds.top+settingsScale(12,dpi),bounds.left+settingsScale(7,dpi),bounds.bottom-settingsScale(12,dpi)};SetDCBrushColor(item.hDC,desktopColor(colors.text));FillRect(item.hDC,&marker,reinterpret_cast<HBRUSH>(GetStockObject(DC_BRUSH)));}
 wchar_t text[96]{};GetWindowTextW(item.hwndItem,text,96);auto font=reinterpret_cast<HFONT>(SendMessageW(item.hwndItem,WM_GETFONT,0,0));auto old=SelectObject(item.hDC,font);SetBkMode(item.hDC,TRANSPARENT);SetTextColor(item.hDC,desktopColor((item.itemState&ODS_DISABLED)?colors.border:colors.text));bounds.left+=settingsScale(16,dpi);DrawTextW(item.hDC,text,-1,&bounds,DT_SINGLELINE|DT_VCENTER|DT_LEFT);SelectObject(item.hDC,old);
 if(item.itemState&ODS_FOCUS){InflateRect(&bounds,-4,-4);DrawFocusRect(item.hDC,&bounds);}
}
inline void settingsWindowIcon(HWND window){auto instance=GetModuleHandleW(nullptr);SendMessageW(window,WM_SETICON,ICON_SMALL,reinterpret_cast<LPARAM>(LoadIconW(instance,MAKEINTRESOURCEW(101))));SendMessageW(window,WM_SETICON,ICON_BIG,reinterpret_cast<LPARAM>(LoadIconW(instance,MAKEINTRESOURCEW(101))));}

// Settings-only presentation layer. Native BUTTON/EDIT/COMBOBOX objects retain
// their keyboard, accessibility, focus and command behavior; no worker changes.
struct SettingsSurface {
 NativeWindowTheme* theme=nullptr;
 int page=0; // shared five-page navigation order
};
inline COLORREF settingsCanvas(const NativeWindowTheme& theme){
 return theme.palette.background.red<.5?RGB(28,28,31):RGB(245,245,248);
}
inline RECT settingsCard(unsigned page,unsigned index,UINT dpi){
 RECT r{176,72,708,232};
 if(page==0)r=index?RECT{176,248,708,382}:RECT{176,72,708,244};
 else if(page==1)r={176,72,708,214};
 else if(page==2)r={176,72,708,220};
 else if(page==3)r=index?RECT{176,334,708,382}:RECT{176,72,708,332};
 else r=index?RECT{176,194,708,382}:RECT{176,72,708,190};
 r.left=settingsScale(r.left,dpi);r.top=settingsScale(r.top,dpi);r.right=settingsScale(r.right,dpi);r.bottom=settingsScale(r.bottom,dpi);return r;
}
inline unsigned settingsCardCount(unsigned page){return page==0||page==3||page==4?2:1;}
inline void settingsRoundFill(HDC dc,RECT r,COLORREF fill,COLORREF edge,int radius){
 auto brush=CreateSolidBrush(fill);auto pen=CreatePen(PS_SOLID,1,edge);
 auto oldBrush=SelectObject(dc,brush),oldPen=SelectObject(dc,pen);
 RoundRect(dc,r.left,r.top,r.right,r.bottom,radius,radius);
 SelectObject(dc,oldBrush);SelectObject(dc,oldPen);DeleteObject(brush);DeleteObject(pen);
}
inline COLORREF settingsControlBackground(HWND parent,HWND control,const SettingsSurface& surface){
 RECT r{};GetWindowRect(control,&r);MapWindowPoints(HWND_DESKTOP,parent,reinterpret_cast<POINT*>(&r),2);
 POINT center{(r.left+r.right)/2,(r.top+r.bottom)/2};
 for(unsigned i=0;i<settingsCardCount(surface.page);++i){auto card=settingsCard(surface.page,i,GetDpiForWindow(parent));if(PtInRect(&card,center))return desktopColor(surface.theme->palette.background);}
 return settingsCanvas(*surface.theme);
}
inline LRESULT CALLBACK settingsSurfaceProcedure(HWND window,UINT message,WPARAM w,LPARAM l,UINT_PTR id,DWORD_PTR data){
 auto& surface=*reinterpret_cast<SettingsSurface*>(data);auto& theme=*surface.theme;
 const auto dpi=GetDpiForWindow(window);const auto text=desktopColor(theme.palette.text),edge=desktopColor(theme.palette.border);
 if(message==WM_ERASEBKGND){
  auto dc=reinterpret_cast<HDC>(w);RECT r;GetClientRect(window,&r);SetDCBrushColor(dc,settingsCanvas(theme));FillRect(dc,&r,reinterpret_cast<HBRUSH>(GetStockObject(DC_BRUSH)));
  for(unsigned i=0;i<settingsCardCount(surface.page);++i)settingsRoundFill(dc,settingsCard(surface.page,i,dpi),desktopColor(theme.palette.background),edge,settingsScale(12,dpi));
  auto icon=reinterpret_cast<HICON>(LoadImageW(GetModuleHandleW(nullptr),MAKEINTRESOURCEW(101),IMAGE_ICON,settingsScale(28,dpi),settingsScale(28,dpi),LR_SHARED));if(icon)DrawIconEx(dc,settingsScale(24,dpi),settingsScale(28,dpi),icon,settingsScale(28,dpi),settingsScale(28,dpi),0,nullptr,DI_NORMAL);
  return 1;
 }
 if(message==WM_CTLCOLORSTATIC||message==WM_CTLCOLOREDIT||message==WM_CTLCOLORBTN||message==WM_CTLCOLORLISTBOX){
  auto dc=reinterpret_cast<HDC>(w);auto control=reinterpret_cast<HWND>(l);
  const auto background=message==WM_CTLCOLORLISTBOX?desktopColor(theme.palette.background):settingsControlBackground(window,control,surface);
  SetTextColor(dc,text);SetBkColor(dc,background);SetDCBrushColor(dc,background);return reinterpret_cast<LRESULT>(GetStockObject(DC_BRUSH));
 }
 // Owner-draw only the list text/fill; the COMBOBOX still owns dropdown,
 // selection and keyboard behavior, including its native arrow button.
 if(message==WM_DRAWITEM){
  auto* item=reinterpret_cast<DRAWITEMSTRUCT*>(l);
  if(item&&item->CtlType==ODT_COMBOBOX){
   const bool selected=item->itemState&ODS_SELECTED;auto dc=item->hDC;RECT r=item->rcItem;
   SetDCBrushColor(dc,desktopColor(selected?theme.palette.selection:theme.palette.background));FillRect(dc,&r,reinterpret_cast<HBRUSH>(GetStockObject(DC_BRUSH)));
   if(item->itemID!=UINT(-1)){wchar_t label[256]{};const auto length=SendMessageW(item->hwndItem,CB_GETLBTEXTLEN,item->itemID,0);if(length>=0&&length<256)SendMessageW(item->hwndItem,CB_GETLBTEXT,item->itemID,reinterpret_cast<LPARAM>(label));auto old=SelectObject(dc,reinterpret_cast<HFONT>(SendMessageW(item->hwndItem,WM_GETFONT,0,0)));SetTextColor(dc,text);SetBkMode(dc,TRANSPARENT);r.left+=settingsScale(8,dpi);DrawTextW(dc,label,-1,&r,DT_SINGLELINE|DT_VCENTER|DT_NOPREFIX);SelectObject(dc,old);}
   if((item->itemState&ODS_FOCUS)&&!(item->itemState&ODS_NOFOCUSRECT)){auto focus=item->rcItem;InflateRect(&focus,-2,-2);DrawFocusRect(dc,&focus);}return TRUE;
  }
 }
 if(message==WM_NOTIFY){
  auto* draw=reinterpret_cast<NMCUSTOMDRAW*>(l);wchar_t cls[32]{};if(draw)GetClassNameW(draw->hdr.hwndFrom,cls,32);
  if(draw&&draw->hdr.code==NM_CUSTOMDRAW&&std::wstring(cls)==L"Button"&&draw->dwDrawStage==CDDS_PREPAINT){
   auto button=draw->hdr.hwndFrom;const auto type=GetWindowLongPtrW(button,GWL_STYLE)&BS_TYPEMASK;
   if(type==BS_PUSHBUTTON||type==BS_DEFPUSHBUTTON||type==BS_AUTOCHECKBOX){
    auto dc=draw->hdc;RECT r=draw->rc;const bool enabled=IsWindowEnabled(button),hot=draw->uItemState&(CDIS_HOT|CDIS_SELECTED);
    const auto background=settingsControlBackground(window,button,surface);SetDCBrushColor(dc,background);FillRect(dc,&r,reinterpret_cast<HBRUSH>(GetStockObject(DC_BRUSH)));
    const bool check=type==BS_AUTOCHECKBOX;const bool primary=GetPropW(button,L"Linghe.Settings.Primary")!=nullptr;
    RECT label=r;
    if(check){RECT box{r.left+settingsScale(2,dpi),(r.top+r.bottom-settingsScale(18,dpi))/2,r.left+settingsScale(20,dpi),(r.top+r.bottom+settingsScale(18,dpi))/2};const bool checked=SendMessageW(button,BM_GETCHECK,0,0)==BST_CHECKED;settingsRoundFill(dc,box,checked?desktopColor(theme.palette.selection):background,enabled?text:edge,settingsScale(4,dpi));if(checked){auto pen=CreatePen(PS_SOLID,settingsScale(2,dpi),enabled?text:edge);auto old=SelectObject(dc,pen);MoveToEx(dc,box.left+settingsScale(4,dpi),box.top+settingsScale(9,dpi),nullptr);LineTo(dc,box.left+settingsScale(8,dpi),box.top+settingsScale(13,dpi));LineTo(dc,box.left+settingsScale(14,dpi),box.top+settingsScale(5,dpi));SelectObject(dc,old);DeleteObject(pen);}label.left+=settingsScale(30,dpi);}
    else {InflateRect(&r,-1,-1);settingsRoundFill(dc,r,enabled&&(hot||primary)?desktopColor(theme.palette.selection):desktopColor(theme.palette.background),enabled&&primary?text:edge,settingsScale(8,dpi));}
    wchar_t title[256]{};GetWindowTextW(button,title,256);auto old=SelectObject(dc,reinterpret_cast<HFONT>(SendMessageW(button,WM_GETFONT,0,0)));SetBkMode(dc,TRANSPARENT);SetTextColor(dc,enabled?text:edge);
    DrawTextW(dc,title,-1,&label,DT_SINGLELINE|DT_VCENTER|(check?DT_LEFT:DT_CENTER)|((draw->uItemState&CDIS_SHOWKEYBOARDCUES)?0:DT_HIDEPREFIX));SelectObject(dc,old);
    if((draw->uItemState&CDIS_FOCUS)&&!(SendMessageW(button,WM_QUERYUISTATE,0,0)&UISF_HIDEFOCUS)){InflateRect(&label,-settingsScale(4,dpi),-settingsScale(4,dpi));DrawFocusRect(dc,&label);}return CDRF_SKIPDEFAULT;
   }
  }
 }
 if(message==WM_NCDESTROY){RemoveWindowSubclass(window,settingsSurfaceProcedure,id);auto result=DefSubclassProc(window,message,w,l);delete &surface;return result;}
 return DefSubclassProc(window,message,w,l);
}
inline void settingsInstallSurface(HWND window,NativeWindowTheme& theme){
 // Parent card erasure must not paint over native child controls during page changes.
 SetWindowLongPtrW(window,GWL_STYLE,GetWindowLongPtrW(window,GWL_STYLE)|WS_CLIPCHILDREN);
 auto* surface=new SettingsSurface{&theme,0};if(!SetWindowSubclass(window,settingsSurfaceProcedure,1,reinterpret_cast<DWORD_PTR>(surface)))delete surface;
 // Public Windows 11 DWM preference; keep the system title bar and shadow.
 auto module=LoadLibraryExW(L"dwmapi.dll",nullptr,LOAD_LIBRARY_SEARCH_SYSTEM32);if(module){auto set=reinterpret_cast<HRESULT(WINAPI*)(HWND,DWORD,LPCVOID,DWORD)>(GetProcAddress(module,"DwmSetWindowAttribute"));const DWORD rounded=2;if(set)set(window,33,&rounded,sizeof(rounded));FreeLibrary(module);}
}
inline void settingsSurfacePage(HWND window,int page){DWORD_PTR data=0;if(GetWindowSubclass(window,settingsSurfaceProcedure,1,&data)){reinterpret_cast<SettingsSurface*>(data)->page=page;RedrawWindow(window,nullptr,nullptr,RDW_INVALIDATE|RDW_ERASE|RDW_ALLCHILDREN);}}
inline void settingsPrimaryButton(HWND button){SetPropW(button,L"Linghe.Settings.Primary",reinterpret_cast<HANDLE>(1));}
