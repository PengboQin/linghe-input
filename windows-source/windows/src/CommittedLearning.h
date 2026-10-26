#pragma once
#include <algorithm>
#include <string>
#include <utility>
#include <vector>
namespace private_input {
using CommittedLearningSelections=std::vector<std::pair<std::wstring,std::wstring>>;
// The caller supplies success only after the editor accepted the final text.
// Partial/mismatched output has no authority to learn an assembled phrase.
inline CommittedLearningSelections committedLearningSelections(const CommittedLearningSelections&selected,const std::wstring&committed,bool succeeded){
 if(!succeeded||selected.empty())return {};std::wstring text,reading;
 for(const auto&part:selected){if(part.first.empty()||part.second.empty()||part.second.find_first_of(L"\t\r\n")!=std::wstring::npos)return {};text+=part.second;if(!reading.empty())reading+=L' ';reading+=part.first;}
 if(text!=committed)return {};auto out=selected;
 // Production candidate admission already enforces the mainland character
 // policy. Limit the extra compound to the auto-phrase product's 2–8 Han span.
 if(selected.size()>1&&committed.size()>=2&&committed.size()<=8&&reading.size()<=128&&std::all_of(committed.begin(),committed.end(),[](wchar_t c){return c>=0x3400&&c<=0x9fff;}))out.emplace_back(std::move(reading),committed);
 return out;
}
}
