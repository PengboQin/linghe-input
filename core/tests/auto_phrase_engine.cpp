// Engine regression for automatic phrase collection: Rime memorizes a composed
// new phrase on commit, the status API classifies it, and forget reverts it.
#include "private_input.h"
#include <iostream>
#include <stdexcept>
#include <string>
static unsigned checks = 0;
static void check(bool condition, const std::string &reason) { ++checks; if (!condition) throw std::runtime_error(reason); }
static void type(PI_Session s, const char *raw) { for (; *raw; ++raw) pi_process_key(s, *raw, 0); }
static long find(PI_Session s, const std::string &word) { for (size_t i = 0; i < pi_candidate_count(s); ++i) if (word == pi_candidate_text(s, i)) return long(i); return -1; }
static long rank(const char *raw, const std::string &word) { auto s = pi_create_session(); type(s, raw); auto r = find(s, word); pi_destroy_session(s); return r; }
int main(int argc, char **argv) {
 if (argc != 3) return 2;
 try {
  check(pi_auto_phrase_status("灵鹤") == -1, "no classification before initialization");
  check(pi_initialize(argv[1], argv[2], 0) != 0, "engine initialized");
  check(pi_auto_phrase_status("你好") == 1, "known vocabulary");
  check(pi_auto_phrase_status("灵鹤") == 2, "composed phrase eligible");
  check(pi_auto_phrase_status("灵") == 0 && pi_auto_phrase_status("abc") == 0, "single character and literal not eligible");
  const long before = rank("linghe", "灵鹤");
  check(before > 0, "composed phrase offered below dictionary words before learning");
  auto s = pi_create_session(); type(s, "linghe"); const long i = find(s, "灵鹤"); check(i >= 0 && pi_select_candidate(s, size_t(i)), "phrase selected");
  const char *commit = pi_take_commit(s); check(commit && std::string(commit) == "灵鹤", "phrase committed"); pi_destroy_session(s);
  check(rank("linghe", "灵鹤") == 0, "Rime memorized the new phrase");
  check(pi_forget_phrase("ni hao", "你好") == 0, "known vocabulary is never forgotten");
  check(pi_forget_phrase("", "灵鹤") == -1 && pi_forget_phrase("ling he", nullptr) == -1, "invalid forget rejected");
  check(pi_forget_phrase("ling he", "灵鹤") == 1, "new phrase forgotten");
  check(rank("linghe", "灵鹤") == before, "ranking restored after undo");
  check(pi_forget_phrase("ling he", "灵鹤") >= 0, "repeated undo harmless");
  check(rank("linghe", "灵鹤") == before, "repeated undo leaves ranking unchanged");
  check(pi_learn_phrase("ni hao", "你好") == 0, "known vocabulary is not taught");
  check(pi_learn_phrase("ling he", "灵鹤") == 1, "phrase committed outside Rime is taught");
  check(rank("linghe", "灵鹤") == 0, "taught phrase ranks first like a native commit");
  check(pi_forget_phrase("ling he", "灵鹤") == 1 && rank("linghe", "灵鹤") == before, "taught phrase can be undone");
  pi_finalize();
 } catch (const std::exception &error) { std::cerr << "FAIL " << error.what() << "\n"; return 1; }
 std::cout << "PASS " << checks << " auto-phrase engine checks\n"; return 0;
}
