#pragma once
#include <windows.h>
#include "CaptureWire.h"
#include "DecisionCapture.h"
#include <memory>
#include <array>
#include <atomic>
#include <condition_variable>
#include <deque>
#include <mutex>
#include <string>
#include <thread>
namespace private_input::activity {
struct CaptureGate {volatile LONG enabled=0;volatile LONG64 generation=0;};
std::wstring pipeName(const std::wstring&suffix={});std::wstring gateName(const std::wstring&suffix={});std::wstring contextCapabilityName(const std::wstring&suffix={});
// Owns no disk or network handles on TSF's input thread. Loss is counted; the
// background pipe sends a content-free coverage gap once the worker is available.
class CaptureEmitter {
 struct Packet {CaptureHeader header;std::wstring text;CaptureContextWire source;std::optional<DecisionCapture>decision;DecisionLink link;size_t cost=0;};
 std::shared_ptr<const CaptureContextWire> hostSource;
 std::wstring suffix,pipe,gate;std::mutex lock;std::condition_variable wake;std::deque<Packet> pending;size_t pendingBytes=0;std::thread worker;bool stopping=false;std::atomic<uint64_t>lost{0};
 void run()noexcept;
public:
 explicit CaptureEmitter(std::wstring name={}):suffix(std::move(name)){}~CaptureEmitter();void start();
 bool diagnosticsEnabled()const noexcept;
 void emitLearning(std::wstring_view reading,std::wstring_view text,HWND foreground,uint32_t kind=3)noexcept;
 void emit(std::wstring_view text,HWND foreground,const std::array<unsigned char,16>&session,const std::array<unsigned char,16>&editor,bool normal,uint32_t layout=0,uint32_t field=0,bool paste=false,bool diagnostic=false,const DecisionCapture*decision=nullptr,const DecisionLink*link=nullptr)noexcept;
 void emitDecision(const DecisionCapture&value,HWND hwnd,const std::array<unsigned char,16>&session,const std::array<unsigned char,16>&editor,uint32_t layout,uint32_t field)noexcept{emit(L"",hwnd,session,editor,true,layout,field,false,true,&value);}
};
}
