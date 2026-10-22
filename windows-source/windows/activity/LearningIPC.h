#pragma once
#include <windows.h>
#include <cstdint>
#include <cstring>
#include <string>
#include <map>
#include <vector>
#include <memory>
#include <mutex>
#include <condition_variable>
#include <thread>
#include <functional>
#include <set>
#include "../src/PublicContextModel.h"
namespace private_input::activity {
inline std::string canonicalLearningReading(std::string value){std::string result;for(unsigned char c:value){if(c>='A'&&c<='Z')c+=32;if(c=='\'')c=' ';if(c==' '){if(!result.empty()&&result.back()!=' ')result.push_back(' ');}else if(c>='a'&&c<='z')result.push_back(char(c));else return {};}if(!result.empty()&&result.back()==' ')result.pop_back();return result;}
constexpr size_t LearningRowLimit=6000;
struct LearningRow {char reading[193]{},text[2049]{};uint64_t frequency=0;double recent=-1;uint32_t pinned=0,kind=0;};
struct LearningMapping {volatile LONG revision=0,enabled=0;uint32_t version=1,count=0;uint64_t generation=0,updatedTick=0;LearningRow rows[LearningRowLimit];};
std::wstring learningName(const std::wstring&suffix={});
struct LearningSnapshot {bool cloudActive=false;uint64_t scopeGeneration=0;std::string cloudToken;std::shared_ptr<const LearningSnapshot>fallback;struct Score {uint64_t frequency=0;bool pinned=false;double recent=-1;};struct Learned{std::string reading,text;};std::set<std::string>explicitKeys;std::map<std::string,Score>scores;std::map<std::string,std::vector<Learned>>spelling;std::vector<LearningRow>personal;};
class LearningReader {
 std::function<void()>preparePublic,refreshSettings;std::filesystem::path publicPath;std::shared_ptr<const private_input::PublicContextModel>publicModel;
 std::shared_ptr<const LearningSnapshot>snapshot=std::make_shared<LearningSnapshot>();std::thread worker;std::mutex lock;std::condition_variable wake;bool stopping=false;void run();
public:
 ~LearningReader();void stop();void start(std::filesystem::path model={},std::function<void()>prepare={},std::function<void()>settings={});std::shared_ptr<const private_input::PublicContextModel>model()const{return std::atomic_load(&publicModel);}std::shared_ptr<const LearningSnapshot>read()const{return std::atomic_load(&snapshot);}
};
}
