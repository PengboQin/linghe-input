#pragma once
#include "GroupProtocol.h"
#include <memory>
namespace private_input::activity {
struct ClipboardLiveMember {Key signingPublic{},senderKey{};};
// Only clipboard domain keys and one delegated signing seed. Never a primary
// signing/owner/exchange seed, group master key, learning key or legacy ledger.
struct ClipboardLiveGrant {
 Id group{},parent{},generation{};uint64_t epoch=0;std::string endpoint,scope,personal;Json certificate;
 Key delegateSeed{};std::map<Id,ClipboardLiveMember>members;
 ~ClipboardLiveGrant();Json encode()const;static ClipboardLiveGrant decode(const Json&,uint64_t now);
};
struct ClipboardLiveOpened {Id group{},sender{},event{};uint64_t epoch=0,issuedAt=0,expiresAt=0;std::string text,kind,digest;};
Data clipboardLiveCertificateBytes(const Json&);Key clipboardLiveCertificateDigest(const Json&);
Data clipboardLiveEventHeader(const Json&);Data clipboardLiveRequestHeader(const Json&);Data clipboardLiveRevokeHeader(const Json&);
Key clipboardSenderKey(const Key&master,const Id&group,uint64_t epoch,const Id&sender,const Key&signingPublic);
Key clipboardLiveKey(const Key&senderKey,const Id&group,uint64_t epoch,const Id&sender,const Key&signingPublic);
ClipboardLiveGrant issueClipboardLiveGrant(const GroupIdentity&,const protocol::VerifiedMembership&,const Key&master,const std::string&endpoint,const std::string&scope,const std::string&personal,uint64_t issuedAt);
Json sealClipboardLive(const ClipboardLiveGrant&,const std::string&text,uint64_t now,const Id&event=newId(),const Data&nonce={});
Json clipboardLiveRequest(const ClipboardLiveGrant&,uint64_t after,const Json&publish,uint64_t now,const Id&nonce=newId());
Json clipboardLiveRevoke(const Json&certificate,const Key&parentSeed,uint64_t now,const Id&nonce=newId());
ClipboardLiveOpened openClipboardProjection(const std::string&kind,const Json&wire,const ClipboardLiveGrant&,uint64_t now);
void validateClipboardLiveResponse(const Json&,uint64_t after,const Json&published);
}
