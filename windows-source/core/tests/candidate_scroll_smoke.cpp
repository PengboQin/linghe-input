#include "private_input.h"
#include <filesystem>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>
void require(bool value, const char *message) { if (!value) throw std::runtime_error(message); }
void type(PI_Session s, const std::string &text) { for (char c : text) require(pi_process_key(s,c,0),"Key not handled"); }
int main(int argc,char **argv) {
 try {
  require(argc==3,"Usage: candidate_scroll_smoke RESOURCES FRESH_DATA"); require(!std::filesystem::exists(argv[2]),"Synthetic directory must be new"); std::filesystem::create_directories(argv[2]);
  require(pi_initialize(argv[1],argv[2],0),"Initialize"); auto s=pi_create_session(); require(s,"Session"); type(s,"shi");
  auto n=pi_load_candidate_batch(s,0,12); require(n==12,"List must include more than the current seven-candidate page");
  require(pi_page_number(s)==0 && std::string(pi_raw_input(s))=="shi","Reading a list changed page or draft");
  auto m=pi_load_candidate_batch(s,n,24); require(m==24,"Continuation missing");
  const auto index=pi_batch_candidate_index(s,0); const std::string text=pi_batch_candidate_text(s,0);
  require(index>=12,"Absolute index missing"); require(pi_select_candidate_absolute(s,index),"Absolute selection"); require(std::string(pi_take_commit(s))==text,"Beyond-page click must commit the exact displayed candidate"); require(std::string(pi_take_commit(s)).empty(),"Commit repeated");
  require(pi_load_candidate_batch(s,0,12)==0,"Committed composition retained stale candidates");
  require(pi_set_nine_key(s,1),"Nine schema"); type(s,"64426"); n=pi_load_candidate_batch(s,0,64); bool found=false;
  for(size_t i=0;i<n;++i) if(std::string(pi_batch_candidate_text(s,i))=="你好") { require(pi_select_candidate_absolute(s,pi_batch_candidate_index(s,i)),"Nine choose"); found=true; break; }
  require(found && std::string(pi_take_commit(s))=="你好","Nine list commit");
  pi_destroy_session(s); pi_finalize(); std::cout<<"PASS: lazy continuation, unchanged draft/page, exact absolute selection past page one, no replay, fresh nine-key list\n";
 } catch(const std::exception&e) {std::cerr<<e.what()<<'\n';return 1;}
}
