#include "LegacyLearning.h"
#include <sstream>
#include <set>
#include <algorithm>
namespace private_input::activity {
Json legacyLearningSeed(const std::string&nativeTSV,const std::string&replica){
 require(nativeTSV.size()<=CurrentLearningCapacity.native_tsv_bytes&&!replica.empty()&&replica.size()<=128,"legacy TSV bounds");validateUtf8(nativeTSV);
 auto result=emptyLearning();std::set<std::string>seen;std::istringstream input(nativeTSV);std::string line;
 while(std::getline(input,line)){
  if(!line.empty()&&line.back()=='\r')line.pop_back();if(line.empty()||line.front()=='#')continue;
  auto first=line.find('\t'),last=line.rfind('\t');require(first!=std::string::npos&&first!=last&&line.find('\t',first+1)==last,"legacy TSV columns");
  auto word=line.substr(0,first),reading=line.substr(first+1,last-first-1),number=line.substr(last+1);
  while(!reading.empty()&&reading.front()==' ')reading.erase(reading.begin());while(!reading.empty()&&reading.back()==' ')reading.pop_back();
  std::transform(reading.begin(),reading.end(),reading.begin(),[](unsigned char c){return c>='A'&&c<='Z'?c+32:c;});
  require(!number.empty()&&number.size()<=10&&number.find_first_not_of("0123456789")==std::string::npos,"legacy count format");
  auto count=std::stoull(number);require(count<=1000000000&&seen.insert(reading+char(31)+word).second,"legacy duplicate/count");
  auto entry=Json::object({{"reading",reading},{"text",word},{"generation",0},{"deleted",false},{"counts",Json::object({{replica,uint64_t(count)}})},{"pinned",false},{"pinVersion",Json::object({{"sequence",0},{"device",""}})}});
  if(count==0){
   // Zero native rows are not learned words, but must pass the same character,
   // field and replica validation as retained rows before being discarded.
   auto zero=emptyLearning();zero["entries"].items.push_back(std::move(entry));validateLearning(zero);continue;
  }
  result["entries"].items.push_back(std::move(entry));require(result.at("entries").items.size()<=CurrentLearningCapacity.native_positive_rows,"legacy learning capacity");
 }
 return validateLearning(result);
}
}
