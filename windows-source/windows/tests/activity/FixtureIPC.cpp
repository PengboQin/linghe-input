// Test executable only. Do not add this file to product targets. The fixture
// intentionally links neither production CaptureIPC.cpp nor LearningIPC.cpp.
// No file/pipe/mapping, token/SID, clipboard, network or worker thread API is
// called here, and passed text is not read, copied, serialized or stored.
#include "FixtureIPC.h"
#include "../../activity/CaptureIPC.h"
#include "../../activity/LearningIPC.h"
#include <atomic>
namespace {std::atomic<uint64_t>starts{0},captures{0},learnings{0},learningStarts{0};}
namespace private_input::activity {
std::wstring pipeName(const std::wstring&){return {};}
std::wstring gateName(const std::wstring&){return {};}
std::wstring contextCapabilityName(const std::wstring&){return {};}
std::wstring learningName(const std::wstring&){return {};}
CaptureEmitter::~CaptureEmitter()=default;
void CaptureEmitter::start(){++starts;}
bool CaptureEmitter::diagnosticsEnabled()const noexcept{return false;}
void CaptureEmitter::emit(std::wstring_view,HWND,const std::array<unsigned char,16>&,const std::array<unsigned char,16>&,bool,uint32_t,uint32_t,bool,bool,const DecisionCapture*,const DecisionLink*)noexcept{++captures;}
void CaptureEmitter::emitLearning(std::wstring_view,std::wstring_view,HWND,uint32_t)noexcept{++learnings;}
void CaptureEmitter::run()noexcept{}
LearningReader::~LearningReader()=default;
void LearningReader::stop(){}
void LearningReader::start(std::filesystem::path,std::function<void()>,std::function<void()>){++learningStarts;}
void LearningReader::run(){}
namespace fixture {
bool namesDisabled()noexcept{return pipeName({}).empty()&&gateName({}).empty()&&contextCapabilityName({}).empty()&&learningName({}).empty();}
IPCStats ipcStats()noexcept{return {true,starts.load(),captures.load(),learnings.load(),learningStarts.load()};}
}
}
