#include "modern_candidate_reading_policy.h"
#include <cassert>
#include <iostream>
int main(){using private_input::mainland::candidate_reading_allowed;
 assert(!candidate_reading_allowed("小厂","xiao han"));
 assert(candidate_reading_allowed("小厂","xiao chang"));
 assert(candidate_reading_allowed("小寒","xiao han"));
 assert(!candidate_reading_allowed("关","xiao"));assert(!candidate_reading_allowed("学","xiao"));assert(!candidate_reading_allowed("胶","xiao"));
 assert(candidate_reading_allowed("学习","xue xi"));assert(candidate_reading_allowed("胶片","jiao pian"));
 assert(!candidate_reading_allowed("干","qian"));assert(candidate_reading_allowed("乾坤","qian kun"));
 assert(!candidate_reading_allowed("征","zhi"));assert(candidate_reading_allowed("徵","zhi"));
 for(auto r:{"piao","po","pu"})assert(candidate_reading_allowed("朴",r));
 for(auto r:{"hang","heng","xing"})assert(candidate_reading_allowed("行",r));
 for(auto r:{"chong","zhong"})assert(candidate_reading_allowed("重",r));
 for(auto r:{"chang","zhang"})assert(candidate_reading_allowed("长",r));
 assert(candidate_reading_allowed("区","ou"));assert(candidate_reading_allowed("吕","lü"));
 assert(candidate_reading_allowed("略","lue"));assert(candidate_reading_allowed("略","lve"));
 assert(candidate_reading_allowed("呣","m"));
 assert(candidate_reading_allowed("原文", "")); // Unknown is not falsely proven invalid.
 assert(!candidate_reading_allowed(std::string("\xFF",1),"a"));
 std::cout<<"modern reading eligibility: passed; no storage/native/session/clipboard changes\n";
}
