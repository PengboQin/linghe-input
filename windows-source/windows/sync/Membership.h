#pragma once
#include "SecureProtocol.h"
#include <optional>
#include <stdexcept>
#include <string>

namespace private_input::protocol {
enum class MembershipErrorCode { malformed, wrongOwner, invalidSignature, rollback, equivocation, notMember };
class MembershipError final : public std::runtime_error {
public:
 const MembershipErrorCode code;
 MembershipError(MembershipErrorCode value,const char* reason):std::runtime_error(reason),code(value){}
};
struct GroupMember {
 Id device{};
 Key signingPublic{},exchangePublic{};
 uint8_t permissions=3;
};
struct SignedMembership {
 static constexpr size_t maxMembers=64,maxHistory=1024;
 uint8_t version=1;
 Id group{},ownerID{};
 Key ownerPublic{};
 uint64_t revision=0,epoch=0;
 std::vector<GroupMember> members;
 Data signature;
 std::optional<Id> issuer;
 std::optional<Key> parent;
 // Presence matters: v1 must not carry even an empty history, and entries in
 // the public flat predecessor proof must not have a nested history.
 std::optional<std::vector<SignedMembership>> history;
 Data canonical()const;
};
class VerifiedMembership;
struct MembershipAnchor {
 Id group{},ownerID{};
 Key ownerPublic{};
 bool operator==(const MembershipAnchor& other)const;
 VerifiedMembership verify(const SignedMembership&,const VerifiedMembership* replacing=nullptr)const;
};
enum class MembershipDomain : uint8_t { learning=1,clipboard=2 };
// Only the verifier can construct this value. A caller cannot turn an
// unverified statement or relay response into a replacement/trust anchor.
class VerifiedMembership final {
 MembershipAnchor pinned;
 SignedMembership value;
 Data bytes;
 Key hash{};
 VerifiedMembership(MembershipAnchor,SignedMembership,Data,Key);
 friend struct MembershipAnchor;
public:
 const MembershipAnchor& anchor()const{return pinned;}
 const SignedMembership& statement()const{return value;}
 const Data& canonicalBytes()const{return bytes;}
 const Key& digest()const{return hash;}
 const GroupMember& member(const Id&)const;
 Trust trust(MembershipDomain)const;
};
// Hashes canonical public bytes, not a signature, JSON or nested history.
Key membershipDigest(const Data& canonical);
// No production signing/secret-key API is exposed by this verification layer.
}
