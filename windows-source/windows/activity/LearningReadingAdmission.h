#pragma once
#include <cstdint>
#include <string>
#include "modern_candidate_reading_policy.h"

namespace private_input::activity {
// kind is the existing wire source: 0 learned, 1 explicit word, 2 shortcut.
// Only the runtime learned projection is filtered; explicit user aliases need
// not spell their expansion. Stored rows and the existing text/glyph gate stay.
inline bool learningRowReadingAllowed(uint32_t kind,const std::string&text,const std::string&reading){
 switch(kind){
  case 0:return private_input::mainland::candidate_reading_allowed(text,reading);
  case 1:case 2:return true;
  default:return false;
 }
}
}
