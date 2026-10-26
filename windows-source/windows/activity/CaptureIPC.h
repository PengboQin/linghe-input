#pragma once
#include <windows.h>
#include "CaptureWire.h"
#include "LearningIntentWire.h"
#include "DecisionCapture.h"
#include <memory>
#include <functional>
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
struct LearningForgetRequest {
 const LearningCapability capability;const std::array<unsigned char,16>event;const uint64_t createdAt;
 const std::wstring reading,text;std::atomic<bool>inFlight{false};const std::shared_ptr<LearningDelivery>delivery=std::make_shared<LearningDelivery>();
 void finish(LearningIntentStatus status){delivery->status=status;inFlight=false;delivery->complete=true;}
 LearningForgetRequest(LearningCapability c,std::array<unsigned char,16>e,uint64_t at,std::wstring r,std::wstring t):capability(c),event(e),createdAt(at),reading(std::move(r)),text(std::move(t)){}
};
class CaptureEmitter {
 struct State;
 std::shared_ptr<State> state;
public:
 CaptureEmitter(const CaptureEmitter&)=delete;CaptureEmitter&operator=(const CaptureEmitter&)=delete;
 explicit CaptureEmitter(std::wstring name={});~CaptureEmitter();void start();
 bool diagnosticsEnabled()const noexcept;
 bool emitLearning(std::wstring_view reading,std::wstring_view text,HWND foreground,uint32_t kind=3,LearningCapability*used=nullptr)noexcept;
 std::shared_ptr<LearningForgetRequest> makeForget(std::wstring reading,std::wstring text,LearningCapability)noexcept;
 bool sendForget(const std::shared_ptr<LearningForgetRequest>&)noexcept;
#ifdef PRIVATE_INPUT_CAPTURE_TEST_HOOKS
 void withQueueLockForTest(const std::function<void()>&);
#endif
 void emit(std::wstring_view text,HWND foreground,const std::array<unsigned char,16>&session,const std::array<unsigned char,16>&editor,bool normal,uint32_t layout=0,uint32_t field=0,bool paste=false,bool diagnostic=false,const DecisionCapture*decision=nullptr,const DecisionLink*link=nullptr)noexcept;
 void emitDecision(const DecisionCapture&value,HWND hwnd,const std::array<unsigned char,16>&session,const std::array<unsigned char,16>&editor,uint32_t layout,uint32_t field)noexcept{emit(L"",hwnd,session,editor,true,layout,field,false,true,&value);}
};
}
