#include "../../activity/LearningReadingAdmission.h"
#include "modern_candidate_reading_policy.h"
#include <array>
#include <iostream>
#include <stdexcept>
#include <tuple>
#include <vector>
using private_input::activity::learningRowReadingAllowed;
namespace {
unsigned checks=0,failures=0;
void check(bool value,const char*label){++checks;if(!value)throw std::runtime_error(label);}
struct Row {
 uint32_t kind;std::string text,reading;uint64_t frequency;bool pinned;
 bool operator==(const Row&other)const{return std::tie(kind,text,reading,frequency,pinned)==std::tie(other.kind,other.text,other.reading,other.frequency,other.pinned);}
};
template<size_t N>std::vector<size_t>project(const std::array<Row,N>&rows){std::vector<size_t>out;for(size_t i=0;i<N;++i)if(learningRowReadingAllowed(rows[i].kind,rows[i].text,rows[i].reading))out.push_back(i);return out;}
void sharedPredicate(){
 check(!private_input::mainland::candidate_reading_allowed("小厂","xiao han"),"actual shared predicate rejects archaic factory reading");
 check(private_input::mainland::candidate_reading_allowed("小寒","xiao han"),"actual shared predicate retains modern cold reading");
 check(private_input::mainland::candidate_reading_allowed("小厂","xiao chang"),"actual shared predicate retains modern factory reading");
}
void ordinaryProjection(){
 const std::array<Row,3>rows={{{0,"小厂","xiao han",1000000000,true},{0,"小寒","xiao han",1,false},{0,"小厂","xiao chang",9,true}}};const auto before=rows;
 check(project(rows)==std::vector<size_t>({1,2}),"high-frequency pinned wrong ordinary reading cannot enter learned snapshot");
 check(rows==before,"ordinary input rows remain byte-value unchanged");
}
void explicitAliases(){
 const std::array<Row,3>rows={{{0,"小厂","xiao han",1000000000,true},{1,"小厂","xiao han",0,false},{2,"小厂","gc",0,false}}};const auto before=rows;
 check(project(rows)==std::vector<size_t>({1,2}),"only explicit personal word/phrase aliases bypass pronunciation policy");
 check(learningRowReadingAllowed(1,"自定义正文","myalias"),"personal word trigger need not be the text pronunciation");
 check(learningRowReadingAllowed(2,"任意快捷短语正文","kj"),"shortcut expansion need not be the text pronunciation");
 check(rows==before,"explicit aliases and original ordinary counters remain unchanged");
}
void bothViewsAndFallback(){
 const std::array<Row,3>legacy={{{0,"小厂","xiao han",999,true},{0,"小寒","xiao han",7,false},{1,"小厂","xh",0,false}}};
 const std::array<Row,3>cloud={{{0,"小厂","xiao han",0,true},{0,"小寒","xiao han",0,false},{2,"小厂","gc",0,false}}};const auto oldLegacy=legacy,oldCloud=cloud;
 check(project(legacy)==std::vector<size_t>({1,2}),"legacy View admission");check(project(cloud)==std::vector<size_t>({1,2}),"cloud View admission");
 const auto&fallback=legacy;check(project(fallback)==std::vector<size_t>({1,2}),"revoked-cloud fallback cannot reintroduce old bad learned row");
 check(legacy==oldLegacy&&cloud==oldCloud,"projection never changes source rows, pin or frequency");
}
void invalidKinds(){check(!learningRowReadingAllowed(3,"小寒","xiao han"),"unknown kind remains refused");check(!learningRowReadingAllowed(UINT32_MAX,"小厂","gc"),"wrapped invalid kind cannot become explicit alias");}
void unknownReading(){check(learningRowReadingAllowed(0,"小厂",""),"missing reading remains unknown rather than invented invalidity");check(learningRowReadingAllowed(0,"小厂","xiaohan"),"unaligned reading remains unknown under shared contract");check(learningRowReadingAllowed(0,"小厂","opaque?"),"opaque native reading remains unknown under shared contract");}
template<class F>void run(const char*name,F work){try{work();std::cout<<"PASS "<<name<<'\n';}catch(const std::exception&e){++failures;std::cout<<"FAIL "<<name<<": "<<e.what()<<'\n';}}
}
int main(){run("shared production predicate",sharedPredicate);run("ordinary learned projection",ordinaryProjection);run("explicit word and shortcut aliases",explicitAliases);run("legacy/cloud/fallback projection",bothViewsAndFallback);run("unknown source-kind guard",invalidKinds);run("unknown reading preserved",unknownReading);std::cout<<"checks="<<checks<<" failures="<<failures<<"; synthetic const rows only; no storage/PC/Rime/network\n";return failures?1:0;}
