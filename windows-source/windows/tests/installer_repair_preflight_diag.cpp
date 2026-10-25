// Read-only diagnostic: replays repair_native::repair() preflight steps in the
// same order and reports which one fails. Stops before execute(); no registry,
// Run, shortcut, journal or process writes. Requires the same elevated Session1
// context as the real repair to be meaningful.
#define LINGHE_SETUP_LIBRARY 1
#include "../installer/Setup.cpp"
#include <iostream>
using namespace repair_native;
namespace {
std::string hex(HRESULT hr){char b[16];snprintf(b,sizeof b,"0x%08lX",static_cast<unsigned long>(hr));return b;}
template<class F> bool step(const char*name,F&&f){
 try{f();std::cout<<"ok   "<<name<<"\n";return true;}
 catch(const Failure&e){std::cout<<"FAIL "<<name<<" code="<<e.code<<" hr="<<hex(e.hr)<<"\n";}
 catch(const std::exception&e){std::cout<<"FAIL "<<name<<" std="<<e.what()<<"\n";}
 catch(...){std::cout<<"FAIL "<<name<<" unknown\n";}
 return false;
}
}
int wmain(){
 std::cout<<"admin="<<administrator()<<"\n";
 if(FAILED(CoInitializeEx(nullptr,COINIT_APARTMENTTHREADED)))return 3;
 Report report;fs::path root=normalizedPath(folder(FOLDERID_ProgramFiles)/L"LingheInput");std::wstring old;fs::path worker,directory;
 step("original-user-context",[&]{requireInteractiveUser();});
 if(!step("registered+validateOld",[&]{normalPath(root);old=registered();validateOld(old,root);}))return 1;
 if(!step("currentWorker",[&]{worker=currentWorker(root);}))return 1;
 if(!step("protectedRoot",[&]{directory=protectedRoot(root);}))return 1;
 for(const auto&entry:fs::directory_iterator(directory)){
  if(entry.path().extension()!=L".journal")continue;auto id=entry.path().stem().wstring();
  std::cout<<"journal "<<entry.path().filename().u8string()<<"\n";
  step("  transactionId",[&]{if(!journal_detail::transactionId(id))throw Failure(42);});
  step("  read+decode",[&]{NativeAdapter adapter(root,directory,id,report);auto j=decodeJournal(adapter.file->read());std::cout<<"     phase="<<int(j.phase)<<" target="<<j.targetVersion<<"\n";});
 }
 fs::path arp;InstalledVersion source,target;
 step("validateUninstallEntry",[&]{arp=validateUninstallEntry(root);if(arp.empty()||!samePath(arp.parent_path(),fs::path(old).parent_path().parent_path()))throw Failure(42,E_ACCESSDENIED);});
 step("verifiedVersion(source)",[&]{source=verifiedVersion(fs::path(old).parent_path().parent_path(),digest(ownExe()));});
 step("verifiedVersion(target)",[&]{target=verifiedVersion(worker.parent_path().parent_path(),digest(ownExe()));});
 step("ownerSid",[&]{(void)ownerSid();});
 Image before;bool captured=false;
 step("capture.registration",[&]{(void)encodeSnapshots(registration(),true);});
 step("capture.arp",[&]{(void)encodeSnapshots({Snapshot(HKEY_LOCAL_MACHINE,UninstallKey)},false);});
 step("capture.run",[&]{(void)runImage();});
 step("capture.link",[&]{(void)linkImage();});
 captured=step("capture",[&]{before=capture();});
 if(captured){
  auto targetDll=worker.parent_path()/L"PrivateInputTSF.dll";
  step("staleRunParse",[&]{auto run=decodeRun(before.slots[2]);if(!run)return;auto d=staleOwnedRunDirectory(*run,root,fs::path(old),targetDll);std::cout<<"     staleDir="<<(d?d->u8string():std::string("none"))<<"\n";if(d)(void)verifiedVersion(*d,digest(ownExe()));});
  step("desired",[&]{(void)desired(before,root,fs::path(old),targetDll);});
  step("beforeLink",[&]{auto l=decodeLink(before.slots[3]);if(l.exists)linkTarget(l.bytes,directory,{fs::path(old).parent_path()/L"LingheInputSettings.exe",worker.parent_path()/L"LingheInputSettings.exe"});});
  step("desiredLink",[&]{(void)desiredLink(before.slots[3],directory,worker.parent_path()/L"LingheInputSettings.exe");});
 }
 std::cout<<"done\n";return 0;
}
