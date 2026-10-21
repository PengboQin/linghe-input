#ifdef NDEBUG
#undef NDEBUG
#endif
#include "../../activity/ArchiveCore.h"
#include <cassert>
#include <iostream>
using namespace private_input::activity;
int main(int argc,char**argv){assert(argc==2);auto path=std::filesystem::path(argv[1]);assert(!std::filesystem::exists(path));
 EventContext c;c.group=newId();c.device=newId();c.installation=newId();c.consent=1;c.session=uuidText(newId());c.editor=uuidText(newId());
 auto encode=[](const std::string&s){return base64(bytes(s));};auto decode=[](const std::string&s){auto raw=unbase64(s);return std::string(raw.begin(),raw.end());};
 {Queue queue(path,encode,decode);queue.configure(uuidText(c.group),1,true);const std::string raw="  第一段\r\n\t第二段\n\n  尾段  ";
 assert(queue.enqueue(c,"ime.paste.v1","paste_action",raw,unixTime(),"system_clipboard"));auto rows=queue.batch();assert(rows.size()==1);auto event=rows[0].event;assert(event.at("content").at("text").str()==raw);assert(event.at("provider_id").str()=="ime.paste.v1"&&event.at("event_type").str()=="paste_action"&&event.at("source_kind").str()=="system_clipboard");auto provenance=event.at("extensions").at("org.linghe.provenance.v1");assert(provenance.at("paste_performed").boolean()&&provenance.at("text_source").str()=="system_clipboard"&&provenance.at("trigger").str()=="clipboard_candidate");
 queue.clear();assert(queue.enqueue(c,"clipboard.observed.v1","clipboard_observed",raw,unixTime(),"clipboard"));event=queue.batch()[0].event;assert(event.at("extensions").at("org.linghe.provenance.v1").at("paste_performed").str()=="unknown");queue.clear();}
 for(auto suffix:{"","-wal","-shm"})std::filesystem::remove(path.string()+suffix);
 std::cout<<"real SQLite queue: raw multiline whitespace round trip, paste attribution, copy is not paste: passed\n";
}
