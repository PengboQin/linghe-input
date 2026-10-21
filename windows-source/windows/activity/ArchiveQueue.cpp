#include "ArchiveCore.h"
#include <set>
#include <algorithm>
#ifdef _WIN32
#include <windows.h>
#else
#include <dlfcn.h>
#endif
namespace private_input::activity { namespace {
struct sqlite3;struct sqlite3_stmt;
using Destructor=void(*)(void*);constexpr int OK=0,ROW=100,DONE=101;
struct SQLite {
#ifdef _WIN32
 HMODULE module=nullptr;
#else
 void*module=nullptr;
#endif
 int(*open)(const char*,sqlite3**,int,const char*)=nullptr;int(*close)(sqlite3*)=nullptr;int(*exec)(sqlite3*,const char*,int(*)(void*,int,char**,char**),void*,char**)=nullptr;
 int(*prepare)(sqlite3*,const char*,int,sqlite3_stmt**,const char**)=nullptr;int(*step)(sqlite3_stmt*)=nullptr;int(*finalize)(sqlite3_stmt*)=nullptr;int(*bindText)(sqlite3_stmt*,int,const char*,int,Destructor)=nullptr;int(*bindInt)(sqlite3_stmt*,int,int64_t)=nullptr;const unsigned char*(*text)(sqlite3_stmt*,int)=nullptr;int64_t(*integer)(sqlite3_stmt*,int)=nullptr;int(*busy)(sqlite3*,int)=nullptr;
 SQLite(){
#ifdef _WIN32
 module=LoadLibraryExW(L"winsqlite3.dll",nullptr,LOAD_LIBRARY_SEARCH_SYSTEM32);
#else
 module=dlopen("/usr/lib/libsqlite3.dylib",RTLD_NOW|RTLD_LOCAL);if(!module)module=dlopen("libsqlite3.so.0",RTLD_NOW|RTLD_LOCAL);
#endif
 require(module!=nullptr,"SQLite unavailable");
#define SQL_LOAD(field,name) field=reinterpret_cast<decltype(field)>(symbol(name));require(field!=nullptr,"SQLite API missing")
 SQL_LOAD(open,"sqlite3_open_v2");SQL_LOAD(close,"sqlite3_close");SQL_LOAD(exec,"sqlite3_exec");SQL_LOAD(prepare,"sqlite3_prepare_v2");SQL_LOAD(step,"sqlite3_step");SQL_LOAD(finalize,"sqlite3_finalize");SQL_LOAD(bindText,"sqlite3_bind_text");SQL_LOAD(bindInt,"sqlite3_bind_int64");SQL_LOAD(text,"sqlite3_column_text");SQL_LOAD(integer,"sqlite3_column_int64");SQL_LOAD(busy,"sqlite3_busy_timeout");
#undef SQL_LOAD
 }
 void* symbol(const char*n){
#ifdef _WIN32
 return reinterpret_cast<void*>(GetProcAddress(module,n));
#else
 return dlsym(module,n);
#endif
 }
 ~SQLite(){
#ifdef _WIN32
 if(module)FreeLibrary(module);
#else
 if(module)dlclose(module);
#endif
 }
};
struct Statement {SQLite&a;sqlite3_stmt*s=nullptr;Statement(SQLite&api,sqlite3*db,const char*sql):a(api){require(a.prepare(db,sql,-1,&s,nullptr)==OK,"SQLite prepare");}~Statement(){if(s)a.finalize(s);}void str(int n,const std::string&t){require(a.bindText(s,n,t.data(),int(t.size()),reinterpret_cast<Destructor>(intptr_t(-1)))==OK,"SQLite bind");}void num(int n,uint64_t x){require(x<=INT64_MAX&&a.bindInt(s,n,int64_t(x))==OK,"SQLite integer");}int step(){int rc=a.step(s);require(rc==ROW||rc==DONE,"SQLite step");return rc;}std::string str(int i){auto p=a.text(s,i);return p?reinterpret_cast<const char*>(p):"";}uint64_t num(int i){auto n=a.integer(s,i);require(n>=0,"negative database integer");return uint64_t(n);}};
}
struct Queue::Impl {SQLite api;sqlite3*db=nullptr;Codec protect,unprotect;
 Impl(const std::filesystem::path&path,Codec p,Codec u):protect(std::move(p)),unprotect(std::move(u)){require(bool(protect)&&bool(unprotect),"queue requires encryption");require(api.open(path.u8string().c_str(),&db,2|4|0x10000,nullptr)==OK,"SQLite open");try{require(api.busy(db,500)==OK,"SQLite timeout");sql("PRAGMA journal_mode=WAL;PRAGMA synchronous=FULL;PRAGMA secure_delete=ON;PRAGMA trusted_schema=OFF;PRAGMA max_page_count=16384;CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY,v TEXT NOT NULL);CREATE TABLE IF NOT EXISTS queue(id TEXT PRIMARY KEY,generation INTEGER NOT NULL,seq INTEGER NOT NULL UNIQUE,payload TEXT NOT NULL);CREATE TABLE IF NOT EXISTS held(id TEXT PRIMARY KEY,generation INTEGER NOT NULL,seq INTEGER NOT NULL UNIQUE,payload TEXT NOT NULL);INSERT OR IGNORE INTO meta VALUES('generation','1'),('seq','0'),('enabled','0'),('group',''),('consent','0'),('dropped','0');");}catch(...){api.close(db);db=nullptr;throw;}}
 ~Impl(){if(db)api.close(db);}void sql(const char*s){require(api.exec(db,s,nullptr,nullptr,nullptr)==OK,"SQLite transaction");}
 std::string get(const char*k){Statement s(api,db,"SELECT v FROM meta WHERE k=?");s.str(1,k);require(s.step()==ROW,"queue metadata");return s.str(0);}uint64_t number(const char*k){auto s=get(k);require(!s.empty()&&s.find_first_not_of("0123456789")==std::string::npos,"queue integer");return std::stoull(s);}void set(const char*k,const std::string&v){Statement s(api,db,"UPDATE meta SET v=? WHERE k=?");s.str(1,v);s.str(2,k);s.step();}void set(const char*k,uint64_t n){set(k,std::to_string(n));}
 void hold(){sql("INSERT INTO held SELECT * FROM queue;DELETE FROM queue");}void wipe(){sql("DELETE FROM queue;DELETE FROM held");}void cleanup(){sql("PRAGMA wal_checkpoint(TRUNCATE)");}
};
namespace {struct Transaction{Queue::Impl&p;bool committed=false;explicit Transaction(Queue::Impl&q):p(q){p.sql("BEGIN IMMEDIATE");}~Transaction(){if(!committed)try{p.sql("ROLLBACK");}catch(...){}}void commit(){p.sql("COMMIT");committed=true;}};}
Queue::Queue(const std::filesystem::path&p,Codec e,Codec d):p(new Impl(p,std::move(e),std::move(d))){}Queue::~Queue()=default;
uint64_t Queue::configure(const std::string&group,uint64_t consent,bool enabled){if(enabled){(void)parseId(group);require(consent>0,"consent required");}Transaction t(*p);auto g=p->number("generation");if(p->get("group")!=group||p->number("consent")!=consent||p->number("enabled")!=uint64_t(enabled)){require(g<INT64_MAX,"generation exhausted");p->hold();p->set("generation",++g);p->set("group",group);p->set("consent",consent);p->set("enabled",uint64_t(enabled));}t.commit();if(!enabled)p->cleanup();return g;}
void Queue::disable(){configure("",0,false);}
void Queue::clear(){Transaction t(*p);p->wipe();auto g=p->number("generation");require(g<INT64_MAX,"generation exhausted");p->set("generation",g+1);t.commit();p->cleanup();}
size_t Queue::heldCount(){Statement s(p->api,p->db,"SELECT COUNT(*) FROM held");require(s.step()==ROW,"held count");return size_t(s.num(0));}
bool Queue::enqueue(const EventContext&c,const std::string&provider,const std::string&type,const std::string&text,uint64_t now,const std::string&source){require(type=="coverage_gap"||(provider=="ime.diagnostic.v1"&&type=="source_import")||(provider=="ime.commit.v1"&&type=="input_commit")||(provider=="clipboard.observed.v1"&&type=="clipboard_observed")||(provider=="ime.paste.v1"&&type=="paste_action"),"provider mismatch");if(text.empty()&&type!="coverage_gap")return false;bool oversized=text.size()>245760;Transaction t(*p);if(!p->number("enabled")||p->get("group")!=uuidText(c.group)||p->number("consent")!=c.consent){t.commit();return false;}Statement limit(p->api,p->db,"SELECT COUNT(*),COALESCE(SUM(length(payload)),0) FROM (SELECT payload FROM queue UNION ALL SELECT payload FROM held)");require(limit.step()==ROW,"queue bounds");if(limit.num(0)>=(provider=="ime.diagnostic.v1"?7500:10000)||limit.num(1)+(oversized?0:text.size())*3+4096>(provider=="ime.diagnostic.v1"?6:8)*1024*1024){p->set("dropped",std::min(p->number("dropped")+1,uint64_t(INT64_MAX)));t.commit();return false;}auto seq=p->number("seq");require(seq<INT64_MAX,"sequence exhausted");auto event=makeEvent(c,++seq,provider,oversized?"coverage_gap":type,oversized?"":text,now,source);if(oversized)event["extensions"]["org.linghe.coverage.v1"]=Json::object({{"reason","event_too_large"},{"original_utf8_bytes",uint64_t(text.size())}});if(event.at("event_type").str()=="clipboard_observed"){event["commit_confirmation"]="not_applicable";event["extensions"]["org.linghe.provenance.v1"]=Json::object({{"paste_performed","unknown"},{"source_application",safeSourceLabel(c.source.identifier,191)?"clipboard_owner":"unknown"}});}if(event.at("event_type").str()=="paste_action"){event["extensions"]["org.linghe.provenance.v1"]=Json::object({{"paste_performed",true},{"text_source","system_clipboard"},{"trigger","clipboard_candidate"}});}auto clear=event.dump();if(clear.size()>262144){event["event_type"]="coverage_gap";event["content"]=Json::object({{"text",""}});event["commit_confirmation"]="not_applicable";event["extensions"]["org.linghe.coverage.v1"]=Json::object({{"reason","event_too_large"},{"original_utf8_bytes",uint64_t(text.size())}});clear=event.dump();}auto encoded=p->protect(clear);require(encoded.size()<=524288,"protected event limit");if(limit.num(1)+encoded.size()>8*1024*1024){p->set("dropped",std::min(p->number("dropped")+1,uint64_t(INT64_MAX)));t.commit();return false;}Statement insert(p->api,p->db,"INSERT INTO queue VALUES(?,?,?,?)");insert.str(1,event.at("event_id").str());insert.num(2,p->number("generation"));insert.num(3,seq);insert.str(4,encoded);require(insert.step()==DONE,"enqueue failed");p->set("seq",seq);t.commit();return true;}
std::vector<QueuedEvent> Queue::batch(size_t limit,size_t byteLimit){require(limit>0&&limit<=128&&byteLimit<=524288,"batch limits");std::vector<QueuedEvent> out;size_t size=0;if(!p->number("enabled"))return out;Statement s(p->api,p->db,"SELECT id,generation,seq,payload FROM queue ORDER BY seq LIMIT ?");s.num(1,limit);while(s.step()==ROW){QueuedEvent e;e.id=s.str(0);e.generation=s.num(1);e.sequence=s.num(2);e.encoded=s.str(3);auto clear=p->unprotect(e.encoded);if(size+clear.size()>byteLimit)break;e.event=Json::parse(clear,262144);require(e.event.at("event_id").str()==e.id&&e.event.at("device_seq").num()==e.sequence,"queue identity mismatch");size+=clear.size();out.push_back(std::move(e));}return out;}
void Queue::acknowledge(const std::vector<QueuedEvent>&sent,const Json&response,const std::string&batchID){require(!sent.empty()&&sent.size()<=128,"ACK batch count");require(response.at("version").num()==1&&response.at("operation").num()==4,"ACK operation");const auto&r=response.at("result");require(parseId(r.at("batch_id").str())==parseId(batchID),"ACK batch identity");std::set<std::string>wanted,confirmed;for(const auto&e:sent)require(wanted.insert(uuidText(parseId(e.id))).second,"duplicate sent ID");for(const char*k:{"accepted_event_ids","duplicate_event_ids"}){const auto&list=r.at(k);require(list.kind==Json::Kind::array&&list.items.size()<=128,"ACK array");for(const auto&id:list.items)require(confirmed.insert(uuidText(parseId(id.str()))).second,"duplicate ACK");}require(wanted==confirmed,"ACK must cover exact sent event IDs");Transaction t(*p);if(!p->number("enabled")||p->number("generation")!=sent[0].generation){t.commit();return;}for(const auto&e:sent){require(e.generation==sent[0].generation,"mixed generations");Statement s(p->api,p->db,"SELECT generation,payload FROM queue WHERE id=?");s.str(1,e.id);require(s.step()==ROW&&s.num(0)==e.generation&&s.str(1)==e.encoded,"ACK record changed");require(p->unprotect(e.encoded)==e.event.dump(),"ACK original changed");Statement erase(p->api,p->db,"DELETE FROM queue WHERE id=? AND generation=? AND payload=?");erase.str(1,e.id);erase.num(2,e.generation);erase.str(3,e.encoded);erase.step();}t.commit();}
size_t Queue::count(){Statement s(p->api,p->db,"SELECT COUNT(*) FROM queue");require(s.step()==ROW,"queue count");return size_t(s.num(0));}uint64_t Queue::generation(){return p->number("generation");}uint64_t Queue::dropped(){return p->number("dropped");}
}
