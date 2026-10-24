#ifdef NDEBUG
#undef NDEBUG
#endif
#include "ClipboardCandidatePolicy.h"
#include "../activity/CaptureWire.h"
#include <cassert>
#include <cstring>
#include <iostream>
using namespace private_input;
int main(){
 ClipboardCandidatePolicy state;
 assert(state.offer(10,true,true,true,true));state.dismiss(10);
 assert(!state.offer(10,true,true,true,true)); // Delete is a tombstone.
 assert(!state.offer(10,true,false,true,true));
 assert(!state.offer(10,true,true,true,true)); // Typing ended, same copy stays hidden.
 assert(state.offer(11,true,true,true,true));
 assert(!state.offer(11,true,true,true,false));
 assert(!state.offer(11,true,true,true,true)); // Focus return cannot revive it.
 assert(state.offer(12,true,true,true,true));
 assert(!state.offer(12,false,true,true,true));
 assert(!state.offer(12,true,true,true,true)); // Permission return cannot revive it.
 assert(state.offer(13,true,true,true,true));
 assert(!state.offer(13,true,true,false,true));assert(!state.offer(13,true,true,true,true));
 const std::string raw="  标题\r\n\t项目\n\n  尾段  ";assert(clipboardCandidateTextAllowed(raw));
 auto preview=clipboardCandidatePreview(L"  标题\r\n\t项目\n\n  尾段  ");assert(preview.find(L'\n')==std::wstring::npos);assert(raw=="  标题\r\n\t项目\n\n  尾段  ");
 // 2026-10-23: readable content is forwarded without URL/path semantics;
 // this explicitly supersedes the old assertions excluding these strings.
 for(auto readable:{"https://example.test/", "\tfile:///tmp/file", "mailto:test@example.test", "\\\\server\\file", "C:\\file", "D:/资料/readme.txt", "https://example.test:443/sync?q=1&b=two#here", "标题\r\n  https://example.test/path\r\n\tC:\\project\\notes.txt  "})assert(clipboardCandidateTextAllowed(readable));
 ClipboardCandidatePolicy held;assert(held.offer(99,true,true,true,true));assert(held.hideForDelete(99));assert(!held.offer(100,true,true,true,true));assert(!held.hideForDelete(100));held.releaseDelete();assert(!held.offer(100,true,true,true,true));assert(!held.offer(101,true,true,true,true));held.resumeEditing();assert(held.offer(102,true,true,true,true));auto unicode=std::wstring(63,L'x')+wchar_t(0xd83d)+wchar_t(0xde00);auto shortened=clipboardCandidatePreview(unicode);assert(shortened[shortened.size()-2]!=wchar_t(0xd83d));assert(!clipboardCandidateTextAllowed(std::string("control\x1b")));assert(!clipboardCandidateTextAllowed({}));assert(!clipboardCandidateTextAllowed(std::string(65537,'a')));assert(!clipboardCandidateTextAllowed(std::string("a\0b",3)));assert(clipboardCandidateTextAllowed(std::string(65536,'a')));
 activity::CaptureHeader header;header.kind=8;header.version=2;header.utf16Count=3;activity::CaptureContextWire source;
 std::string packet(sizeof(header)+6+sizeof(source),0);memcpy(packet.data(),&header,sizeof(header));memcpy(packet.data()+sizeof(header)+6,&source,sizeof(source));activity::CaptureFrame frame;assert(activity::decodeCaptureFrame(packet.data(),packet.size(),frame)&&frame.header.kind==8&&frame.hasContext);
 packet.pop_back();assert(!activity::decodeCaptureFrame(packet.data(),packet.size(),frame));
 std::cout<<"clipboard candidate policy + exact whitespace + readable URL/path admission + size/control/privacy bounds + v2 paste framing: passed\n";
}
