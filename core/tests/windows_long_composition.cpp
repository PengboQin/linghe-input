#include "private_input.h"
#include "pinyin_text.h"
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
static void require(bool ok,const char *message){if(!ok)throw std::runtime_error(message);}
static void type(PI_Session s,const std::string &input){for(unsigned char c:input)require(pi_process_key(s,c,0)!=0,"Typed key rejected");}
static size_t native(PI_Session s,const std::string &text){
 for(size_t offset=0;offset<1024;offset+=128){auto count=pi_load_candidate_batch(s,offset,128);for(size_t i=0;i<count;++i)if(text==pi_batch_candidate_text(s,i))return pi_batch_candidate_index(s,i);if(count<128)break;}
 throw std::runtime_error("Native candidate absent: "+text);
}
static bool repair(PI_Session s,const std::string &text){auto count=pi_load_repair_candidates(s,16);for(size_t i=0;i<count;++i)if(text==pi_repair_candidate_text(s,i))return true;return false;}
int main(int argc,char **argv){
 try{
  require(argc==3,"usage: windows_long_composition SHARED NEW_OWNED_USER");
  const auto shared=std::filesystem::absolute(argv[1]),user=std::filesystem::absolute(argv[2]);
  require(!std::filesystem::exists(user),"Fixture must not overwrite an existing user directory");std::filesystem::create_directories(user);
  require(pi_prepare_repair_resources(shared.string().c_str()),"Prepare immutable public resources before engine startup");
  require(pi_active_session_count()==0,"Public preload must not create an engine session");
  require(pi_initialize(shared.string().c_str(),user.string().c_str(),0),"Initialize");
  auto s=pi_create_session();require(s&&pi_set_private(s,1),"Private fixture session");
  const std::string input="wokankanzhegedaoshihounengyouduochang",sentence="我看看这个到时候能有多长";
  type(s,input);require(native(s,sentence)==0,"Full sentence must retain native first place");
  const std::string raw=pi_raw_input(s),preedit=pi_preedit(s);require(!repair(s,sentence),"Repair shadows full native sentence");
  pi_load_candidate_batch(s,128,128);require(!repair(s,sentence),"Deep batch changed native protection");
  require(raw==pi_raw_input(s)&&preedit==pi_preedit(s),"Probe mutated live composition");
  require(pi_select_candidate_absolute(s,native(s,sentence)),"Select full sentence");require(sentence==pi_take_commit(s),"Full sentence commit");require(!*pi_take_commit(s),"Full sentence replayed");
  type(s,input);std::string prefix;
  for(const auto &word:{"我看看","这个","到时候","能","有","多长"}){
   require(pi_select_candidate_absolute(s,native(s,word)),"Partial select");prefix+=word;
   if(prefix!=sentence){require(prefix==pi_selected_prefix(s),"Selected Chinese prefix lost");auto start=pi_unselected_input_start(s);require(start<input.size(),"Active ASCII tail absent");
    const auto before=std::string(pi_raw_input(s));pi_load_repair_candidates(s,16);require(before==pi_raw_input(s)&&prefix==pi_selected_prefix(s),"Repair changed selected prefix");
    std::cout<<"prefix="<<prefix<<" tail="<<input.substr(start)<<"\n";
   }
  }
  require(sentence==pi_take_commit(s),"Partial selections did not commit entire sentence");require(!*pi_take_commit(s),"Partial commit replayed");
  for(const std::string end:{"d","sh"}){
   pi_clear(s);type(s,"wokankanzhege"+end);require(pi_select_candidate_absolute(s,native(s,"我看看")),"Prefix before unfinished tail");
   require(!repair(s,"这个"),"Same-text repair dropped unfinished next syllable");
   require(pi_select_candidate_absolute(s,native(s,"这个")),"Native selection before unfinished tail");
   auto start=pi_unselected_input_start(s);const std::string current=pi_raw_input(s);require(start<current.size()&&current.substr(start)==end,"Unfinished tail lost");
   type(s,end=="d"?"aoshihounengyouduochang":"ihou");require(native(s,end=="d"?"到时候能有多长":"时候")!=SIZE_MAX,"Continuation after partial selection failed");
  }
  pi_clear(s);type(s,"shijei");pi_load_candidate_batch(s,0,128);require(repair(s,"世界"),"Genuine transposition repair suppressed");
  pi_clear(s);type(s,"haoo");pi_load_candidate_batch(s,0,128);require(repair(s,"好"),"Extra complete vowel repair suppressed");
  for(const auto &item:{std::pair<const char *,const char *>{"linaxaing","联想"},{"zhongguoo","中国"}}){pi_clear(s);type(s,item.first);pi_load_candidate_batch(s,0,128);require(repair(s,item.second),"Existing typo correction regressed");}
  pi_clear(s);type(s,"shenm");require(native(s,"什么")!=SIZE_MAX,"Valid unfinished full/native syllable lost");require(!repair(s,"什么"),"Unnecessary repair shadowed valid native completion");
  pi_clear(s);type(s,"nihao");pi_load_candidate_batch(s,128,128);require(!repair(s,"你好"),"Deep batch allowed a repair to shadow exact native choice");require(native(s,"你好")==0,"Fallback changed exact native first choice");
  pi_clear(s);type(s,"nihaoo");require(pi_select_candidate_absolute(s,native(s,"你")),"Repair prefix fixture");
  require(repair(s,"好"),"Selected-prefix repair absent");auto count=pi_load_repair_candidates(s,16);size_t chosen=SIZE_MAX;for(size_t i=0;i<count;++i)if(std::string(pi_repair_candidate_text(s,i))=="好")chosen=i;
  require(std::string(pi_commit_repair_candidate(s,chosen))=="你好","Repair replaced already selected Chinese");require(!*pi_preedit(s)&&!*pi_take_commit(s),"Repair left duplicate pending commit");
  pi_destroy_session(s);pi_finalize();std::cout<<"PASS native long sentence, 6 partial choices, d/sh continuation, shijei/haoo corrections, exactly-once prefix repair\n";return 0;
 }catch(const std::exception &e){pi_finalize();std::cerr<<"FAIL "<<e.what()<<"\n";return 1;}
}
