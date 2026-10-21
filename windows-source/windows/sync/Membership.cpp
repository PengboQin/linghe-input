#include "Membership.h"
#include <sodium.h>
#include <algorithm>
#include <limits>
#include <set>
#include <utility>

namespace private_input::protocol {namespace {
void require(bool ok,MembershipErrorCode code,const char* reason){if(!ok)throw MembershipError(code,reason);}
void init(){if(sodium_init()<0)throw std::runtime_error("Crypto initialization failed");}
template<class T> void append(Data& into,const T& source){into.insert(into.end(),source.begin(),source.end());}
void be(Data& into,uint64_t value){for(int shift=56;shift>=0;shift-=8)into.push_back(uint8_t(value>>shift));}
const GroupMember* findMember(const SignedMembership& value,const Id& device){auto found=std::find_if(value.members.begin(),value.members.end(),[&](const auto& member){return member.device==device;});return found==value.members.end()?nullptr:&*found;}
}
Data SignedMembership::canonical()const{
 require((version==1||version==2)&&revision>0&&epoch==revision&&!members.empty()&&members.size()<=maxMembers,MembershipErrorCode::malformed,"Invalid membership metadata");
 std::set<Id> devices;std::set<Key> signing,exchange;
 for(const auto& member:members){
  require(member.permissions>0&&member.permissions<=3,MembershipErrorCode::malformed,"Invalid member permissions");
  require(devices.insert(member.device).second&&signing.insert(member.signingPublic).second&&exchange.insert(member.exchangePublic).second,MembershipErrorCode::malformed,"Duplicate member identity or key");
 }
 const char label[]="PrivateInput/membership/v1";Data result(label,label+sizeof(label));result.push_back(version);
 append(result,group);append(result,ownerID);append(result,ownerPublic);be(result,revision);be(result,epoch);result.push_back(uint8_t(members.size()));
 auto sorted=members;
 // UUID canonical uppercase hexadecimal order is lexicographic byte order.
 std::sort(sorted.begin(),sorted.end(),[](const auto& a,const auto& b){return a.device<b.device;});
 for(const auto& member:sorted){append(result,member.device);append(result,member.signingPublic);append(result,member.exchangePublic);result.push_back(member.permissions);}
 if(version==2){require(issuer.has_value()&&parent.has_value(),MembershipErrorCode::malformed,"Missing v2 predecessor binding");append(result,*issuer);append(result,*parent);}
 else require(!issuer&&!parent&&!history,MembershipErrorCode::malformed,"v1 carries v2 fields");
 return result;
}
Key membershipDigest(const Data& bytes){init();Key result{};crypto_hash_sha256(result.data(),bytes.data(),bytes.size());return result;}
bool MembershipAnchor::operator==(const MembershipAnchor& other)const{return group==other.group&&ownerID==other.ownerID&&ownerPublic==other.ownerPublic;}
VerifiedMembership MembershipAnchor::verify(const SignedMembership& statement,const VerifiedMembership* old)const{
 init();auto anchored=[&](const SignedMembership& item){require(item.group==group&&item.ownerID==ownerID&&item.ownerPublic==ownerPublic,MembershipErrorCode::wrongOwner,"Membership does not match pinned group/owner");};
 anchored(statement);auto bytes=statement.canonical();
 const size_t count=statement.history?statement.history->size():0;
 require(count<=SignedMembership::maxHistory&&(statement.version==1?count==0:count>0),MembershipErrorCode::malformed,"Invalid predecessor proof length");
 if(statement.history)for(const auto& item:*statement.history)require(!item.history,MembershipErrorCode::malformed,"Nested predecessor history");
 const SignedMembership* previous=nullptr;std::optional<Key> previousDigest,retainedDigest;
 auto verifyItem=[&](const SignedMembership& item){
  anchored(item);auto canonical=item.canonical();const Key* publicKey=&ownerPublic;
  if(previous){
   require(item.version==2&&item.parent&&*item.parent==*previousDigest&&previous->revision<std::numeric_limits<uint64_t>::max()&&item.revision==previous->revision+1&&item.issuer.has_value(),MembershipErrorCode::notMember,"Invalid membership predecessor");
   const auto* signer=findMember(*previous,*item.issuer);
   require(signer&&signer->permissions==3,MembershipErrorCode::notMember,"Issuer lacks predecessor all permission");publicKey=&signer->signingPublic;
  }else require(item.version==1,MembershipErrorCode::malformed,"Proof does not start at owner-signed v1");
  require(item.signature.size()==crypto_sign_BYTES&&crypto_sign_verify_detached(item.signature.data(),canonical.data(),canonical.size(),publicKey->data())==0,MembershipErrorCode::invalidSignature,"Membership signature rejected");
  previousDigest=membershipDigest(canonical);
  if(old&&item.revision==old->statement().revision)retainedDigest=*previousDigest;
  previous=&item;
 };
 if(statement.history)for(const auto& item:*statement.history)verifyItem(item);
 verifyItem(statement);
 if(old){
  require(old->anchor()==*this&&statement.revision>=old->statement().revision,MembershipErrorCode::rollback,"Membership replacement rolls back or changes anchor");
  if(statement.version==2)require(retainedDigest&&*retainedDigest==old->digest(),MembershipErrorCode::equivocation,"Replacement forks retained history");
  else if(statement.revision==old->statement().revision)require(bytes==old->canonicalBytes(),MembershipErrorCode::equivocation,"Conflicting owner snapshot at same revision");
 }
 return VerifiedMembership(*this,statement,std::move(bytes),*previousDigest);
}
VerifiedMembership::VerifiedMembership(MembershipAnchor anchor,SignedMembership statement,Data canonical,Key digest):pinned(std::move(anchor)),value(std::move(statement)),bytes(std::move(canonical)),hash(digest){}
const GroupMember& VerifiedMembership::member(const Id& device)const{const auto* found=findMember(value,device);require(found,MembershipErrorCode::notMember,"Device is absent from verified membership");return *found;}
Trust VerifiedMembership::trust(MembershipDomain domain)const{
 const auto required=static_cast<uint8_t>(domain);require(required==1||required==2,MembershipErrorCode::malformed,"Unknown sync domain");
 Trust result;result.group=value.group;result.epoch=value.epoch;
 for(const auto& item:value.members)if((item.permissions&required)==required)result.members.emplace(item.device,item.signingPublic);
 return result;
}
}
