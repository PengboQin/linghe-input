#include "desktop_candidates.hpp"
#include "CandidateStream.h"
#include "pinyin_text.h"
#include <algorithm>
#include <cassert>
#include <iostream>
int main(){
 using namespace private_input;
 // The production comparator cannot let even an extreme context/learned
 // score move an edit above a legal alphabetic spelling or unfinished path.
 std::vector<CandidateChoice> spellingRows={{"full",0,SIZE_MAX,"shi he"},{"unfinished",1,SIZE_MAX,"shi heng"},{"repair",SIZE_MAX,0,"shi hou"}};
 for(auto &row:spellingRows){row.rankingClass=pinyin::alphabetic_candidate_priority("shihe",row.reading,row.repair!=SIZE_MAX);row.rankingScore=row.repair!=SIZE_MAX?1e12:0;}
 std::stable_sort(spellingRows.begin(),spellingRows.end(),candidateRankingBefore);
 assert(spellingRows[0].text=="full"&&spellingRows[1].text=="unfinished"&&spellingRows[2].text=="repair");
 DesktopCandidates state;state.reset(100);assert(state.selected==0&&state.digit(1)==0);
 state.horizontal(1);assert(state.selected==1);
 state.vertical(1);assert(state.expanded&&state.selected==1&&state.first()==0);
 state.vertical(1);assert(state.selected==7&&state.digit(2)==7);
 for(size_t i=0;i<36;++i)assert(state.shortcut(i)==(i>=6&&i<12?i-5:0));
 state.page(1);assert(state.selected==43&&state.first()==36);
 assert(state.shortcut(42)==1&&state.shortcut(36)==0);
 state.configure(9,5,4);state.selected=99;
 assert(state.digit(5)==99&&state.digit(6)==state.count);
 assert(state.digit(0)==state.count&&state.digit(10)==state.count);
 state.reset(2);assert(!state.expanded&&state.digit(3)==state.count);
 state.horizontal(-10);assert(state.selected==0);
 state.configure(0,99,-3);assert(state.collapsed==3&&state.columns==9&&state.rows==3);
 // Native batches remain append-only even when a repair occupies row 128.
 CandidateStream stream;size_t requests=0;
 auto reader=[&](size_t offset,size_t limit){++requests;assert(limit==128);std::vector<CandidateChoice> rows;for(size_t i=offset;i<std::min(offset+limit,size_t(300));++i)rows.push_back({std::to_string(i),i,SIZE_MAX});return rows;};
 stream.reset(reader,{{"repair",SIZE_MAX,4}});
 assert(stream.rows.size()==129&&stream.nativeOffset==128&&stream.hasMoreNative);
 assert(stream.appendNative(reader)&&stream.rows.size()==257&&stream.nativeOffset==256);
 assert(stream.rows[128].repair==4&&stream.rows[129].absolute==128);
 assert(stream.appendNative(reader)&&stream.rows.size()==301&&!stream.hasMoreNative);
 assert(!stream.appendNative(reader)&&requests==3&&stream.rows.back().absolute==299);
 state.configure(6,6,6);state.reset(stream.rows.size());
 for(int i=0;i<300;++i)state.horizontal(1);
 assert(state.selected==300&&state.digit(1)==300&&state.digit(2)==301);
 // Exact multiples require one empty batch, then stop requesting.
 requests=0;stream.reset([&](size_t offset,size_t){++requests;std::vector<CandidateChoice> rows;if(!offset)rows.resize(128);return rows;},{});
 assert(!stream.appendNative([&](size_t offset,size_t){++requests;assert(offset==128);return std::vector<CandidateChoice>{};}));
 assert(!stream.hasMoreNative&&requests==2);
 std::cout<<"PASS row-local digits, stable grid expansion, deep append-only candidates, exact-batch termination\n";
}
