#pragma once
#include "ContentModel.h"
#include <optional>
namespace private_input::activity {
Json emptyRecent();Json validateRecent(const Json&);Json recentProjection(const Json&);Json mergeRecent(const Json&,const Json&,uint64_t referenceDay);Json mergeLegacyRecent(const Json&,const Json&,uint64_t referenceDay);
Json confirmRecentDelta(const Json&,const Json&before,const Json&after,const std::string&device,uint64_t referenceDay,std::optional<uint64_t>trustedDay);
struct RecentLocalDelta {std::string reading,text;uint64_t generation=0,from=0,to=0,day=0;};
std::optional<RecentLocalDelta> confirmedRecentLocalDelta(const Json&beforeWord,const Json&afterWord,const std::string&device,std::optional<uint64_t>trustedDay);
Json applyRecentLocalDeltas(const Json&recent,const Json&authoritative,const std::vector<RecentLocalDelta>&,const std::string&device,uint64_t referenceDay);
double recentScore(const Json&entry,std::optional<uint64_t>referenceDay);
}
