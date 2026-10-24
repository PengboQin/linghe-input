#pragma once
#include <windows.h>
#include <uxtheme.h>
#include <commctrl.h>
#include <inputscope.h>
#include <algorithm>
#include <cstdlib>
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
 RECT bounds=item.rcItem;FillRect(item.hDC,&bounds,theme.paint(item.hDC));
 const auto& colors=theme.palette;
 const UINT dpi=GetDpiForWindow(item.hwndItem);const int inset=settingsScale(2,dpi),radius=settingsScale(10,dpi);
 if(selected){auto brush=CreateSolidBrush(desktopColor(colors.selection));auto old=SelectObject(item.hDC,brush);auto pen=SelectObject(item.hDC,GetStockObject(NULL_PEN));RoundRect(item.hDC,bounds.left+inset,bounds.top+inset,bounds.right-inset,bounds.bottom-inset,radius,radius);SelectObject(item.hDC,pen);SelectObject(item.hDC,old);DeleteObject(brush);}
 wchar_t text[96]{};GetWindowTextW(item.hwndItem,text,96);auto font=reinterpret_cast<HFONT>(SendMessageW(item.hwndItem,WM_GETFONT,0,0));auto old=SelectObject(item.hDC,font);SetBkMode(item.hDC,TRANSPARENT);SetTextColor(item.hDC,desktopColor(colors.text));bounds.left+=settingsScale(16,dpi);DrawTextW(item.hDC,text,-1,&bounds,DT_SINGLELINE|DT_VCENTER|DT_LEFT);SelectObject(item.hDC,old);
 if(item.itemState&ODS_FOCUS){InflateRect(&bounds,-4,-4);DrawFocusRect(item.hDC,&bounds);}
}
inline void settingsWindowIcon(HWND window){auto instance=GetModuleHandleW(nullptr);SendMessageW(window,WM_SETICON,ICON_SMALL,reinterpret_cast<LPARAM>(LoadIconW(instance,MAKEINTRESOURCEW(101))));SendMessageW(window,WM_SETICON,ICON_BIG,reinterpret_cast<LPARAM>(LoadIconW(instance,MAKEINTRESOURCEW(101))));}
