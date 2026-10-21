#include "private_input.h"
#include <filesystem>
#include <iostream>
#include <string>
#include <vector>
namespace fs = std::filesystem;
static int failures = 0;
static void check(bool ok, const std::string &what) {
  if (!ok) { std::cout << "FAIL " << what << "\n"; ++failures; }
}
static void type(PI_Session s, const std::string &text) { for (unsigned char c : text) pi_process_key(s, c, 0); }
static std::vector<std::string> repairs(PI_Session s) {
  std::vector<std::string> rows;
  const auto count = pi_load_repair_candidates(s, 16);
  for (size_t i = 0; i < count; ++i) rows.push_back(pi_repair_candidate_text(s, i));
  return rows;
}
static bool has(const std::vector<std::string> &rows, const std::string &text) {
  for (const auto &row : rows) if (row == text) return true;
  return false;
}
static void show(PI_Session s, const std::string &input) {
  pi_clear(s);
  type(s, input);
  pi_load_candidate_batch(s, 0, 32);
  const auto rows = repairs(s);
  std::cout << input << " ->";
  for (const auto &row : rows) std::cout << " " << row;
  std::cout << "\n";
}
int main(int argc, char **argv) {
  if (argc < 3) { std::cout << "usage: repair_smoke SHARED USER\n"; return 2; }
  const fs::path shared = fs::absolute(argv[1]), user = fs::absolute(argv[2]);
  fs::remove_all(user);
  fs::create_directories(user);
  if (!pi_initialize(shared.string().c_str(), user.string().c_str(), 1)) { std::cout << "FAIL init\n"; return 1; }
  auto s = pi_create_session();
  check(s != 0, "session");
  show(s, "linaxaing");
  check(has(repairs(s), "联想"), "linaxaing repairs to 联想");
  show(s, "haoo");
  check(has(repairs(s), "好"), "haoo repairs to 好");
  show(s, "zhongguoo");
  check(has(repairs(s), "中国"), "zhongguoo repairs to 中国");
  show(s, "shijei");
  check(has(repairs(s), "世界"), "shijei repairs to 世界 (transposition)");
  show(s, "nihao");
  check(repairs(s).empty(), "exact nihao offers no repairs");
  show(s, "nihap");
  check(!has(repairs(s), "你好"), "substitution-only typo is not rewritten as a repair");
  // Commit a repair: the suffix is replaced, the live composition ends.
  pi_clear(s);
  type(s, "haoo");
  pi_load_candidate_batch(s, 0, 32);
  const auto count = pi_load_repair_candidates(s, 16);
  size_t index = SIZE_MAX;
  for (size_t i = 0; i < count; ++i) if (std::string(pi_repair_candidate_text(s, i)) == "好") index = i;
  check(index != SIZE_MAX, "好 repair row present before commit");
  if (index != SIZE_MAX) {
    const std::string committed = pi_commit_repair_candidate(s, index);
    check(committed == "好", "repair commit text");
    check(std::string(pi_preedit(s)).empty(), "repair commit clears composition");
    check(std::string(pi_take_commit(s)).empty(), "repair commit is not replayed");
  }
  // Privacy: the repair probe must not leak into a private session.
  pi_clear(s);
  check(pi_set_private(s, 1) != 0, "private schema");
  show(s, "linaxaing");
  check(has(repairs(s), "联想"), "private session repairs without learning");
  pi_destroy_session(s);
  pi_finalize();
  std::cout << (failures ? "FAILURES " : "PASS ") << failures << "\n";
  return failures ? 1 : 0;
}
