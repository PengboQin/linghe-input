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
namespace private_input::activity {
struct CaptureGate {volatile LONG enabled=0;volatile LONG64 generation=0;};
std::wstring pipeName(const std::wstring&suffix={});std::wstring gateName(const std::wstring&suffix={});std::wstring contextCapabilityName(const std::wstring&suffix={});
// Owns no disk or network handles on TSF's input thread. Loss is counted; the
// background pipe sends a content-free coverage gap once the worker is available.
// Destruction retires shared worker state without waiting for pipe I/O on TSF.
class CaptureEmitter {
 struct State;
 std::shared_ptr<State> state;
public:
 CaptureEmitter(const CaptureEmitter&)=delete;CaptureEmitter&operator=(const CaptureEmitter&)=delete;
 explicit CaptureEmitter(std::wstring name={});~CaptureEmitter();void start();
 bool diagnosticsEnabled()const noexcept;
 void emitLearning(std::wstring_view reading,std::wstring_view text,HWND foreground,uint32_t kind=3)noexcept;
 void emit(std::wstring_view text,HWND foreground,const std::array<unsigned char,16>&session,const std::array<unsigned char,16>&editor,bool normal,uint32_t layout=0,uint32_t field=0,bool paste=false,bool diagnostic=false,const DecisionCapture*decision=nullptr,const DecisionLink*link=nullptr)noexcept;
 void emitDecision(const DecisionCapture&value,HWND hwnd,const std::array<unsigned char,16>&session,const std::array<unsigned char,16>&editor,uint32_t layout,uint32_t field)noexcept{emit(L"",hwnd,session,editor,true,layout,field,false,true,&value);}
};
}
