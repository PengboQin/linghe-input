#include "DeviceIdentity.h"
#include <windows.h>
#include <bcrypt.h>
#include <dpapi.h>
#include <sddl.h>
#include <aclapi.h>
#include <vector>
#include <limits>
#include <cstring>

namespace private_input {
void eraseIdentityMemory(void*p,size_t n)noexcept{SecureZeroMemory(p,n);}
namespace {
struct Handle { HANDLE value=INVALID_HANDLE_VALUE; explicit Handle(HANDLE h):value(h){} ~Handle(){if(value!=INVALID_HANDLE_VALUE&&value)CloseHandle(value);} Handle(const Handle&)=delete; };
struct Local { void* value=nullptr; ~Local(){if(value)LocalFree(value);} };
struct Bytes:std::vector<unsigned char> { using std::vector<unsigned char>::vector; ~Bytes(){if(!empty())SecureZeroMemory(data(),size());} };
void check(bool ok,const char* message){if(!ok)throw IdentityError(message,GetLastError());}
std::vector<unsigned char> sid(){
 HANDLE h=nullptr;check(OpenProcessToken(GetCurrentProcess(),TOKEN_QUERY,&h),"Current token unavailable");Handle token(h);
 DWORD size=0;GetTokenInformation(h,TokenUser,nullptr,0,&size);std::vector<unsigned char> data(size);
 check(GetTokenInformation(h,TokenUser,data.data(),size,&size),"Current SID unavailable");
 auto user=reinterpret_cast<TOKEN_USER*>(data.data());std::vector<unsigned char> copy(GetLengthSid(user->User.Sid));
 check(CopySid(DWORD(copy.size()),copy.data(),user->User.Sid),"SID copy failed");return copy;
}
struct Security {
 Local memory;SECURITY_ATTRIBUTES attributes{};
 Security(){auto owner=sid();LPWSTR name=nullptr;check(ConvertSidToStringSidW(owner.data(),&name),"SID formatting failed");Local text;text.value=name;
  std::wstring descriptor=L"O:"+std::wstring(name)+L"D:P(A;;FA;;;"+name+L")";
  check(ConvertStringSecurityDescriptorToSecurityDescriptorW(descriptor.c_str(),SDDL_REVISION_1,reinterpret_cast<PSECURITY_DESCRIPTOR*>(&memory.value),nullptr),"Private ACL failed");
  attributes={sizeof(attributes),memory.value,FALSE};
 }
};
void verify(HANDLE handle){
 BY_HANDLE_FILE_INFORMATION info{};check(GetFileInformationByHandle(handle,&info),"File metadata unavailable");
 check(!(info.dwFileAttributes&FILE_ATTRIBUTE_REPARSE_POINT)&&info.nNumberOfLinks<=1,"Reparse or linked identity rejected");
 PSID owner=nullptr;PACL acl=nullptr;PSECURITY_DESCRIPTOR descriptor=nullptr;
 DWORD code=GetSecurityInfo(handle,SE_FILE_OBJECT,OWNER_SECURITY_INFORMATION|DACL_SECURITY_INFORMATION,&owner,nullptr,&acl,nullptr,&descriptor);
 if(code!=ERROR_SUCCESS)throw IdentityError("ACL read failed",code);Local allocation;allocation.value=descriptor;
 auto current=sid();check(owner&&EqualSid(owner,current.data())&&acl&&acl->AceCount==1,"Unexpected identity owner/ACL");
 void* ace=nullptr;check(GetAce(acl,0,&ace),"Identity ACE unavailable");auto allow=reinterpret_cast<ACCESS_ALLOWED_ACE*>(ace);
 check(allow->Header.AceType==ACCESS_ALLOWED_ACE_TYPE&&EqualSid(&allow->SidStart,current.data())&&(allow->Mask&FILE_ALL_ACCESS)==FILE_ALL_ACCESS,"Identity ACL not owner-only");
 SECURITY_DESCRIPTOR_CONTROL control{};DWORD revision=0;
 check(GetSecurityDescriptorControl(descriptor,&control,&revision)&&(control&SE_DACL_PROTECTED),"Identity ACL inherited unexpectedly");
}
void noReparseParents(const std::filesystem::path& path){
 std::filesystem::path current;
 for(const auto& part:path){current/=part;DWORD attrs=GetFileAttributesW(current.c_str());
  check(attrs!=INVALID_FILE_ATTRIBUTES&&!(attrs&FILE_ATTRIBUTE_REPARSE_POINT),"Identity parent missing or redirected");}
}
struct Lock {
 Handle file;
 explicit Lock(const std::filesystem::path& root):file([&]{Security security;return CreateFileW((root/L"identity.lock").c_str(),GENERIC_READ|GENERIC_WRITE|READ_CONTROL,FILE_SHARE_READ|FILE_SHARE_WRITE,&security.attributes,OPEN_ALWAYS,FILE_ATTRIBUTE_NORMAL|FILE_FLAG_OPEN_REPARSE_POINT,nullptr);}()){
  check(file.value!=INVALID_HANDLE_VALUE,"Identity lock unavailable");verify(file.value);
  OVERLAPPED offset{};check(LockFileEx(file.value,LOCKFILE_EXCLUSIVE_LOCK|LOCKFILE_FAIL_IMMEDIATELY,0,MAXDWORD,MAXDWORD,&offset),"Identity is busy");
 }
 ~Lock(){OVERLAPPED offset{};UnlockFileEx(file.value,0,MAXDWORD,MAXDWORD,&offset);}
};
constexpr char magic[]="PrivateInput/WinIdentity/v1";
constexpr char entropy[]="live.linghe.privateinput.sync.identity.v1";
Bytes encode(const DeviceIdentity& value){
 Bytes result;result.insert(result.end(),magic,magic+sizeof(magic));
 for(const auto& bytes:{std::pair<const unsigned char*,size_t>{value.device.data(),16},{value.owner.data(),16},{value.signingSeed.data(),32},{value.ownerSeed.data(),32},{value.exchangeSecret.data(),32},{value.storageKey.data(),32}})result.insert(result.end(),bytes.first,bytes.first+bytes.second);
 for(int shift=56;shift>=0;shift-=8)result.push_back(unsigned(value.reservedSequence>>shift)&255);return result;
}
DeviceIdentity decode(const unsigned char* data,size_t size){
 check(size==sizeof(magic)+168&&std::memcmp(data,magic,sizeof(magic))==0,"Corrupt identity record");DeviceIdentity value;size_t index=sizeof(magic);
 for(const auto& bytes:{std::pair<unsigned char*,size_t>{value.device.data(),16},{value.owner.data(),16},{value.signingSeed.data(),32},{value.ownerSeed.data(),32},{value.exchangeSecret.data(),32},{value.storageKey.data(),32}}){std::memcpy(bytes.first,data+index,bytes.second);index+=bytes.second;}
 for(int i=0;i<8;++i)value.reservedSequence=(value.reservedSequence<<8)|data[index++];return value;
}
void random(void* data,size_t size){if(BCryptGenRandom(nullptr,static_cast<PUCHAR>(data),ULONG(size),BCRYPT_USE_SYSTEM_PREFERRED_RNG)<0)throw IdentityError("System entropy unavailable");}
}
DeviceIdentityVault::DeviceIdentityVault(std::filesystem::path root):root_(std::filesystem::absolute(root).lexically_normal()){
 noReparseParents(root_.parent_path());Security security;
 if(!CreateDirectoryW(root_.c_str(),&security.attributes))check(GetLastError()==ERROR_ALREADY_EXISTS,"Private identity directory unavailable");
 Handle directory(CreateFileW(root_.c_str(),READ_CONTROL|FILE_READ_ATTRIBUTES,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,nullptr,OPEN_EXISTING,FILE_FLAG_BACKUP_SEMANTICS|FILE_FLAG_OPEN_REPARSE_POINT,nullptr));
 check(directory.value!=INVALID_HANDLE_VALUE,"Private directory unavailable");verify(directory.value);
}
DeviceIdentity DeviceIdentityVault::readLocked(){
 Handle file(CreateFileW((root_/L"identity.dpapi").c_str(),GENERIC_READ|READ_CONTROL,FILE_SHARE_READ,nullptr,OPEN_EXISTING,FILE_FLAG_OPEN_REPARSE_POINT,nullptr));
 check(file.value!=INVALID_HANDLE_VALUE,"Identity absent; explicit setup required");verify(file.value);LARGE_INTEGER size{};
 check(GetFileSizeEx(file.value,&size)&&size.QuadPart>0&&size.QuadPart<=8192,"Identity size invalid");Bytes encrypted(size_t(size.QuadPart));DWORD read=0;
 check(ReadFile(file.value,encrypted.data(),DWORD(encrypted.size()),&read,nullptr)&&read==encrypted.size(),"Identity read failed");
 DATA_BLOB input{DWORD(encrypted.size()),encrypted.data()},additional{sizeof(entropy),reinterpret_cast<BYTE*>(const_cast<char*>(entropy))},plain{};
 check(CryptUnprotectData(&input,nullptr,&additional,nullptr,nullptr,CRYPTPROTECT_UI_FORBIDDEN,&plain),"DPAPI identity authentication failed");
 try{auto identity=decode(plain.pbData,plain.cbData);SecureZeroMemory(plain.pbData,plain.cbData);LocalFree(plain.pbData);return identity;}
 catch(...){SecureZeroMemory(plain.pbData,plain.cbData);LocalFree(plain.pbData);throw;}
}
void DeviceIdentityVault::saveLocked(const DeviceIdentity& identity,bool create){
 const auto target=root_/L"identity.dpapi";DWORD attrs=GetFileAttributesW(target.c_str());
 if(create)check(attrs==INVALID_FILE_ATTRIBUTES&&GetLastError()==ERROR_FILE_NOT_FOUND,"Identity already exists");
 else check(attrs!=INVALID_FILE_ATTRIBUTES&&!(attrs&FILE_ATTRIBUTE_REPARSE_POINT),"Identity changed before save");
 auto bytes=encode(identity);DATA_BLOB input{DWORD(bytes.size()),bytes.data()},additional{sizeof(entropy),reinterpret_cast<BYTE*>(const_cast<char*>(entropy))},encrypted{};
 check(CryptProtectData(&input,L"PrivateInput device identity",&additional,nullptr,nullptr,CRYPTPROTECT_UI_FORBIDDEN,&encrypted),"DPAPI protection failed");Local allocation;allocation.value=encrypted.pbData;
 unsigned char nonce[16];random(nonce,sizeof(nonce));std::wstring name=L"identity-";const wchar_t* digits=L"0123456789abcdef";
 for(auto c:nonce){name+=digits[c>>4];name+=digits[c&15];}name+=L".tmp";const auto temp=root_/name;
 try{
  {Security security;Handle file(CreateFileW(temp.c_str(),GENERIC_WRITE|READ_CONTROL,0,&security.attributes,CREATE_NEW,FILE_ATTRIBUTE_NORMAL|FILE_FLAG_WRITE_THROUGH|FILE_FLAG_OPEN_REPARSE_POINT,nullptr));
   check(file.value!=INVALID_HANDLE_VALUE,"Identity staging failed");verify(file.value);DWORD written=0;
   check(WriteFile(file.value,encrypted.pbData,encrypted.cbData,&written,nullptr)&&written==encrypted.cbData&&FlushFileBuffers(file.value),"Identity persistence failed");}
  check(MoveFileExW(temp.c_str(),target.c_str(),MOVEFILE_WRITE_THROUGH|(create?0:MOVEFILE_REPLACE_EXISTING)),"Identity atomic replacement failed");
 }catch(...){DeleteFileW(temp.c_str());throw;}
}
DeviceIdentity DeviceIdentityVault::create(){Lock lock(root_);DWORD attrs=GetFileAttributesW((root_/L"identity.dpapi").c_str());check(attrs==INVALID_FILE_ATTRIBUTES&&GetLastError()==ERROR_FILE_NOT_FOUND,"Identity already exists");
 DeviceIdentity identity;random(identity.device.data(),16);random(identity.owner.data(),16);
 identity.device[6]=(identity.device[6]&15)|64;identity.device[8]=(identity.device[8]&63)|128;
 identity.owner[6]=(identity.owner[6]&15)|64;identity.owner[8]=(identity.owner[8]&63)|128;
 random(identity.signingSeed.data(),32);random(identity.ownerSeed.data(),32);random(identity.exchangeSecret.data(),32);random(identity.storageKey.data(),32);
 saveLocked(identity,true);return identity;
}
DeviceIdentity DeviceIdentityVault::resetForDeparture(){Lock lock(root_);DeviceIdentity identity;random(identity.device.data(),16);random(identity.owner.data(),16);identity.device[6]=(identity.device[6]&15)|64;identity.device[8]=(identity.device[8]&63)|128;identity.owner[6]=(identity.owner[6]&15)|64;identity.owner[8]=(identity.owner[8]&63)|128;random(identity.signingSeed.data(),32);random(identity.ownerSeed.data(),32);random(identity.exchangeSecret.data(),32);random(identity.storageKey.data(),32);saveLocked(identity,false);return identity;}
DeviceIdentity DeviceIdentityVault::load(){Lock lock(root_);return readLocked();}
DeviceIdentity DeviceIdentityVault::reserveSequence(){Lock lock(root_);auto identity=readLocked();check(identity.reservedSequence!=std::numeric_limits<uint64_t>::max(),"Identity sequence exhausted");++identity.reservedSequence;saveLocked(identity,false);return identity;}
}
