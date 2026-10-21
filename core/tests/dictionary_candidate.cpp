#include "private_input.h"
#include <algorithm>
#include <chrono>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <sys/resource.h>
#include <vector>
namespace fs=std::filesystem;
using Clock=std::chrono::steady_clock;
void require(bool value,const char *message){if(!value)throw std::runtime_error(message);}
std::string read(const fs::path &p){std::ifstream f(p);return {std::istreambuf_iterator<char>(f),{}};}
struct Case {const char *reading;const char *word;};
const Case cases[]={{"nihao","你好"},{"shijie","世界"},{"shanghai","上海"},{"beijing","北京"},
  {"hangzhou","杭州"},{"chongqing","重庆"},{"zhongguo","中国"},{"zhongwen","中文"},
  {"shurufa","输入法"},{"jiantieban","剪贴板"},{"yinsi","隐私"},{"tongbu","同步"},
  {"shebei","设备"},{"shouji","手机"},{"diannao","电脑"},{"wangluo","网络"},
  {"wenjian","文件"},{"gongzuo","工作"},{"xuexi","学习"},{"lvxing","旅行"},
  {"gongsi","公司"},{"xiexie","谢谢"},{"zaijian","再见"},{"jintian","今天"},
  {"mingtian","明天"},{"qingtian","晴天"},{"anquan","安全"},{"kaifang","开放"},
  {"zhonghuarenmingongheguo","中华人民共和国"},{"jintiantianqihenhao","今天天气很好"},
  {"womende","我们的"},{"kaiyuanruanjian","开源软件"}};
int main(int argc,char **argv){
 try{
  require(argc==3,"dictionary_candidate SHARED NEW_OWNED_TEST_DIR");
  const fs::path shared=fs::absolute(argv[1]),user=fs::absolute(argv[2]);
  require(!fs::exists(user),"Existing data must be preserved");fs::create_directories(user);
  const auto started=Clock::now();require(pi_initialize(shared.string().c_str(),user.string().c_str(),0),"Initialize failed");
  auto session=pi_create_session();require(session,"Precompiled dictionary missing");
  const auto startup=std::chrono::duration<double,std::milli>(Clock::now()-started).count();
  std::vector<double> timings;int firstPage=0,found=0;
  std::cout<<"{\"newProcessStartupMs\":"<<startup<<",\"cases\":[";
  for(size_t n=0;n<std::size(cases);++n){
   pi_clear(session);for(unsigned char c:std::string(cases[n].reading)){
    auto t=Clock::now();pi_process_key(session,c,0);timings.push_back(std::chrono::duration<double,std::micro>(Clock::now()-t).count());
    require(std::string(pi_take_commit(session)).empty(),"Typing unexpectedly committed text");
   }
   int rank=-1;
   for(int page=0;page<10;++page){
    for(size_t i=0;i<pi_candidate_count(session);++i)if(cases[n].word==std::string(pi_candidate_text(session,i))){
     rank=page*7+int(i);require(pi_select_candidate(session,i),"Candidate selection failed");
     require(cases[n].word==std::string(pi_take_commit(session)),"Candidate committed another word");
     require(std::string(pi_take_commit(session)).empty(),"Commit replayed");break;
    }
    if(rank>=0||!pi_process_key(session,0xff56,0))break;
   }
   if(rank>=0)++found;if(rank>=0&&rank<7)++firstPage;
   std::cout<<(n?",":"")<<"{\"reading\":\""<<cases[n].reading<<"\",\"expected\":\""<<cases[n].word<<"\",\"rank\":"<<rank<<"}";
  }
  pi_clear(session);for(unsigned char c:std::string("shi"))pi_process_key(session,c,0);
  require(pi_page_number(session)==0&&pi_has_next_page(session),"Real dictionary pagination unavailable");
  require(pi_process_key(session,0xff56,0)&&pi_page_number(session)==1,"Next page failed");
  require(pi_process_key(session,0xff55,0)&&pi_page_number(session)==0,"Previous page failed");
  pi_clear(session);for(unsigned char c:std::string("nihao"))pi_process_key(session,c,0);
  require(std::string(pi_raw_input(session))=="nihao","Raw draft includes display formatting or lost letters");
  pi_clear(session);require(pi_set_ascii_mode(session,1),"English mode failed");
  require(!pi_process_key(session,'A',0)&&std::string(pi_take_commit(session)).empty(),"English must pass through to its host without a duplicate commit");
  require(pi_set_ascii_mode(session,0),"Chinese mode restore failed");pi_clear(session);
  // Repeated own phrases for stable key latency; no host document or network.
  for(int pass=0;pass<12;++pass)for(const auto &sample:cases){
   pi_clear(session);for(unsigned char c:std::string(sample.reading)){
    auto t=Clock::now();pi_process_key(session,c,0);timings.push_back(std::chrono::duration<double,std::micro>(Clock::now()-t).count());
    (void)pi_take_commit(session);
   }
  }
  pi_clear(session);pi_destroy_session(session);
  const auto before=user/"before.tsv",after=user/"after.tsv";
  require(pi_export_learning(before.string().c_str())>=0,"Export failed");
  session=pi_create_session();require(pi_set_private(session,1),"Private schema unavailable");
  for(unsigned char c:std::string("shanghai"))pi_process_key(session,c,0);
  require(pi_select_candidate(session,0),"Private selection failed");(void)pi_take_commit(session);pi_destroy_session(session);
  require(pi_export_learning(after.string().c_str())>=0&&read(before)==read(after),"Private mode changed learning");
  std::sort(timings.begin(),timings.end());struct rusage usage{};getrusage(RUSAGE_SELF,&usage);
  std::cout<<"],\"found\":"<<found<<",\"firstPage\":"<<firstPage<<",\"total\":"<<std::size(cases)
   <<",\"keySamples\":"<<timings.size()<<",\"p50KeyUs\":"<<timings[timings.size()/2]
   <<",\"p95KeyUs\":"<<timings[timings.size()*95/100]<<",\"p99KeyUs\":"<<timings[timings.size()*99/100]
   <<",\"peakRSSBytes\":"<<usage.ru_maxrss<<",\"noStartupDeployment\":true,\"privateLearningUnchanged\":true,\"rawDraftAndModeSwitch\":true,\"pagination\":true}\n";
  pi_finalize();return found==int(std::size(cases))?0:2;
 }catch(const std::exception &e){pi_finalize();std::cerr<<"FAIL: "<<e.what()<<"\n";return 1;}
}
