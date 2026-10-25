// Read-only native test: no registration, Run writes, process control or user data.
#define LINGHE_SETUP_LIBRARY 1
#include "../installer/Setup.cpp"
#include <iostream>
namespace {
unsigned checks=0;
void check(bool yes){if(!yes)throw std::runtime_error("stale Run fixture failed");++checks;}
std::wstring command(const fs::path&p){return L"\""+p.wstring()+L"\" --background";}
}
int wmain(int argc,wchar_t**argv){
 if(argc!=1&&argc!=2)return 2;
 try{
  const fs::path root=L"C:\\LingheInputFixture",same=root/L"versions/0.6.2-win1/AMD64/PrivateInputTSF.dll",other=root/L"versions/0.6.3-win1/AMD64/PrivateInputTSF.dll";
  const auto stale=(root/L"versions/0.4.2-win1/AMD64/LingheInputActivity.exe").make_preferred();
  auto parsed=repair_native::staleOwnedRunDirectory(command(stale),root,same,same);
  check(parsed&&samePath(*parsed,stale.parent_path().parent_path()));
  check(!repair_native::staleOwnedRunDirectory(command(stale),root,same,other));
  for(const auto&text:{command(L"C:\\outside\\0.4.2-win1\\AMD64\\LingheInputActivity.exe"),command(root/L"versions/0.4.2-win1/AMD64/not-this-app.exe"),command(root/L"versions/unknown/AMD64/LingheInputActivity.exe"),command(root/L"versions/0.4.2-win1/x86/LingheInputActivity.exe"),command(stale)+L" --extra",stale.wstring()+L" --background",command(stale)+L" ",L"\""+stale.wstring()+L"\" --settings",command(root/L"versions/0.4.2-win1/AMD64/../AMD64/LingheInputActivity.exe")})check(!repair_native::staleOwnedRunDirectory(text,root,same,same));
  // The native helper uses these unchanged production hash/manifest predicates.
  check(!linghe::installer::recognizedSetupHash(std::string(64,'0'),std::string(64,'a')));
  linghe::installer::PayloadEntry entry{std::string(64,'a'),"AMD64/LingheInputActivity.exe"};
  check(!linghe::installer::validOwnedPayload(entry,true,true,std::string(64,'b'),linghe::installer::PayloadPurpose::InstallOrRepair));
  check(!linghe::installer::validOwnedPayload(entry,false,false,"",linghe::installer::PayloadPurpose::InstallOrRepair));
  bool installedRead=false;size_t payloads=0,currentPayloads=0;
  if(argc==2){
   // The only optional live action is inert validation of the retained package.
   check(SUCCEEDED(CoInitializeEx(nullptr,COINIT_APARTMENTTHREADED)));
   requireInteractiveUser();
   fs::path installed=argv[1];auto current=normalizedPath(installed/L"versions/0.6.2-win1/AMD64/PrivateInputTSF.dll");auto historical=normalizedPath(installed/L"versions/0.4.2-win1/AMD64/LingheInputActivity.exe");
   check(samePath(repair_native::currentWorker(installed),current.parent_path()/L"LingheInputActivity.exe"));
   validateOld(current.wstring(),installed);check(samePath(validateUninstallEntry(installed),current.parent_path().parent_path()/L"LingheInputSetup.exe"));
   auto currentVerified=verifiedVersion(current.parent_path().parent_path(),digest(ownExe()));currentPayloads=currentVerified.files.size();check(currentPayloads>0);
   repair_native::requireVerifiedStaleRun(command(historical),installed,current,current);
   auto verified=verifiedVersion(historical.parent_path().parent_path(),digest(ownExe()));payloads=verified.files.size();check(payloads>0);installedRead=true;
   auto before=repair_native::capture();auto after=repair_native::desired(before,installed,current,current);auto planned=repair_native::decodeRun(after.slots[2]);check(planned&&*planned==command(current.parent_path()/L"LingheInputActivity.exe"));check(after.slots[0]==before.slots[0]&&after.slots[1]==before.slots[1]&&after.slots[3]==before.slots[3]);CoUninitialize();
  }
  std::cout<<"{\"passed\":true,\"checks\":"<<checks<<",\"historicalInstalledPayloadReadOnly\":"<<(installedRead?"true":"false")<<",\"payloadsVerified\":"<<payloads<<",\"currentPayloadsVerified\":"<<currentPayloads<<",\"fullDesiredReadOnly\":true,\"registryWritten\":false,\"processesChanged\":false,\"userDataRead\":false}\n";return 0;
 }catch(const Failure&f){std::cerr<<"validation failed code="<<f.code<<" hresult="<<unsigned(f.hr)<<'\n';return 1;}catch(const std::exception&e){std::cerr<<e.what()<<'\n';return 1;}
}
