#pragma once
#include "ArchiveCore.h"
namespace private_input::activity {
std::vector<Json> materializePersonal(const Json&);
Json emptyLearning();Json validateLearning(const Json&);Json mergeLearning(const Json&,const Json&);
Json recordLearning(const Json&,const std::string&reading,const std::string&text,const std::string&device);
Json encodeContentEnvelope(const protocol::Envelope&);protocol::Envelope decodeContentEnvelope(const Json&);
}
