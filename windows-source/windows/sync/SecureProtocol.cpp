#include "SecureProtocol.h"
#include <sodium.h>
#include <stdexcept>
#include <algorithm>
#include <cstring>
namespace private_input::protocol {namespace {
void require(bool value,const char* reason){if(!value)throw std::runtime_error(reason);}
template<size_t N> struct Secret {std::array<unsigned char,N> bytes{};~Secret(){sodium_memzero(bytes.data(),N);}};
void be(Data& data,uint64_t value){for(int shift=56;shift>=0;shift-=8)data.push_back((value>>shift)&255);}
template<class T> void append(Data& into,const T& source){into.insert(into.end(),source.begin(),source.end());}
void init(){require(sodium_init()>=0,"Crypto initialization failed");}
std::array<unsigned char,12> nonce(uint64_t sequence){std::array<unsigned char,12> value{};for(int i=0;i<8;++i)value[4+i]=(sequence>>(56-i*8))&255;return value;}
Secret<32> derive(const Envelope& message,const Key& master,const Key& publicKey){
 Data salt;append(salt,message.group);be(salt,message.epoch);
 const char label[]="PrivateInput/sender-domain-key/v1";Data info(label,label+sizeof(label));append(info,message.sender);append(info,publicKey);info.push_back(message.domain);
 Secret<32> prk,key;require(crypto_kdf_hkdf_sha256_extract(prk.bytes.data(),salt.data(),salt.size(),master.data(),master.size())==0,"HKDF extraction failed");
 require(crypto_kdf_hkdf_sha256_expand(key.bytes.data(),32,reinterpret_cast<const char*>(info.data()),info.size(),prk.bytes.data())==0,"HKDF expansion failed");return key;
}
void validate(const Data& payload,unsigned char domain){
 require(!payload.empty()&&payload.size()<=(domain==2?65536:2097152),"Invalid payload bound");
 if(domain!=2)return;
 for(size_t i=0;i<payload.size();){
  auto c=payload[i++];require(c!=0,"NUL text rejected");if(c<128)continue;
  uint32_t code;int count;uint32_t minimum;
  if(c>=0xc2&&c<=0xdf){code=c&31;count=1;minimum=0x80;}
  else if(c>=0xe0&&c<=0xef){code=c&15;count=2;minimum=0x800;}
  else if(c>=0xf0&&c<=0xf4){code=c&7;count=3;minimum=0x10000;}
  else throw std::runtime_error("Invalid UTF-8 leader");
  require(i+count<=payload.size(),"Truncated UTF-8");while(count--){auto next=payload[i++];require((next&0xc0)==0x80,"Invalid UTF-8 continuation");code=(code<<6)|(next&63);}
  require(code>=minimum&&code<=0x10ffff&&!(code>=0xd800&&code<=0xdfff),"Invalid Unicode scalar");
 }
}
const Key& member(const Envelope& message,const Trust& trust){
 require(message.group==trust.group&&message.epoch==trust.epoch,"Wrong group or epoch");auto found=trust.members.find(message.sender);require(found!=trust.members.end(),"Untrusted sender");return found->second;
}
}
Data header(const Envelope& message){
 require(message.epoch&&message.sequence&&(message.domain==1||message.domain==2)&&message.expiresAt>message.issuedAt&&message.expiresAt-message.issuedAt<=(message.domain==2?600:604800),"Invalid envelope metadata");
 require(message.ciphertext.size()<=(message.domain==2?65536:2097152)+16,"Invalid ciphertext bound");
 const char label[]="PrivateInput/event/v1";Data result(label,label+sizeof(label));result.push_back(1);
 append(result,message.group);append(result,message.sender);append(result,message.event);be(result,message.epoch);be(result,message.sequence);result.push_back(message.domain);be(result,message.issuedAt);be(result,message.expiresAt);return result;
}
Envelope sealOpaquePayload(const Data& payload,Envelope message,const Key& master,const Key& seed,const Trust& trust){
 init();validate(payload,message.domain);Key publicKey{};Secret<64> signing;
 require(crypto_sign_seed_keypair(publicKey.data(),signing.bytes.data(),seed.data())==0,"Signing key failed");require(member(message,trust)==publicKey,"Sender key changed");
 message.ciphertext.clear();message.signature.clear();const auto aad=header(message);auto key=derive(message,master,publicKey);auto n=nonce(message.sequence);
 message.ciphertext.resize(payload.size()+16);unsigned long long size=0;
 require(crypto_aead_chacha20poly1305_ietf_encrypt(message.ciphertext.data(),&size,payload.data(),payload.size(),aad.data(),aad.size(),nullptr,n.data(),key.bytes.data())==0&&size==message.ciphertext.size(),"Encryption failed");
 Data authenticated=aad;append(authenticated,message.ciphertext);message.signature.resize(64);
 require(crypto_sign_detached(message.signature.data(),nullptr,authenticated.data(),authenticated.size(),signing.bytes.data())==0,"Signature failed");return message;
}
Opened openOpaquePayload(const Envelope& message,const Key& master,const Trust& trust,const Ledger& ledger,uint64_t now){
 init();const auto aad=header(message);const auto& signer=member(message,trust);Data authenticated=aad;append(authenticated,message.ciphertext);
 require(message.signature.size()==64&&crypto_sign_verify_detached(message.signature.data(),authenticated.data(),authenticated.size(),signer.data())==0,"Signature rejected");
 require(now<message.expiresAt&&(message.issuedAt<=now||message.issuedAt-now<=300),"Message expired or future-dated");
 auto next=ledger;auto id=std::make_tuple(message.group,message.epoch,message.sender);auto found=next.find(id);
 if(found==next.end())next[id]={message.sequence,1};else{
  auto& window=found->second;
  if(message.sequence>window.highest){auto distance=message.sequence-window.highest;window.bitmap=distance>=64?1:(window.bitmap<<distance)|1;window.highest=message.sequence;}
  else{auto distance=window.highest-message.sequence;require(distance<64&&!(window.bitmap&(uint64_t(1)<<distance)),"Replay rejected");window.bitmap|=uint64_t(1)<<distance;}
 }
 require(message.ciphertext.size()>=16,"Truncated ciphertext");auto key=derive(message,master,signer);auto n=nonce(message.sequence);Data payload(message.ciphertext.size()-16);unsigned long long size=0;
 require(crypto_aead_chacha20poly1305_ietf_decrypt(payload.data(),&size,nullptr,message.ciphertext.data(),message.ciphertext.size(),aad.data(),aad.size(),n.data(),key.bytes.data())==0&&size==payload.size(),"Decryption failed");validate(payload,message.domain);
 return {std::move(payload),std::move(next)};
}
}
