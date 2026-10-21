#pragma once
#include "Json.h"
#include "SourceContext.h"
#include "../sync/SecureProtocol.h"
#include <functional>
#include <filesystem>
#include <memory>
namespace private_input::activity {
using protocol::Id;using protocol::Key;using protocol::Data;
std::string uuidText(const Id&);Id parseId(std::string_view);Id newId();
std::string base64(const Data&);Data unbase64(const std::string&,size_t exact=0);
Key sha256(const Data&);Key publicKey(const Key& seed);Data sign(const Data&,const Key&seed);
void append(Data&,const Data&);void be64(Data&,uint64_t);Data bytes(std::string_view);
Json signedEnvelope(const Id&group,const Id&device,const Key&seed,uint8_t op,const Json&body,uint64_t now,bool archive=true);
std::string timestamp(uint64_t unixSeconds);uint64_t unixTime();
struct EventContext {Id group{},device{},installation{};uint64_t consent=0;std::string session,editor;SourceContext source;Json deviceDescription;};
Json makeEvent(const EventContext&,uint64_t seq,std::string provider,std::string type,std::string text,uint64_t now,const std::string&source="ime_output");
struct QueuedEvent {std::string id,encoded;uint64_t generation=0,sequence=0;Json event;};
class Queue {
public:
 struct Impl;
private:
 std::unique_ptr<Impl>p;
public:
 using Codec=std::function<std::string(const std::string&)>;
 Queue(const std::filesystem::path&,Codec protect,Codec unprotect);~Queue();
 Queue(const Queue&)=delete;
 uint64_t configure(const std::string&group,uint64_t consent,bool enabled);
 bool enqueue(const EventContext&,const std::string&provider,const std::string&type,const std::string&text,uint64_t now,const std::string&source="ime_output");
 std::vector<QueuedEvent> batch(size_t limit=64,size_t bytes=400000);
 void acknowledge(const std::vector<QueuedEvent>&sent,const Json&response,const std::string&batchID);
 void disable();void clear();size_t heldCount();size_t count();uint64_t generation();uint64_t dropped();
};
}
