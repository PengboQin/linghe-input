#include "private_input.h"
#include <filesystem>
#include <iostream>
#include <fstream>
#include <stdexcept>
#include <string>
void check(bool value, const char *why) { if (!value) throw std::runtime_error(why); }
void type(PI_Session s, const std::string &value) { for (char c : value) check(pi_process_key(s, c, 0), "Nine-key digit was not handled"); }
int find(PI_Session s, const std::string &word) {
  for (int page = 0; page < 20; ++page) {
    for (size_t i = 0; i < pi_candidate_count(s); ++i) if (word == pi_candidate_text(s,i)) return (int)i;
    if (!pi_has_next_page(s)) break;
    pi_process_key(s, 0xff56, 0);
  } return -1;
}
int main(int argc, char **argv) {
 try {
  check(argc == 3, "Usage: nine_key_smoke RESOURCES FRESH_DATA");
  check(!std::filesystem::exists(argv[2]), "Fresh synthetic data required");
  std::filesystem::create_directories(argv[2]); check(pi_initialize(argv[1],argv[2],0), "Initialize");
  auto s=pi_create_session(); check(pi_set_nine_key(s,1), "Nine-key schema");
  type(s,"64426"); check(std::string(pi_raw_input(s)) == "64426", "Digits selected candidates instead of composing");
  auto index=find(s,"你好"); check(index>=0,"Nine-key nihao missing"); check(pi_select_candidate(s,index),"Select");
  check(std::string(pi_take_commit(s))=="你好","Commit");
  type(s,"2482647426646498348264"); index=find(s,"床前明月光"); check(index>=0,"Classical long phrase missing");
  pi_clear(s); check(std::string(pi_raw_input(s)).empty(),"Clear pending"); check(std::string(pi_take_commit(s)).empty(),"Clear committed text");
  check(pi_set_private(s,1),"Private nine schema"); type(s,"64426"); check(find(s,"你好")>=0,"Private nine candidate"); pi_clear(s);
  check(pi_set_nine_key(s,0),"Back to pinyin"); type(s,"chuangqianmingyueguang"); check(find(s,"床前明月光")>=0,"Full pinyin classical phrase");
  pi_clear(s); pi_destroy_session(s);
  const auto imported = std::filesystem::path(argv[2])/"synthetic-preference.tsv";
  { std::ofstream file(imported); file << "拟好\tni hao\t1000\n"; }
  check(pi_import_learning(imported.string().c_str())>=0,"Import shared pinyin learning");
  s=pi_create_session(); check(pi_set_nine_key(s,1),"Reopen nine"); type(s,"64426");
  check(std::string(pi_candidate_text(s,0))=="拟好","Shared frequency must rank nine-key candidates");
  pi_clear(s); pi_destroy_session(s);
  const auto before=std::filesystem::path(argv[2])/"before-private.tsv", after=std::filesystem::path(argv[2])/"after-private.tsv";
  check(pi_export_learning(before.string().c_str())>0,"Export nine-key learning");
  s=pi_create_session(); check(pi_set_nine_key(s,1) && pi_set_private(s,1),"Disable learning");
  type(s,"64426"); check(pi_select_candidate(s,0),"Private candidate"); pi_take_commit(s); pi_destroy_session(s);
  check(pi_export_learning(after.string().c_str())>0,"Export preserved data");
  std::ifstream a(before),b(after); std::string av{std::istreambuf_iterator<char>(a),{}},bv{std::istreambuf_iterator<char>(b),{}};
  check(av==bv,"Private nine-key input changed learned words");
  pi_finalize(); std::cout << "PASS: real nine-key composition, candidate commit, clear, private schema and classical phrase in both layouts\n";
 } catch(const std::exception &e) { std::cerr<< e.what()<<'\n'; return 1; }
}
