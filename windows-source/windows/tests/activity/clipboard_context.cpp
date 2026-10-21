#include "../../activity/AutomaticClipboard.h"
#include "../../activity/SourceContext.h"
#ifdef _WIN32
#include "../../activity/SourceContextWin.h"
#endif
#include <iostream>
#include <cstring>
using namespace private_input::activity;
namespace {unsigned checks=0;void check(bool condition){++checks;if(!condition)throw std::runtime_error("clipboard/context check "+std::to_string(checks));}template<class F>void reject(F f){bool failed=false;try{f();}catch(...){failed=true;}check(failed);}
Json message(const std::string&sender,const std::string&text){return Json::object({{"event",uuidText(newId())},{"sender",sender},{"text",text}});}
void label(char*out,uint16_t&length,const std::string&text){std::memcpy(out,text.c_str(),text.size()+1);length=uint16_t(text.size());}
std::string frame(CaptureHeader h,const CaptureContextWire*context=nullptr){std::string bytes(sizeof(h)+h.utf16Count*2+(context?sizeof(*context):0),0);std::memcpy(bytes.data(),&h,sizeof(h));if(context)std::memcpy(bytes.data()+sizeof(h)+h.utf16Count*2,context,sizeof(*context));return bytes;}
}
int main(){
 Json disk;bool fail=false;auto persist=[&](const Json&next){if(fail)throw JsonError("synthetic disk failure");disk=next;};
 auto group=uuidText(newId()),personal=uuidText(newId()),self=uuidText(newId()),peer=uuidText(newId());AutomaticClipboard automatic({},persist);
 automatic.configure(group,1,personal,true);check(!automatic.enabled()&&!automatic.active());automatic.setEnabled(true);check(automatic.active()&&!automatic.ready());
 auto old=message(peer,"old server backlog");check(!automatic.observe({old},false,false,self));check(!automatic.ready());check(!automatic.observe({},false,false,self));check(!automatic.ready());check(!automatic.observe({},true,false,self));check(automatic.ready());
 auto fresh=message(peer,"new remote copy");auto selected=automatic.observe({fresh},true,false,self);check(selected&&selected->at("text").str()=="new remote copy");check(!automatic.observe({fresh},true,false,self));
 auto equivalent=fresh;equivalent["text"]="tampered duplicate";reject([&]{automatic.observe({equivalent},true,false,self);});check(!automatic.observe({message(self,"self echo")},true,false,self));
 auto racing=message(peer,"late while local copied");check(!automatic.observe({racing},true,true,self));check(!automatic.observe({racing},true,false,self));
 check(clipboardApplyFence(true,7,7,4,4,100,100,false));check(!clipboardApplyFence(true,7,7,5,4,100,100,false));check(!clipboardApplyFence(true,7,7,4,4,101,100,false));check(!clipboardApplyFence(true,7,7,4,4,100,100,true));check(!clipboardApplyFence(true,8,7,4,4,100,100,false));check(!clipboardApplyFence(false,7,7,4,4,100,100,false));
 check(clipboardEchoFence(100,100,true,false));check(clipboardEchoFence(101,100,true,true));check(!clipboardEchoFence(101,100,true,false));check(!clipboardEchoFence(100,100,false,true));
 automatic.setEnabled(false);check(!automatic.active()&&!automatic.observe({message(peer,"revoked")},true,false,self));automatic.setEnabled(true);check(!automatic.ready());check(!automatic.observe({message(peer,"enable baseline")},true,false,self));check(!automatic.ready());automatic.observe({},true,false,self);check(automatic.ready());
 automatic.configure(group,1,personal,false);check(automatic.enabled()&&!automatic.active());automatic.configure(group,1,personal,true);check(!automatic.ready());automatic.observe({},true,false,self);
 auto before=disk.dump();auto pending=message(peer,"must persist before OS apply");fail=true;reject([&]{automatic.observe({pending},true,false,self);});check(disk.dump()==before);fail=false;check(automatic.observe({pending},true,false,self).has_value());
 AutomaticClipboard restarted(disk,persist);restarted.configure(group,1,personal,true);check(!restarted.ready());check(!restarted.observe({message(peer,"restart server backlog")},false,false,self));check(!restarted.observe({},true,false,self));check(restarted.ready());
 restarted.configure(group,2,personal,true);check(!restarted.ready()&&restarted.enabled());reject([&]{restarted.configure(group,1,personal,true);});restarted.configure(group,2,uuidText(newId()),true);check(!restarted.enabled());
 automatic.configure(uuidText(newId()),1,personal,true);check(!automatic.enabled());automatic.setEnabled(true);automatic.observe({},true,false,self);reject([&]{automatic.observe({message(peer,std::string(65537,'x'))},true,false,self);});reject([&]{automatic.observe({message(peer,std::string("x\0y",3))},true,false,self);});
 CaptureHeader header;header.utf16Count=2;CaptureFrame decoded;auto legacy=frame(header);check(sizeof(header)==88&&decodeCaptureFrame(legacy.data(),legacy.size(),decoded)&&!decoded.hasContext);SourceContext legacySource;legacySource.captureComponent="input_method";auto legacyMeta=sourceContextJSON(legacySource);check(legacyMeta.at("input_method_version").str()=="unavailable"&&legacyMeta.at("source_app_id").kind==Json::Kind::null);
 CaptureContextWire wire;label(wire.app,wire.appBytes,"OriginalHost.exe");label(wire.name,wire.nameBytes,"Original Host");label(wire.version,wire.versionBytes,"0.4.4");label(wire.build,wire.buildBytes,"1");wire.provenance=1;wire.field=1;wire.layout=1;header.version=2;auto packet=frame(header,&wire);check(decodeCaptureFrame(packet.data(),packet.size(),decoded)&&decoded.hasContext);auto original=sourceContextFromWire(decoded.context);label(wire.app,wire.appBytes,"Worker.exe");check(original.identifier=="OriginalHost.exe");
 EventContext c;c.group=newId();c.device=newId();c.installation=newId();c.consent=1;c.source=original;auto archived=makeEvent(c,1,"ime.commit.v1","input_commit","synthetic",unixTime());check(archived.at("source_app").str()=="OriginalHost.exe");const auto&meta=archived.at("extensions").at("org.linghe.context.v1");check(meta.at("source_app_id").str()=="OriginalHost.exe"&&meta.at("source_app_name").str()=="Original Host"&&meta.at("app_identity_status").str()=="available"&&meta.at("layout").str()=="pinyin_qwerty");
 c.source.identifier="C:\\Example\\User\\Worker.exe";check(makeEvent(c,2,"ime.commit.v1","input_commit","synthetic",unixTime()).at("source_app").kind==Json::Kind::null);
 c.source={};c.source.identifier="Owner.exe";c.source.captureComponent="clipboard_observer";c.source.provenance="clipboard_owner";auto clip=makeEvent(c,3,"clipboard.observed.v1","clipboard_observed","synthetic",unixTime(),"clipboard");check(clip.at("extensions").at("org.linghe.context.v1").at("app_identity_status").str()=="identifier_only");
 auto bad=packet;bad.pop_back();check(!decodeCaptureFrame(bad.data(),bad.size(),decoded));bad=packet;reinterpret_cast<CaptureHeader*>(bad.data())->version=99;check(!decodeCaptureFrame(bad.data(),bad.size(),decoded));header.version=2;header.kind=3;bad=frame(header,&wire);check(!decodeCaptureFrame(bad.data(),bad.size(),decoded));header.version=1;bad=frame(header);check(decodeCaptureFrame(bad.data(),bad.size(),decoded));
 wire.app[0]='\\';bad=frame(CaptureHeader{CaptureMagic,2,1,1,0},&wire);check(!decodeCaptureFrame(bad.data(),bad.size(),decoded));wire.app[0]='O';wire.name[0]=char(0xff);reject([&]{sourceContextFromWire(wire);});
#ifdef _WIN32
 auto basename=sourceFromProcessPath(L"C:\\Example\\User\\RealHost.exe",false);check(captureWireString(basename.app,basename.appBytes)=="RealHost.exe");auto host=sourceForCurrentHost();check(host.appBytes>0&&captureWireString(host.app,host.appBytes).find('\\')==std::string::npos);
#endif
 std::cout<<"clipboard/context isolated checks passed: "<<checks<<"; default off, cold drain, echo, local race, pending/revocation, restart, epoch rollback, durable failure, original host and v1/v2 bounds\n";
}
