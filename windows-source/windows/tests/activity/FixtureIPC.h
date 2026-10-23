#pragma once
#include <cstdint>
namespace private_input::activity::fixture {
struct IPCStats {bool productionTransportDisabled=false;uint64_t starts=0,captureAttempts=0,learningAttempts=0,learningStarts=0;};
IPCStats ipcStats()noexcept;
bool namesDisabled()noexcept;
}
