#pragma once
#include "GroupProtocol.h"
namespace private_input::activity {
// Pure bounded admission builder. Caller persists its complete result encrypted
// BEFORE POST, retries the same bundle, and adopts localKey only after ACK.
struct PreparedAdmission {Json bundle;Key localKey;};
PreparedAdmission prepareAdmission(const Json& current,const GroupIdentity& sponsor,const Json& request,uint64_t now);
}
