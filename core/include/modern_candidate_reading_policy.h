#pragma once
#include "mainland_candidate_policy.h"
#include "private_modern_readings.h"
#include <algorithm>
#include <iterator>
#include <string>
#include <string_view>
#include <vector>

namespace private_input { namespace mainland {
// Automatic candidates only. Literal input, clipboard/history and persistent
// learning data are never rewritten. Explicit personal aliases bypass this
// reading check in their source adapter, retaining the existing text policy.
inline bool candidate_reading_allowed(const std::string &text, const std::string &reading) {
  if (!candidate_allowed(text)) return false;
  std::string normalized;
  for (size_t i=0;i<reading.size();++i) {
    auto c=static_cast<unsigned char>(reading[i]);
    if (c==0xC3 && i+1<reading.size() &&
        (static_cast<unsigned char>(reading[i+1])==0xBC || static_cast<unsigned char>(reading[i+1])==0x9C)) {
      normalized.push_back('v');++i;continue;
    }
    if (c>='A' && c<='Z') c=static_cast<unsigned char>(c+32);
    if (c=='\'' || c==' ' || c=='\t') { normalized.push_back(' ');continue; }
    // Missing/opaque native comments are not evidence of an invalid reading.
    // Keep them as unknown; the presentation layer must not claim exactness.
    if (c<'a' || c>'z') return true;
    normalized.push_back(static_cast<char>(c));
  }
  std::vector<std::string> syllables;
  for (size_t start=0;start<normalized.size();) {
    while (start<normalized.size() && normalized[start]==' ') ++start;
    if (start==normalized.size()) break;
    auto end=normalized.find(' ',start);if(end==std::string::npos)end=normalized.size();
    auto part=normalized.substr(start,end-start);
    if(part=="lue")part="lve";else if(part=="nue")part="nve";
    syllables.push_back(std::move(part));start=end;
  }
  if(syllables.empty())return true;
  std::vector<uint32_t> characters;
  // candidate_allowed above already verified strict UTF-8 and the inventory.
  for(size_t i=0;i<text.size();) {
    auto lead=static_cast<unsigned char>(text[i++]);uint32_t code=lead;size_t extra=0;
    if(lead>=0xF0){code=lead&7;extra=3;}else if(lead>=0xE0){code=lead&15;extra=2;}else if(lead>=0xC0){code=lead&31;extra=1;}
    for(size_t n=0;n<extra;++n)code=(code<<6)|(static_cast<unsigned char>(text[i++])&63);
    characters.push_back(code);
  }
  // Erhua, mixed text and incomplete comments need a richer lexical relation;
  // do not invent per-character alignment or silently drop their suffix.
  if(characters.size()!=syllables.size())return true;
  for(size_t i=0;i<characters.size();++i) {
    const auto first=std::begin(modern_reading_characters),last=std::end(modern_reading_characters);
    const auto found=std::lower_bound(first,last,characters[i],[](const ModernReadingCharacter &row,uint32_t code){return row.codepoint<code;});
    if(found==last || found->codepoint!=characters[i])continue;
    const std::string_view accepted(found->readings);bool allowed=false;
    for(size_t at=0;at<accepted.size();) {
      auto end=accepted.find(' ',at);if(end==std::string_view::npos)end=accepted.size();
      if(accepted.substr(at,end-at)==syllables[i]){allowed=true;break;}at=end+1;
    }
    if(!allowed)return false;
  }
  return true;
}
}}
