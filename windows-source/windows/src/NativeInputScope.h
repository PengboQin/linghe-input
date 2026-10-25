#pragma once
#include <windows.h>
#include <cwchar>
namespace private_input {
// Query only native window metadata; never send a synchronous message or read
// password contents. Unknown custom controls still require the host's TSF scope.
inline bool nativePasswordWindow(HWND window){
 wchar_t name[64]{};
 if(!window||!GetClassNameW(window,name,64))return false;
 const bool edit=_wcsicmp(name,L"Edit")==0||_wcsnicmp(name,L"RichEdit",8)==0;
 return edit&&(GetWindowLongPtrW(window,GWL_STYLE)&ES_PASSWORD)!=0;
}
}
