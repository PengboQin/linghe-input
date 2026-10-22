#include "../installer/FailureFeedback.h"
#include <cassert>
#include <cstdlib>
static unsigned checks=0;
#define CHECK(value) do{++checks;if(!(value))std::abort();}while(false)
#include <iostream>
int main(){using namespace linghe::installer;
 for(auto state:{UpgradeState::RegistrationArpMismatch,UpgradeState::ArpVersionMismatch,UpgradeState::WorkerMismatch,UpgradeState::StartupMismatch})CHECK(!upgradeReason("mixed-installation-"+std::to_string(static_cast<unsigned>(state))).empty());
 CHECK(upgradeReason("mixed-installation-99").empty());
 auto message=failureFeedback(42,"mixed-installation-"+std::to_string(static_cast<unsigned>(UpgradeState::StartupMismatch)),0x8007051a,false,L"C:\\Example\\last-install.json",true,L"C:\\Example\\Setup.exe");
 CHECK(message.find(L"0x8007051A")!=std::wstring::npos);CHECK(message.find(L"--repair")!=std::wstring::npos);CHECK(message.find(L"C:\\Example\\last-install.json")!=std::wstring::npos);
 CHECK(failureFeedback(42,"mixed-installation-4",0,false,L"x",false,L"setup").find(L"未能写入")!=std::wstring::npos);
 CHECK(failureFeedback(42,"repair-running-target",0,false,L"x",true,L"setup").find(L"--repair")==std::wstring::npos);
 CHECK(failureFeedback(42,"mixed-installation-4",0,true,L"x",true,L"setup").find(L"--repair")==std::wstring::npos);
 std::cout<<"PASS "<<checks<<" installer feedback assertions; pure presentation, no repair/registry/UI\n";
}
