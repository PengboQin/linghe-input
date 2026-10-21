#pragma once
#include "ContentModel.h"
#include <optional>
namespace private_input::activity {
Json emptyRecent();Json validateRecent(const Json&);Json recentProjection(const Json&);Json mergeRecent(const Json&,const Json&,uint64_t referenceDay);Json mergeLegacyRecent(const Json&,const Json&,uint64_t referenceDay);
Json confirmRecentDelta(const Json&,const Json&before,const Json&after,const std::string&device,uint64_t referenceDay,std::optional<uint64_t>trustedDay);
double recentScore(const Json&entry,std::optional<uint64_t>referenceDay);
}
