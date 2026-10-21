#pragma once
#include <atomic>
#include <cstdint>
namespace private_input::activity {
// A clipboard sequence is not proof that its data was readable. Only the UI
// clipboard observer publishes success; network passes cannot age a denial out.
// No text, source identity, keys, mutexes or persisted user state are held here.
class ClipboardReadSafety {
 std::atomic<uint64_t>accepted{0},deniedSequence{0};
 static uint64_t token(uint32_t sequence,uint64_t generation){return generation&&generation<=UINT32_MAX?(generation<<32)|sequence:0;}
public:
 enum class Observation {metadataBaseline,stableText,verifiedEmpty,denied};
 void invalidate(uint64_t generation=0){accepted.store(0);auto denied=deniedSequence.load();if(denied&&generation&&generation<=UINT32_MAX&&generation>=(denied>>32)){auto promoted=token(uint32_t(denied),generation);deniedSequence.compare_exchange_strong(denied,promoted);}}
 void begin(){invalidate();}
 bool observe(uint32_t start,uint32_t finish,uint64_t generation,uint64_t currentGeneration,Observation outcome){
  if(start!=finish||generation!=currentGeneration||!token(start,generation))return false;
  if(outcome==Observation::denied){accepted.store(0);deniedSequence.store(token(start,generation));return false;}
  if(outcome==Observation::metadataBaseline&&blocked(start)){accepted.store(0);return false;}
  // Metadata alone never washes an existing same-sequence read failure away.
  if(outcome==Observation::stableText||outcome==Observation::verifiedEmpty){auto denied=deniedSequence.load();if(denied&&uint32_t(denied)==start){if((denied>>32)>generation||!deniedSequence.compare_exchange_strong(denied,0))return false;}}
  accepted.store(token(start,generation));return true;
 }
 bool allows(uint32_t sequence,uint64_t generation)const{auto expected=token(sequence,generation);return expected&&accepted.load()==expected&&!blocked(sequence);}
 bool blocked(uint32_t sequence)const{auto denied=deniedSequence.load();return denied&&uint32_t(denied)==sequence;}
};
}
