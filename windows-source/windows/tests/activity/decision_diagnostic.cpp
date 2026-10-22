#include "../../activity/DecisionCapture.h"
#include "../../activity/DecisionOutput.h"
#include "../../activity/ArchiveCore.h"
#include "../../activity/CaptureWire.h"
#include <cassert>
#include <cstdlib>
static unsigned checks=0;
#define CHECK(value) do{++checks;if(!(value))std::abort();}while(false)
#include <fstream>
#include <iostream>
#include <sstream>
using namespace private_input::activity;
int main(int argc,char**argv){CHECK(argc==3);std::ifstream f(argv[1]);std::stringstream in;in<<f.rdbuf();auto cases=Json::parse(in.str());size_t count=0;
 for(const auto&c:cases.items){bool valid=false;try{valid=validDecisionEnvelope(Json::parse(c.at("event_json").str()));}catch(...){}if(valid!=c.at("valid").boolean()){std::cerr<<"golden mismatch "<<c.at("name").str()<<"\n";return 2;}++count;}
 CHECK(count>=46);
 DecisionCapture d;d.link={"composition-synthetic","decision-synthetic","state-synthetic"};d.clock="clock-synthetic";d.revision=3;d.monotonicUS=12;d.pressUS=10;d.releaseUS=12;d.pressState=d.releaseState="state-synthetic";d.before="444";d.after="44";d.key="space";d.method="space";d.markedText="GHI";d.markedStatus="insert_requested";d.preview={{"candidate-0","合成候选","he cheng hou xuan",0}};d.selected=DecisionCandidate{"candidate-31","独立合成候选","du li he cheng hou xuan",31};
 auto payload=d.json();CHECK(validDecisionDiagnostic(payload.at("decision")));
 EventContext c;c.group=newId();c.device=newId();c.installation=newId();c.consent=1;c.session="session-synthetic";c.editor="epoch-synthetic";
 auto event=makeEvent(c,1,"ime.diagnostic.v1","source_import",payload.dump(),1792540800,"ime_diagnostic");CHECK(validDecisionEnvelope(event));CHECK(event.at("content").at("text").str()=="44");CHECK(!event.at("extensions").at("org.linghe.input.v1").has("decision"));CHECK(event.at("extensions").at("org.linghe.decision.v1").at("selected_candidate").at("absolute_rank").num()==31);
 auto link=d.link.json();for(auto flags:{0,1,2,3,4,5,6}){auto packet=decisionOutputPacket("raw\ntext",link,flags&1,flags&2,flags&4);CHECK(packet.kind==1&&packet.text=="raw\ntext");}auto packet=decisionOutputPacket("raw\ntext",link,true,true,true);CHECK(packet.kind==11&&Json::parse(packet.text).at("text").str()=="raw\ntext");CHECK(decisionOutputPacket(std::string(120000,'x'),link,true,true,true).kind==1);
 c.decisionLink=link;auto output=makeEvent(c,2,"ime.commit.v1","input_commit","实际合成输出",1792540800);CHECK(validDecisionEnvelope(output));CHECK(output.at("extensions").at("org.linghe.decision-link.v1").at("decision_id").str()=="decision-synthetic");c.decisionLink=Json();
 Queue q(argv[2],[](const std::string&s){return "synthetic:"+s;},[](const std::string&s){return s.substr(10);});CHECK(!q.enqueue(c,"ime.diagnostic.v1","source_import",payload.dump(),1792540800,"ime_diagnostic"));q.configure(uuidText(c.group),1,true);CHECK(q.enqueue(c,"ime.diagnostic.v1","source_import",payload.dump(),1792540800,"ime_diagnostic"));auto first=q.batch();CHECK(first.size()==1&&first[0].event.at("extensions").has("org.linghe.decision.v1"));q.configure(uuidText(c.group),2,true);CHECK(!q.enqueue(c,"ime.diagnostic.v1","source_import",payload.dump(),1792540800,"ime_diagnostic"));CHECK(q.batch().empty());c.consent=2;CHECK(q.enqueue(c,"ime.diagnostic.v1","source_import",payload.dump(),1792540800,"ime_diagnostic"));q.disable();CHECK(q.batch().empty());CHECK(!q.enqueue(c,"ime.diagnostic.v1","source_import",payload.dump(),1792540800,"ime_diagnostic"));
 CaptureHeader h;h.version=2;h.kind=11;h.utf16Count=1;CaptureContextWire context;std::string wire(sizeof(h)+2+sizeof(context),'\0');memcpy(wire.data(),&h,sizeof(h));memcpy(wire.data()+sizeof(h)+2,&context,sizeof(context));CaptureFrame decoded;CHECK(decodeCaptureFrame(wire.data(),wire.size(),decoded)&&sizeof(h)==88&&decoded.header.kind==11);wire.pop_back();CHECK(!decodeCaptureFrame(wire.data(),wire.size(),decoded));
 std::cout<<"PASS "<<count<<" shared golden cases + "<<checks<<" executed summary/marked/output/old-worker-fallback/consent/wire assertions\n";
}
