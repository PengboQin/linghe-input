#pragma once
#include "ClipboardLiveProtocol.h"
namespace private_input::activity {
struct ClipboardLiveBatch {std::vector<Json>fresh;bool cold=false;};
// One writer, independent encrypted file. Its cursor/receipts never enter the
// original ContentStore FIFO, nextSequence, ACK path or replay ledger.
class ClipboardLiveStore {
 Json state;std::function<void(const Json&)>persist;
 void save(const Json&);bool receive(Json&,const ClipboardLiveOpened&,uint64_t now);
public:
 ClipboardLiveStore(Json,std::function<void(const Json&)>);
 void configure(const ClipboardLiveGrant&);bool ready()const{return state.at("ready").boolean();}
 uint64_t cursor()const{return state.at("cursor").num();}const Json&current()const{return state;}
 Json pending(uint64_t now);void stage(const ClipboardLiveGrant&,const std::string&,uint64_t now,const Json&context=Json());
 ClipboardLiveBatch apply(const ClipboardLiveGrant&,const Json&response,const Json&published,uint64_t now);
 bool importLegacy(const ClipboardLiveGrant&,const Json&wire,uint64_t now,bool mayApply,Json*value=nullptr);
 std::vector<Json>compatibility(uint64_t now)const;void compatibilityQueued(const Id&event);
 void fallbackToCompatibility(uint64_t now);void clearPending(bool clearTexts=false);
 bool knows(const Id&sender,const Id&event)const;
 static Json initial();
};
}
