#pragma once
#include "ContentModel.h"
#include "LearningIntentWire.h"
namespace private_input::activity {
struct LearningOwner {std::string personal,device,installation;bool local=true;};
struct LearningIntent {Id event{},token{};uint64_t createdAt=0;std::string reading,text;unsigned action=3;};
struct LearningIntentResult {LearningIntentStatus status=LearningIntentStatus::Retry;bool archiveChanged=false;};
inline constexpr size_t LearningPendingRows=128,LearningPendingBytes=524288,LearningReceiptRows=1024,LearningReceiptBytes=262144;
inline constexpr uint64_t LearningAdmissionSeconds=30,LearningReceiptSeconds=120;
inline constexpr uint64_t LearningForgetAdmissionSeconds=300,LearningForgetReceiptSeconds=600;
}
