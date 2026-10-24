#include "private_input.h"
#include "rime_api.h"
#include <filesystem>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <cassert>
namespace fs=std::filesystem;
static uint64_t badCount(const fs::path&file){std::ifstream in(file);std::string row;while(std::getline(in,row)){std::istringstream fields(row);std::string text,reading,count;std::getline(fields,text,'\t');std::getline(fields,reading,'\t');std::getline(fields,count);if(text=="小厂"&&reading=="xiao han")return std::stoull(count);}return 0;}
int main(int argc,char**argv){assert(argc==3);fs::path data=argv[2];assert(!fs::exists(data));fs::create_directories(data);assert(pi_initialize(argv[1],data.c_str(),0));
 {std::ofstream seed(data/"seed.tsv");seed<<"小厂\txiao han\t1000000\n小寒\txiao han\t1\n";}
 assert(pi_import_learning((data/"seed.tsv").c_str())>=0);assert(pi_export_learning((data/"before.tsv").c_str())>=0);const auto count=badCount(data/"before.tsv");assert(count==1000000);
 auto s=pi_create_session();assert(s);pi_set_nine_key(s,0);pi_set_word_pinned("xiao han","小厂",1);for(char c:std::string("xiaohan"))pi_process_key(s,c,0);
 assert(pi_candidate_count(s)>0);const std::string first=pi_candidate_text(s,0);assert(first!="小厂");
 size_t rawBad=SIZE_MAX;RimeCandidateListIterator it{};auto*api=rime_get_api();assert(api->candidate_list_begin(s,&it));while(api->candidate_list_next(&it)){if(it.candidate.text&&it.candidate.comment&&std::string(it.candidate.text)=="小厂"&&std::string(it.candidate.comment)=="xiao han"){rawBad=it.index;break;}}api->candidate_list_end(&it);assert(rawBad!=SIZE_MAX);
 assert(!pi_select_candidate_absolute(s,rawBad));assert(std::string(pi_raw_input(s))=="xiaohan");
 auto n=pi_load_candidate_batch(s,0,32);assert(n>0);for(size_t i=0;i<n;++i)assert(pi_candidate_reading_allowed(pi_batch_candidate_text(s,i),pi_batch_candidate_comment(s,i)));
 assert(pi_process_key(s,' ',0));assert(std::string(pi_take_commit(s))==first);pi_clear(s);
 // The identical digit code remains ambiguous; it is not forced into the
 // alphabetic ordering, but unsupported carrier readings cannot reappear.
 pi_set_nine_key(s,1);for(char c:std::string("9426426"))pi_process_key(s,c,0);n=pi_load_candidate_batch(s,0,32);assert(n>0);for(size_t i=0;i<n;++i)assert(pi_candidate_reading_allowed(pi_batch_candidate_text(s,i),pi_batch_candidate_comment(s,i)));
 pi_destroy_session(s);assert(pi_export_learning((data/"after.tsv").c_str())>=0);assert(badCount(data/"after.tsv")==count);pi_finalize();
 assert(pi_initialize(argv[1],data.c_str(),0));s=pi_create_session();for(char c:std::string("xiaohan"))pi_process_key(s,c,0);assert(std::string(pi_candidate_text(s,0))!="小厂");pi_destroy_session(s);pi_finalize();
 std::cout<<"{\"passed\":true,\"legacyHighFrequencyAndPinSuppressedOnlyInCandidates\":true,\"legacyBadCounterUnchanged\":true,\"spaceMatchesVisibleCandidate\":true,\"directBadAbsoluteIDRejected\":true,\"nineKeyStillAmbiguousAndAdmissible\":true,\"processRestartCovered\":true,\"allDataSynthetic\":true}\n";
}
