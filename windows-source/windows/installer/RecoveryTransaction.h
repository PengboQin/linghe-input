#pragma once
// Installer-only transaction algorithm. The explicit Setup --repair adapter supplies
// protected Win32 persistence and ownership checks; this header performs no I/O.
#include <array>
#include <cstddef>
#include <stdexcept>
#include <string>

namespace linghe::installer::recovery {
enum class Slot : std::size_t { Registration, Arp, OwnedRunValue, OwnedShortcut, Count };
enum class Phase { Prepared, Applying, RollingBack, Committed, RolledBack, RecoveryRequired };
struct Image {
 // Opaque bounded snapshots of ONLY product-owned state. The adapter binds each
 // slot to fixed keys/value/link and original user SID; never a journal pathname.
 std::array<std::string, static_cast<std::size_t>(Slot::Count)> slots;
};
struct Journal {
 unsigned schema=1;
 std::string transaction, ownerSid, sourceSetupHash, targetSetupHash, targetVersion;
 Image before, desired;
 Phase phase=Phase::Prepared;
 unsigned intent=0; // Write-ahead step, including the step that might have crashed.
};
struct Adapter {
 virtual ~Adapter()=default;
 // Must verify exact setup pins, inert embedded manifest, ALL payload files,
 // fixed CLSID, no reparse/links, same user SID/session and unique healthy normal
 // target worker (PID + creation time + image hash). Do not stop/start workers.
 virtual void preflight(const Journal&)=0;
 // Capture/desired are built by the trusted adapter, never supplied by CLI JSON.
 // Store must atomically replace and FlushFileBuffers a protected, size-bounded
 // journal; persist intent BEFORE each side effect. No user-writable journal.
 virtual void store(const Journal&)=0;
 // Compare-and-swap ONLY this slot against the captured/previously-owned state;
 // fail on unrelated external edits rather than overwriting them.
 virtual void apply(Slot,const Image&)=0;
 virtual bool matches(const Image&)=0;
 // Includes live ownership fences against concurrent changes to this product.
 // Restores the complete TSF-owned registry/category + API state for Registration.
 virtual void restore(Slot,const Image&)=0;
};
struct Result { bool committed=false, restored=false, retryRequired=false; };

inline Result rollback(Journal& j,Adapter& a) {
 j.phase=Phase::RollingBack;
 try { a.store(j); } catch(...) {
  // Existing write-ahead journal still says Applying/Prepared. No further
  // mutation without durable recovery intent; a later invocation can retry.
  return {false,false,true};
 }
 bool restored=true;
 // Restore ALL slots, including the in-flight one. restore must be idempotent.
 for(std::size_t n=static_cast<std::size_t>(Slot::Count);n>0;--n) {
  try { a.restore(static_cast<Slot>(n-1),j.before); } catch(...) { restored=false; }
 }
 try { restored=a.matches(j.before)&&restored; } catch(...) { restored=false; }
 j.phase=restored?Phase::RolledBack:Phase::RecoveryRequired;
 try { a.store(j); } catch(...) { return {false,restored,true}; }
 return {false,restored,!restored};
}

inline Result execute(Journal& j,Adapter& a) {
 if(j.schema!=1||j.transaction.empty()||j.ownerSid.empty())
  throw std::runtime_error("invalid recovery journal identity");
 a.preflight(j); // Both live paths and journal contents revalidated every run.
 if(j.phase==Phase::Committed) {const bool ok=a.matches(j.desired);return {ok,false,!ok};}
 if(j.phase==Phase::RolledBack) {const bool ok=a.matches(j.before);return {false,ok,!ok};}
 if(j.phase!=Phase::Prepared) return rollback(j,a); // Crash: rollback, never guess forward.
 a.store(j); // No side effects if the initial protected snapshot cannot be saved.
 try {
  for(std::size_t n=0;n<static_cast<std::size_t>(Slot::Count);++n) {
   j.phase=Phase::Applying;j.intent=static_cast<unsigned>(n);
   a.store(j);
   a.apply(static_cast<Slot>(n),j.desired);
  }
  if(!a.matches(j.desired))throw std::runtime_error("recovery readback mismatch");
  // Full consistency includes ARP version/command, Run, link AND unique healthy
  // ordinary-user target worker. Unknown or duplicate workers block commit.
  a.preflight(j);
  j.phase=Phase::Committed;
  a.store(j); // Commit marker is part of success, never an afterthought receipt.
  return {true,false,false};
 }catch(...) { return rollback(j,a); }
}
} // namespace linghe::installer::recovery
