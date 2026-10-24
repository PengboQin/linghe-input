#include <windows.h>
#include <shellapi.h>
#include <commctrl.h>
#include <shlobj.h>
#include <bcrypt.h>
#include <wrl/client.h>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <vector>
#include <set>
#include <string>
#include <stdexcept>
#include <algorithm>
#include <cwctype>
#include <optional>
#include <memory>
#include <tlhelp32.h>
#include "RecoveryJournalCodec.h"
#include "FailureFeedback.h"
#include "InstallReview.h"
#include "ProtectedJournalFile.h"
#include "UpgradeState.h"
#include "PayloadManifest.h"
#include "../src/PrivateInputTSF.h"
#include "../src/TsfBranding.h"
#include "../src/RegistrationEnumeration.h"
#include "RegistrationCatalogCheck.h"
namespace fs = std::filesystem;
namespace {
constexpr wchar_t Version[] = L"0.6.2-win1";
constexpr char VersionUtf8[] = "0.6.2-win1";
// Use the DLL's actual COM identity for preflight, installation and rollback.
// A second handwritten GUID previously caused a successful registration to be
// reported as failed and left the real registration outside the snapshot.
const std::wstring OwnClass = [] {
 wchar_t value[39]{};
 if(!StringFromGUID2(CLSID_PrivateInput,value,39))throw std::runtime_error("Invalid COM identity");
 return std::wstring(value);
}();
const std::wstring ClassBase = std::wstring(L"Software\\Classes\\CLSID\\") + OwnClass;
const std::wstring ClassKey = ClassBase + L"\\InprocServer32";
const std::wstring UninstallKey = L"Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\LingheInput." + OwnClass.substr(1,36);
struct Failure { int code; HRESULT hr; explicit Failure(int c, HRESULT h = E_FAIL):code(c),hr(h){} };
struct Report {
 int code = 1; HRESULT hr = S_OK;
 std::string action = "install", stage = "arguments", rollback = "not-needed",repairTargetVersion;
 bool workerStartupMigrated=false,workerRestartRequired=false,userTipUpdated=false,registrationCatalogVerified=false;
 bool quiet = false, committed = false, fileCleanupPending = false, retryRequired = false, unknownFilesPreserved = false, shortcutUpdated = false;
};
std::wstring ownExe() { wchar_t p[32768]; DWORD n=GetModuleFileNameW(nullptr,p,32768); if(!n||n>=32768)throw Failure(10); return {p,n}; }
bool showInstallReview(const linghe::installer::InstallReview&review){
 // Native controls only; systems without TaskDialog use the existing standard
 // OK/Cancel dialog. No directory, receipt, registry or process is modified here.
 HMODULE controls=LoadLibraryExW(L"comctl32.dll",nullptr,LOAD_LIBRARY_SEARCH_SYSTEM32);
 if(controls){using Show=HRESULT(WINAPI*)(const TASKDIALOGCONFIG*,int*,int*,BOOL*);auto show=reinterpret_cast<Show>(GetProcAddress(controls,"TaskDialogIndirect"));if(show){TASKDIALOG_BUTTON start{IDOK,review.start.c_str()};TASKDIALOGCONFIG config{};config.cbSize=sizeof(config);config.dwFlags=TDF_ALLOW_DIALOG_CANCELLATION|TDF_SIZE_TO_CONTENT;config.dwCommonButtons=TDCBF_CANCEL_BUTTON;config.pszWindowTitle=review.title.c_str();config.pszMainInstruction=review.instruction.c_str();config.pszContent=review.body.c_str();config.cButtons=1;config.pButtons=&start;config.nDefaultButton=IDCANCEL;int selected=IDCANCEL;auto result=show(&config,&selected,nullptr,nullptr);FreeLibrary(controls);if(SUCCEEDED(result))return selected==IDOK;}else FreeLibrary(controls);}
 auto text=review.instruction+L"\n\n"+review.body+L"\n\n按“确定”"+review.start+L"，或取消。";
 return MessageBoxW(nullptr,text.c_str(),review.title.c_str(),MB_OKCANCEL|MB_DEFBUTTON2|MB_ICONINFORMATION)==IDOK;
}
bool administrator() {
 BOOL yes=FALSE; SID_IDENTIFIER_AUTHORITY nt=SECURITY_NT_AUTHORITY; PSID group=nullptr;
 if(AllocateAndInitializeSid(&nt,2,SECURITY_BUILTIN_DOMAIN_RID,DOMAIN_ALIAS_RID_ADMINS,0,0,0,0,0,0,&group)) { CheckTokenMembership(nullptr,group,&yes); FreeSid(group); }
 return yes != FALSE;
}
// TSF preferences and Run belong to the actual interactive user. Elevation via
// a different administrator must fail before touching either user's state.
// We never impersonate, load another hive, change the shell, or guess a SID.
std::vector<BYTE> processUser(HANDLE process) {
 HANDLE token=nullptr;if(!OpenProcessToken(process,TOKEN_QUERY,&token))throw Failure(10,HRESULT_FROM_WIN32(GetLastError()));
 DWORD size=0;GetTokenInformation(token,TokenUser,nullptr,0,&size);
 if(!size||size>65536){CloseHandle(token);throw Failure(10,E_ACCESSDENIED);}
 std::vector<BYTE> value(size);
 BOOL ok=GetTokenInformation(token,TokenUser,value.data(),size,&size);auto error=GetLastError();CloseHandle(token);
 if(!ok)throw Failure(10,HRESULT_FROM_WIN32(error));return value;
}
void requireInteractiveUser() {
 auto shell=GetShellWindow();DWORD pid=0;if(!shell||!GetWindowThreadProcessId(shell,&pid)||!pid)throw Failure(10,E_ACCESSDENIED);
 DWORD ours=0,theirs=0;if(!ProcessIdToSessionId(GetCurrentProcessId(),&ours)||!ProcessIdToSessionId(pid,&theirs)||!ours||ours!=theirs)throw Failure(10,E_ACCESSDENIED);
 HANDLE process=OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION,FALSE,pid);if(!process)throw Failure(10,HRESULT_FROM_WIN32(GetLastError()));
 std::vector<BYTE> shellUser;try{shellUser=processUser(process);}catch(...){CloseHandle(process);throw;}CloseHandle(process);
 auto current=processUser(GetCurrentProcess());
 if(!EqualSid(reinterpret_cast<TOKEN_USER*>(current.data())->User.Sid,reinterpret_cast<TOKEN_USER*>(shellUser.data())->User.Sid))throw Failure(10,E_ACCESSDENIED);
}
fs::path folder(REFKNOWNFOLDERID id) { PWSTR p=nullptr; HRESULT hr=SHGetKnownFolderPath(id,0,nullptr,&p); if(FAILED(hr))throw Failure(10,hr); fs::path result(p); CoTaskMemFree(p); return result; }
fs::path normalizedPath(fs::path value) { return value.lexically_normal().make_preferred(); }
bool samePath(const fs::path& left,const fs::path& right) {
 auto a=normalizedPath(left).wstring(),b=normalizedPath(right).wstring();
 return CompareStringOrdinal(a.data(),int(a.size()),b.data(),int(b.size()),TRUE)==CSTR_EQUAL;
}
bool inside(const fs::path& p,const fs::path& root) {
 auto s=normalizedPath(fs::absolute(p)).wstring(), prefix=normalizedPath(fs::absolute(root)).wstring()+L"\\";
 return s.size()>prefix.size() && CompareStringOrdinal(s.data(),int(prefix.size()),prefix.data(),int(prefix.size()),TRUE)==CSTR_EQUAL;
}
// Check every existing ancestor, including Program Files/Profile. Do not follow junctions.
void normalPath(const fs::path& p) {
 auto absolute=normalizedPath(fs::absolute(p));
 for(auto q=absolute;!q.empty();q=q.parent_path()) {
  DWORD flags=GetFileAttributesW(q.c_str());
  if(flags!=INVALID_FILE_ATTRIBUTES && (flags&FILE_ATTRIBUTE_REPARSE_POINT))throw Failure(10,E_ACCESSDENIED);
  if(q==q.parent_path())break;
 }
}
std::string digest(const fs::path& p) {
 BCRYPT_ALG_HANDLE alg=nullptr; BCRYPT_HASH_HANDLE hash=nullptr; DWORD length=0,got=0; std::vector<UCHAR> object; UCHAR out[32];
 if(BCryptOpenAlgorithmProvider(&alg,BCRYPT_SHA256_ALGORITHM,nullptr,0)<0)throw Failure(10);
 try {
  if(BCryptGetProperty(alg,BCRYPT_OBJECT_LENGTH,reinterpret_cast<PUCHAR>(&length),sizeof(length),&got,0)<0)throw Failure(10);
  object.resize(length); if(BCryptCreateHash(alg,&hash,object.data(),length,nullptr,0,0)<0)throw Failure(10);
  std::ifstream input(p,std::ios::binary); if(!input)throw Failure(10);
  char buffer[65536]; while(input) { input.read(buffer,sizeof(buffer)); auto n=input.gcount(); if(n&&BCryptHashData(hash,reinterpret_cast<PUCHAR>(buffer),ULONG(n),0)<0)throw Failure(10); }
  if(input.bad()||BCryptFinishHash(hash,out,32,0)<0)throw Failure(10);
 } catch(...) { if(hash)BCryptDestroyHash(hash); BCryptCloseAlgorithmProvider(alg,0); throw; }
 BCryptDestroyHash(hash); BCryptCloseAlgorithmProvider(alg,0);
 std::string result; for(UCHAR b:out) { result+="0123456789abcdef"[b>>4]; result+="0123456789abcdef"[b&15]; } return result;
}
void settingsShortcut(const std::vector<fs::path>& allowed,const fs::path& target,bool remove,Report& report) noexcept {
 try {
  auto file=folder(FOLDERID_CommonPrograms)/L"灵鹤输入法.lnk";normalPath(file);
  Microsoft::WRL::ComPtr<IShellLinkW> link;if(FAILED(CoCreateInstance(CLSID_ShellLink,nullptr,CLSCTX_INPROC_SERVER,IID_PPV_ARGS(&link))))return;
  Microsoft::WRL::ComPtr<IPersistFile> persist;if(FAILED(link.As(&persist)))return;
  if(fs::exists(file)) {
   if(FAILED(persist->Load(file.c_str(),STGM_READ))) {report.unknownFilesPreserved=true;return;}
   wchar_t path[32768]{},arguments[1024]{};WIN32_FIND_DATAW info{};
   if(FAILED(link->GetPath(path,32768,&info,SLGP_RAWPATH))||FAILED(link->GetArguments(arguments,1024))||arguments[0]||std::none_of(allowed.begin(),allowed.end(),[&](const auto&p){return samePath(path,p);})) {report.unknownFilesPreserved=true;return;}
  } else if(remove)return;
  if(remove) {report.shortcutUpdated=DeleteFileW(file.c_str())!=FALSE;return;}
  normalPath(target);if(!fs::is_regular_file(target))return;
  if(FAILED(link->SetPath(target.c_str()))||FAILED(link->SetArguments(L""))||FAILED(link->SetWorkingDirectory(target.parent_path().c_str()))||FAILED(link->SetDescription(L"灵鹤输入法设置"))||FAILED(link->SetIconLocation((target.parent_path()/L"PrivateInputTSF.dll").c_str(),0)))return;
  auto temp=file.parent_path()/(L".LingheInput-"+std::to_wstring(GetCurrentProcessId())+L"-"+std::to_wstring(GetTickCount64())+L".tmp.lnk");normalPath(temp);if(fs::exists(temp))return;
  if(SUCCEEDED(persist->Save(temp.c_str(),TRUE))) {report.shortcutUpdated=MoveFileExW(temp.c_str(),file.c_str(),MOVEFILE_REPLACE_EXISTING|MOVEFILE_WRITE_THROUGH)!=FALSE;if(!report.shortcutUpdated)DeleteFileW(temp.c_str());}
 } catch(...) {}
}
std::wstring registered() {
 HKEY key=nullptr; LONG error=RegOpenKeyExW(HKEY_LOCAL_MACHINE,ClassKey.c_str(),0,KEY_QUERY_VALUE|KEY_WOW64_64KEY,&key);
 if(error==ERROR_FILE_NOT_FOUND||error==ERROR_PATH_NOT_FOUND)return {};
 if(error!=ERROR_SUCCESS)throw Failure(10,HRESULT_FROM_WIN32(error));
 wchar_t buffer[32768]; DWORD type=0,n=sizeof(buffer); error=RegQueryValueExW(key,nullptr,nullptr,&type,reinterpret_cast<BYTE*>(buffer),&n); RegCloseKey(key);
 if(error!=ERROR_SUCCESS||type!=REG_SZ||n<sizeof(wchar_t)||n%sizeof(wchar_t)||buffer[n/sizeof(wchar_t)-1])throw Failure(10);
 std::wstring result(buffer); if((result.size()+1)*sizeof(wchar_t)!=n)throw Failure(10); return normalizedPath(result).wstring();
}
void setRegistered(const std::wstring& path) {
 auto preferred=normalizedPath(path).wstring();
 HKEY key=nullptr; LONG error=RegOpenKeyExW(HKEY_LOCAL_MACHINE,ClassKey.c_str(),0,KEY_SET_VALUE|KEY_WOW64_64KEY,&key);
 if(error!=ERROR_SUCCESS)throw Failure(20,HRESULT_FROM_WIN32(error));
 error=RegSetValueExW(key,nullptr,0,REG_SZ,reinterpret_cast<const BYTE*>(preferred.c_str()),DWORD((preferred.size()+1)*sizeof(wchar_t))); RegCloseKey(key);
 if(error!=ERROR_SUCCESS)throw Failure(20,HRESULT_FROM_WIN32(error));
}
HRESULT registerDll(const fs::path& dll,bool remove,std::string* stage=nullptr) {
 SetDefaultDllDirectories(LOAD_LIBRARY_SEARCH_DEFAULT_DIRS); auto cookie=AddDllDirectory(dll.parent_path().c_str());
 HMODULE lib=LoadLibraryExW(dll.c_str(),nullptr,LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR|LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
 if(!lib) { auto error=GetLastError(); if(cookie)RemoveDllDirectory(cookie); return HRESULT_FROM_WIN32(error); }
 using Entry=HRESULT(WINAPI*)(); auto entry=reinterpret_cast<Entry>(GetProcAddress(lib,remove?"DllUnregisterServer":"DllRegisterServer"));
 HRESULT hr=entry?entry():E_NOINTERFACE;
 if(FAILED(hr)&&stage){
  unsigned failedStage=0;using Diagnostic=unsigned(WINAPI*)();auto diagnostic=reinterpret_cast<Diagnostic>(GetProcAddress(lib,"DllGetRegistrationDiagnostic"));
  if(diagnostic){failedStage=diagnostic();*stage+=".dll-stage-"+std::to_string(failedStage);}
  using Enumeration=private_input::registration::EnumerationDiagnostic;
  using EnumerationDiagnostic=HRESULT(WINAPI*)(Enumeration*);
  auto readEnumeration=reinterpret_cast<EnumerationDiagnostic>(GetProcAddress(lib,"DllGetRegistrationEnumerationDiagnostic"));
  Enumeration value;
  if(readEnumeration&&SUCCEEDED(readEnumeration(&value))&&(value.stage==failedStage||(remove&&value.stage==15)))
   *stage+=private_input::registration::enumerationDiagnosticSuffix(value);
 }
 FreeLibrary(lib); if(cookie)RemoveDllDirectory(cookie); return hr;
}
// Microsoft's documented IME enablement API. Flags 0 adds only our TIP; it
// never requests DEFPROFILE, CLEANINSTALL, another user hive or a default change.
void updateOwnUserTip(bool remove,Report&report){
 requireInteractiveUser();
 if(!remove){Microsoft::WRL::ComPtr<ITfInputProcessorProfiles> profiles;auto hr=CoCreateInstance(CLSID_TF_InputProcessorProfiles,nullptr,CLSCTX_INPROC_SERVER,IID_PPV_ARGS(&profiles));if(FAILED(hr))throw Failure(44,hr);BOOL enabled=FALSE;hr=profiles->IsEnabledLanguageProfile(CLSID_PrivateInput,MAKELANGID(LANG_CHINESE,SUBLANG_CHINESE_SIMPLIFIED),GUID_PrivateInputProfile,&enabled);if(FAILED(hr))throw Failure(44,hr);if(!enabled)return;}
 HMODULE input=LoadLibraryExW(L"input.dll",nullptr,LOAD_LIBRARY_SEARCH_SYSTEM32);if(!input)throw Failure(44,HRESULT_FROM_WIN32(GetLastError()));
 using Install=BOOL(WINAPI*)(LPCWSTR,DWORD);auto install=reinterpret_cast<Install>(GetProcAddress(input,"InstallLayoutOrTip"));
 wchar_t cls[39]{},profile[39]{};StringFromGUID2(CLSID_PrivateInput,cls,39);StringFromGUID2(GUID_PrivateInputProfile,profile,39);auto tip=std::wstring(L"0x0804:")+cls+profile;
 BOOL okay=install&&install(tip.c_str(),remove?1u:0u);auto error=GetLastError();FreeLibrary(input);if(!okay)throw Failure(44,HRESULT_FROM_WIN32(error?error:ERROR_GEN_FAILURE));report.userTipUpdated=true;
}
struct Value { std::wstring name; DWORD type; std::vector<BYTE> bytes; };
struct Tree { std::vector<Value> values; std::vector<std::pair<std::wstring,Tree>> children; };
Tree readTree(HKEY key,unsigned depth=0) {
 if(depth>32)throw Failure(10); Tree tree; DWORD count=0,maxName=0,maxData=0,subkeys=0,maxSubkey=0;
 LONG error=RegQueryInfoKeyW(key,nullptr,nullptr,nullptr,&subkeys,&maxSubkey,nullptr,&count,&maxName,&maxData,nullptr,nullptr);
 if(error!=ERROR_SUCCESS||count>256||subkeys>256||maxData>1024*1024)throw Failure(10);
 for(DWORD i=0;i<count;i++) {
  std::vector<wchar_t> name(maxName+2); Value value; DWORD n=DWORD(name.size()),size=maxData;
  value.bytes.resize(maxData); error=RegEnumValueW(key,i,name.data(),&n,nullptr,&value.type,value.bytes.data(),&size);
  if(error!=ERROR_SUCCESS||value.type==REG_LINK)throw Failure(10); value.name.assign(name.data(),n); value.bytes.resize(size); tree.values.push_back(std::move(value));
 }
 for(DWORD i=0;i<subkeys;i++) {
  std::vector<wchar_t> name(maxSubkey+2); DWORD n=DWORD(name.size()); error=RegEnumKeyExW(key,i,name.data(),&n,nullptr,nullptr,nullptr,nullptr);
  if(error!=ERROR_SUCCESS)throw Failure(10); HKEY child=nullptr;
  error=RegOpenKeyExW(key,name.data(),REG_OPTION_OPEN_LINK,KEY_READ|KEY_WOW64_64KEY,&child); if(error!=ERROR_SUCCESS)throw Failure(10);
  try { tree.children.emplace_back(std::wstring(name.data(),n),readTree(child,depth+1)); } catch(...) { RegCloseKey(child); throw; } RegCloseKey(child);
 }
 return tree;
}
LONG writeTree(HKEY key,const Tree& tree) {
 for(const auto& value:tree.values) { LONG error=RegSetValueExW(key,value.name.c_str(),0,value.type,value.bytes.data(),DWORD(value.bytes.size())); if(error!=ERROR_SUCCESS)return error; }
 for(const auto& child:tree.children) { HKEY target=nullptr; LONG error=RegCreateKeyExW(key,child.first.c_str(),0,nullptr,0,KEY_WRITE|KEY_WOW64_64KEY,nullptr,&target,nullptr); if(error!=ERROR_SUCCESS)return error; error=writeTree(target,child.second); RegCloseKey(target); if(error!=ERROR_SUCCESS)return error; }
 return ERROR_SUCCESS;
}
struct Snapshot {
 HKEY hive; std::wstring path; bool existed=false; Tree tree;
 Snapshot(HKEY h,std::wstring p):hive(h),path(std::move(p)) {
  HKEY key=nullptr; LONG error=RegOpenKeyExW(hive,path.c_str(),REG_OPTION_OPEN_LINK,KEY_READ|KEY_WOW64_64KEY,&key);
  if(error==ERROR_FILE_NOT_FOUND||error==ERROR_PATH_NOT_FOUND)return;
  if(error!=ERROR_SUCCESS)throw Failure(10,HRESULT_FROM_WIN32(error)); existed=true;
  try { tree=readTree(key); } catch(...) { RegCloseKey(key); throw; } RegCloseKey(key);
 }
 bool restore() const {
  auto separator=path.find_last_of(L'\\'); auto parent=path.substr(0,separator), leaf=path.substr(separator+1); HKEY key=nullptr;
  LONG error=RegOpenKeyExW(hive,parent.c_str(),0,KEY_ALL_ACCESS|KEY_WOW64_64KEY,&key);
  if((error==ERROR_FILE_NOT_FOUND||error==ERROR_PATH_NOT_FOUND)&&!existed)return true;
  if(error!=ERROR_SUCCESS)return false; error=RegDeleteTreeW(key,leaf.c_str()); RegCloseKey(key);
  if(error!=ERROR_SUCCESS&&error!=ERROR_FILE_NOT_FOUND&&error!=ERROR_PATH_NOT_FOUND)return false;
  if(!existed)return true;
  error=RegCreateKeyExW(hive,path.c_str(),0,nullptr,0,KEY_WRITE|KEY_WOW64_64KEY,nullptr,&key,nullptr); if(error!=ERROR_SUCCESS)return false;
  error=writeTree(key,tree); RegCloseKey(key); return error==ERROR_SUCCESS;
 }
};
std::vector<Snapshot> snapshots(bool includeSystray=false) {
 std::vector<Snapshot> result; result.emplace_back(HKEY_LOCAL_MACHINE,ClassBase);
 result.emplace_back(HKEY_LOCAL_MACHINE,UninstallKey);
 for(HKEY hive:{HKEY_LOCAL_MACHINE,HKEY_CURRENT_USER}) {
  result.emplace_back(hive,std::wstring(L"Software\\Microsoft\\CTF\\TIP\\")+OwnClass);
  // Snapshot only this service's item and supported category reverse mappings.
  result.emplace_back(hive,std::wstring(L"Software\\Microsoft\\CTF\\Category\\Item\\")+OwnClass);
  result.emplace_back(hive,std::wstring(L"Software\\Microsoft\\CTF\\Category\\Category\\{34745C63-B2F0-4784-8B67-5E12C8701A31}\\")+OwnClass);
  if(includeSystray){wchar_t systray[39]{};StringFromGUID2(linghe::tsf::SystrayCategory,systray,39);result.emplace_back(hive,std::wstring(L"Software\\Microsoft\\CTF\\Category\\Category\\")+systray+L"\\"+OwnClass);}
 }
 return result;
}
std::wstring registryString(HKEY key,const wchar_t* name) {
 wchar_t value[32768]; DWORD type=0,size=sizeof(value);
 auto error=RegQueryValueExW(key,name,nullptr,&type,reinterpret_cast<BYTE*>(value),&size);
 if(error!=ERROR_SUCCESS||type!=REG_SZ||size<sizeof(wchar_t)||size%sizeof(wchar_t)||value[size/sizeof(wchar_t)-1])throw Failure(10);
 std::wstring result(value); if((result.size()+1)*sizeof(wchar_t)!=size)throw Failure(10); return result;
}
fs::path validateUninstallEntry(const fs::path& root) {
 HKEY key=nullptr; auto error=RegOpenKeyExW(HKEY_LOCAL_MACHINE,UninstallKey.c_str(),0,KEY_QUERY_VALUE|KEY_WOW64_64KEY,&key);
 if(error==ERROR_FILE_NOT_FOUND||error==ERROR_PATH_NOT_FOUND)return {};
 if(error!=ERROR_SUCCESS)throw Failure(10,HRESULT_FROM_WIN32(error));
 fs::path installer;
 try {
  if(registryString(key,L"DisplayName")!=L"灵鹤输入法"||!samePath(registryString(key,L"InstallLocation"),root))throw Failure(10,E_ACCESSDENIED);
  auto command=registryString(key,L"UninstallString"); auto closing=command.find(L'"',1);
  if(command.empty()||command.front()!=L'"'||closing==std::wstring::npos||
     (command.substr(closing+1)!=L" --uninstall"&&command.substr(closing+1)!=L" --unregister"))throw Failure(10,E_ACCESSDENIED);
  installer=normalizedPath(command.substr(1,closing-1)); normalPath(installer);
  if(installer.filename()!=L"LingheInputSetup.exe"||!samePath(installer.parent_path().parent_path(),root/L"versions")||
     !linghe::installer::ownedVersionName(installer.parent_path().filename().u8string()))throw Failure(10,E_ACCESSDENIED);
  if(registryString(key,L"DisplayVersion")!=installer.parent_path().filename().wstring())throw Failure(42,HRESULT_FROM_WIN32(ERROR_REVISION_MISMATCH));
 } catch(...) { RegCloseKey(key); throw; } RegCloseKey(key); return installer;
}
void uninstallEntry(const fs::path& root,const fs::path& installer,bool remove) {
 if(remove) {
  auto error=RegDeleteTreeW(HKEY_LOCAL_MACHINE,UninstallKey.c_str());
  if(error!=ERROR_SUCCESS&&error!=ERROR_FILE_NOT_FOUND&&error!=ERROR_PATH_NOT_FOUND)throw Failure(20,HRESULT_FROM_WIN32(error));
  return;
 }
 HKEY key=nullptr; auto error=RegCreateKeyExW(HKEY_LOCAL_MACHINE,UninstallKey.c_str(),0,nullptr,0,KEY_SET_VALUE|KEY_WOW64_64KEY,nullptr,&key,nullptr);
 if(error!=ERROR_SUCCESS)throw Failure(20,HRESULT_FROM_WIN32(error));
 try {
  auto text=[&](const wchar_t* name,const std::wstring& value) { auto status=RegSetValueExW(key,name,0,REG_SZ,reinterpret_cast<const BYTE*>(value.c_str()),DWORD((value.size()+1)*sizeof(wchar_t))); if(status!=ERROR_SUCCESS)throw Failure(20,HRESULT_FROM_WIN32(status)); };
  auto number=[&](const wchar_t* name,DWORD value) { auto status=RegSetValueExW(key,name,0,REG_DWORD,reinterpret_cast<const BYTE*>(&value),sizeof(value)); if(status!=ERROR_SUCCESS)throw Failure(20,HRESULT_FROM_WIN32(status)); };
  text(L"DisplayName",L"灵鹤输入法"); text(L"DisplayVersion",Version); text(L"InstallLocation",normalizedPath(root).wstring());
  text(L"UninstallString",L"\""+normalizedPath(installer).wstring()+L"\" --uninstall");
  text(L"QuietUninstallString",L"\""+normalizedPath(installer).wstring()+L"\" --uninstall --quiet");
  text(L"Comments",L"卸载已验证的灵鹤程序文件，保留个人词库与配置。占用或未知文件保留可重试入口。");
  number(L"NoModify",1); number(L"NoRepair",1);
 } catch(...) { RegCloseKey(key); throw; } RegCloseKey(key);
}
void migrateOwnedWorkerStartup(const fs::path&oldDLL,const fs::path&newDLL,Report&report){if(oldDLL.empty())return;auto previous=oldDLL.parent_path()/L"LingheInputActivity.exe";HWND active=FindWindowW(L"LingheInput.Activity",nullptr);if(active){DWORD pid=0;GetWindowThreadProcessId(active,&pid);HANDLE process=OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION,FALSE,pid);if(process){wchar_t path[32768]{};DWORD size=32768;if(QueryFullProcessImageNameW(process,0,path,&size)&&samePath(path,previous))report.workerRestartRequired=true;CloseHandle(process);}}HKEY key=nullptr;if(RegOpenKeyExW(HKEY_CURRENT_USER,L"Software\\Microsoft\\Windows\\CurrentVersion\\Run",0,KEY_QUERY_VALUE|KEY_SET_VALUE,&key)!=ERROR_SUCCESS)return;try{auto value=registryString(key,L"LingheInputActivity");auto next=newDLL.parent_path()/L"LingheInputActivity.exe";auto expected=L"\""+previous.wstring()+L"\" --background";if(value==expected){auto command=L"\""+next.wstring()+L"\" --background";if(RegSetValueExW(key,L"LingheInputActivity",0,REG_SZ,reinterpret_cast<const BYTE*>(command.c_str()),DWORD((command.size()+1)*sizeof(wchar_t)))==ERROR_SUCCESS)report.workerStartupMigrated=true;else report.workerRestartRequired=true;}}catch(...){}RegCloseKey(key);}
// Ordinary upgrade must never silently normalize an already mixed setup.
// In particular DLL/ARP 047 with a healthy 043 worker needs a reviewed repair,
// rather than migrating startup based on the wrong DLL. All checks precede copy.
std::optional<std::wstring> ownedRunCommand(){
 HKEY key=nullptr;auto error=RegOpenKeyExW(HKEY_CURRENT_USER,L"Software\\Microsoft\\Windows\\CurrentVersion\\Run",0,KEY_QUERY_VALUE,&key);
 if(error==ERROR_FILE_NOT_FOUND||error==ERROR_PATH_NOT_FOUND)return {};
 if(error!=ERROR_SUCCESS)throw Failure(42,HRESULT_FROM_WIN32(error));
 DWORD size=0;error=RegQueryValueExW(key,L"LingheInputActivity",nullptr,nullptr,nullptr,&size);
 if(error==ERROR_FILE_NOT_FOUND){RegCloseKey(key);return {};}
 if(error!=ERROR_SUCCESS){RegCloseKey(key);throw Failure(42,HRESULT_FROM_WIN32(error));}
 try{auto value=registryString(key,L"LingheInputActivity");RegCloseKey(key);return value;}catch(...){RegCloseKey(key);throw;}
}
void requireConsistentUpgrade(const std::wstring& old,const fs::path& arpInstaller,Report& report){
 const auto oldDll=fs::path(old),expected=oldDll.parent_path()/L"LingheInputActivity.exe";
 bool active=false,workerMatches=false;
 HWND window=FindWindowW(L"LingheInput.Activity",nullptr);
 if(window){
  active=true;DWORD pid=0;GetWindowThreadProcessId(window,&pid);
  HANDLE process=OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION,FALSE,pid);
  if(!process)throw Failure(42,HRESULT_FROM_WIN32(GetLastError()));
  try{
   wchar_t path[32768]{};DWORD count=32768;
   if(!QueryFullProcessImageNameW(process,0,path,&count))throw Failure(42,HRESULT_FROM_WIN32(GetLastError()));
   auto current=processUser(GetCurrentProcess()),other=processUser(process);
   DWORD a=0,b=0;
   workerMatches=!old.empty()&&samePath(path,expected)&&EqualSid(reinterpret_cast<TOKEN_USER*>(current.data())->User.Sid,reinterpret_cast<TOKEN_USER*>(other.data())->User.Sid)&&ProcessIdToSessionId(GetCurrentProcessId(),&a)&&ProcessIdToSessionId(pid,&b)&&a==b;
  }catch(...){CloseHandle(process);throw;}CloseHandle(process);
 }
 auto startup=ownedRunCommand();
 const bool runMatches=startup&&*startup==L"\""+expected.wstring()+L"\" --background";
 const bool arpMatches=!old.empty()&&!arpInstaller.empty()&&samePath(arpInstaller.parent_path(),oldDll.parent_path().parent_path());
 auto verdict=linghe::installer::upgradeState(!old.empty(),!arpInstaller.empty(),arpMatches,active,workerMatches,bool(startup),runMatches);
 if(verdict!=linghe::installer::UpgradeState::Ready){
  report.stage="mixed-installation-"+std::to_string(static_cast<unsigned>(verdict));
  throw Failure(42,HRESULT_FROM_WIN32(ERROR_REVISION_MISMATCH));
 }
}
struct Item { std::string sha; fs::path rel; unsigned resource=0; };
struct Payload { fs::path source; std::vector<Item> files; bool embedded=false; };
struct Resource { const BYTE* data; DWORD size; };
Resource embeddedResource(unsigned id) {
 auto resource=FindResourceW(nullptr,MAKEINTRESOURCEW(id),RT_RCDATA); if(!resource)throw Failure(10);
 auto size=SizeofResource(nullptr,resource); auto handle=LoadResource(nullptr,resource);
 auto bytes=static_cast<const BYTE*>(LockResource(handle));
 if(!bytes||!size||size>linghe::installer::MaxPayloadFile)throw Failure(10);
 return {bytes,size};
}
std::string digestBytes(const BYTE* bytes,DWORD size) {
 BCRYPT_ALG_HANDLE alg=nullptr; BCRYPT_HASH_HANDLE hash=nullptr; DWORD length=0,got=0; std::vector<UCHAR> object; UCHAR out[32];
 if(BCryptOpenAlgorithmProvider(&alg,BCRYPT_SHA256_ALGORITHM,nullptr,0)<0)throw Failure(10);
 try {
  if(BCryptGetProperty(alg,BCRYPT_OBJECT_LENGTH,reinterpret_cast<PUCHAR>(&length),sizeof(length),&got,0)<0)throw Failure(10);
  object.resize(length); if(BCryptCreateHash(alg,&hash,object.data(),length,nullptr,0,0)<0)throw Failure(10);
  // Hash the memory-mapped resource in bounded chunks; do not duplicate the complete payload in RAM.
  for(DWORD offset=0;offset<size;) { DWORD count=(std::min)(size-offset,DWORD(65536)); if(BCryptHashData(hash,const_cast<PUCHAR>(bytes+offset),count,0)<0)throw Failure(10); offset+=count; }
  if(BCryptFinishHash(hash,out,32,0)<0)throw Failure(10);
 } catch(...) { if(hash)BCryptDestroyHash(hash); BCryptCloseAlgorithmProvider(alg,0); throw; }
 BCryptDestroyHash(hash); BCryptCloseAlgorithmProvider(alg,0);
 std::string result; for(UCHAR b:out) { result+="0123456789abcdef"[b>>4]; result+="0123456789abcdef"[b&15]; } return result;
}
Payload package() {
 Payload result;
 auto manifestResource=FindResourceW(nullptr,MAKEINTRESOURCEW(linghe::installer::ManifestResource),RT_RCDATA);
 std::string manifestBytes;
 if(manifestResource) {
  // Any malformed/missing embedded entry is fatal. Never fall back to neighbouring files.
  result.embedded=true; auto bytes=embeddedResource(linghe::installer::ManifestResource);
  if(bytes.size>256*1024)throw Failure(10);
  manifestBytes.assign(reinterpret_cast<const char*>(bytes.data),bytes.size);
 } else {
#ifdef LINGHE_EMBEDDED_ONLY
  throw Failure(10);
#else
  result.source=fs::path(ownExe()).parent_path()/L"payload";
  normalPath(result.source/L"manifest.sha256");
  std::ifstream input(result.source/L"manifest.sha256",std::ios::binary); if(!input)throw Failure(10);
  char chunk[4096]; while(input) { input.read(chunk,sizeof(chunk)); manifestBytes.append(chunk,size_t(input.gcount())); if(manifestBytes.size()>256*1024)throw Failure(10); }
  if(input.bad())throw Failure(10);
#endif
 }
 auto entries=linghe::installer::parseManifest(manifestBytes,VersionUtf8); unsigned id=linghe::installer::FirstFileResource; unsigned long long total=0;
 for(const auto& entry:entries) {
  Item item{entry.sha256,fs::u8path(entry.path),result.embedded?id:0}; ++id;
  if(result.embedded) {
   auto bytes=embeddedResource(item.resource); total+=bytes.size;
   if(total>linghe::installer::MaxPayloadTotal||digestBytes(bytes.data,bytes.size)!=item.sha)throw Failure(10);
  } else {
   normalPath(result.source/item.rel);
   if(!fs::is_regular_file(result.source/item.rel))throw Failure(10);
   auto size=fs::file_size(result.source/item.rel); total+=size;
   if(size>linghe::installer::MaxPayloadFile||total>linghe::installer::MaxPayloadTotal||digest(result.source/item.rel)!=item.sha)throw Failure(10);
  }
  result.files.push_back(std::move(item));
 }
 return result;
}
void writeEmbedded(const fs::path& target,unsigned resource) {
 auto bytes=embeddedResource(resource);
 HANDLE file=CreateFileW(target.c_str(),GENERIC_WRITE,0,nullptr,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,nullptr);
 if(file==INVALID_HANDLE_VALUE)throw Failure(10,HRESULT_FROM_WIN32(GetLastError()));
 bool ok=true;
 for(DWORD offset=0;ok&&offset<bytes.size;) { DWORD count=(std::min)(bytes.size-offset,DWORD(65536)),written=0; ok=WriteFile(file,bytes.data+offset,count,&written,nullptr)&&written==count; offset+=count; }
 if(ok)ok=FlushFileBuffers(file)!=FALSE; CloseHandle(file);
 if(!ok) { DeleteFileW(target.c_str()); throw Failure(10); }
}
void validateOld(const std::wstring& old,const fs::path& root) {
 if(old.empty())return; fs::path p=normalizedPath(old);
 if(!p.is_absolute()||!inside(p,root/L"versions")||p.filename()!=L"PrivateInputTSF.dll"||p.parent_path().filename()!=L"AMD64"||!samePath(p.parent_path().parent_path().parent_path(),root/L"versions"))throw Failure(10,E_ACCESSDENIED);
 normalPath(p); if(!fs::is_regular_file(p))throw Failure(10);
}
struct InstalledVersion { fs::path directory, installer; std::vector<linghe::installer::PayloadEntry> files; };
InstalledVersion verifiedVersion(const fs::path& directory,const std::string& runningHash,
                                 linghe::installer::PayloadPurpose purpose=linghe::installer::PayloadPurpose::InstallOrRepair) {
 normalPath(directory); auto version=directory.filename().u8string();
 if(!linghe::installer::ownedVersionName(version)||!fs::is_directory(directory))throw Failure(10,E_ACCESSDENIED);
 auto installer=directory/L"LingheInputSetup.exe"; normalPath(installer);
 if(!fs::is_regular_file(installer)||!linghe::installer::recognizedSetupHash(digest(installer),runningHash))throw Failure(10,E_ACCESSDENIED);
 // Read resources as inert data, never execute an old installer to inspect it.
 HMODULE data=LoadLibraryExW(installer.c_str(),nullptr,LOAD_LIBRARY_AS_DATAFILE_EXCLUSIVE|LOAD_LIBRARY_AS_IMAGE_RESOURCE);
 if(!data)throw Failure(10,HRESULT_FROM_WIN32(GetLastError()));
 std::string bytes;
 try {
  auto entry=FindResourceW(data,MAKEINTRESOURCEW(linghe::installer::ManifestResource),RT_RCDATA);
  auto size=entry?SizeofResource(data,entry):0;
  auto resource=entry?LoadResource(data,entry):nullptr;
  auto memory=resource?static_cast<const char*>(LockResource(resource)):nullptr;
  if(!memory||!size||size>256*1024)throw Failure(10,E_ACCESSDENIED);
  bytes.assign(memory,size);
 } catch(...) { FreeLibrary(data); throw; }
 FreeLibrary(data);
 auto files=linghe::installer::parseManifest(bytes,version);
 // A complete preflight precedes unregister/deletion. Tampered bytes are never
 // loaded as a DLL or deleted. Only explicit uninstall cleanup retries allow missing files.
 for(const auto& item:files) {
  auto path=directory/fs::u8path(item.path); normalPath(path);
  const bool exists=fs::exists(path),regular=exists&&fs::is_regular_file(path);
  if(!linghe::installer::validOwnedPayload(item,exists,regular,regular?digest(path):std::string{},purpose))
   throw Failure(10,E_ACCESSDENIED);
 }
 return {directory,installer,std::move(files)};
}
std::vector<InstalledVersion> uninstallPlan(const fs::path& root,const std::wstring& old,Report& report) {
 std::vector<InstalledVersion> versions; auto base=root/L"versions"; normalPath(base);
 if(!fs::exists(base)) { if(!old.empty())throw Failure(10,E_ACCESSDENIED); return versions; }
 auto runningHash=digest(ownExe()); bool activeFound=old.empty();
 for(const auto& entry:fs::directory_iterator(base)) {
  // Unknown directories, files, junctions or legacy installers are retained.
  // They do not provide authority to delete contents or execute old code.
  auto name=entry.path().filename().u8string();
  if(!linghe::installer::ownedVersionName(name)) { report.unknownFilesPreserved=true; continue; }
  bool active=!old.empty()&&samePath(entry.path()/L"AMD64"/L"PrivateInputTSF.dll",old);
  try { auto version=verifiedVersion(entry.path(),runningHash,linghe::installer::PayloadPurpose::CleanupRetry); versions.push_back(std::move(version)); if(active)activeFound=true; }
  catch(...) { if(active)throw; report.unknownFilesPreserved=true; }
 }
 if(!activeFound)throw Failure(10,E_ACCESSDENIED);
 return versions;
}
fs::path cleanVersions(const std::vector<InstalledVersion>& versions,const fs::path& arpInstaller,Report& report) {
 std::set<fs::path> directories; std::vector<fs::path> installers;
 fs::path lastInstaller=arpInstaller;
 if(lastInstaller.empty()&&!versions.empty())lastInstaller=versions.back().installer;
 if(!lastInstaller.empty()&&std::none_of(versions.begin(),versions.end(),[&](const auto& version){return samePath(version.installer,lastInstaller);}))report.unknownFilesPreserved=true;
 for(const auto& version:versions) {
  std::set<fs::path> expected{version.installer};
  for(const auto& item:version.files) {
   auto file=version.directory/fs::u8path(item.path); expected.insert(file);
   for(auto parent=file.parent_path();parent!=version.directory;parent=parent.parent_path())directories.insert(parent);
  }
  // Detect unknown files without following reparse points; no broad recursive
  // removal is used, even for apparently empty/unregistered versions.
  for(fs::recursive_directory_iterator i(version.directory),end;i!=end;++i) {
   DWORD attributes=GetFileAttributesW(i->path().c_str());
   if(attributes==INVALID_FILE_ATTRIBUTES||(attributes&FILE_ATTRIBUTE_REPARSE_POINT)) { i.disable_recursion_pending(); report.unknownFilesPreserved=true; continue; }
   if(!i->is_directory()&&!expected.count(i->path()))report.unknownFilesPreserved=true;
   if(i->is_directory()&&!directories.count(i->path())) { i.disable_recursion_pending(); report.unknownFilesPreserved=true; }
  }
  for(const auto& item:version.files) {
   auto file=version.directory/fs::u8path(item.path); normalPath(file);
   if(!fs::exists(file))continue;
   // Repeat the hash immediately before deleting: preflight is not a licence
   // to remove a file changed during the registration transaction.
   if(!fs::is_regular_file(file)||linghe::installer::cleanupDisposition(version.files,item.path,true,digest(file))!=linghe::installer::CleanupDisposition::RemoveVerified) { report.unknownFilesPreserved=true; continue; }
   if(!DeleteFileW(file.c_str()))report.fileCleanupPending=true;
  }
  directories.insert(version.directory); installers.push_back(version.installer);
 }
 // Retain all proof/cleanup executables until every payload is gone. A loaded
 // DLL, unknown file or running uninstaller leaves an explicit retry result.
 if(!report.fileCleanupPending&&!report.unknownFilesPreserved)for(const auto& installer:installers) {
  if(samePath(installer,lastInstaller))continue;
  normalPath(installer);
  if(!DeleteFileW(installer.c_str()))report.fileCleanupPending=true;
 }
 std::vector<fs::path> ordered(directories.begin(),directories.end());
 std::sort(ordered.begin(),ordered.end(),[](const auto& a,const auto& b){return a.native().size()>b.native().size();});
 for(const auto& directory:ordered) {
  if(directory==lastInstaller.parent_path())continue;
  normalPath(directory); if(!RemoveDirectoryW(directory.c_str())&&GetLastError()!=ERROR_FILE_NOT_FOUND&&GetLastError()!=ERROR_PATH_NOT_FOUND)report.fileCleanupPending=true;
 }
 // Never remove the ARP record while its running installer cannot be deleted.
 if(!lastInstaller.empty()&&samePath(lastInstaller,ownExe()))report.fileCleanupPending=true;
 report.retryRequired=report.fileCleanupPending||report.unknownFilesPreserved;
 return lastInstaller;
}
#include "RepairExisting.inc"
bool receipt(const fs::path& target,const Report& report) {
 fs::path temporary;
 try {
  normalPath(target); fs::create_directories(target.parent_path());
  if(fs::exists(target)) { std::ifstream in(target,std::ios::binary); std::string prefix(256,'\0'); in.read(prefix.data(),prefix.size()); if(prefix.find("\"application\":\"LingheInputSetup\"")==std::string::npos)return false; }
  temporary=target; temporary+=L"."+std::to_wstring(GetCurrentProcessId())+L"."+std::to_wstring(GetTickCount64())+L".tmp"; normalPath(temporary);
  HANDLE output=CreateFileW(temporary.c_str(),GENERIC_WRITE,0,nullptr,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,nullptr); if(output==INVALID_HANDLE_VALUE)return false;
  std::ostringstream json; json<<"{\"application\":\"LingheInputSetup\",\"schemaVersion\":1,\"version\":\""<<VersionUtf8<<"\",\"action\":\""<<report.action<<"\",\"status\":\""<<(report.retryRequired?"incomplete":report.code==0?"succeeded":"failed")<<"\",\"exitCode\":"<<report.code<<",\"stage\":\""<<report.stage<<"\",\"hresult\":"<<static_cast<unsigned long>(report.hr)<<",\"rollbackStatus\":\""<<report.rollback<<"\",\"installationCommitted\":"<<(report.committed?"true":"false")<<",\"fileCleanupPending\":"<<(report.fileCleanupPending?"true":"false")<<",\"retryRequired\":"<<(report.retryRequired?"true":"false")<<",\"unknownFilesPreserved\":"<<(report.unknownFilesPreserved?"true":"false")<<",\"shortcutUpdated\":"<<(report.shortcutUpdated?"true":"false")<<",\"workerStartupMigrated\":"<<(report.workerStartupMigrated?"true":"false")<<",\"workerRestartRequired\":"<<(report.workerRestartRequired?"true":"false")<<",\"userTipUpdated\":"<<(report.userTipUpdated?"true":"false")<<",\"registrationCatalogVerified\":"<<(report.registrationCatalogVerified?"true":"false")<<",\"repairTargetVersion\":\""<<report.repairTargetVersion<<"\",\"userDataPreserved\":true}\n";
  auto bytes=json.str(); DWORD written=0; bool ok=WriteFile(output,bytes.data(),DWORD(bytes.size()),&written,nullptr)&&written==bytes.size()&&FlushFileBuffers(output); CloseHandle(output);
  if(ok)ok=MoveFileExW(temporary.c_str(),target.c_str(),MOVEFILE_REPLACE_EXISTING|MOVEFILE_WRITE_THROUGH)!=FALSE;
  if(!ok)DeleteFileW(temporary.c_str()); return ok;
 } catch(...) { if(!temporary.empty())DeleteFileW(temporary.c_str()); return false; }
}
}
#ifndef LINGHE_SETUP_LIBRARY
int WINAPI wWinMain(HINSTANCE,HINSTANCE,PWSTR,int) {
 Report report; fs::path receiptPath; HRESULT com=E_FAIL; bool explicitAction=false,remove=false,repair=false,receiptAllowed=false,reviewConfirmed=false;
 HANDLE mutex=nullptr; bool locked=false;
 try {
  int count=0; LPWSTR* args=CommandLineToArgvW(GetCommandLineW(),&count); if(!args)throw Failure(2);
  std::vector<std::wstring> arguments; for(int i=1;i<count;i++)arguments.emplace_back(args[i]); LocalFree(args);
  if(arguments.size()==1&&arguments[0]==L"--verify-owned-tsf-catalog"){
   const auto initialized=CoInitializeEx(nullptr,COINIT_APARTMENTTHREADED);
   if(FAILED(initialized))return static_cast<int>(initialized);
   const auto status=linghe::installer::ownedRegistrationCatalogStatus();CoUninitialize();return static_cast<int>(status);
  }
  // Recognize quiet even when another argument is invalid: invalid CLI must never display UI in session 0.
  report.quiet=std::find(arguments.begin(),arguments.end(),L"--quiet")!=arguments.end();
  for(size_t i=0;i<arguments.size();i++) {
   const auto& arg=arguments[i]; if(arg==L"--quiet")continue;
   if(arg==L"--review-confirmed"){if(reviewConfirmed)throw Failure(2,E_INVALIDARG);reviewConfirmed=true;continue;}
   if(arg==L"--install"||arg==L"--unregister"||arg==L"--uninstall") { if(explicitAction)throw Failure(2,E_INVALIDARG); explicitAction=true; remove=arg!=L"--install"; }
   else if(arg==L"--repair"){if(explicitAction)throw Failure(2,E_INVALIDARG);explicitAction=true;repair=true;}
   else if(arg==L"--receipt"&&i+1<arguments.size()&&receiptPath.empty())receiptPath=arguments[++i];
   else throw Failure(2,E_INVALIDARG);
  }
  report.action=repair?"repair":remove?"uninstall":"install";
  if(report.quiet&&!explicitAction)throw Failure(2,E_INVALIDARG);
  if(reviewConfirmed&&(!explicitAction||report.quiet||!administrator()))throw Failure(2,E_INVALIDARG);
  fs::path root=normalizedPath(folder(FOLDERID_ProgramFiles)/L"LingheInput");
  if(receiptPath.empty())receiptPath=root/L"receipts/last-install.json";
  else {
   auto evidence=folder(FOLDERID_Profile)/L"Projects/private-input-windows/evidence";
   if(!receiptPath.is_absolute()||receiptPath.extension()!=L".json"||(!inside(receiptPath,root/L"receipts")&&!inside(receiptPath,evidence)))throw Failure(2,E_ACCESSDENIED);
  }
  normalPath(receiptPath); receiptAllowed=true;
  if(linghe::installer::reviewNeeded(report.quiet,reviewConfirmed)){report.stage="review";std::wstring current;auto existing=registered();if(!existing.empty()){auto name=fs::path(existing).parent_path().parent_path().filename();if(linghe::installer::ownedVersionName(name.u8string()))current=name.wstring();}if(!showInstallReview(linghe::installer::installReview(Version,root.wstring(),current,remove,repair)))return 0;reviewConfirmed=true;}
  if(!administrator()) {
   report.stage="elevation-required"; if(report.quiet)throw Failure(740,HRESULT_FROM_WIN32(ERROR_ELEVATION_REQUIRED));
   auto exe=ownExe(); std::wstring parameters=repair?L"--repair":remove?L"--uninstall":L"--install";parameters+=L" --review-confirmed";parameters+=L" --receipt \""+receiptPath.wstring()+L"\"";
   auto launched=reinterpret_cast<INT_PTR>(ShellExecuteW(nullptr,L"runas",exe.c_str(),parameters.c_str(),nullptr,SW_SHOWNORMAL)); if(launched>32)return 0; throw Failure(740,HRESULT_FROM_WIN32(GetLastError()?GetLastError():ERROR_CANCELLED));
  }
  report.stage="original-user-context"; requireInteractiveUser();
  report.stage="lock"; mutex=CreateMutexW(nullptr,FALSE,(L"Global\\LingheInputSetup."+OwnClass.substr(1,36)).c_str());
  if(!mutex)throw Failure(10,HRESULT_FROM_WIN32(GetLastError()));
  auto wait=WaitForSingleObject(mutex,0); if(wait!=WAIT_OBJECT_0&&wait!=WAIT_ABANDONED)throw Failure(10,HRESULT_FROM_WIN32(ERROR_BUSY)); locked=true;
  report.stage="initialize"; com=CoInitializeEx(nullptr,COINIT_APARTMENTTHREADED); if(FAILED(com))throw Failure(20,com);
  normalPath(root); auto old=registered(); validateOld(old,root); fs::path arpInstaller;
  // Explicit recovery validates its protected write-ahead journal before fresh
  // ARP consistency, which may be in-flight after a crash between value writes.
  if(!repair)arpInstaller=validateUninstallEntry(root);
  if(repair){repair_native::repair(root,old,report);}
  else {
  if(!remove){report.stage="upgrade-consistency";requireConsistentUpgrade(old,arpInstaller,report);}
  // Upgrades must not execute an unrelated registry target for rollback.
  if(!remove&&!old.empty()) { report.stage="previous-version-validation"; verifiedVersion(fs::path(old).parent_path().parent_path(),digest(ownExe())); }
  fs::path dll; std::vector<InstalledVersion> removal;
  if(remove) { report.stage="uninstall-validation"; removal=uninstallPlan(root,old,report); }
  if(!remove) {
   report.stage="package-validation"; auto payload=package();
   auto destination=root/L"versions"/Version; normalPath(destination); fs::create_directories(destination);
   report.stage="copy";
   for(const auto& item:payload.files) {
    auto target=destination/item.rel; normalPath(target); fs::create_directories(target.parent_path());
    if(fs::exists(target)) { if(digest(target)!=item.sha)throw Failure(10); }
    else { if(payload.embedded)writeEmbedded(target,item.resource); else fs::copy_file(payload.source/item.rel,target); if(digest(target)!=item.sha)throw Failure(10); }
   }
   // Retain the exact complete installer for the Apps & Features entry. Do not overwrite unknown bytes.
   auto installer=destination/L"LingheInputSetup.exe"; normalPath(installer); auto sourceExe=fs::path(ownExe());
   if(fs::exists(installer)) { if(digest(installer)!=digest(sourceExe))throw Failure(10); }
   else fs::copy_file(sourceExe,installer);
   dll=destination/L"AMD64"/L"PrivateInputTSF.dll";
  }
  report.stage="snapshot"; auto before=snapshots(true); bool mutated=false;
  try {
   report.stage=remove?"unregister":"register";
   if(remove) { if(!old.empty()) { mutated=true; auto hr=registerDll(old,true); if(FAILED(hr))throw Failure(20,hr); } }
   else { mutated=true; if(!old.empty())setRegistered(dll.wstring()); auto hr=registerDll(dll,false,&report.stage); if(FAILED(hr))throw Failure(20,hr); if(!samePath(registered(),dll))throw Failure(20);report.stage="registration-catalog";hr=linghe::installer::verifyRegistrationInFreshProcess(ownExe());if(FAILED(hr))throw Failure(20,hr);report.registrationCatalogVerified=true; }
   if(!remove) { report.stage="uninstall-entry"; mutated=true; uninstallEntry(root,dll.parent_path().parent_path()/L"LingheInputSetup.exe",false); }
   report.committed=true;
  } catch(...) {
   if(mutated) {
    bool restored=true; for(const auto& snapshot:before)if(!snapshot.restore())restored=false;
    // Restore the previous service's registration API state as well as the saved registry content.
    if(!old.empty()&&restored&&FAILED(registerDll(old,false)))restored=false;
    // Old registration may rewrite metadata; restore the exact captured values once more.
    for(const auto& snapshot:before)if(!snapshot.restore())restored=false;
    report.rollback=restored?(old.empty()?"restored-owned-registry":"restored-registry-and-old-registration"):"incomplete";
    if(!restored) { report.hr=E_FAIL; throw Failure(21); }
   }
   throw;
  }
  if(remove) {
   report.stage="user-tip-removal";updateOwnUserTip(true,report);
   std::vector<fs::path> shortcuts;for(const auto&version:removal)shortcuts.push_back(version.directory/L"AMD64"/L"LingheInputSettings.exe");settingsShortcut(shortcuts,{},true,report);
   report.stage="file-cleanup";
   // This phase follows the successful registry transaction. Do not attempt
   // rollback to DLLs whose payload may already have been removed.
   fs::path lastInstaller;
   try { lastInstaller=cleanVersions(removal,arpInstaller,report); }
   catch(...) { report.fileCleanupPending=true; report.retryRequired=true; }
   if(report.retryRequired) { report.code=40; report.stage="cleanup-retry-required"; }
   else {
    report.stage="uninstall-entry-removal"; Snapshot entry(HKEY_LOCAL_MACHINE,UninstallKey); uninstallEntry(root,{},true);
    // Keep registry and final cleanup executable consistent. If the final file
    // is unexpectedly locked, restore its original retry entry immediately.
    if(!lastInstaller.empty()&&!DeleteFileW(lastInstaller.c_str())) {
     report.fileCleanupPending=true; report.retryRequired=true; report.code=40; report.stage="cleanup-retry-required";
     if(!entry.restore())throw Failure(21);
    } else {
     if(!lastInstaller.empty())RemoveDirectoryW(lastInstaller.parent_path().c_str());
     RemoveDirectoryW((root/L"versions").c_str());
     report.code=0; report.stage="complete";
    }
   }
  } else {report.stage="user-tip-enable";updateOwnUserTip(false,report);migrateOwnedWorkerStartup(fs::path(old),dll,report); std::vector<fs::path> shortcuts{dll.parent_path()/L"LingheInputSettings.exe"};if(!old.empty())shortcuts.push_back(fs::path(old).parent_path()/L"LingheInputSettings.exe");settingsShortcut(shortcuts,dll.parent_path()/L"LingheInputSettings.exe",false,report);report.code=0; report.stage="complete"; }
  } // Ordinary install/uninstall; explicit repair never falls through.
 } catch(const Failure& error) {
  report.code=error.code; report.hr=error.hr;
  if(remove&&report.committed) { report.fileCleanupPending=true; report.retryRequired=true; if(report.code!=21)report.code=40; }
 }
 catch(...) {
  report.code=10; report.hr=E_FAIL;
  if(remove&&report.committed) { report.fileCleanupPending=true; report.retryRequired=true; report.code=40; }
 }
 if(SUCCEEDED(com))CoUninitialize();
 const bool receiptSaved=receiptAllowed&&receipt(receiptPath,report);
 if(receiptAllowed&&!receiptSaved) { if(report.code==0) { report.code=30; report.stage="receipt"; } }
 if(locked)ReleaseMutex(mutex); if(mutex)CloseHandle(mutex);
 if(!report.quiet) {
  if(report.code==0)MessageBoxW(nullptr,repair?L"登记已修复到当前正在运行的后台版本。个人资料与后台保持不变。\n现在可以再运行普通安装更新。":remove?L"灵鹤输入法已卸载。个人词库与配置已保留。":report.workerRestartRequired?L"安装完成。旧后台正在继续保留你的归档。\n请在方便时重新登录 Windows，以加载新后台并迁移旧输入习惯；不会自动注销。":L"安装完成。请在系统输入法列表选择“灵鹤输入法”。\n左右键选词，空格确认；上下键展开网格。",L"灵鹤输入法",MB_OK|MB_ICONINFORMATION);
  else {const auto message=linghe::installer::failureFeedback(report.code,report.stage,static_cast<uint32_t>(report.hr),report.committed,receiptPath.wstring(),receiptSaved,ownExe());MessageBoxW(nullptr,message.c_str(),L"灵鹤输入法",MB_OK|MB_ICONERROR);}
 }
 return report.code;
}

#endif // LINGHE_SETUP_LIBRARY
