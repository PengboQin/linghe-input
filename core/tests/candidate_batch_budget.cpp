// White-box deterministic iterator fixture: production loader, no runtime or
// app/user files. The separate native fixture verifies real Rime selection.
#include "../src/private_input.cpp"
#include "fixtures/legacy_candidate_batch_20261023.inc"
#include <iostream>
#include <stdexcept>
namespace fixture {
std::vector<StreamCandidate> rows;
std::string raw="shi",committed;
size_t visited=0;
RimeApi fake{};
unsigned checks=0;
void ck(bool value,const char *reason) {++checks;if(!value)throw std::runtime_error(reason);}
Bool from(RimeSessionId,RimeCandidateListIterator *it,int offset) {
  if(offset<0 || static_cast<size_t>(offset)>=rows.size())return False;
  it->index=offset-1;it->ptr=reinterpret_cast<void*>(static_cast<uintptr_t>(offset)+1);return True;
}
Bool begin(RimeSessionId id,RimeCandidateListIterator *it) {return from(id,it,0);}
Bool next(RimeCandidateListIterator *it) {
  const auto at=reinterpret_cast<uintptr_t>(it->ptr)-1;
  if(at>=rows.size())return False;
  it->index=static_cast<int>(at);it->candidate.text=const_cast<char*>(rows[at].text.c_str());
  it->candidate.comment=const_cast<char*>(rows[at].comment.c_str());
  it->ptr=reinterpret_cast<void*>(at+2);++visited;return True;
}
void end(RimeCandidateListIterator*){}
void reset(bool nine=false,bool path=false) {
 sessions.clear();preferences.clear();pinned_words.clear();raw=nine ? "647486742":"shi";committed.clear();visited=0;
 Snapshot s;s.input=raw;s.active_reading=raw;s.nine_key=nine;
 if(path){s.path.reading="ni shuo sha";s.path.input=raw;s.path_prefix="";s.path_active=true;}
 sessions.emplace(1,std::move(s));api=&fake;
}
using Choices=std::vector<StreamCandidate>;
Choices output(size_t count) {
 Choices result;for(size_t i=0;i<count;++i)result.push_back({pi_batch_candidate_text(1,i),pi_batch_candidate_comment(1,i),pi_batch_candidate_index(1,i)});return result;
}
void same(const Choices&a,const Choices&b) {
 ck(a.size()==b.size(),"equal output length");for(size_t i=0;i<a.size();++i)
 ck(a[i].text==b[i].text && a[i].comment==b[i].comment && a[i].index==b[i].index,"same ranking, text, reading and absolute index as original loader");
}
Choices drain(size_t offset,size_t count,size_t budget) {
 for(size_t turns=0;turns<10000;++turns) {
  const auto before=visited,n=pi_load_candidate_batch_bounded(1,offset,count,budget);
  ck(pi_candidate_batch_scanned(1)<=budget,"scan budget respected");
  ck(pi_candidate_batch_scanned(1)==visited-before,"actual iterator rows counted across all phases");
  if(!pi_candidate_batch_pending(1))return output(n);
  ck(pi_candidate_batch_scanned(1)>0,"positive-budget pending call makes scan progress");
  if(!sessions.at(1).ranked_ready)ck(n==0,"pin/path preparation never publishes partial head");
 }
 throw std::runtime_error("no progress bound");
}
void configurePins(int kind) {
 if(kind==1 || kind==3)pinned_words.emplace("shi","pin-late");
 if(kind==2 || kind==3)pinned_words.emplace("shi","pin-absent");
}
int run() {
 fake.candidate_list_begin=begin;fake.candidate_list_from_index=from;fake.candidate_list_next=next;fake.candidate_list_end=end;
 fake.get_input=[](RimeSessionId)->const char*{return raw.c_str();};fake.get_caret_pos=[](RimeSessionId){return raw.size();};
 fake.get_context=[](RimeSessionId,RimeContext*)->Bool{return False;};fake.clear_composition=[](RimeSessionId)->void{raw.clear();};
 fake.select_candidate=[](RimeSessionId,size_t index)->Bool{if(index>=rows.size())return False;committed=rows[index].text;raw.clear();return True;};
 fake.get_commit=[](RimeSessionId,RimeCommit *out)->Bool{if(committed.empty())return False;out->text=const_cast<char*>(committed.c_str());return True;};
 fake.free_commit=[](RimeCommit*)->Bool{committed.clear();return True;};
 rows.clear();for(size_t i=0;i<300;++i)rows.push_back({"後臺","shi",i});
 for(size_t i=300;i<330;++i)rows.push_back({i==325 ? "pin-late":"普通"+std::to_string(i),"shi",i});
 ck(!private_input::mainland::candidate_allowed(rows[0].text),"fixture has actual rejected candidates");
 for(int kind=0;kind<4;++kind) {
  reset();configurePins(kind);preferences[{"shi","普通310"}]=90;
  const auto oracle=output(legacy_batch_oracle(1,0,24));
  reset();configurePins(kind);preferences[{"shi","普通310"}]=90;
  auto zero=pi_load_candidate_batch_bounded(1,0,24,0);
  ck(zero==0 && pi_candidate_batch_pending(1) && pi_candidate_batch_scanned(1)==0 && visited==0,"zero budget cannot scan or falsely end stream");
  const auto bounded=drain(0,24,1);same(oracle,bounded);
  const auto visits=visited;
  same(bounded,output(pi_load_candidate_batch_bounded(1,0,24,0)));
  ck(!pi_candidate_batch_pending(1) && pi_candidate_batch_scanned(1)==0 && visits==visited,"cached completed window needs no rows");
  const auto tail=drain(24,24,1);ck(tail.size()==6,"short final batch only after actual EOF");
  ck(!pi_candidate_batch_pending(1),"actual EOF distinguished from budget truncation");
  if(kind==1 || kind==3)ck(bounded.front().text=="pin-late","deep pin promoted before any publication");
  const auto expected=bounded.front();ck(pi_select_candidate_absolute(1,expected.index),"absolute selection accepts filtered/deep pinned native index");
  ck(std::string(pi_take_commit(1))==expected.text && std::string(pi_take_commit(1)).empty(),"absolute selection commits exact displayed text once");
  ck(!pi_candidate_batch_pending(1) && pi_candidate_batch_scanned(1)==0,"selection refresh clears progress");
 }
 // Path preparation visits at most its original 128-row prefix; all those
 // visits share the same one-row budget with pin and admission phases.
 rows.clear();for(size_t i=0;i<160;++i)rows.push_back({"词"+std::to_string(i),i%3==0 ? "ni shuo sha":(i%3==1 ? "ni shuo":"mi shi"),i});
 reset(true,true);pinned_words.emplace("ni shuo sha","词145");const auto oracle=output(legacy_batch_oracle(1,0,128));
 reset(true,true);pinned_words.emplace("ni shuo sha","词145");const auto bounded=drain(0,128,1);same(oracle,bounded);
 ck(sessions.at(1).candidate_progress.path_rows==128,"9-key compatible prepass capped at exactly 128 scanned rows");
 reset();rows={{"後臺","shi",0},{"後臺","shi",1}};
 ck(pi_load_candidate_batch_bounded(1,0,1,1)==0 && pi_candidate_batch_pending(1),"all-rejected first row not EOF");
 ck(pi_load_candidate_batch_bounded(1,0,1,1)==0 && pi_candidate_batch_pending(1),"last rejected row still not guessed EOF");
 ck(pi_load_candidate_batch_bounded(1,0,1,1)==0 && !pi_candidate_batch_pending(1),"iterator EOF closes all-rejected stream");
 reset();pi_load_candidate_batch_bounded(1,0,1,1);pi_clear(1);ck(!pi_candidate_batch_pending(1)&&pi_candidate_batch_scanned(1)==0,"explicit clear resets counters and pending");
 ck(pi_load_candidate_batch_bounded(1,100001,1,1)==0 && !pi_candidate_batch_pending(1) && !pi_candidate_batch_scanned(1),"invalid offset returns no stale pending or scan count");
 ck(pi_load_candidate_batch_bounded(99,0,1,1)==0 && !pi_candidate_batch_pending(99) && !pi_candidate_batch_scanned(99),"unknown session is inert");
 reset();rows.clear();for(size_t i=0;i<200;++i)rows.push_back({"词"+std::to_string(i),"shi",i});
 auto partial=pi_load_candidate_batch_bounded(1,0,12,1);ck(partial==1 && pi_candidate_batch_pending(1),"ordinary partial batch explicitly pending");
 const auto old=output(pi_load_candidate_batch(1,0,12));ck(old.size()==12 && !pi_candidate_batch_pending(1),"legacy API completes a partially budgeted request");
 reset();const auto expected=output(legacy_batch_oracle(1,0,12));same(expected,old);
 sessions.clear();api=nullptr;std::cout<<"PASS "<<checks<<" deterministic production-loader budget assertions; synthetic iterator only\n";return 0;
}
}
int main(){try{return fixture::run();}catch(const std::exception&e){std::cerr<<"FAIL "<<e.what()<<"\n";return 1;}}
