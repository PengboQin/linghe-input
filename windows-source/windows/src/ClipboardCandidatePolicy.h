#pragma once
#include <cstdint>
#include <string>
#include <string_view>
namespace private_input {
// Copy identity is the system sequence, not the displayed (possibly shortened)
// text. A dismissal remains retired across typing, contexts and permission flips.
struct ClipboardCandidatePolicy {
 uint32_t retired=0,shown=0;bool deleteHeld=false,deletionSuppressed=false;
 bool hideForDelete(uint32_t sequence){if(deleteHeld)return false;deleteHeld=true;deletionSuppressed=true;dismiss(sequence);return true;}
 void releaseDelete(){deleteHeld=false;}
 void resumeEditing(){deletionSuppressed=false;}
 void dismiss(uint32_t sequence){if(sequence)retired=sequence;shown=0;}
 bool offer(uint32_t sequence,bool allowed,bool idle,bool normal,bool focused){
  if(deleteHeld||deletionSuppressed)return false;
  if(!allowed||!normal||!focused||!idle){if(shown)dismiss(shown);return false;}
  if(!sequence||sequence==retired)return false;shown=sequence;return true;
 }
};
inline bool clipboardCandidateTextAllowed(std::string_view text){
 if(text.empty()||text.size()>65536||text.find('\0')!=std::string_view::npos)return false;for(unsigned char c:text)if((c<32&&c!='\r'&&c!='\n'&&c!='\t')||c==127)return false;
 // Readable URL/path strings are ordinary clipboard payloads. Preserve their
 // original spacing and spelling. This admission rule does not relax any
 // dictionary-learning or input-field privacy policy.
 return true;
}
inline std::wstring clipboardCandidatePreview(std::wstring_view original){std::wstring out=L"粘贴 · ";size_t n=0;for(wchar_t c:original){if(n++==64){if(!out.empty()&&out.back()>=0xd800&&out.back()<=0xdbff)out.pop_back();out+=L"…";break;}out+=c==L'\r'||c==L'\n'||c==L'\t'?L' ':c;}return out;}
}
