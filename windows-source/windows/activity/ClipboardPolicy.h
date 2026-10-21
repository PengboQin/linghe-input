#pragma once
#include <string>
#include <cstdint>
namespace private_input::activity {
// Application provenance may be unknown. This provider observes a copy event,
// never infers a paste, and is separate from TSF's fail-closed input scopes.
inline bool clipboardMayObserve(bool explicitConsent,bool defaultInputDesktop,bool trustedPasswordSignal,bool exclusionFormatPresent,bool exclusionValueReadable,bool exclusionValue){
 return explicitConsent&&defaultInputDesktop&&!trustedPasswordSignal&&(!exclusionFormatPresent||(exclusionValueReadable&&!exclusionValue));
}
inline bool clipboardOriginMatches(uint32_t version,const std::string&event,const std::string&sender,const std::string&hash,const std::string&expectedEvent,const std::string&expectedSender,const std::string&expectedHash,bool sameText,uint32_t sequence,uint32_t expectedSequence){return version==2&&sameText&&sequence==expectedSequence&&event==expectedEvent&&sender==expectedSender&&hash==expectedHash;}
}
