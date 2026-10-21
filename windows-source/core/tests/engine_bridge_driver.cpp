#include "private_input.h"
#include <filesystem>
#include <iostream>
#include <stdexcept>
#include <string>
namespace fs=std::filesystem;
void check(bool ok,const char *reason){if(!ok)throw std::runtime_error(reason);}
void type(PI_Session s,const std::string &text){for(unsigned char c:text)pi_process_key(s,c,0);}
int main(int argc,char **argv){
  try{
    check(argc>=4,"usage: engine_bridge_driver SHARED TEST_USER_DIR learn|import|rank [fixture]");
    fs::path shared=fs::absolute(argv[1]),user=fs::absolute(argv[2]);fs::create_directories(user);
    check(pi_initialize(shared.string().c_str(),user.string().c_str(),0),"initialization failed");
    auto session=pi_create_session();check(session,"session failed");
    const std::string action=argv[3];
    if(action=="learn"){
      check(argc==6,"learn needs reading and text");
      const std::string reading=argv[4],word=argv[5];
      check(reading=="nihao"&&(word=="你好"||word=="拟好"),"driver accepts only its synthetic fixture");
      type(session,reading);int index=-1;
      for(size_t i=0;i<pi_candidate_count(session);++i)if(word==pi_candidate_text(session,i)){index=int(i);break;}
      check(index>=0&&pi_select_candidate(session,index),"fixture candidate not selectable");
      check(word==pi_take_commit(session),"commit mismatch");
    }else if(action=="rank"){
      type(session,"nihao");check(pi_candidate_count(session)>0,"no candidates");
      std::cout<<pi_candidate_text(session,0)<<"\n";
    }else if(action!="import"&&action!="import-rank")throw std::runtime_error("unknown fixture action");
    pi_destroy_session(session);
    if(action=="import"||action=="import-rank"){
      check(argc==5,"import needs snapshot file");
      check(pi_import_learning(argv[4])>=0,"engine import failed");
      if(action=="import-rank") {
        session=pi_create_session();check(session,"post-import session failed");
        type(session,"nihao");check(pi_candidate_count(session)>0,"post-import candidates missing");
        std::cout<<pi_candidate_text(session,0)<<"\n";
        pi_destroy_session(session);
      }
    }
    const auto out=user/"checkpoint.tsv";
    check(pi_export_learning(out.string().c_str())>=0,"engine export failed");
    pi_finalize();return 0;
  }catch(const std::exception &e){pi_finalize();std::cerr<<"FAIL: "<<e.what()<<"\n";return 1;}
}
