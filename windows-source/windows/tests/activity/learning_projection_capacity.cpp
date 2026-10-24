#include "../../activity/CloudLearningRank.h"
#include <sodium.h>
#include <algorithm>
#include <iostream>
using namespace private_input::activity;
namespace {
std::string hash(const Json&j){auto h=sha256(bytes(j.dump()));const char hex[]="0123456789abcdef";std::string result;for(auto c:h){result+=hex[c>>4];result+=hex[c&15];}return result;}
std::string reading(unsigned n){std::string value="a";for(unsigned i=0;i<4;++i){value+=char('a'+n%26);n/=26;}return value;}
}
int main(){try{
 require(sodium_init()>=0,"sodium");const auto producer=uuidText(newId());auto native=emptyLearning();
 // These valid long local terms cannot join the bounded cloud projection;
 // they must remain in localFallback, never disappear behind cloud rows.
 for(unsigned i=0;i<6000;++i)native["entries"].items.push_back(Json::object({{"reading",reading(i)},{"text",std::string(40,'x')},{"generation",0},{"deleted",false},{"counts",Json::object({{producer,1}})},{"pinned",i==5999},{"pinVersion",Json::object({{"sequence",0},{"device",""}})}}));
 validateLearning(native);const auto original=native.dump();auto records=recordLearning(emptyLearning(),reading(0),"合成",producer).at("entries");auto digest=cloudComponentDigest(producer,records);
 auto model=Json::object({{"version",1},{"generation",1},{"terms",Json::array()},{"tombstones",Json::array()},{"watermarks",Json::array()},{"producer_watermarks",Json::array({Json::object({{"producer_id",producer},{"producer_revision",1},{"component_digest",digest}})})}});
 for(unsigned i=0;i<5000;++i)model["terms"].items.push_back(Json::object({{"reading",reading(i)},{"text","合成"},{"layout","shared"},{"term_generation",0},{"weight",1},{"pinned",false}}));
 // Reading generation is least-significant first; the model requires key order.
 std::sort(model["terms"].items.begin(),model["terms"].items.end(),[](const Json&a,const Json&b){return a.at("reading").str()<b.at("reading").str();});
 auto seal=[&]{model["sha256"]=hash(Json::object({{"generation",model.at("generation")},{"algorithm_version","shared-lexeme-decay-v2"},{"upserts",model.at("terms")},{"watermarks",model.at("watermarks")},{"producer_watermarks",model.at("producer_watermarks")}}));model["fence_sha256"]=hash(model.at("tombstones"));};seal();
 auto shadow=Json::object({{"model",model},{"modelBaselines",Json::object({{producer,Json::object({{"revision",1},{"digest",digest},{"records",records}})}})}});
 bool refused=false;try{(void)cloudRankProjection(shadow,native,{producer});}catch(const JsonError&){refused=true;}
 require(refused,"cloud+local union above10000 must refuse instead of silently truncating mapping/personal rows");require(native.dump()==original,"projection must leave all6000 local rows/pin unchanged");
 model["terms"].items.resize(4000);seal();shadow["model"]=model;auto fits=cloudRankProjection(shadow,native,{producer});
 require(fits.at("rows").items.size()==4000&&fits.at("localFallback").items.size()==6000,"exact10000 union retains all cloud and local fallback terms");
 require(native.dump()==original,"exact-limit projection is immutable");
 std::cout<<"PASS 4 production projection union/immutability checks; synthetic6000local+5000cloud over-limit, exact10000 retained; no files/network/Windows\n";return 0;
}catch(const std::exception&e){std::cerr<<e.what()<<'\n';return 1;}}
