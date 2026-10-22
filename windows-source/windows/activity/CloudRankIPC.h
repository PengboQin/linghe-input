#pragma once
#ifdef _WIN32
#include <windows.h>
#include <sddl.h>
#include <string>
#include <cstring>
namespace private_input::activity {
// Separate from the unchanged learning-v1 mapping, so older loaded TIPs keep
// their original legacy ranks. This small independent gate can revoke cloud
// ranks even while the backend owner is waiting for HTTP.
struct CloudRankPermission {volatile LONG revision=0,enabled=0,revocationSerial=0,authorizedSerial=-1;uint32_t version=1;char token[80]{};};
inline std::wstring cloudRankPermissionName(){HANDLE token=nullptr;if(!OpenProcessToken(GetCurrentProcess(),TOKEN_QUERY,&token))return {};DWORD size=0;GetTokenInformation(token,TokenUser,nullptr,0,&size);std::string buffer(size,'\0');BOOL ok=GetTokenInformation(token,TokenUser,buffer.data(),size,&size);CloseHandle(token);if(!ok)return {};LPWSTR sid=nullptr;if(!ConvertSidToStringSidW(reinterpret_cast<TOKEN_USER*>(buffer.data())->User.Sid,&sid))return {};DWORD session=0;ProcessIdToSessionId(GetCurrentProcessId(),&session);auto name=L"Local\\LingheInput.CloudRank."+std::wstring(sid)+L"."+std::to_wstring(session);LocalFree(sid);return name;}
inline LONG cloudRankRevocationSerial(){auto name=cloudRankPermissionName();if(name.empty())return 0;HANDLE mapping=OpenFileMappingW(FILE_MAP_READ,FALSE,name.c_str());if(!mapping)return 0;auto*gate=static_cast<const CloudRankPermission*>(MapViewOfFile(mapping,FILE_MAP_READ,0,0,sizeof(CloudRankPermission)));LONG serial=gate?gate->revocationSerial:0;if(gate)UnmapViewOfFile(gate);CloseHandle(mapping);return serial;}
inline void revokeCloudRankIPC(){auto name=cloudRankPermissionName();if(name.empty())return;HANDLE mapping=OpenFileMappingW(FILE_MAP_WRITE|FILE_MAP_READ,FALSE,name.c_str());if(!mapping)return;auto*gate=static_cast<CloudRankPermission*>(MapViewOfFile(mapping,FILE_MAP_WRITE|FILE_MAP_READ,0,0,sizeof(CloudRankPermission)));if(gate&&gate->version==1){InterlockedIncrement(&gate->revocationSerial);MemoryBarrier();InterlockedExchange(&gate->enabled,0);}if(gate)UnmapViewOfFile(gate);CloseHandle(mapping);}
inline bool cloudRankPermission(const CloudRankPermission*gate,std::string&token){if(!gate)return false;auto revision=gate->revision,serial=gate->revocationSerial;MemoryBarrier();if((revision&1)||gate->version!=1||!gate->enabled||gate->authorizedSerial!=serial||!memchr(gate->token,0,sizeof(gate->token)))return false;token=gate->token;MemoryBarrier();return !token.empty()&&gate->revision==revision&&gate->revocationSerial==serial&&gate->authorizedSerial==serial&&gate->enabled;}
}
#endif
