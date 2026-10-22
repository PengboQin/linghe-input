#pragma once
#include "CloudLearningShadow.h"
namespace private_input::activity {
// Pure bounded projection: replaces legacy recent contribution for cloud eligible
// lexemes. Never mutates the native archive or reads files/network.
Json cloudRankProjection(const Json&shadow,const Json&native,const std::vector<std::string>&ownProducers);
}
