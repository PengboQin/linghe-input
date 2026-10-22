#pragma once
#include "ContentModel.h"
#include <functional>
namespace private_input::activity {
struct GroupIdentity;
// Shadow migration only. It never supplies ranking contributions, reads archive
// or clipboard bodies, or switches off the existing learning transports.
Json cloudLearningRequest(const Id&,const GroupIdentity&,uint8_t,const Json&,uint64_t);
bool cloudLearningTermEligible(const Json&);
std::string cloudComponentDigest(const std::string&,const Json&);
Json cloudOwnComponents(const Json&archive,const std::string&producer);
Json cloudMergeComponents(const Json&,const Json&,const std::string&producer);
void validateCloudStagedModel(const Json&);
Json cloudStageModel(const Json&previous,const Json&response,uint64_t generation);
struct CloudLearningShadow {
 Json state;std::function<void(const Json&)>persist;
 CloudLearningShadow(Json,std::function<void(const Json&)>);
 static Json initial(const std::string&scope);
 void save(const Json&);
 void synchronize(const Json&archive,const std::vector<std::string>&producers,
                  uint64_t generation,uint64_t consent,const std::string&installation,
                  const std::function<Json(uint8_t,const Json&)>&rpc);
};
}
