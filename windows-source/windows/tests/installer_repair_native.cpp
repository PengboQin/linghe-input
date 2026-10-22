// Native administrative fixture only: fresh synthetic HKCU key + fresh protected
// ProgramData UUID directory. Never calls production repair/registration/Run.
#define LINGHE_SETUP_LIBRARY 1
#include "../installer/Setup.cpp"
#include <iostream>

namespace {
using namespace linghe::installer::recovery;
unsigned checks=0;
void check(bool value){if(!value)throw std::runtime_error("native repair fixture check");++checks;}
struct Fixture final:Adapter {
 std::wstring key;Tree before,after;ProtectedJournalFile&file;Image live;bool fail=false;
 Fixture(std::wstring k,Tree a,Tree b,ProtectedJournalFile&f):key(std::move(k)),before(std::move(a)),after(std::move(b)),file(f){}
 void preflight(const Journal&j)override{check(j.ownerSid==repair_native::ownerSid());check(key.rfind(L"Software\\LingheInputDev\\RepairFixtures\\",0)==0);}
 void store(const Journal&j)override{file.write(encodeJournal(j));check(decodeJournal(file.read()).phase==j.phase);}
 void apply(Slot slot,const Image&target)override{if(slot==Slot::Registration){repair_native::patchTree(HKEY_CURRENT_USER,key,before,after,after);if(fail){fail=false;throw std::runtime_error("synthetic post-write failure");}}live.slots[size_t(slot)]=target.slots[size_t(slot)];}
 void restore(Slot slot,const Image&target)override{if(slot==Slot::Registration)repair_native::patchTree(HKEY_CURRENT_USER,key,before,after,before);live.slots[size_t(slot)]=target.slots[size_t(slot)];}
 bool matches(const Image&target)override{Snapshot current(HKEY_CURRENT_USER,key);repair_native::Writer a,b;repair_native::putTree(a,current.tree);repair_native::putTree(b,target.slots[0]=="after"?after:before);return a.data==b.data&&live.slots==target.slots;}
};
}
int wmain(int argc,wchar_t**){
 if(argc!=1)return 2;if(!administrator())return 740;
 HRESULT com=CoInitializeEx(nullptr,COINIT_APARTMENTTHREADED);if(FAILED(com))return 1;
 fs::path fixtureRoot;std::wstring key;bool ownKey=false,ownRoot=false;int result=1;
 try{
  // Same Windows path with different separators must produce identical
  // serialized desired registration bytes, not a false ownership rejection.
  Tree slashA,slashB;Value pathValue;pathValue.name=L"IconFile";repair_native::setString(pathValue,L"C:\\fixture\\old\\PrivateInputTSF.dll");slashA.values.push_back(pathValue);slashB=slashA;
  repair_native::transformPaths(slashA,L"C:\\fixture\\old\\PrivateInputTSF.dll",L"C:\\fixture\\new\\PrivateInputTSF.dll");
  repair_native::transformPaths(slashB,L"C:/fixture/old/PrivateInputTSF.dll",L"C:/fixture/new/PrivateInputTSF.dll");
  repair_native::Writer canonicalA,canonicalB;repair_native::putTree(canonicalA,slashA);repair_native::putTree(canonicalB,slashB);check(canonicalA.data==canonicalB.data);
  const auto id=repair_native::nonce();fixtureRoot=folder(FOLDERID_ProgramData)/(L"LingheInputRepairFixture-"+id);normalPath(fixtureRoot);
  linghe::installer::recovery::journal_detail::Local sd;linghe::installer::recovery::journal_detail::descriptor(sd);SECURITY_ATTRIBUTES sa{sizeof(sa),sd.value,FALSE};
  check(CreateDirectoryW(fixtureRoot.c_str(),&sa)!=FALSE);ownRoot=true;auto parent=fixtureRoot/L"Storage",directory=parent/L"Transactions";
  check(CreateDirectoryW(parent.c_str(),&sa)!=FALSE);check(CreateDirectoryW(directory.c_str(),&sa)!=FALSE);
  key=L"Software\\LingheInputDev\\RepairFixtures\\"+id;HKEY opened=nullptr;DWORD disposition=0;
  check(RegCreateKeyExW(HKEY_CURRENT_USER,key.c_str(),0,nullptr,0,KEY_ALL_ACCESS|KEY_WOW64_64KEY,nullptr,&opened,&disposition)==ERROR_SUCCESS);check(disposition==REG_CREATED_NEW_KEY);ownKey=true;
  const wchar_t initial[]=L"owned-before",choice[]=L"preserve-user-choice";
  check(RegSetValueExW(opened,L"IconFile",0,REG_SZ,reinterpret_cast<const BYTE*>(initial),sizeof(initial))==ERROR_SUCCESS);
  check(RegSetValueExW(opened,L"UserChoice",0,REG_SZ,reinterpret_cast<const BYTE*>(choice),sizeof(choice))==ERROR_SUCCESS);RegCloseKey(opened);
  Snapshot captured(HKEY_CURRENT_USER,key);Tree after=captured.tree;for(auto&v:after.values)if(v.name==L"IconFile")repair_native::setString(v,L"owned-after");
  {
   ProtectedJournalFile file(directory,id);Journal j;j.transaction=repair_native::narrow(id);j.ownerSid=repair_native::ownerSid();j.sourceSetupHash=std::string(64,'a');j.targetSetupHash=std::string(64,'b');j.targetVersion="0.4.3-win1";j.before.slots={"before","before-arp","before-run","before-link"};j.desired.slots={"after","after-arp","after-run","after-link"};
   Fixture adapter(key,captured.tree,after,file);adapter.live=j.before;adapter.fail=true;auto rolled=execute(j,adapter);check(!rolled.committed&&rolled.restored&&!rolled.retryRequired);check(adapter.matches(j.before));
   j.phase=Phase::Prepared;j.intent=0;auto success=execute(j,adapter);check(success.committed&&adapter.matches(j.desired));
   j.phase=Phase::Applying;j.intent=0;file.write(encodeJournal(j));adapter.live=j.desired;auto resumed=decodeJournal(file.read());auto restored=execute(resumed,adapter);check(restored.restored&&adapter.matches(j.before));
   // Native per-value CAS refuses an unrelated concurrent edit rather than
   // overwriting it during recovery.
   check(RegOpenKeyExW(HKEY_CURRENT_USER,key.c_str(),0,KEY_SET_VALUE|KEY_WOW64_64KEY,&opened)==ERROR_SUCCESS);const wchar_t other[]=L"external-choice";check(RegSetValueExW(opened,L"UserChoice",0,REG_SZ,reinterpret_cast<const BYTE*>(other),sizeof(other))==ERROR_SUCCESS);RegCloseKey(opened);
   bool refused=false;try{repair_native::patchTree(HKEY_CURRENT_USER,key,captured.tree,after,after);}catch(...){refused=true;}check(refused);Snapshot external(HKEY_CURRENT_USER,key);auto found=std::find_if(external.tree.values.begin(),external.tree.values.end(),[](const auto&v){return v.name==L"UserChoice";});check(found!=external.tree.values.end()&&repair_native::stringValue(*found)==other);
   // A truncated post-intent stage is retained only after validation of the
   // trusted durable journal; never use its bytes as replay instructions.
   auto pending=directory/(id+L".journal.pending");repair_native::createBytes(pending,"partial",&sa);file.retireStagedAfterValidation([&](const std::string&bytes){check(bytes=="partial");check(decodeJournal(file.read()).ownerSid==repair_native::ownerSid());});check(!fs::exists(pending));
   // Real shell-link serialization/readback, with inert System32 target refs.
   wchar_t system[32768]{};check(GetSystemDirectoryW(system,32768)>0);repair_native::Writer missing;missing.number(false);auto absent=repair_native::desiredLink(missing.data,directory,fs::path(system)/L"notepad.exe");check(absent==missing.data);
   Microsoft::WRL::ComPtr<IShellLinkW> link;check(SUCCEEDED(CoCreateInstance(CLSID_ShellLink,nullptr,CLSCTX_INPROC_SERVER,IID_PPV_ARGS(&link))));check(SUCCEEDED(link->SetPath((fs::path(system)/L"cmd.exe").c_str())));Microsoft::WRL::ComPtr<IPersistFile> persist;check(SUCCEEDED(link.As(&persist)));auto source=directory/(repair_native::nonce()+L".fixture.lnk");check(SUCCEEDED(persist->Save(source.c_str(),TRUE)));repair_native::Writer original;original.number(true);original.bytes(repair_native::fileBytes(source));check(DeleteFileW(source.c_str())!=FALSE);auto desired=repair_native::desiredLink(original.data,directory,fs::path(system)/L"notepad.exe");repair_native::linkTarget(repair_native::decodeLink(desired).bytes,directory,{fs::path(system)/L"notepad.exe"});++checks;
  }
  result=0;
 }catch(const std::exception&e){std::cerr<<"fixture error: "<<e.what()<<"\n";}catch(const Failure&f){std::cerr<<"fixture Win32 stage error code="<<f.code<<" hresult="<<unsigned(f.hr)<<"\n";}catch(...){std::cerr<<"fixture unknown error\n";}
 if(result==0){if(ownKey)RegDeleteTreeW(HKEY_CURRENT_USER,key.c_str());if(ownRoot){std::error_code ignored;fs::remove_all(fixtureRoot,ignored);}}
 CoUninitialize();std::cout<<"{\"passed\":"<<(result==0?"true":"false")<<",\"checks\":"<<checks<<",\"realRegistryFixture\":true,\"realProtectedFile\":true,\"productionAppTouched\":false,\"workerStopped\":false,\"defaultInputChanged\":false}\n";return result;
}
