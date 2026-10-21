#include "../../activity/ArchiveCore.h"
#include "../../activity/CaptureWire.h"
#include <cassert>
#include <filesystem>
#include <iostream>
using namespace private_input::activity;
int main(int argc,char**argv){assert(argc==2);std::filesystem::path path=argv[1];assert(!std::filesystem::exists(path));
EventContext c;c.group=newId();c.device=newId();c.installation=newId();c.consent=1;c.session="synthetic-session";c.editor="synthetic-editor";c.deviceDescription=Json::object({{"platform","windows"},{"model","synthetic"}});
auto detail=Json::object({{"action","key"},{"key","8"},{"raw_before","444"},{"raw_after",""},{"committed",false}});
auto row=makeEvent(c,1,"ime.diagnostic.v1","source_import",detail.dump(),1792540800,"ime_diagnostic");assert(row.at("content").at("text").str().empty());assert(row.at("event_type").str()=="source_import");assert(row.at("commit_confirmation").str()=="not_applicable");assert(!row.at("extensions").at("org.linghe.input.v1").at("committed").boolean());assert(row.at("extensions").at("org.linghe.device.v1").at("model").str()=="synthetic");
{Queue q(path,[](const std::string&s){return "synthetic:"+s;},[](const std::string&s){assert(s.substr(0,10)=="synthetic:");return s.substr(10);});assert(!q.enqueue(c,"ime.diagnostic.v1","source_import",detail.dump(),1792540800,"ime_diagnostic"));q.configure(uuidText(c.group),1,true);assert(q.enqueue(c,"ime.diagnostic.v1","source_import",detail.dump(),1792540800,"ime_diagnostic"));auto batch=q.batch();assert(batch.size()==1&&batch[0].event.at("content").at("text").str().empty());q.disable();assert(q.batch().empty());assert(!q.enqueue(c,"ime.diagnostic.v1","source_import",detail.dump(),1792540800,"ime_diagnostic"));}
CaptureHeader h;h.version=2;h.kind=9;h.utf16Count=1;CaptureContextWire metadata;std::string wire(sizeof(h)+2+sizeof(metadata),'\0');std::memcpy(wire.data(),&h,sizeof(h));std::memcpy(wire.data()+sizeof(h)+2,&metadata,sizeof(metadata));CaptureFrame decoded;assert(decodeCaptureFrame(wire.data(),wire.size(),decoded)&&decoded.header.kind==9);wire.pop_back();assert(!decodeCaptureFrame(wire.data(),wire.size(),decoded));
std::filesystem::remove(path);std::filesystem::remove(path.string()+"-wal");std::filesystem::remove(path.string()+"-shm");std::cout<<"PASS diagnostic wire, empty raw spelling, durable queue, permission disable and device metadata\n";}
