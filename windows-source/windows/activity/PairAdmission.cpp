#include "PairAdmission.h"
#include <sodium.h>
#include <algorithm>
#include <limits>
namespace private_input::activity { namespace {
Data raw(const Key&k){return {k.begin(),k.end()};}
Key key(const Json&v){auto d=unbase64(v.str(),32);Key k;std::copy(d.begin(),d.end(),k.begin());return k;}
Json wrap(const protocol::SignedMembership&m,const protocol::GroupMember&recipient,const GroupIdentity&i,const Key&groupKey,const Key&context,uint64_t now,uint64_t expires,bool pairing,Json*challenge){
 Key secret{},pub{},shared{},prk{},derived{};randombytes_buf(secret.data(),32);require(crypto_scalarmult_curve25519_base(pub.data(),secret.data())==0,"ephemeral public");
 auto wire=Json::parse(protocol::encodeMembershipJSON(m));auto j=Json::object({{"version",1},{"purpose",pairing?1:2},{"recipient",uuidText(recipient.device)},{"ephemeralPublic",base64(raw(pub))},{"context",base64(raw(context))},{"membership",wire},{"issuedAt",now},{"expiresAt",expires},{"sealedKey",""},{"signature",""}});
 auto header=wrappedHeader(j);if(challenge){auto t=j;t["membership"]["signature"]="";t["signature"]=base64(sign(header,i.signingSeed));*challenge=Json::object({{"template",t}});}
 require(crypto_scalarmult_curve25519(shared.data(),secret.data(),recipient.exchangePublic.data())==0,"recipient exchange public");auto salt=sha256(header);crypto_auth_hmacsha256(prk.data(),shared.data(),shared.size(),salt.data());auto info=bytes(std::string_view("PrivateInput/wrapping-key/v1\0",29));info.push_back(1);crypto_auth_hmacsha256(derived.data(),info.data(),info.size(),prk.data());
 Data box(60);randombytes_buf(box.data(),12);unsigned long long count=0;int result=crypto_aead_chacha20poly1305_ietf_encrypt(box.data()+12,&count,groupKey.data(),32,header.data(),header.size(),nullptr,box.data(),derived.data());sodium_memzero(secret.data(),32);sodium_memzero(shared.data(),32);sodium_memzero(prk.data(),32);sodium_memzero(derived.data(),32);require(result==0&&count==48,"group key seal");j["sealedKey"]=base64(box);append(header,box);j["signature"]=base64(sign(header,i.signingSeed));return j;
}
}
PreparedAdmission prepareAdmission(const Json&current,const GroupIdentity&i,const Json&request,uint64_t now){
 auto anchor=anchorOf(current);auto previous=anchor.verify(protocol::decodeMembershipJSON(current.dump()));const auto&me=previous.member(i.device);require(me.permissions==3&&me.signingPublic==publicKey(i.signingSeed),"sponsor permission");
 auto canonical=canonicalPair(request);const auto&member=request.at("member");auto recipient=parseId(member.at("device").str());auto publicSigning=key(member.at("signingPublic"));auto signature=unbase64(request.at("signature").str(),64);require(crypto_sign_verify_detached(signature.data(),canonical.data(),canonical.size(),publicSigning.data())==0,"request signature");auto issued=request.at("issuedAt").num(),expiry=request.at("expiresAt").num();require(issued<=now+300&&expiry>now&&now<=std::numeric_limits<uint64_t>::max()-2592000,"request expired");require(std::none_of(previous.statement().members.begin(),previous.statement().members.end(),[&](const auto&m){return m.device==recipient;}),"already member");
 auto next=previous.statement();require(next.revision<std::numeric_limits<uint64_t>::max()&&next.epoch<std::numeric_limits<uint64_t>::max()&&next.members.size()<64,"membership limit");auto predecessor=next;predecessor.history.reset();auto history=next.history.value_or(std::vector<protocol::SignedMembership>{});history.push_back(predecessor);require(history.size()<=1024,"membership proof limit");next.version=2;next.issuer=i.device;next.parent=previous.digest();next.history=history;++next.revision;++next.epoch;next.members.push_back({recipient,publicSigning,key(member.at("exchangePublic")),3});next.signature=sign(next.canonical(),i.signingSeed);(void)anchor.verify(next,&previous);
 PreparedAdmission result;randombytes_buf(result.localKey.data(),32);std::vector<Json>packages;Json challenge;auto context=sha256(canonical);for(const auto&m:next.members){bool joining=m.device==recipient;packages.push_back(wrap(next,m,i,result.localKey,joining?context:Key{},now,joining?std::min(expiry,now+600):now+2592000,joining,joining?&challenge:nullptr));}
 result.bundle=Json::object({{"session",request.at("session")},{"membership",Json::parse(protocol::encodeMembershipJSON(next))},{"challenge",challenge},{"packages",Json::array(packages)}});return result;
}
}
