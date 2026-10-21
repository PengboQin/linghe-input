#include "private_input.h"
#include <filesystem>
#include <fstream>
#include <set>
#include <stdexcept>
#include <iostream>
#include <vector>
#include <chrono>
namespace fs = std::filesystem;
void require(bool ok, const char *message) { if (!ok) throw std::runtime_error(message); }
void type(PI_Session s, const std::string &text) { for (char c : text) pi_process_key(s, c, 0); }
struct Choice { std::string text, reading; size_t index; };
std::vector<Choice> batch(PI_Session s, size_t offset, size_t limit) {
  std::vector<Choice> v; auto n = pi_load_candidate_batch(s, offset, limit);
  for (size_t i = 0; i < n; ++i) v.push_back({pi_batch_candidate_text(s, i), pi_batch_candidate_comment(s, i), pi_batch_candidate_index(s, i)});
  return v;
}
int main(int argc, char **argv) {
 try {
  require(argc == 3, "usage resources fresh-synthetic-dir"); require(!fs::exists(argv[2]), "fresh test directory required"); fs::create_directories(argv[2]);
  require(pi_initialize(argv[1], argv[2], 0), "initialize"); auto s = pi_create_session(); type(s, "shi");
  auto before = batch(s, 0, 64); require(before.size() > 12, "deep candidate required");
  auto target = before[20]; require(pi_set_word_pinned(target.reading.c_str(), target.text.c_str(), 1), "pin");
  auto begin = std::chrono::steady_clock::now(); auto first = batch(s, 0, 12);
  require(first.front().text == target.text, "deep candidate not promoted to first batch");
  std::set<size_t> indices; size_t offset = 0, total = 0;
  for (;;) { auto part = batch(s, offset, 12); for (auto &c : part) { require(indices.insert(c.index).second, "candidate duplicated across batches"); ++total; } offset += part.size(); if (part.size() < 12) break; }
  require(total >= before.size(), "candidate stream truncated");
  require(pi_select_candidate_absolute(s, first.front().index), "absolute selection"); require(std::string(pi_take_commit(s)) == target.text, "pin committed wrong absolute index");
  require(pi_set_nine_key(s, 1), "nine"); type(s, "744"); require(batch(s, 0, 12).front().text == target.text, "pin not shared with nine-key reading"); pi_clear(s);
  require(pi_set_private(s, 1), "privacy"); type(s, "744"); require(batch(s, 0, 12).front().text != target.text, "pin leaked into private mode"); pi_clear(s);
  require(pi_reset_word_frequency("ni hao", "合成自造词甲", 0) == -2, "active reset must reject"); pi_destroy_session(s);
  require(pi_set_word_pinned(target.reading.c_str(), target.text.c_str(), 0), "unpin");
  s = pi_create_session(); type(s, "shi"); const auto baseline = batch(s, 0, 64).front().text; pi_destroy_session(s);
  const auto baseWord = target.text == "试" ? std::string("狮") : std::string("试");
  fs::path imported = fs::path(argv[2]) / "import.tsv", exported = fs::path(argv[2]) / "export.tsv";
  { std::ofstream f(imported); f << "合成自造词甲\tni hao\t120\n世界\tshi jie\t8\n" << baseWord << "\tshi\t120\n"; }
  require(pi_import_learning(imported.c_str()) >= 0, "import");
  require(pi_reset_word_frequency("shi", baseWord.c_str(), 0) == 2, "base dictionary word must remove user promotion");
  require(pi_reset_word_frequency("ni hao", "合成自造词甲", 0) == 1, "reset"); require(pi_export_learning(exported.c_str()) >= 0, "export");
  std::ifstream f(exported); std::string data((std::istreambuf_iterator<char>(f)), {});
  require(data.find("合成自造词甲\tni hao\t1") != std::string::npos, "native frequency did not reset"); require(data.find(baseWord + "\tshi\t") == std::string::npos, "base word kept user priority after reset"); require(data.find("世界\tshi jie\t8") != std::string::npos, "reset changed another word");
  s = pi_create_session(); type(s, "shi"); auto restored = batch(s, 0, 64); require(restored.front().text == baseline, "base frequency reset did not restore fresh default order"); pi_clear(s); type(s, "nihao"); bool retained = false; for (const auto &c : batch(s, 0, 64)) if (c.text == "合成自造词甲") retained = true; require(retained, "custom word was deleted by reset"); pi_destroy_session(s); pi_finalize();
  std::cout << "PASS pin deep candidate, stable stream/absolute selection, nine-key/private boundaries, native reset retains custom/other words; stream ms=" << std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now()-begin).count() << "\n";
 } catch (const std::exception &e) { pi_finalize(); std::cerr << "FAIL " << e.what() << "\n"; return 1; }
}
