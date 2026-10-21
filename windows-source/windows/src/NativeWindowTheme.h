#pragma once
#include <windows.h>
#include "DesktopTheme.h"
inline bool desktopSystemDark(){DWORD light=1,size=sizeof(light);HKEY key=nullptr;if(RegOpenKeyExW(HKEY_CURRENT_USER,L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",0,KEY_QUERY_VALUE,&key)==ERROR_SUCCESS){RegQueryValueExW(key,L"AppsUseLightTheme",nullptr,nullptr,reinterpret_cast<BYTE*>(&light),&size);RegCloseKey(key);}return light==0;}
inline COLORREF desktopColor(const private_input::ThemeRGB&c){return RGB(int(c.red*255+.5),int(c.green*255+.5),int(c.blue*255+.5));}
class NativeWindowTheme{
 HBRUSH background=nullptr;
public:
 private_input::DesktopTheme::Palette palette{};~NativeWindowTheme(){if(background)DeleteObject(background);}
 void apply(HWND window,private_input::DesktopTheme theme){bool dark=theme.mode==2||(theme.mode==0&&desktopSystemDark());palette=theme.palette(dark);if(background)DeleteObject(background);background=CreateSolidBrush(desktopColor(palette.background));HMODULE module=LoadLibraryExW(L"dwmapi.dll",nullptr,LOAD_LIBRARY_SEARCH_SYSTEM32);if(module){auto set=reinterpret_cast<HRESULT(WINAPI*)(HWND,DWORD,LPCVOID,DWORD)>(GetProcAddress(module,"DwmSetWindowAttribute"));BOOL enabled=dark;if(set)set(window,20,&enabled,sizeof(enabled));FreeLibrary(module);}InvalidateRect(window,nullptr,TRUE);}
 HBRUSH paint(HDC dc)const{SetTextColor(dc,desktopColor(palette.text));SetBkColor(dc,desktopColor(palette.background));return background?background:GetSysColorBrush(COLOR_WINDOW);}
};
