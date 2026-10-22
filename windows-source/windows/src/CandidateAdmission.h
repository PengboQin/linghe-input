#pragma once
#include "private_input.h"
#include <string>

namespace private_input {
// Automatic suggestions only. The sole character table lives in shared core;
// literal insertion, clipboard contents and stored source records stay intact.
template<class GlyphSupport>
inline bool candidateAllowedForDisplay(const std::string &text,GlyphSupport supports) {
  return pi_candidate_text_allowed(text.c_str()) != 0 && supports(text);
}
}
