#pragma once
#include <array>
#include <vector>
#include <map>
#include <tuple>
#include <cstdint>
namespace private_input::protocol {
using Id=std::array<unsigned char,16>;
using Key=std::array<unsigned char,32>;
using Data=std::vector<unsigned char>;
struct Envelope {Id group{},sender{},event{};uint64_t epoch=0,sequence=0,issuedAt=0,expiresAt=0;unsigned char domain=0;Data ciphertext,signature;};
// Obtain product trust from MembershipAnchor::verify(...).trust(domain).
// Typed membership is implemented; relay JSON, storage transactions and product
// integration are pending. An arbitrary caller-created map is not an authority.
struct Trust {Id group{};uint64_t epoch=0;std::map<Id,Key> members;};
struct Window {uint64_t highest=0,bitmap=0;};
using Ledger=std::map<std::tuple<Id,uint64_t,Id>,Window>;
struct Opened {Data payload;Ledger ledger;};
Data header(const Envelope& message);
Envelope sealOpaquePayload(const Data& payload,Envelope metadata,const Key& master,const Key& signingSeed,const Trust& trust);
Opened openOpaquePayload(const Envelope& message,const Key& master,const Trust& trust,const Ledger& ledger,uint64_t now);
// Learning archives still require semantic validation before transactional apply.
}
