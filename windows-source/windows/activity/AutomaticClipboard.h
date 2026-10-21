#pragma once
#include "ArchiveCore.h"
#include <optional>
namespace private_input::activity {
inline bool clipboardApplyFence(bool active,uint64_t currentGeneration,uint64_t expectedGeneration,uint64_t currentLocalSerial,uint64_t expectedLocalSerial,uint32_t currentSequence,uint32_t expectedSequence,bool pending,bool verifiedEmptySequence=false){return active&&!pending&&currentGeneration==expectedGeneration&&currentLocalSerial==expectedLocalSerial&&currentSequence==expectedSequence&&(currentSequence!=0||verifiedEmptySequence);}
inline bool clipboardEchoFence(uint32_t sequence,uint32_t ownSequence,bool sameHash,bool knownOwnMarker){return sameHash&&((sequence!=0&&sequence==ownSequence)||knownOwnMarker);}
// Clipboard ordering is local observation/relay delivery order, never a claim
// that independent device wall clocks establish a reliable global order.
class AutomaticClipboard {
 Json state;std::function<void(const Json&)>persist;bool sharing=false,armed=false;
 void save(const Json&next);
public:
 AutomaticClipboard(Json,std::function<void(const Json&)>);
 const Json&current()const{return state;}
 bool enabled()const{return state.at("enabled").boolean();}
 bool active()const{return enabled()&&sharing&&!state.at("group").str().empty();}
 bool ready()const{return active()&&armed;}
 bool configure(const std::string&group,uint64_t epoch,const std::string&personal,bool shared);
 void setEnabled(bool);
 // Call for newly durably received envelopes only. Cold-start draining marks
 // them seen without writing the OS clipboard until a complete empty pull.
 std::optional<Json> observe(const std::vector<Json>&newItems,bool drained,bool localActivity,const std::string&self);
};
}
