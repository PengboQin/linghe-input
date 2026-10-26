#include <algorithm>
#include "mainland_candidate_policy.h"
#include "private_input.h"
#include <filesystem>
#include <fstream>
#include <iostream>
#include <set>
#include <stdexcept>
#include <vector>
static unsigned checks = 0;
static void check(bool condition, const char *reason) { ++checks; if (!condition) throw std::runtime_error(reason); }
static void type(PI_Session s,const std::string&raw) { for (auto c:raw) pi_process_key(s,c,0); }
int main(int argc,char **argv) {
 try {
  using private_input::mainland::candidate_allowed;
  for (const auto &row : private_input::mainland::standard_characters) check(private_input::mainland::character_tier(row.code)==row.tier,"standard character tier lookup");
  for (const auto text : {"后台干活台湾叶子", "淘宝天猫微信抖音", "西安重庆深圳", "王梓涵龚玥", "春眠不觉晓", "apple", "GPT-5.2", "1.4", "@example.com", "你好，world！", "😀", "❤️", "〇"})
    check(candidate_allowed(text),"common/name/place/brand/literal symbols preserved");
  for (const auto text : {"後臺", "發財", "龍門", "繁體", "𨈖", "𰻞", "神", "ㄅ", "龘", "\U000323B0", "\U0003FFFF", "一\U000E0100", "一\U000E01EF", ""})
    check(!candidate_allowed(text),"nonstandard automatic suggestion rejected");
  for (const auto text : {std::string("\xE0\x80\xAF"),std::string("\xED\xA0\x80"),std::string("\xF4\x90\x80\x80"),std::string("\xE4\xB8"),std::string("\x80")})
    check(!candidate_allowed(text),"malformed Unicode rejected");
  check(argc==3,"Usage: mainland_candidate_policy SYNTHETIC_SHARED FRESH_USER");
  check(!std::filesystem::exists(argv[2]),"synthetic user must be new");
  std::filesystem::create_directories(argv[2]);
  check(pi_initialize(argv[1],argv[2],1),"initialize isolated legacy dictionary");
  check(pi_candidate_text_allowed("你好") && !pi_candidate_text_allowed("後臺"),"C ABI same policy");
  auto session=pi_create_session();check(session,"session");type(session,"hao");
  for (size_t i=0;i<pi_candidate_count(session);++i)check(candidate_allowed(pi_candidate_text(session,i)),"visible page admitted");
  const auto count=pi_load_candidate_batch(session,0,128);check(count>=5,"filter searches beyond rejected native page");
  std::vector<std::string> full;std::vector<size_t> ids;
  for(size_t i=0;i<count;++i){full.emplace_back(pi_batch_candidate_text(session,i));ids.push_back(pi_batch_candidate_index(session,i));check(candidate_allowed(full.back()),"stream admitted");}
  const auto first=pi_load_candidate_batch(session,0,2);check(first==2,"first filtered batch");
  std::vector<std::string> paged;for(size_t i=0;i<first;++i)paged.emplace_back(pi_batch_candidate_text(session,i));
  const auto second=pi_load_candidate_batch(session,first,128);for(size_t i=0;i<second;++i)paged.emplace_back(pi_batch_candidate_text(session,i));
  check(full==paged,"logical filtered continuation has no duplicates/gaps");
  // A native id the filter hid (not necessarily 0 once the dictionary itself is
  // standard-only) must never be selectable by a stale absolute id.
  size_t hidden=SIZE_MAX;for(size_t k=0;k<(ids.empty()?0:ids.back());++k)if(std::find(ids.begin(),ids.end(),k)==ids.end()){hidden=k;break;}
  if(hidden!=SIZE_MAX)check(!pi_select_candidate_absolute(session,hidden),"hidden legacy native candidate cannot be selected by stale absolute id");
  check(pi_select_candidate_absolute(session,ids[0]),"native absolute id retained after filtering");
  check(std::string(pi_take_commit(session))==full[0],"exact displayed row committed");
  type(session,"hao");check(pi_load_candidate_batch(session,0,2)==2,"fresh stream after commit");
  const std::string wanted=pi_batch_candidate_text(session,0);pi_process_key(session,' ',0);
  check(std::string(pi_take_commit(session))==wanted,"space selects admitted visible fallback, never hidden legacy native first");
  pi_clear(session);check(pi_candidate_text_allowed("𨈖")==0,"nonstandard old personal candidate denied");
  pi_destroy_session(session);
  const auto imported=std::filesystem::path(argv[2])/"legacy-personal.tsv";
  { std::ofstream stream(imported);stream<<"後臺\thao\t99999\n好\thao\t2\n"; }
  check(pi_import_learning(imported.string().c_str())>=0,"legacy import preserved, not destructively purged");
  check(pi_set_word_pinned("hao","後臺",1),"old pin metadata retained");
  session=pi_create_session();type(session,"hao");
  const auto learned=pi_load_candidate_batch(session,0,128);check(learned>=5,"learned filtered candidates available");
  for(size_t i=0;i<learned;++i)check(candidate_allowed(pi_batch_candidate_text(session,i)),"import and pin cannot bypass admission");
  pi_clear(session);type(session,"haoo");
  const auto repaired=pi_load_repair_candidates(session,32);bool repair_found=false;
  for(size_t i=0;i<repaired;++i){check(candidate_allowed(pi_repair_candidate_text(session,i)),"repair exit admitted");if(std::string(pi_repair_candidate_text(session,i))=="好"){check(std::string(pi_commit_repair_candidate(session,i))=="好","repair retains native id after filtering");repair_found=true;break;}}
  check(repair_found,"legacy hidden rows do not hide valid repair");
  pi_clear(session);
  const std::vector<std::pair<std::string,std::string>> recall = {{"taobao","淘宝"},{"tianmao","天猫"},{"weixin","微信"},{"douyin","抖音"},{"xiaohongshu","小红书"},{"gaodeditu","高德地图"},{"linghe","灵鹤"},{"chongqing","重庆"},{"luan","六安"},{"yuchi","尉迟"}};
  for(const auto &item : recall) {
    pi_clear(session);type(session,item.first);const auto n=pi_load_candidate_batch(session,0,128);bool found=false;
    for(size_t i=0;i<n;++i)if(item.second==pi_batch_candidate_text(session,i)){found=true;check(pi_select_candidate_absolute(session,pi_batch_candidate_index(session,i)),"supplement actual native selection");check(std::string(pi_take_commit(session))==item.second,"supplement exact native commit");break;}
    check(found,"public brand/place/surname recall reachable");
  }
  pi_destroy_session(session);pi_finalize();
  std::cout<<"PASS "<<checks<<" policy/table/legacy stream/selection checks\n";
 }catch(const std::exception&e){pi_finalize();std::cerr<<e.what()<<'\n';return 1;}
}
