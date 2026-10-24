#include "private_input.h"
#include <filesystem>
#include <fstream>
#include <iostream>
#include <map>
#include <stdexcept>
#include <string>
namespace fs=std::filesystem;
static void check(bool value,const char*why){if(!value)throw std::runtime_error(why);}
static std::map<std::string,long long> rows(const fs::path&file){
 std::ifstream input(file);std::string line;std::map<std::string,long long> result;
 while(std::getline(input,line)){if(line.empty()||line[0]=='#')continue;auto first=line.find('\t'),last=line.rfind('\t');check(first!=std::string::npos&&last!=first,"invalid native export");result.emplace(line.substr(0,last),std::stoll(line.substr(last+1)));}return result;
}
int main(int argc,char**argv){try{
 check(argc==3,"shared and synthetic fresh user directory required");const fs::path shared=fs::absolute(argv[1]),user=fs::absolute(argv[2]);check(!fs::exists(user),"must not overwrite a user database");fs::create_directories(user);
 check(pi_initialize(shared.string().c_str(),user.string().c_str(),0)==1,"initialize");
 auto session=pi_create_session();check(session!=0,"session");
 check(pi_set_learning_capacity_profile("expanded-10000",2)==-2,"changing active runtime must be busy");
 check(pi_set_learning_capacity_profile("legacy-5000",1)==1,"same active profile is safe");pi_destroy_session(session);
 const auto data=user/"new-5001.tsv",before=user/"before.tsv",after=user/"after.tsv";
 {std::ofstream file(data);for(int i=0;i<5001;i++)file<<"容量"<<i<<"\trong liang\t1\n";}
 check(pi_export_learning(before.string().c_str())>=0,"baseline export");
 check(pi_import_learning(data.string().c_str())==-1,"legacy profile must reject5001");
 check(pi_export_learning(after.string().c_str())>=0&&rows(before)==rows(after),"rejected import changed native data");
 check(pi_set_learning_capacity_profile("expanded-10000",2)==1,"explicit current profile");
 check(pi_set_learning_capacity_profile("expanded-10000",1)==0,"mismatched profile identity");
 check(pi_set_learning_capacity_profile("future",2)==0,"unknown profile identity");
 check(pi_import_learning(data.string().c_str())>=0,"current profile native import5001");
 check(pi_export_learning(after.string().c_str())>=0,"current native export");auto imported=rows(after);
 check(imported.size()==5001&&imported.at("容量5000\trong liang")==1,"full native model5001 not retained");
 check(pi_import_learning(data.string().c_str())>=0,"repeat MAX import");
 check(pi_export_learning(after.string().c_str())>=0&&rows(after)==imported,"replayed import double counted");
 session=pi_create_session();check(session&&pi_set_private(session,1),"current private input session");
 for(char c:std::string("xiaohan"))pi_process_key(session,c,0);
 auto count=pi_load_candidate_batch(session,0,32);check(count>0,"current profile candidates empty");
 for(size_t i=0;i<count;i++)check(std::string(pi_batch_candidate_text(session,i))!="小厂","old factory reading returned in current profile");
 pi_clear(session);for(char c:std::string("nihao"))pi_process_key(session,c,0);
 check(pi_process_key(session,' ',0)&&std::string(pi_take_commit(session))=="你好","current profile space commit");pi_destroy_session(session);
 check(pi_export_learning(after.string().c_str())>=0&&rows(after)==imported,"private input changed native learning");
 const auto over=user/"too-many.tsv";{std::ofstream file(over);for(int i=0;i<10001;i++)file<<"容量"<<i<<"\trong liang\t1\n";}
 check(pi_import_learning(over.string().c_str())==-1,"current profile must remain bounded10000");
 check(pi_export_learning(after.string().c_str())>=0&&rows(after)==imported,"rejected10001 changed native data");
 pi_finalize();check(pi_initialize(shared.string().c_str(),user.string().c_str(),0)==1,"restart");
 check(pi_set_learning_capacity_profile("expanded-10000",2)==1,"select current after restart");
 check(pi_export_learning(after.string().c_str())>=0&&rows(after)==imported,"native restart lost counts");pi_finalize();
 std::cout<<"{\"passed\":true,\"actualRimeImportExport\":true,\"nativeTerms\":5001,\"maxImportReplayIdempotent\":true,\"unknownAndOverlimitPreserveData\":true,\"restartPreserved\":true,\"allDataSynthetic\":true}\n";return 0;
 }catch(const std::exception&e){pi_finalize();std::cerr<<e.what()<<'\n';return 1;}}
