#pragma once
// Native preflight feeds verified current observations, never CLI-supplied paths.
// This policy performs no writes. A mixed installation needs an explicit repair.
namespace linghe::installer {
enum class UpgradeState { Ready, RegistrationArpMismatch, ArpVersionMismatch, WorkerMismatch, StartupMismatch };
inline UpgradeState upgradeState(bool registered,bool arp,bool arpMatches,
                                 bool worker,bool workerMatches,bool startup,bool startupMatches){
 if(registered!=arp)return UpgradeState::RegistrationArpMismatch;
 if(arp&&!arpMatches)return UpgradeState::ArpVersionMismatch;
 if(worker&&(!registered||!workerMatches))return UpgradeState::WorkerMismatch;
 if(startup&&(!registered||!startupMatches))return UpgradeState::StartupMismatch;
 return UpgradeState::Ready;
}
}
