#pragma once
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>
#include <utility>
namespace private_input {
struct CandidateChoice {
 std::string text;
 std::size_t absolute=SIZE_MAX,repair=SIZE_MAX;
 std::string reading;bool custom=false;int rankingClass=0;double rankingScore=0;
 CandidateChoice(std::string value={},std::size_t native=SIZE_MAX,std::size_t corrected=SIZE_MAX,std::string code={},bool personal=false):text(std::move(value)),absolute(native),repair(corrected),reading(std::move(code)),custom(personal){}
};
// 128 is a native API batch size, never a total candidate limit. Append-only
// rows keep already visible repair and native selections at stable positions.
struct CandidateStream {
 std::vector<CandidateChoice> rows;
 std::size_t nativeOffset=0;
 bool hasMoreNative=true;
 template<class Reader> bool appendNative(Reader read){
  if(!hasMoreNative)return false;
  auto batch=read(nativeOffset,128);
  hasMoreNative=batch.size()==128;nativeOffset+=batch.size();
  for(auto &row:batch)rows.push_back(std::move(row));
  return !batch.empty();
 }
 template<class Reader> void reset(Reader read,std::vector<CandidateChoice> repairs){
  rows.clear();nativeOffset=0;hasMoreNative=true;appendNative(read);
  for(auto &row:repairs)rows.push_back(std::move(row));
 }
};
}
