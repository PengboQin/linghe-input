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
 // URI/file references are not plain-text paste suggestions. Inspect each line
 // without trimming or modifying the payload itself.
 for(size_t at=0;at<text.size();){auto end=text.find_first_of("\r\n",at);if(end==std::string_view::npos)end=text.size();auto line=text.substr(at,end-at);while(!line.empty()&&(line.front()==' '||line.front()=='\t'))line.remove_prefix(1);
  if(line.substr(0,2)=="\\\\"||(line.size()>2&&((line[0]>='A'&&line[0]<='Z')||(line[0]>='a'&&line[0]<='z'))&&line[1]==':'&&(line[2]=='\\'||line[2]=='/')))return false;
  auto colon=line.find(':');if(colon!=std::string_view::npos&&colon>0){bool scheme=(line[0]>='A'&&line[0]<='Z')||(line[0]>='a'&&line[0]<='z');for(size_t i=1;i<colon&&scheme;++i){auto c=line[i];scheme=(c>='A'&&c<='Z')||(c>='a'&&c<='z')||(c>='0'&&c<='9')||c=='+'||c=='-'||c=='.';}if(scheme)return false;}
  if(end==text.size())break;at=end+1;
 }return true;
}
inline std::wstring clipboardCandidatePreview(std::wstring_view original){std::wstring out=L"粘贴 · ";size_t n=0;for(wchar_t c:original){if(n++==64){if(!out.empty()&&out.back()>=0xd800&&out.back()<=0xdbff)out.pop_back();out+=L"…";break;}out+=c==L'\r'||c==L'\n'||c==L'\t'?L' ':c;}return out;}
}
