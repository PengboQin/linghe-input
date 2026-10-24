#include "private_input.h"
#include <filesystem>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>
namespace fs=std::filesystem;
struct Row {std::string text,reading;size_t index;};
unsigned checks=0;
void ck(bool value,const char *reason){++checks;if(!value)throw std::runtime_error(reason);}
void type(PI_Session s,const std::string &text){for(unsigned char c:text)ck(pi_process_key(s,c,0),"native key");}
std::vector<Row> read(PI_Session s,size_t n){std::vector<Row>r;for(size_t i=0;i<n;++i)r.push_back({pi_batch_candidate_text(s,i),pi_batch_candidate_comment(s,i),pi_batch_candidate_index(s,i)});return r;}
std::vector<Row> bounded(PI_Session s,size_t offset,size_t count,size_t budget=1){
 for(size_t turns=0;turns<10000;++turns){
  auto n=pi_load_candidate_batch_bounded(s,offset,count,budget);ck(pi_candidate_batch_scanned(s)<=budget,"actual native per-call budget");
  if(!pi_candidate_batch_pending(s))return read(s,n);
 }
 throw std::runtime_error("actual native budget did not complete");
}
void same(const std::vector<Row>&a,const std::vector<Row>&b){ck(a.size()==b.size(),"native length unchanged");for(size_t i=0;i<a.size();++i)ck(a[i].text==b[i].text&&a[i].reading==b[i].reading&&a[i].index==b[i].index,"native text/readings/order/absolute ids unchanged");}
int main(int argc,char **argv){try{
 ck(argc==3,"usage resources fresh synthetic root");ck(!fs::exists(argv[2]),"fresh synthetic user");fs::create_directories(argv[2]);
 ck(pi_initialize(argv[1],argv[2],0),"native initialize");auto s=pi_create_session();ck(s,"native session");type(s,"shi");
 const auto legacy=read(s,pi_load_candidate_batch(s,0,36));ck(legacy.size()==36,"native stream beyond first page");
 pi_clear(s);type(s,"shi");same(legacy,bounded(s,0,36));
 auto first=bounded(s,0,12,0);ck(first.size()==12&&pi_candidate_batch_scanned(s)==0,"native cached zero budget reads no rows");
 const auto target=legacy[20];ck(pi_set_word_pinned(target.reading.c_str(),target.text.c_str(),1),"pin actual deep native candidate");
 const auto oldPinned=read(s,pi_load_candidate_batch(s,0,12));ck(oldPinned.front().text==target.text,"legacy native pin promoted");
 pi_clear(s);type(s,"shi");same(oldPinned,bounded(s,0,12));
 const auto displayed=read(s,pi_load_candidate_batch_bounded(s,0,12,0)).front();
 ck(pi_select_candidate_absolute(s,displayed.index),"actual native absolute selection");
 ck(std::string(pi_take_commit(s))==displayed.text,"actual native commit equals displayed row");
 ck(std::string(pi_take_commit(s)).empty(),"actual native commit consumed once");
 ck(!pi_candidate_batch_pending(s)&&pi_candidate_batch_scanned(s)==0,"native selection clears budget state");
 pi_clear(s);ck(pi_set_nine_key(s,1),"native nine mode");type(s,"647486742");
 const auto oldNine=read(s,pi_load_candidate_batch(s,0,24));ck(!oldNine.empty(),"native nine candidates");
 pi_clear(s);type(s,"647486742");same(oldNine,bounded(s,0,24));
 ck(pi_nine_remember_candidate_path(s,pi_raw_input(s),pi_selected_prefix(s),"ni shuo sha"),"verified native nine path seed");
 // Refresh the unchanged composition so both reads include the same path prepass.
 ck(pi_set_word_pinned("ni shuo sha","你说啥",1),"native nine pin refresh");
 const auto pathOld=read(s,pi_load_candidate_batch(s,0,24));
 pi_clear(s);type(s,"647486742");ck(pi_nine_remember_candidate_path(s,pi_raw_input(s),pi_selected_prefix(s),"ni shuo sha"),"native path fresh seed");
 same(pathOld,bounded(s,0,24));
 pi_destroy_session(s);pi_finalize();std::cout<<"PASS "<<checks<<" real Rime budget/legacy equivalence/deep-pin/absolute-commit assertions; synthetic user only\n";
 }catch(const std::exception&e){pi_finalize();std::cerr<<"FAIL "<<e.what()<<"\n";return 1;}}
