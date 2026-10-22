#pragma once
#include "DecisionDiagnostic.h"
namespace private_input::activity {
struct DecisionOutputPacket {uint32_t kind=1;std::string text;};
// No wrapper is constructed unless both current permissions and explicit new
// worker capability are present. Old workers receive original text unchanged.
inline DecisionOutputPacket decisionOutputPacket(const std::string&text,const Json&link,bool capability,bool diagnosticAllowed,bool outputAllowed){
 if(!capability||!diagnosticAllowed||!outputAllowed||!validDecisionLink(link))return {1,text};
 auto wrapped=Json::object({{"text",text},{"decision_link",link}}).dump();
 // Conservative byte ceiling also bounds UTF16 units before the unchanged IPC.
 if(wrapped.size()>120000)return {1,text};return {11,std::move(wrapped)};
}
}
