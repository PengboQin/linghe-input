#include "PrivateInputTSF.h"
#include <iostream>
#include <filesystem>
#include <string>
int wmain(int argc,wchar_t **argv){
  if(argc!=3)return 2;std::wstring action=argv[1];if(action!=L"register"&&action!=L"unregister")return 2;
  auto file=std::filesystem::absolute(argv[2]).lexically_normal();if(file.filename()!=L"PrivateInputTSF.dll")return 2;
  HRESULT initialized=CoInitializeEx(nullptr,COINIT_APARTMENTTHREADED);if(FAILED(initialized))return 3;
  HMODULE module=LoadLibraryExW(file.c_str(),nullptr,LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR|LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
  if(!module){std::cout<<"{\"loadError\":"<<GetLastError()<<"}\n";CoUninitialize();return 4;}
  using Operation=HRESULT(WINAPI*)();auto operation=reinterpret_cast<Operation>(GetProcAddress(module,action==L"register"?"DllRegisterServer":"DllUnregisterServer"));
  HRESULT hr=operation?operation():E_NOINTERFACE;std::cout<<"{\"hresult\":"<<unsigned(hr)<<",\"defaultInputChanged\":false}\n";
  FreeLibrary(module);CoUninitialize();return FAILED(hr)?1:0;
}
