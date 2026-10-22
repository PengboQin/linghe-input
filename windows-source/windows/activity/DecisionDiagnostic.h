#pragma once
#include "Json.h"
#include <algorithm>
#include <set>
namespace private_input::activity {
inline bool decisionTag(const Json&j){return j.kind==Json::Kind::string&&!j.text.empty()&&j.text.size()<=96&&std::all_of(j.text.begin(),j.text.end(),[](unsigned char c){return c>=33&&c<=126;});}
inline bool decisionNumber(const Json&j){return j.kind==Json::Kind::number&&j.integer<=9007199254740991ULL;}
inline bool decisionText(const Json&j){if(j.kind!=Json::Kind::string||j.text.size()>256)return false;try{validateUtf8(j.text);return true;}catch(...){return false;}}
inline bool decisionCandidate(const Json&c){if(c.kind!=Json::Kind::object)return false;for(auto*k:{"candidate_id","text","absolute_rank","source"})if(!c.has(k))return false;for(auto&p:c.fields)if(p.first!="candidate_id"&&p.first!="text"&&p.first!="reading"&&p.first!="absolute_rank"&&p.first!="source")return false;static const std::set<std::string>sources={"exact","public","personal","cloud","correction","semantic","literal","unknown"};return decisionTag(c.at("candidate_id"))&&decisionText(c.at("text"))&&decisionNumber(c.at("absolute_rank"))&&c.at("source").kind==Json::Kind::string&&sources.count(c.at("source").text)&&(!c.has("reading")||decisionText(c.at("reading")));}
inline bool validDecisionLink(const Json&j){if(j.kind!=Json::Kind::object||j.fields.empty())return false;for(auto&p:j.fields)if((p.first!="composition_id"&&p.first!="decision_id"&&p.first!="state_id")||!decisionTag(p.second))return false;return true;}
inline bool validDecisionDiagnostic(const Json&v){try{
 static const std::set<std::string>required={"version","composition_id","revision","state_id","stage","clock_domain","monotonic_us"};
 static const std::set<std::string>ids={"composition_id","state_id","clock_domain","snapshot_id","decision_id","press_state_id","release_state_id","selected_candidate_id","output_event_id","related_decision_id"};
 static const std::set<std::string>hashes={"core_hash","resource_hash","policy_hash","model_hash"};
 static const std::set<std::string>counts={"revision","monotonic_us","total_count","observed_count","selected_rank","recall_count","filtered_count","press_monotonic_us","release_monotonic_us"};
 static const std::set<std::string>extra={"candidates","selected_candidate","truncated","coverage","method","reason","model_version","local_overlay","filter_reason_counts","label_source","intended_text","marked_text","marked_status"};
 static const std::set<std::string>stages={"input","candidates","press","release","selection","commit","cancel","feedback","error","marked_text"};
 if(v.kind!=Json::Kind::object)return false;for(auto&k:required)if(!v.has(k))return false;
 if(v.at("version").kind!=Json::Kind::number||v.at("version").integer!=1||v.at("stage").kind!=Json::Kind::string||!stages.count(v.at("stage").text))return false;
 for(auto&p:v.fields){auto&k=p.first;auto&j=p.second;if(!required.count(k)&&!ids.count(k)&&!hashes.count(k)&&!counts.count(k)&&!extra.count(k))return false;
  if(ids.count(k)&&!decisionTag(j))return false;if(counts.count(k)&&!decisionNumber(j))return false;
  if(hashes.count(k)&&(j.kind!=Json::Kind::string||j.text.size()!=64||!std::all_of(j.text.begin(),j.text.end(),[](char c){return (c>='0'&&c<='9')||(c>='a'&&c<='f');})))return false;
  if((k=="reason"||k=="model_version")&&!decisionTag(j))return false;
  if((k=="truncated"||k=="local_overlay")&&j.kind!=Json::Kind::boolean)return false;
 }
 if(v.has("method")){static const std::set<std::string>s={"touch","mouse","space","number","enter","gesture","unknown"};if(v.at("method").kind!=Json::Kind::string||!s.count(v.at("method").text))return false;}
 if(v.has("label_source")){static const std::set<std::string>s={"user_confirmed","weak_signal","synthetic"};if(v.at("label_source").kind!=Json::Kind::string||!s.count(v.at("label_source").text))return false;}
 if(v.has("marked_text")){auto&m=v.at("marked_text");if(m.kind!=Json::Kind::string||m.text.size()>4096)return false;validateUtf8(m.text);}
 if(v.has("marked_status")){static const std::set<std::string>s={"not_used","insert_requested","host_acknowledged","host_rejected","unknown"};if(v.at("marked_status").kind!=Json::Kind::string||!s.count(v.at("marked_status").text))return false;}
 if(v.has("intended_text")&&(v.at("stage").text!="feedback"||!v.has("label_source")||!decisionText(v.at("intended_text"))))return false;
 if(v.has("filter_reason_counts")){auto&r=v.at("filter_reason_counts");if(r.kind!=Json::Kind::object||r.fields.size()>8)return false;for(auto&p:r.fields)if(!decisionTag(Json(p.first))||!decisionNumber(p.second))return false;}
 if(v.has("selected_candidate")){auto&c=v.at("selected_candidate");if(!decisionCandidate(c))return false;if(v.has("selected_candidate_id")&&v.at("selected_candidate_id").str()!=c.at("candidate_id").str())return false;if(v.has("selected_rank")&&v.at("selected_rank").num()!=c.at("absolute_rank").num())return false;}
 if(v.has("candidates")){auto&rows=v.at("candidates");if(rows.kind!=Json::Kind::array||rows.items.size()>5||!v.has("observed_count")||v.at("observed_count").num()!=rows.items.size()||!v.has("coverage")||!v.has("truncated"))return false;auto coverage=v.at("coverage").str();if(coverage!="published_subset"&&coverage!="visible_subset"&&coverage!="complete_set")return false;auto truncated=v.at("truncated").boolean();std::set<std::string>seen;std::set<uint64_t>ranks;
  for(auto&c:rows.items){if(!decisionCandidate(c)||!seen.insert(c.at("candidate_id").str()).second||!ranks.insert(c.at("absolute_rank").num()).second)return false;if(v.has("total_count")&&c.at("absolute_rank").num()>=v.at("total_count").num())return false;}
  if(v.has("total_count")){auto total=v.at("total_count").num();if(total<rows.items.size()||(!truncated&&total>rows.items.size())||(coverage=="complete_set"&&total!=rows.items.size()))return false;}if(coverage=="complete_set"&&truncated)return false;
 }else if(v.has("total_count")||v.has("observed_count")||v.has("coverage")||v.has("truncated"))return false;
 return true;
 }catch(...){return false;}}
inline bool validDecisionEnvelope(const Json&e){try{if(!e.has("extensions"))return true;auto&ext=e.at("extensions");if(ext.has("org.linghe.decision-link.v1")){auto type=e.at("event_type").str();if(type!="input_commit"&&type!="paste_action"&&type!="text_revise"&&type!="text_retract")return false;if(!validDecisionLink(ext.at("org.linghe.decision-link.v1")))return false;}
 if(ext.has("org.linghe.decision.v1")||ext.has("org.linghe.input.v1")){if(e.at("provider_id").str()!="ime.diagnostic.v1"||e.at("event_type").str()!="source_import"||e.at("source_kind").str()!="ime_diagnostic"||e.at("commit_confirmation").str()!="not_applicable")return false;}
 return !ext.has("org.linghe.decision.v1")||validDecisionDiagnostic(ext.at("org.linghe.decision.v1"));}catch(...){return false;}}
}
