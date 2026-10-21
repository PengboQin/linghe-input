#include "../sync/DeviceIdentity.h"
#include <algorithm>
#include <fstream>
#include <iostream>
#include <thread>
#include <chrono>
#include <vector>
#include <set>
using namespace private_input;
void require(bool value,const char* message){if(!value)throw std::runtime_error(message);}
std::vector<unsigned char> bytes(const std::filesystem::path& p){std::ifstream file(p,std::ios::binary);return {std::istreambuf_iterator<char>(file),{}};}
DeviceIdentity reserve(DeviceIdentityVault& vault){
 for(int attempt=0;attempt<2000;++attempt){try{return vault.reserveSequence();}catch(const IdentityError& error){if(error.code!=ERROR_LOCK_VIOLATION)throw;std::this_thread::sleep_for(std::chrono::milliseconds(5));}}
 throw std::runtime_error("Owned sequence lock remained busy");
}
int wmain(int argc,wchar_t** argv){
 try{
  require(argc==4&&std::wstring(argv[3])==L"--synthetic-fixture","Own synthetic fixture required");
  const std::wstring action=argv[1];const std::filesystem::path root=argv[2];DeviceIdentityVault vault(root);
  if(action==L"init"){
   bool absent=false;try{vault.load();}catch(const IdentityError&){absent=true;}require(absent,"Existing identity preserved, init rejected");
   auto identity=vault.create();require(identity.reservedSequence==0&&identity.device!=identity.owner,"Independent identities unavailable");
   auto loaded=vault.load();require(loaded.device==identity.device&&loaded.signingSeed==identity.signingSeed&&loaded.ownerSeed==identity.ownerSeed,"DPAPI reopen identity mismatch");
   const auto encrypted=bytes(root/L"identity.dpapi");
   for(const auto* secret:{&identity.signingSeed,&identity.ownerSeed,&identity.exchangeSecret,&identity.storageKey}){
    require(std::search(encrypted.begin(),encrypted.end(),secret->begin(),secret->end())==encrypted.end(),"Fixture file contains a plaintext private key");
   }
   auto one=reserve(vault),two=reserve(vault);require(one.reservedSequence==1&&two.reservedSequence==2,"Persistent sequence reservation failed");
   bool duplicate=false;try{vault.create();}catch(const IdentityError&){duplicate=true;}require(duplicate,"Existing identity regenerated");
   std::cout<<"{\"initialSequence\":2,\"dpapiReopen\":true,\"noPlaintextSeeds\":true,\"duplicateCreateRejected\":true}\n";
  }else if(action==L"supervise"){
   // Native process harness: no PowerShell execution-policy changes or script.
   auto before=vault.load().reservedSequence;wchar_t binary[32768]{};
   require(GetModuleFileNameW(nullptr,binary,32768)>0,"Own executable path unavailable");
   struct Child {HANDLE process;HANDLE read;};std::vector<Child> children;
   for(int i=0;i<32;++i){
    SECURITY_ATTRIBUTES security{sizeof(security),nullptr,TRUE};HANDLE read=nullptr,write=nullptr;
    require(CreatePipe(&read,&write,&security,0),"Owned output pipe failed");SetHandleInformation(read,HANDLE_FLAG_INHERIT,0);
    STARTUPINFOW startup{};startup.cb=sizeof(startup);startup.dwFlags=STARTF_USESTDHANDLES;startup.hStdOutput=write;startup.hStdError=write;
    PROCESS_INFORMATION process{};std::wstring command=L"\""+std::wstring(binary)+L"\" reserve \""+root.wstring()+L"\" --synthetic-fixture";
    bool started=CreateProcessW(binary,command.data(),nullptr,nullptr,TRUE,CREATE_NO_WINDOW,nullptr,nullptr,&startup,&process)!=FALSE;
    CloseHandle(write);if(!started){CloseHandle(read);throw std::runtime_error("Owned child launch failed");}
    CloseHandle(process.hThread);children.push_back({process.hProcess,read});
   }
   std::set<uint64_t> sequences;
   for(auto child:children){
    require(WaitForSingleObject(child.process,20000)==WAIT_OBJECT_0,"Owned reservation exceeded deadline");DWORD code=1;GetExitCodeProcess(child.process,&code);
    char buffer[256];DWORD size=0;std::string output;while(ReadFile(child.read,buffer,sizeof(buffer),&size,nullptr)&&size){output.append(buffer,size);require(output.size()<4096,"Owned output unexpectedly large");}
    CloseHandle(child.read);CloseHandle(child.process);require(code==0,"Owned child reservation failed");
    const std::string prefix="{\"sequence\":";require(output.find(prefix)==0,"Owned output malformed");sequences.insert(std::stoull(output.substr(prefix.size())));
   }
   auto after=vault.load().reservedSequence;require(sequences.size()==32&&after==before+32,"Cross-process sequence collision");
   std::cout<<"{\"processes\":32,\"uniqueSequences\":32,\"before\":"<<before<<",\"after\":"<<after<<",\"uiChanged\":false}\n";
  }else if(action==L"reserve"){
   auto identity=reserve(vault);std::cout<<"{\"sequence\":"<<identity.reservedSequence<<"}\n";
  }else if(action==L"load"){
   auto identity=vault.load();std::cout<<"{\"reservedSequence\":"<<identity.reservedSequence<<"}\n";
  }else if(action==L"corrupt"){
   auto original=bytes(root/L"identity.dpapi");require(!original.empty(),"No own fixture to corrupt");auto bad=original;bad[bad.size()/2]^=64;
   {std::ofstream stream(root/L"identity.dpapi",std::ios::binary|std::ios::trunc);stream.write(reinterpret_cast<const char*>(bad.data()),bad.size());}
   bool rejected=false;try{vault.load();}catch(const IdentityError&){rejected=true;}
   auto unchanged=bytes(root/L"identity.dpapi");require(rejected&&unchanged==bad,"Corrupt record reset or accepted");
   {std::ofstream stream(root/L"identity.dpapi",std::ios::binary|std::ios::trunc);stream.write(reinterpret_cast<const char*>(original.data()),original.size());}
   vault.load();std::cout<<"{\"corruptRejectedWithoutReset\":true,\"ownFixtureRestored\":true}\n";
  }else throw std::runtime_error("Unknown fixture action");return 0;
 }catch(const IdentityError& error){std::cerr<<"IdentityError: "<<error.what()<<" code="<<error.code<<"\n";return 1;}
 catch(const std::exception& error){std::cerr<<"FAIL: "<<error.what()<<"\n";return 1;}
}
