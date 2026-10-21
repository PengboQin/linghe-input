#pragma once
#include <windows.h>
#include <string>
#include <cstring>
#include "CaptureIPC.h"
namespace private_input::activity {
constexpr size_t ClipboardCandidateUnits=65536;
struct ClipboardCandidateMapping {
 volatile LONG revision=0,enabled=0,permissionGeneration=1;
 uint32_t version=1,sequence=0,count=0;LONG capturedGeneration=0;
 uint64_t updatedTick=0,leaseTick=0;
 wchar_t text[ClipboardCandidateUnits+1]{};
};
inline std::wstring clipboardCandidateName(const std::wstring&suffix={}){return gateName(suffix)+L".clipboard-candidate-v1";}
struct ClipboardCandidateSnapshot {uint32_t sequence=0;LONG generation=0;std::wstring text;};
class ClipboardCandidateReader {
 HANDLE handle=nullptr;const ClipboardCandidateMapping*view=nullptr;
public:
 ~ClipboardCandidateReader(){close();}
 void close(){if(view)UnmapViewOfFile(view);if(handle)CloseHandle(handle);view=nullptr;handle=nullptr;}
 ClipboardCandidateSnapshot read(){
  ClipboardCandidateSnapshot result;
  if(!view){handle=OpenFileMappingW(FILE_MAP_READ,FALSE,clipboardCandidateName().c_str());if(handle)view=static_cast<const ClipboardCandidateMapping*>(MapViewOfFile(handle,FILE_MAP_READ,0,0,sizeof(ClipboardCandidateMapping)));if(!view){close();return result;}}
  const auto revision=view->revision,generation=view->permissionGeneration;MemoryBarrier();const auto now=GetTickCount64();
  if((revision&1)||!view->enabled||view->version!=1||view->capturedGeneration!=generation||!view->sequence||view->count==0||view->count>ClipboardCandidateUnits||now<view->leaseTick||now-view->leaseTick>45000||now<view->updatedTick||now-view->updatedTick>120000)return result;
  result.sequence=view->sequence;result.generation=generation;result.text.assign(view->text,view->count);MemoryBarrier();
  if(view->revision!=revision||view->permissionGeneration!=generation||!view->enabled||GetClipboardSequenceNumber()!=result.sequence||result.text.find(L'\0')!=std::wstring::npos)return {};
  return result;
 }
};
}
