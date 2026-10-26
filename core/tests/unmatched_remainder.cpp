// Full-pinyin input with unmatched trailing letters must never get stuck:
// selecting the converted part (or pressing space afterwards) commits the
// selection plus the raw letters. Matchable remainders keep composing.
#include "private_input.h"
#include <cstdio>
#include <string>
static int failures=0;
static void check(bool ok,const char*what){if(!ok){std::printf("FAIL %s\n",what);++failures;}}
static PI_Session typed(const char*raw){auto s=pi_create_session();for(;*raw;++raw)pi_process_key(s,*raw,0);return s;}
static long find(PI_Session s,const std::string&w){for(size_t i=0;i<pi_candidate_count(s);i++)if(w==pi_candidate_text(s,i))return long(i);return -1;}
int main(int argc,char**argv){
 if(argc<3||!pi_initialize(argv[1],argv[2],0)){std::puts("init failed");return 2;}
 {auto s=typed("nihaoi");long i=find(s,"你好");check(i>=0,"nihaoi offers 你好");pi_select_candidate(s,size_t(i));
  check(std::string(pi_take_commit(s))=="你好i","selection commits 你好i");check(std::string(pi_raw_input(s)).empty(),"composition cleared");pi_destroy_session(s);}
 {auto s=typed("jintianzenmeyangi");pi_process_key(s,' ',0);
  check(std::string(pi_take_commit(s))=="今天怎么样i","space commits sentence plus letter");pi_destroy_session(s);}
 {auto s=typed("nihaoi");long i=find(s,"你");if(i>=0){pi_select_candidate(s,size_t(i));
  check(std::string(pi_take_commit(s)).empty(),"partial 你 keeps composing");check(pi_candidate_count(s)>0,"remainder still has candidates");}pi_destroy_session(s);}
 {auto s=typed("nihao");pi_process_key(s,' ',0);check(std::string(pi_take_commit(s))=="你好","plain input unchanged");pi_destroy_session(s);}
 pi_finalize();std::printf("unmatched_remainder failures=%d\n",failures);return failures?1:0;}
