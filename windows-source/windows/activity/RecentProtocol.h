#pragma once
#include "RecentModel.h"
#include "GroupProtocol.h"
namespace private_input::activity {
Data recentRequestCanonical(const Json&);
Json recentRequest(const Id&,const GroupIdentity&,uint8_t,const Json&,uint64_t);
Data recentHeader(const Json&);Json sealRecent(const Json&,const protocol::VerifiedMembership&,const GroupIdentity&,const Key&,uint64_t);Json openRecent(const Json&,const protocol::VerifiedMembership&,const Key&,uint64_t);
void validateRecentStatus(const Json&,const Json&request,const protocol::VerifiedMembership&,uint64_t beganTick,uint64_t endedTick);
}
