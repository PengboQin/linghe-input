#pragma once
#include "DecisionDiagnostic.h"
#include <vector>
#include <optional>
namespace private_input::activity {
// Small plain values frozen on TSF; JSON construction belongs to pipe worker.
struct DecisionLink {std::string composition,decision,state;bool empty()const{return composition.empty();}Json json()const{auto j=Json::object();if(!composition.empty())j["composition_id"]=composition;if(!decision.empty())j["decision_id"]=decision;if(!state.empty())j["state_id"]=state;return j;}};
struct DecisionCandidate {std::string id,text,reading;uint64_t rank=0;Json json()const{auto j=Json::object({{"candidate_id",id},{"text",text},{"absolute_rank",rank},{"source","unknown"}});if(!reading.empty())j["reading"]=reading;return j;}};
struct DecisionCapture {
 DecisionLink link;std::string clock,stage="selection",method="unknown",reason,before,after,key,snapshot,markedText,markedStatus;
 uint64_t revision=0,monotonicUS=0,pressUS=0,releaseUS=0;std::string pressState,releaseState,selectedID;std::optional<uint64_t>selectedRank;
 bool legacyOnly=false,includePreview=true;std::vector<DecisionCandidate>preview;std::optional<DecisionCandidate>selected;bool truncated=true;
 Json json()const{if(legacyOnly)return Json::object({{"action","key"},{"key",key},{"raw_before",before},{"raw_after",after},{"committed",false}});auto d=Json::object({{"version",1},{"composition_id",link.composition},{"revision",revision},{"state_id",link.state},{"stage",stage},{"clock_domain",clock},{"monotonic_us",monotonicUS},{"method",method}});if(!link.decision.empty())d["decision_id"]=link.decision;if(!snapshot.empty())d["snapshot_id"]=snapshot;if(!markedStatus.empty()){d["marked_text"]=markedText;d["marked_status"]=markedStatus;}if(!reason.empty())d["reason"]=reason;if(!pressState.empty())d["press_state_id"]=pressState;if(!releaseState.empty())d["release_state_id"]=releaseState;if(pressUS)d["press_monotonic_us"]=pressUS;if(releaseUS)d["release_monotonic_us"]=releaseUS;if(selected)d["selected_candidate"]=selected->json();if(!selectedID.empty())d["selected_candidate_id"]=selectedID;if(selectedRank)d["selected_rank"]=*selectedRank;if(includePreview){std::vector<Json>rows;for(auto&c:preview)rows.push_back(c.json());d["candidates"]=Json::array(std::move(rows));d["observed_count"]=uint64_t(preview.size());d["coverage"]="published_subset";d["truncated"]=truncated;}require(validDecisionDiagnostic(d),"decision diagnostic shape");return Json::object({{"action","choose"},{"key",key},{"raw_before",before},{"raw_after",after},{"committed",false},{"decision",d}});}
};
}
