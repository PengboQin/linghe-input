#pragma once
#include "private_standard_characters.h"
#include <algorithm>
#include <iterator>
#include <string>

namespace private_input { namespace mainland {
inline int character_tier(uint32_t code) {
  const auto first = std::begin(standard_characters), last = std::end(standard_characters);
  const auto found = std::lower_bound(first, last, code,
    [](const StandardCharacter &value, uint32_t key) { return value.code < key; });
  return found != last && found->code == code ? found->tier : 0;
}
// SIP/TIP are reserved for ideographs, including later additions. A future
// extension must not accidentally pass as a non-Chinese symbol. IVS forms do
// not expand this simplified inventory; emoji VS16 (FE0F) remains allowed.
inline bool restricted_character(uint32_t code) {
  return (code >= 0x3400 && code <= 0x4DBF) || (code >= 0x4E00 && code <= 0x9FFF) ||
         (code >= 0xF900 && code <= 0xFAFF) || (code >= 0x20000 && code <= 0x3FFFF) ||
         (code >= 0x2E80 && code <= 0x2FFF) || (code >= 0x3100 && code <= 0x312F) ||
         (code >= 0x31A0 && code <= 0x31BF) || (code >= 0xE0100 && code <= 0xE01EF);
}
// Strict UTF-8. Automatic suggestions only: never apply to literal commits,
// clipboard contents, raw input, learning/archive storage, or imported history.
inline bool candidate_allowed(const std::string &text) {
  if (text.empty()) return false;
  for (size_t i = 0; i < text.size();) {
    const auto lead = static_cast<unsigned char>(text[i++]);
    uint32_t code = lead; size_t continuation = 0; uint32_t minimum = 0;
    if (lead >= 0xC2 && lead <= 0xDF) { code = lead & 0x1F; continuation = 1; minimum = 0x80; }
    else if (lead >= 0xE0 && lead <= 0xEF) { code = lead & 0x0F; continuation = 2; minimum = 0x800; }
    else if (lead >= 0xF0 && lead <= 0xF4) { code = lead & 7; continuation = 3; minimum = 0x10000; }
    else if (lead >= 0x80) return false;
    if (i + continuation > text.size()) return false;
    for (size_t j = 0; j < continuation; ++j) {
      const auto next = static_cast<unsigned char>(text[i++]);
      if ((next & 0xC0) != 0x80) return false;
      code = (code << 6) | (next & 0x3F);
    }
    if (code < minimum || code > 0x10FFFF || (code >= 0xD800 && code <= 0xDFFF)) return false;
    if (restricted_character(code) && !character_tier(code)) return false;
  }
  return true;
}
}}
