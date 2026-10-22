#include "private_input.h"
#include "rime_api.h"
#include <leveldb/db.h>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <map>
namespace fs=std::filesystem;
static int checks=0;
static void check(bool ok,const char* text){if(!ok)throw std::runtime_error(text);++checks;}
static void type(PI_Session session,const std::string& text){for(unsigned char c:text)pi_process_key(session,c,0);}
static long find(PI_Session session,const std::string& text){
 for(size_t offset=0;offset<512;offset+=96){size_t n=pi_load_candidate_batch(session,offset,96);for(size_t i=0;i<n;i++)if(text==pi_batch_candidate_text(session,i))return static_cast<long>(pi_batch_candidate_index(session,i));if(n<96)break;}return -1;
}
static std::string read(const fs::path& file){std::ifstream in(file,std::ios::binary);return {std::istreambuf_iterator<char>(in),{}};}
static std::map<std::string,std::string> snapshot(const fs::path& root){std::map<std::string,std::string> out;for(const auto& item:fs::recursive_directory_iterator(root))if(item.is_regular_file())out.emplace(fs::relative(item.path(),root).string(),read(item.path()));return out;}
static unsigned long long learnedCount(const fs::path& path){leveldb::DB* raw=nullptr;leveldb::Options options;options.create_if_missing=false;check(leveldb::DB::Open(options,path.string(),&raw).ok(),"open isolated closed user database");std::unique_ptr<leveldb::DB> db(raw);std::string value;check(db->Get(leveldb::ReadOptions(),"ni hao \t你好",&value).ok(),"learned userdb row remains");auto start=value.find("c=");check(start!=std::string::npos,"learned counter format");return std::stoull(value.substr(start+2));}
static std::string staging(){char output[4096]{};rime_get_api()->get_staging_dir_s(output,sizeof(output));return output;}
static std::string prebuilt(){char output[4096]{};rime_get_api()->get_prebuilt_data_dir_s(output,sizeof(output));return output;}
int main(int argc,char** argv){try{
 check(argc==5,"usage OLD_FIXTURE NEW_SHARED FRESH_ROOT expect-stale|expect-fresh");const fs::path old=fs::absolute(argv[1]),shared=fs::absolute(argv[2]),root=fs::absolute(argv[3]),user=root/"Rime";const bool fresh=std::string(argv[4])=="expect-fresh";
 check(!fs::exists(root),"synthetic root must be new");fs::create_directories(user);{std::ofstream out(user/"retain-user-note.txt");out<<"SYNTHETIC USER DATA - RETAIN";}
 check(pi_initialize(old.c_str(),user.c_str(),1),"deploy=1 old fixture initialize");check(fs::equivalent(staging(),user/"build"),"deploy=1 keeps normal user/build staging");
 auto session=pi_create_session();check(session!=0,"old fixture session");
 for(int n=0;n<3;n++){type(session,"nihao");auto selected=find(session,"你好");check(selected>=0,"old fixture nihao");check(pi_select_candidate_absolute(session,selected),"learn old fixture term");check(std::string(pi_take_commit(session))=="你好","old fixture commit");}
 pi_clear(session);type(session,"taobao");check(find(session,"淘宝")<0,"old fixture lacks new public platform term");pi_destroy_session(session);check(pi_export_learning((root/"before.tsv").c_str())>0,"export old learning");pi_finalize();
 check(fs::is_regular_file(user/"build/private_pinyin.table.bin"),"stale public compiled table exists in user/build");const auto oldBuild=snapshot(user/"build");const auto before=learnedCount(user/"private_pinyin.userdb");check(before>=3,"old userdb learned count seeded");
 check(pi_initialize(shared.c_str(),user.c_str(),0),"new packaged NO_DEPLOY initialize");
 if(fresh){check(staging()==(user/"ManagedPrebuilt-v1").string(),"NO_DEPLOY isolated managed staging");check(prebuilt()==(shared/"build").string(),"NO_DEPLOY explicit bundled prebuilt");}
 session=pi_create_session();check(session!=0,"new package session");type(session,"taobao");bool recalled=find(session,"淘宝")>=0;check(recalled==fresh,"new platform term reflects selected compiled table");pi_destroy_session(session);
 check(pi_export_learning((root/"after.tsv").c_str())>0,"export learning after packaged switch");pi_finalize();
 const auto after=learnedCount(user/"private_pinyin.userdb");check(before==after,"existing userdb counter preserved exactly");check(snapshot(user/"build")==oldBuild,"legacy user/build content left byte-identical");check(read(user/"retain-user-note.txt")=="SYNTHETIC USER DATA - RETAIN","other user file retained");
 std::cout<<"PASS "<<checks<<" assertions; mode="<<(fresh?"fixed-bundled":"baseline-stale")<<"; taobao="<<recalled<<"; userdb_count="<<before<<"->"<<after<<"; no real user files\n";return 0;
}catch(const std::exception& error){pi_finalize();std::cerr<<"FAIL "<<error.what()<<"\n";return 1;}}
