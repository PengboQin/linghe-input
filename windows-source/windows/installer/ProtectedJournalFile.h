#pragma once
// Protected Win32 journal storage. Used only by explicit constrained Setup --repair.
// Caller supplies an internal fixed recovery directory, NEVER a CLI pathname.
// No registry, worker, profile, clipboard or network access occurs in this file.
#include <windows.h>
#include <aclapi.h>
#include <sddl.h>
#include <objbase.h>
#include <filesystem>
#include <string>
#include <stdexcept>
#include <system_error>
#include <functional>

namespace linghe::installer::recovery {
namespace journal_detail {
inline void wincheck(bool ok){if(!ok)throw std::system_error(GetLastError(),std::system_category());}
inline void reject(bool ok,const char* why){if(!ok)throw std::runtime_error(why);}
struct Handle {
 HANDLE value=INVALID_HANDLE_VALUE;
 explicit Handle(HANDLE h=INVALID_HANDLE_VALUE):value(h){}
 ~Handle(){if(value!=INVALID_HANDLE_VALUE)CloseHandle(value);}
 Handle(const Handle&)=delete;Handle&operator=(const Handle&)=delete;
};
struct Local {
 void* value=nullptr;
 Local()=default;Local(const Local&)=delete;Local&operator=(const Local&)=delete;
 ~Local(){if(value)LocalFree(value);}
};
inline void noRedirection(std::filesystem::path path){
 reject(path.is_absolute(),"journal root must be absolute");
 path=path.lexically_normal();
 for(auto p=path;!p.empty();p=p.parent_path()){
  auto attributes=GetFileAttributesW(p.c_str());
  wincheck(attributes!=INVALID_FILE_ATTRIBUTES);
  reject(!(attributes&FILE_ATTRIBUTE_REPARSE_POINT),"journal ancestor reparse point");
  if(p==p.parent_path())break;
 }
}
inline void protectedObject(HANDLE handle,bool directory){
 BY_HANDLE_FILE_INFORMATION info{};wincheck(GetFileInformationByHandle(handle,&info)!=FALSE);
 reject(!(info.dwFileAttributes&FILE_ATTRIBUTE_REPARSE_POINT),"journal redirection");
 reject(bool(info.dwFileAttributes&FILE_ATTRIBUTE_DIRECTORY)==directory,"journal object kind");
 if(!directory)reject(info.nNumberOfLinks==1,"journal hardlink");
 PSID owner=nullptr;PACL dacl=nullptr;PSECURITY_DESCRIPTOR security=nullptr;
 DWORD error=GetSecurityInfo(handle,SE_FILE_OBJECT,OWNER_SECURITY_INFORMATION|DACL_SECURITY_INFORMATION,
                             &owner,nullptr,&dacl,nullptr,&security);
 if(error!=ERROR_SUCCESS)throw std::system_error(error,std::system_category());
 Local allocated;allocated.value=security;
 BYTE adminBytes[SECURITY_MAX_SID_SIZE]{},systemBytes[SECURITY_MAX_SID_SIZE]{};
 DWORD adminSize=sizeof(adminBytes),systemSize=sizeof(systemBytes);
 wincheck(CreateWellKnownSid(WinBuiltinAdministratorsSid,nullptr,adminBytes,&adminSize)!=FALSE);
 wincheck(CreateWellKnownSid(WinLocalSystemSid,nullptr,systemBytes,&systemSize)!=FALSE);
 reject(owner&&(EqualSid(owner,adminBytes)||EqualSid(owner,systemBytes)),"untrusted journal owner");
 SECURITY_DESCRIPTOR_CONTROL control{};DWORD revision=0;
 wincheck(GetSecurityDescriptorControl(security,&control,&revision)!=FALSE);
 reject(dacl&&(control&SE_DACL_PROTECTED),"journal DACL must be explicit/protected");
 ACL_SIZE_INFORMATION size{};wincheck(GetAclInformation(dacl,&size,sizeof(size),AclSizeInformation)!=FALSE);
 reject(size.AceCount==2,"journal requires exact SYSTEM/Admin DACL");
 bool admin=false,system=false;
 for(DWORD n=0;n<size.AceCount;++n){
  void* raw=nullptr;wincheck(GetAce(dacl,n,&raw)!=FALSE);
  auto header=static_cast<ACE_HEADER*>(raw);
  reject(header->AceType==ACCESS_ALLOWED_ACE_TYPE&&!(header->AceFlags&INHERITED_ACE),"journal ACE type");
  auto ace=static_cast<ACCESS_ALLOWED_ACE*>(raw);auto sid=reinterpret_cast<PSID>(&ace->SidStart);
  reject(ace->Mask==FILE_ALL_ACCESS,"journal ACL rights");
  if(EqualSid(sid,adminBytes)){reject(!admin,"duplicate admin ACE");admin=true;}
  else if(EqualSid(sid,systemBytes)){reject(!system,"duplicate system ACE");system=true;}
  else throw std::runtime_error("untrusted journal writer");
 }
 reject(admin&&system,"journal administrative ACL");
}
inline Local* descriptor(Local& value){
 PSECURITY_DESCRIPTOR sd=nullptr;
 wincheck(ConvertStringSecurityDescriptorToSecurityDescriptorW(
  L"O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)",SDDL_REVISION_1,&sd,nullptr)!=FALSE);
 value.value=sd;return &value;
}
inline bool transactionId(const std::wstring& id){
 if(id.size()!=36)return false;
 for(std::size_t n=0;n<id.size();++n){
  if(n==8||n==13||n==18||n==23){if(id[n]!=L'-')return false;}
  else if(!((id[n]>=L'0'&&id[n]<=L'9')||(id[n]>=L'a'&&id[n]<=L'f')||
            (id[n]>=L'A'&&id[n]<=L'F')))return false;
 }
 return true;
}
} // journal_detail

class ProtectedJournalFile {
 static constexpr DWORD MaxBytes=1024*1024;
 std::filesystem::path root,file;
 journal_detail::Handle parentDirectory;
 journal_detail::Handle directory;
 static HANDLE openDirectory(const std::filesystem::path& root){
  journal_detail::noRedirection(root);
  // No DELETE sharing: pin the directory while this adapter is alive.
  return CreateFileW(root.c_str(),READ_CONTROL|FILE_READ_ATTRIBUTES|FILE_LIST_DIRECTORY,
   FILE_SHARE_READ|FILE_SHARE_WRITE,nullptr,OPEN_EXISTING,
   FILE_FLAG_BACKUP_SEMANTICS|FILE_FLAG_OPEN_REPARSE_POINT,nullptr);
 }
 static std::string readFile(const std::filesystem::path& name,bool allowEmpty=false){
  journal_detail::Handle h(CreateFileW(name.c_str(),GENERIC_READ|READ_CONTROL,
   FILE_SHARE_READ,nullptr,OPEN_EXISTING,FILE_FLAG_OPEN_REPARSE_POINT,nullptr));
  journal_detail::wincheck(h.value!=INVALID_HANDLE_VALUE);
  journal_detail::protectedObject(h.value,false);
  LARGE_INTEGER size{};journal_detail::wincheck(GetFileSizeEx(h.value,&size)!=FALSE);
  journal_detail::reject((size.QuadPart>0||allowEmpty)&&size.QuadPart>=0&&size.QuadPart<=MaxBytes,"journal size bound");
  std::string bytes(static_cast<std::size_t>(size.QuadPart),'\0');DWORD offset=0;
  while(offset<bytes.size()){
   DWORD count=0;journal_detail::wincheck(ReadFile(h.value,&bytes[offset],DWORD(bytes.size()-offset),&count,nullptr)!=FALSE);
   journal_detail::reject(count>0,"journal truncated read");offset+=count;
  }
  return bytes;
 }
public:
 // The native adapter must create the fixed recovery root and dedicated parent with owner BA/SYSTEM,
 // protected two-ACE DACL. This constructor refuses existing per-user-writable
 // roots; it never changes an existing ACL or enables privileges to take ownership.
 ProtectedJournalFile(const std::filesystem::path& internalRoot,const std::wstring& id)
  :root(internalRoot.lexically_normal()),parentDirectory(openDirectory(root.parent_path())),directory(openDirectory(root)){
  journal_detail::wincheck(parentDirectory.value!=INVALID_HANDLE_VALUE);
  journal_detail::protectedObject(parentDirectory.value,true);
  journal_detail::wincheck(directory.value!=INVALID_HANDLE_VALUE);
  journal_detail::protectedObject(directory.value,true);
  journal_detail::reject(journal_detail::transactionId(id),"invalid journal transaction ID");
  file=root/(id+L".journal");
 }
 std::string read()const{
  return readFile(file); // Validate schema, pins, SID and fixed slots before replay.
 }
 void write(const std::string& bytes){
  journal_detail::reject(!bytes.empty()&&bytes.size()<=MaxBytes,"journal size bound");
  const auto existing=GetFileAttributesW(file.c_str());
  if(existing!=INVALID_FILE_ATTRIBUTES){(void)read();} // Reject poisoned existing target, not blind replace.
  else journal_detail::reject(GetLastError()==ERROR_FILE_NOT_FOUND,"journal target access");
  // CREATE_NEW avoids overwriting any other temporary; no arbitrary supplied temp path.
  auto temp=file;temp+=L".pending";
  journal_detail::Local sd;journal_detail::descriptor(sd);
  SECURITY_ATTRIBUTES sa{sizeof(sa),sd.value,FALSE};
  {
   journal_detail::Handle h(CreateFileW(temp.c_str(),GENERIC_WRITE|READ_CONTROL,0,&sa,CREATE_NEW,
    FILE_ATTRIBUTE_NORMAL|FILE_FLAG_OPEN_REPARSE_POINT|FILE_FLAG_WRITE_THROUGH,nullptr));
   journal_detail::wincheck(h.value!=INVALID_HANDLE_VALUE);
   journal_detail::protectedObject(h.value,false);
   DWORD offset=0;
   while(offset<bytes.size()){
    DWORD written=0;journal_detail::wincheck(WriteFile(h.value,bytes.data()+offset,DWORD(bytes.size()-offset),&written,nullptr)!=FALSE);
    journal_detail::reject(written>0,"journal short write");offset+=written;
   }
   journal_detail::wincheck(FlushFileBuffers(h.value)!=FALSE);
  }
  journal_detail::wincheck(MoveFileExW(temp.c_str(),file.c_str(),MOVEFILE_REPLACE_EXISTING|MOVEFILE_WRITE_THROUGH)!=FALSE);
  journal_detail::reject(read()==bytes,"journal durable replacement readback");
 }
 // Called only under the existing setup mutex, AFTER the trusted adapter validates
 // the original durable journal's transaction/SID/pins/scope. The callback may
 // quarantine a truncated stage; it MUST NOT authorize replay from those bytes.
 // Preserve it under a unique
 // diagnostic name rather than deleting it, so a failed write can be retried.
 void retireStagedAfterValidation(const std::function<void(const std::string&)>& validate){
  auto temp=file;temp+=L".pending";
  const auto bytes=readFile(temp,true);validate(bytes);
  GUID id{};if(FAILED(CoCreateGuid(&id)))throw std::runtime_error("journal retirement nonce");
  wchar_t name[39]{};journal_detail::reject(StringFromGUID2(id,name,39)!=0,"journal retirement ID");
  auto retired=file;retired+=std::wstring(L".retained-")+name;
  journal_detail::wincheck(MoveFileExW(temp.c_str(),retired.c_str(),MOVEFILE_WRITE_THROUGH)!=FALSE);
 }
 // No unlink primitive; unknown/corrupt staged state remains untouched and blocks
 // replay until an explicitly supported recovery path can establish ownership.
};
} // namespace linghe::installer::recovery
