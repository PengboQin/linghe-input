#include "../../src/CommittedLearning.h"
#include <iostream>
#include <stdexcept>
using private_input::committedLearningSelections;
int main(){unsigned checks=0;auto check=[&](bool x){++checks;if(!x)throw std::runtime_error("committed learning assertion");};
 auto single=committedLearningSelections({{L"ling he",L"灵鹤"}},L"灵鹤",true);check(single.size()==1&&single.front().second==L"灵鹤");
 auto combined=committedLearningSelections({{L"ling",L"灵"},{L"he",L"鹤"}},L"灵鹤",true);check(combined.size()==3);check(std::count_if(combined.begin(),combined.end(),[](const auto&p){return p.second==L"灵鹤";})==1);check(combined.back().first==L"ling he");
 check(committedLearningSelections({{L"ling",L"灵"},{L"he",L"鹤"}},L"灵",true).empty());
 check(committedLearningSelections({{L"ling",L"灵"},{L"he",L"鹤"}},L"灵鹤",false).empty());
 check(committedLearningSelections({{L"ling",L"灵"},{L"he",L"鹤"}},L"灵鹤raw",true).empty());
 check(committedLearningSelections({{L"ling",L"灵"},{L"",L"鹤"}},L"灵鹤",true).empty());
 check(committedLearningSelections({{L"a",L"a"},{L"b",L"b"}},L"ab",true).size()==2);
 check(committedLearningSelections({{L"a",L"一二三四五"},{L"b",L"六七八九"}},L"一二三四五六七八九",true).size()==2);
 std::cout<<"PASS "<<checks<<" committed learning single/compound/no-partial/no-failed-commit checks\n";
}
