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
CaptureEmitter::CaptureEmitter(std::wstring){}
CaptureEmitter::~CaptureEmitter()=default;
void CaptureEmitter::start(){++starts;}
bool CaptureEmitter::diagnosticsEnabled()const noexcept{return false;}
void CaptureEmitter::emit(std::wstring_view,HWND,const std::array<unsigned char,16>&,const std::array<unsigned char,16>&,bool,uint32_t,uint32_t,bool,bool,const DecisionCapture*,const DecisionLink*)noexcept{++captures;}
bool CaptureEmitter::emitLearning(std::wstring_view,std::wstring_view,HWND,uint32_t,LearningCapability*)noexcept{++learnings;return true;}
std::shared_ptr<LearningForgetRequest>CaptureEmitter::makeForget(std::wstring,std::wstring,LearningCapability)noexcept{return {};}
bool CaptureEmitter::sendForget(const std::shared_ptr<LearningForgetRequest>&)noexcept{return false;}

LearningReader::LearningReader()=default;
LearningReader::~LearningReader()=default;
std::shared_ptr<const LearningSnapshot>LearningReader::read()const{static const auto snapshot=std::make_shared<const LearningSnapshot>();return snapshot;}
std::shared_ptr<const private_input::PublicContextModel>LearningReader::model()const{return {};}
void LearningReader::stop(){}
void LearningReader::start(std::filesystem::path,std::function<void()>,std::function<void()>){++learningStarts;}

namespace fixture {
bool namesDisabled()noexcept{return pipeName({}).empty()&&gateName({}).empty()&&contextCapabilityName({}).empty()&&learningName({}).empty();}
IPCStats ipcStats()noexcept{return {true,starts.load(),captures.load(),learnings.load(),learningStarts.load()};}
}
}
