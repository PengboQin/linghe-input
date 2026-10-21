#include "private_input.h"
#include "private_pinyin_syllables.h"
#include <filesystem>
#include <iostream>
#include <stdexcept>
#include <string>
void require(bool value, const char *message) { if (!value) throw std::runtime_error(message); }
void type(PI_Session s, const std::string &text) { for (char c : text) require(pi_process_key(s,c,0),"Key not handled"); }
void filter(PI_Session s, const std::string &wanted) {
  const auto count = pi_nine_syllable_count(s);
  for (size_t i=0;i<count;++i) if (wanted==pi_nine_syllable_text(s,i)) { require(pi_nine_select_syllable(s,i),"Syllable selection"); require(std::string(pi_take_commit(s)).empty(),"Filter committed host text"); return; }
  throw std::runtime_error("Missing real syllable option: "+wanted);
}
void choose(PI_Session s,const std::string &wanted) {
  const auto count = pi_load_candidate_batch(s,0,128);
  for (size_t i=0;i<count;++i) if (wanted==pi_batch_candidate_text(s,i)) { require(pi_select_candidate_absolute(s,pi_batch_candidate_index(s,i)),"Candidate select"); return; }
  throw std::runtime_error("Missing candidate: "+wanted);
}
int main(int argc,char **argv) {
 try {
  require(argc==3 || argc==4,"Usage: nine_filter_smoke RESOURCES FRESH_DATA [NO_DEPLOY]"); require(!std::filesystem::exists(argv[2]),"Synthetic directory must be new"); std::filesystem::create_directories(argv[2]);
  require(pi_initialize(argv[1],argv[2],argc==3),"Initialize"); auto s=pi_create_session(); require(s && pi_set_nine_key(s,1),"Nine schema");
  type(s,"782636874472666"); // quan dou shi pao mo
  filter(s,"quan");
  std::cout << "AFTER_QUAN:";
  const auto options=pi_nine_syllable_count(s);
  for(size_t i=0;i<options;++i) std::cout << " " << pi_nine_syllable_text(s,i);
  std::cout << std::endl;
  filter(s,"fou");
  require(std::string(pi_raw_input(s))=="quan'fou'74472666","Alternative reading lost original tail");
  require(pi_process_key(s,0xff08,0),"Undo alternate syllable");
  require(std::string(pi_raw_input(s))=="quan'36874472666","Undo did not restore ambiguous spelling");
  filter(s,"dou"); filter(s,"shi"); filter(s,"pao"); filter(s,"mo");
  require(std::string(pi_raw_input(s))=="quan'dou'shi'pao'mo'","Consecutive complete filters changed spelling");
  size_t verified=0;
  const std::string mapping="22233344455566677778889999";
  for(const auto *syllable:private_input::pinyin_syllables) {
    std::string code; for(char c:std::string(syllable)) code+=mapping[c-'a'];
    pi_clear(s); type(s,"7826"+code+"74472666"); filter(s,"quan");
    filter(s,syllable);
    require(std::string(pi_raw_input(s))=="quan'"+std::string(syllable)+"'74472666","Full inventory filter consumed wrong tail");
    require(pi_nine_undo_syllable(s),"Inventory filter undo");
    require(std::string(pi_raw_input(s))=="quan'"+code+"74472666","Inventory undo changed input");
    ++verified;
  }
  std::cout << "Complete syllables verified after quan: " << verified << std::endl;
  pi_clear(s);
  type(s,"9663694243946474924542694");
  auto unstable=std::string(pi_nine_display_preedit(s,"wo"));
  require(unstable.find("wxyz")==std::string::npos && unstable.find("mno")==std::string::npos,"Unresolved draft expanded into every ambiguous key group");
  require(std::string(pi_raw_input(s))=="9663694243946474924542694","Display mutated draft");
  pi_clear(s);
  type(s,"6"); require(std::string(pi_nine_display_preedit(s,"ni hao"))=="n","Display invented untyped completion");
  type(s,"4426"); require(std::string(pi_nine_display_preedit(s,"ni hao"))=="ni hao","Numeric draft not displayed as pinyin");
  require(std::string(pi_raw_input(s))=="64426" && std::string(pi_take_commit(s)).empty(),"Display changed raw input or committed");
  filter(s,"mi"); require(std::string(pi_raw_input(s))=="mi'426","Filter lost remaining digits");
  require(std::string(pi_nine_display_preedit(s,"mi gao"))=="mi gao","Display did not follow selected reading");
  auto n=pi_load_candidate_batch(s,0,96); require(n>0,"No narrowed candidates");
  for(size_t i=0;i<n;++i) require(std::string(pi_batch_candidate_comment(s,i)).find("ni")==std::string::npos,"Other reading leaked into filtered candidates");
  require(pi_nine_undo_syllable(s),"Undo"); require(std::string(pi_raw_input(s))=="64426","Undo changed original draft");
  filter(s,"ni"); type(s,"744543"); require(pi_nine_undo_syllable(s),"Undo after extra input"); require(std::string(pi_raw_input(s))=="64426744543","Undo dropped appended input");
  filter(s,"ni"); filter(s,"hao"); require(std::string(pi_raw_input(s))=="ni'hao'744543","Consecutive filtering lost tail");
  choose(s,"你好"); require(std::string(pi_take_commit(s)).empty(),"Partial word prematurely committed");
  require(std::string(pi_nine_display_preedit(s,"shi jie"))=="你好 shi jie","Display lost confirmed Chinese prefix");
  filter(s,"shi"); require(std::string(pi_raw_input(s))=="ni'hao'shi'543","Partial selection filter lost raw spelling");
  require(pi_process_key(s,0xff08,0),"Backspace"); require(std::string(pi_raw_input(s))=="ni'hao'744543","Backspace did not undo latest syllable filter");
  require(pi_process_key(s,0xff08,0),"Delete after filter undo");
  require(std::string(pi_raw_input(s))=="ni'hao'74454","Delete after undo did not edit tail");
  require(std::string(pi_preedit(s)).find("你好")==0,"Backspace withdrew confirmed word");
  type(s,"3"); choose(s,"世界"); require(std::string(pi_take_commit(s))=="你好世界","Final partial selection commit changed text");
  require(std::string(pi_take_commit(s)).empty(),"Commit replay"); require(!pi_nine_can_undo_syllable(s) && pi_nine_syllable_count(s)==0,"Stale filter state after commit");
  require(pi_set_private(s,1),"Private schema"); type(s,"64426"); filter(s,"ni"); choose(s,"你好"); require(std::string(pi_take_commit(s))=="你好","Private schema filtering failed");
  pi_destroy_session(s); pi_finalize(); std::cout<<"PASS: true syllable narrowing, no early commit, retained tail, undo with appended input, partial selection, backspace, exact commit, private schema\n";
 } catch(const std::exception&e) {std::cerr<<e.what()<<'\n';return 1;}
}
