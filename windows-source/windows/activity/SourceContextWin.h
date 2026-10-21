#pragma once
#include "CaptureWire.h"
#include <windows.h>
#include <filesystem>
#include <string>
#include <vector>
namespace private_input::activity {
inline std::string sourceUTF8(const std::wstring&s){if(s.empty())return {};int n=WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,s.data(),int(s.size()),nullptr,0,nullptr,nullptr);if(n<=0)return {};std::string out(n,0);return WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,s.data(),int(s.size()),out.data(),n,nullptr,nullptr)==n?out:std::string{};}
template<size_t N>inline void sourceCopy(char(&out)[N],uint16_t&length,const std::string&s){if(s.size()>=N)return;for(unsigned char c:s)if(c<32||c==127||c=='/'||c=='\\'||c==':')return;std::memcpy(out,s.data(),s.size());length=uint16_t(s.size());}
inline CaptureContextWire sourceFromProcessPath(const std::wstring&path,bool description){
 CaptureContextWire result;sourceCopy(result.app,result.appBytes,sourceUTF8(std::filesystem::path(path).filename().wstring()));sourceCopy(result.version,result.versionBytes,"0.4.6");sourceCopy(result.build,result.buildBytes,"1");
 if(description&&!path.empty()){
  static HMODULE module=LoadLibraryExW(L"version.dll",nullptr,LOAD_LIBRARY_SEARCH_SYSTEM32);
  auto size=module?reinterpret_cast<DWORD(WINAPI*)(LPCWSTR,LPDWORD)>(GetProcAddress(module,"GetFileVersionInfoSizeW")):nullptr;
  auto read=module?reinterpret_cast<BOOL(WINAPI*)(LPCWSTR,DWORD,DWORD,LPVOID)>(GetProcAddress(module,"GetFileVersionInfoW")):nullptr;
  auto query=module?reinterpret_cast<BOOL(WINAPI*)(LPCVOID,LPCWSTR,LPVOID*,PUINT)>(GetProcAddress(module,"VerQueryValueW")):nullptr;
  DWORD ignored=0,n=size?size(path.c_str(),&ignored):0;
  if(n&&n<=1024*1024&&read&&query){std::vector<unsigned char>bytes(n);if(read(path.c_str(),0,n,bytes.data())){
   struct Translation{WORD language,codepage;};Translation*translations=nullptr;UINT count=0;
   if(query(bytes.data(),L"\\VarFileInfo\\Translation",reinterpret_cast<void**>(&translations),&count)&&translations&&count>=sizeof(Translation)){
    wchar_t key[96]{};swprintf(key,96,L"\\StringFileInfo\\%04x%04x\\FileDescription",translations[0].language,translations[0].codepage);wchar_t*name=nullptr;UINT length=0;
    if(query(bytes.data(),key,reinterpret_cast<void**>(&name),&length)&&name&&length>1&&length<=256)sourceCopy(result.name,result.nameBytes,sourceUTF8(std::wstring(name,length-1)));
   }
  }}
 }
 return result;
}
inline CaptureContextWire sourceForCurrentHost(bool description=false){wchar_t path[32768]{};auto n=GetModuleFileNameW(nullptr,path,32768);auto result=sourceFromProcessPath(n&&n<32768?std::wstring(path,n):L"",description);result.provenance=1;return result;}
inline CaptureContextWire sourceForClipboardOwner(HWND owner){CaptureContextWire result;sourceCopy(result.version,result.versionBytes,"0.4.6");sourceCopy(result.build,result.buildBytes,"1");if(!owner)return result;DWORD pid=0;GetWindowThreadProcessId(owner,&pid);if(!pid)return result;HANDLE process=OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION,FALSE,pid);if(!process)return result;wchar_t path[32768]{};DWORD n=32768;bool okay=QueryFullProcessImageNameW(process,0,path,&n)!=FALSE;CloseHandle(process);if(okay&&n<32768){result=sourceFromProcessPath(std::wstring(path,n),false);result.provenance=2;}return result;}
}
