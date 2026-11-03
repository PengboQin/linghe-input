#pragma once
#include "Json.h"
#include <algorithm>
namespace private_input::activity {
// Read-only presentation of the existing local learning archive, not cloud weights.
inline Json learnedVocabularyView(const Json&archive){
 std::vector<Json>rows;
 for(const auto&e:archive.at("entries").items){
  if(e.at("deleted").boolean())continue;
  uint64_t count=0;for(const auto&part:e.at("counts").fields){auto n=part.second.num();count+=std::min(n,uint64_t(1000000000)-count);}
  const bool pinned=e.at("pinned").boolean();if(!count&&!pinned)continue;
  rows.push_back(Json::object({{"text",e.at("text")},{"reading",e.at("reading")},{"frequency",count},{"pinned",pinned}}));
 }
 std::sort(rows.begin(),rows.end(),[](const Json&a,const Json&b){
  if(a.at("frequency").num()!=b.at("frequency").num())return a.at("frequency").num()>b.at("frequency").num();
  if(a.at("text").str()!=b.at("text").str())return a.at("text").str()<b.at("text").str();
  return a.at("reading").str()<b.at("reading").str();
 });return Json::array(std::move(rows));
}
}
