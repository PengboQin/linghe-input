#include "../../activity/LegacyLearning.h"
#include <iostream>
#include <set>
using namespace private_input::activity;
namespace {
unsigned checks=0,failures=0;
void check(bool value,const char*label){++checks;if(!value)throw std::runtime_error(label);}
template<class F>void reject(F action,const char*label){bool rejected=false;try{action();}catch(const JsonError&){rejected=true;}check(rejected,label);}
std::string row(const std::string&word,uint64_t count){return word+"\tce shi\t"+std::to_string(count)+"\n";}
std::string exported(unsigned positive,unsigned zero){std::string text="# synthetic host fixture\n";for(unsigned i=0;i<positive;++i)text+=row("合成正词"+std::to_string(i),i%7+1);for(unsigned i=0;i<zero;++i)text+=row("合成零词"+std::to_string(i),0);return text;}
void largeExport(){
 auto seed=legacyLearningSeed(exported(4650,615),"synthetic-replica");const auto&rows=seed.at("entries").items;
 check(rows.size()==4650,"5265 native rows yield exactly 4650 positive learning entries");
 std::set<std::string>words;for(const auto&entry:rows){
  auto word=entry.at("text").str();check(words.insert(word).second,"positive rows remain unique");
  check(word.rfind("合成正词",0)==0,"zero native words never promoted");
  auto index=std::stoul(word.substr(std::string("合成正词").size()));
  check(entry.at("counts").at("synthetic-replica").num()==index%7+1,"all positive native frequencies preserved");
 }
 check(legacyLearningSeed(exported(5000,1),"synthetic-replica").at("entries").items.size()==5000,"5000 positives plus zero allowed");
}
void allZero(){auto seed=legacyLearningSeed(exported(0,5265),"synthetic-replica");check(seed.dump()==emptyLearning().dump(),"all-zero export is valid empty learning archive");}
void strictZeros(){
 std::vector<std::string>invalid={
  row("重复零",0)+row("重复零",0),row("重复正零",1)+row("重复正零",0),row("重复零正",0)+row("重复零正",1),
  "大小写\tCE SHI\t0\n大小写\tce shi\t0\n","空格\t ce shi \t0\n空格\tce shi\t0\n",
  "坏码\tce1\t0\n","\tce shi\t0\n",std::string("坏")+char(0)+"字\tce shi\t0\n",
  std::string("坏")+char(31)+"字\tce shi\t0\n","坏字\t\t0\n","多列\tce shi\textra\t0\n",
  "负数\tce shi\t-0\n","溢出\tce shi\t1000000001\n",std::string("\xc0\xaf\tce shi\t0\n"),
  std::string(1025,'x')+"\tce shi\t0\n",std::string("长码\t")+std::string(129,'a')+"\t0\n"};
 auto original=legacyLearningSeed(row("已有词",8),"synthetic-replica");const auto saved=original.dump();
 for(const auto&bad:invalid){bool committed=false;reject([&]{auto incoming=legacyLearningSeed(row("合法前缀",2)+bad,"synthetic-replica");original=mergeLearning(original,incoming);committed=true;},"invalid or duplicate zero export rejected entirely");check(!committed&&original.dump()==saved,"failed conversion never publishes prefix or changes existing model");}
 // Bad rows after >5000 valid total rows must still be examined.
 auto manyZeros=exported(0,5265);reject([&]{legacyLearningSeed(manyZeros+row("合成零词5264",0),"synthetic-replica");},"duplicate zero after 5000 total rows rejected");reject([&]{legacyLearningSeed(manyZeros+"坏尾\tce1\t0\n","synthetic-replica");},"invalid zero tail after 5000 total rows rejected");
}
void limits(){reject([&]{legacyLearningSeed(exported(10001,0),"synthetic-replica");},"current10001 positive entries refused");reject([&]{legacyLearningSeed(std::string(2097153,'#'),"synthetic-replica");},"2 MiB native byte limit retained");reject([&]{legacyLearningSeed(row("零",0),"");},"empty replica rejected even for all-zero input");}
template<class F>void run(const char*name,F work){try{work();std::cout<<"PASS "<<name<<'\n';}catch(const std::exception&e){++failures;std::cout<<"FAIL "<<name<<": "<<e.what()<<'\n';}}
}
int main(){run("large positive/zero export",largeExport);run("all-zero export",allZero);run("strict zero validation and atomic rejection",strictZeros);run("positive/byte/replica limits",limits);std::cout<<"checks="<<checks<<" failures="<<failures<<"; synthetic host only, no PC/native DB/profile/network\n";return failures?1:0;}
