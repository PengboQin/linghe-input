#include "AutomaticClipboard.h"
namespace private_input::activity {
AutomaticClipboard::AutomaticClipboard(Json value,std::function<void(const Json&)>write):state(value.kind==Json::Kind::null?Json::object({{"version",1},{"enabled",false},{"group",""},{"epoch",0},{"personal",""},{"seen",Json::object()}}):std::move(value)),persist(std::move(write)){
 require(state.at("version").num()==1&&state.at("seen").fields.size()<=512&&state.dump().size()<=196608,"auto clipboard state bound");(void)state.at("enabled").boolean();
 if(!state.at("group").str().empty())(void)parseId(state.at("group").str());if(!state.at("personal").str().empty())(void)parseId(state.at("personal").str());
 for(const auto&entry:state.at("seen").fields){(void)parseId(entry.first);auto value=entry.second.str();require(value.size()==81&&value[36]==':',"auto clipboard receipt");(void)parseId(value.substr(0,36));(void)unbase64(value.substr(37),32);}
 // armed is intentionally not restored: an app restart must first baseline
 // this device and drain all old server recipients without applying them.
}
void AutomaticClipboard::save(const Json&next){require(next.dump().size()<=196608,"auto clipboard state bound");persist(next);state=next;}
bool AutomaticClipboard::configure(const std::string&group,uint64_t epoch,const std::string&personal,bool shared){
 if(!group.empty()){(void)parseId(group);require(epoch>0,"auto clipboard epoch");}(void)parseId(personal);
 const bool identity=state.at("group").str()!=group||state.at("personal").str()!=personal;
 if(!identity&&epoch<state.at("epoch").num())throw JsonError("auto clipboard epoch rollback");
 const bool changed=identity||state.at("epoch").num()!=epoch||sharing!=shared;
 auto next=state;if(identity){next["enabled"]=false;next["seen"]=Json::object();}else if(state.at("epoch").num()!=epoch)next["seen"]=Json::object();
 next["group"]=group;next["epoch"]=epoch;next["personal"]=personal;if(next.dump()!=state.dump())save(next);sharing=shared;if(changed)armed=false;return changed;
}
void AutomaticClipboard::setEnabled(bool enabled){if(this->enabled()==enabled)return;auto next=state;next["enabled"]=enabled;save(next);armed=false;}
std::optional<Json> AutomaticClipboard::observe(const std::vector<Json>&items,bool drained,bool localActivity,const std::string&self){
 if(!active())return {};const auto selfID=uuidText(parseId(self));auto next=state;std::optional<Json>candidate;const bool wasArmed=armed;
 for(const auto&item:items){auto event=uuidText(parseId(item.at("event").str())),sender=uuidText(parseId(item.at("sender").str())),text=item.at("text").str();validateUtf8(text);require(!text.empty()&&text.size()<=65536&&text.find('\0')==std::string::npos,"auto clipboard text bound");auto digest=sha256(bytes(text));auto hash=base64(Data(digest.begin(),digest.end()));
  auto identity=sender+":"+hash;auto&seen=next["seen"];if(seen.has(event)){require(seen.at(event).str()==identity,"auto clipboard event equivocation");continue;}
  if(seen.fields.size()>=512)seen.fields.erase(seen.fields.begin());seen[event]=identity;
  if(wasArmed&&!localActivity&&sender!=selfID)candidate=Json::object({{"event",event},{"sender",sender},{"hash",hash},{"text",text}});
 }
 if(next.dump()!=state.dump())save(next);if(drained&&items.empty())armed=true;return candidate;
}
}
