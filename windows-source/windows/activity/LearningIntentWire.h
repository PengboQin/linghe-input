#pragma once
#include <array>
#include <cstdint>
#include <atomic>
#include <memory>
#include "CaptureWire.h"
#include "learning_capacity_profiles.h"
namespace private_input::activity {
inline constexpr wchar_t LearningIntentGateSuffix[]=L".intent-v1";
inline constexpr uint32_t LearningIntentGateMagic=0x31494c4c,LearningIntentAckMagic=0x31414c4c;
inline constexpr size_t LearningPublishedRowLimit=private_input::learning_capacity::expanded_10000.term_rows+1000;
enum class LearningIntentStatus:uint32_t {Applied=1,Pending=2,Duplicate=3,Stale=4,Quota=5,Retry=6,Invalid=7,Expired=8};
inline bool learningDurableAccepted(LearningIntentStatus s){return s==LearningIntentStatus::Applied||s==LearningIntentStatus::Pending||s==LearningIntentStatus::Duplicate;}
struct LearningCapability {std::array<unsigned char,16>token{};uint64_t generation=0;};
// Completion is process-local. Applied/Duplicate are local Worker ACKs, never
// cloud confirmation; Pending means only durable deferred acceptance.
struct LearningDelivery {std::atomic<LearningIntentStatus>status{LearningIntentStatus::Retry};std::atomic<bool>complete{false};void finish(LearningIntentStatus s){status=s;complete=true;}};
struct LearningIntentGate {volatile int32_t revision=0,enabled=0;uint32_t magic=LearningIntentGateMagic,version=1;std::array<unsigned char,16>token{};};
struct LearningIntentAck {uint32_t magic=LearningIntentAckMagic,version=1;std::array<unsigned char,16>event{};LearningIntentStatus status=LearningIntentStatus::Retry;uint32_t reserved=0;};
static_assert(sizeof(LearningIntentGate)==32&&sizeof(LearningIntentAck)==32,"versioned local learning capability and ACK ABI");
inline bool hasLearningIntentID(const std::array<unsigned char,16>&id){for(auto b:id)if(b)return true;return false;}
inline bool currentLearningSourceHeader(const CaptureHeader&h){return h.magic==CaptureMagic&&h.version==1&&h.scope==1&&(h.kind==3||h.kind==5||h.kind==6||h.kind==7||h.kind==12)&&hasLearningIntentID(h.session)&&hasLearningIntentID(h.editor);}
inline bool currentLearningIntentHeader(const CaptureHeader&h){return currentLearningSourceHeader(h)&&(h.kind==3||h.kind==12);}
inline bool validLearningIntentAck(const LearningIntentAck&a,const std::array<unsigned char,16>&event){return a.magic==LearningIntentAckMagic&&a.version==1&&a.event==event&&a.reserved==0&&uint32_t(a.status)>=1&&uint32_t(a.status)<=8;}
}
