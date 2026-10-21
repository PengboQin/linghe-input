#pragma once
#include "Membership.h"
#include <string_view>

namespace private_input::protocol {
// Only public Membership statements/templates, never a trusted anchor. Decode
// is not authorization: always call a pinned MembershipAnchor::verify before use.
class MembershipWireError final : public std::runtime_error {
public:
 explicit MembershipWireError(const char* reason):std::runtime_error(reason){}
};
struct MembershipWireLimits {
 static constexpr size_t maximumBytes=2*1024*1024, maximumDepth=6, maximumNodes=65536;
 // Callers may lower, never raise, the hard budgets. A node is one JSON value;
 // object keys are bounded separately (64 decoded bytes) and are not nodes.
 size_t bytes=maximumBytes,depth=maximumDepth,nodes=maximumNodes;
};
SignedMembership decodeMembershipJSON(std::string_view,MembershipWireLimits={});
std::string encodeMembershipJSON(const SignedMembership&,MembershipWireLimits={});
}
