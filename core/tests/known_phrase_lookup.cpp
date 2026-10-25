#include "known_phrase_lookup.h"
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>
static unsigned checks = 0;
static void check(bool condition, const std::string &reason) { ++checks; if (!condition) throw std::runtime_error(reason); }
int main(int argc, char **argv) {
 if (argc != 2) return 2;
 const std::string essay = argv[1];
 using namespace private_input::known_phrase;
 try {
  std::ifstream input(essay, std::ios::binary); std::vector<std::string> words; std::string line;
  while (std::getline(input, line)) words.push_back(line.substr(0, line.find('\t')));
  check(words.size() > 1000, "vocabulary loaded");
  for (size_t i = 0; i < words.size(); i += 211) check(lookup(essay, words[i]) == Status::known, "sampled word found: " + words[i]);
  check(lookup(essay, words.front()) == Status::known, "first line found");
  check(lookup(essay, words.back()) == Status::known, "last line found");
  for (const char *absent : {"", "灵鹤输入法测试词", "\x01", "\xF4\x8F\xBF\xBF", "zzzz"}) check(lookup(essay, absent) == Status::not_eligible, std::string("absent text not found: ") + absent);
  check(lookup(essay + ".missing", "你好") == Status::unavailable, "missing vocabulary reported, never treated as new");
  check(classify(essay, "你好") == Status::known, "common word known");
  check(classify(essay, "灵鹤") == Status::eligible_new, "uncommon Han phrase eligible");
  for (const char *rejected : {"灵", "灵鹤输入法真好用啊呀", "灵鹤!", "abc", "灵鹤123", "後臺", "", "😀😀"}) check(classify(essay, rejected) == Status::not_eligible, std::string("not eligible: ") + rejected);
  check(classify(essay + ".missing", "灵鹤") == Status::unavailable, "no new-word claim without vocabulary");
 } catch (const std::exception &error) { std::cerr << "FAIL " << error.what() << "\n"; return 1; }
 std::cout << "PASS " << checks << " known-phrase checks\n"; return 0;
}
