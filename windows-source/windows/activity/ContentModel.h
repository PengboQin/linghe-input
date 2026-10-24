#pragma once
#include "ArchiveCore.h"
#include "learning_capacity_profiles.h"
namespace private_input::activity {
struct LearningCapacityError:JsonError {using JsonError::JsonError;};
using LearningCapacity=private_input::learning_capacity::Profile;
inline constexpr const auto& LegacyLearningCapacity=private_input::learning_capacity::legacy_5000;
inline constexpr const auto& CurrentLearningCapacity=private_input::learning_capacity::expanded_10000;
const LearningCapacity& learningArchiveProfile(const Json&,const LearningCapacity& reader=CurrentLearningCapacity);
Json learningProfileMetadata(const LearningCapacity&);
Json reprofileLearning(const Json&,const LearningCapacity&);
std::vector<Json> materializePersonal(const Json&,const LearningCapacity& reader=CurrentLearningCapacity);
Json emptyLearning(const LearningCapacity& profile=CurrentLearningCapacity);Json validateLearning(const Json&,const LearningCapacity& reader=CurrentLearningCapacity);Json mergeLearning(const Json&,const Json&,const LearningCapacity& reader=CurrentLearningCapacity);
Json recordLearning(const Json&,const std::string&reading,const std::string&text,const std::string&device,const LearningCapacity& reader=CurrentLearningCapacity);
Json encodeContentEnvelope(const protocol::Envelope&);protocol::Envelope decodeContentEnvelope(const Json&);
}
