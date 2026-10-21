#pragma once
#include "ArchiveCore.h"
#include "../sync/MembershipWire.h"
namespace private_input::activity {
struct GroupIdentity {Id device{},owner{};Key signingSeed{},ownerSeed{},exchangeSecret{};};
Json publicMember(const GroupIdentity&);protocol::MembershipAnchor anchorOf(const Json&);
Json pairRequest(const GroupIdentity&,uint64_t now);Data canonicalPair(const Json&);
Json initialMembership(const GroupIdentity&);
Data wrappedHeader(const Json&);Key openGroupKey(const Json&pack,const GroupIdentity&,const protocol::MembershipAnchor&,const protocol::VerifiedMembership*previous,const Key&context,uint64_t now);
void verifyJoinTemplate(const Json&pack,const GroupIdentity&,const protocol::MembershipAnchor&,const Json&pair,uint64_t now);
}
