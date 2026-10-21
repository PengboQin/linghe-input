#include "pinyin_text.h"
#include "desktop_candidates.hpp"
#include <iostream>
#include <set>
#include <stdexcept>

static unsigned assertions = 0;
static void check(bool value, const char *message) {
  ++assertions;
  if (!value) throw std::runtime_error(message);
}

int main() {
  using namespace private_input::pinyin;
  const std::set<std::string> syllables{"hao", "shi", "shen", "shenme", "dao", "duo", "de", "jie"};
  check(preserves_native_consumption("zheged", "zhe ge", syllables), "keep pending d");
  check(preserves_native_consumption("zhegesh", "zhe ge", syllables), "keep pending sh");
  check(preserves_native_consumption("nihao", "ni hao", syllables), "keep exact native word");
  check(!preserves_native_consumption("haoo", "hao", syllables), "allow extra vowel repair");
  check(!preserves_native_consumption("shijei", "shi jie", syllables), "allow transposition repair");
  check(is_full_spelling("lue", "lve"), "u/v equivalent");
  check(consumed_prefix("csm", "chi shen me", false) == 3, "initial abbreviation");
  check(consumed_prefix("shih", "shi hou", false) == 4, "unfinished final syllable");
  private_input::DesktopCandidates nav;
  nav.columns = 6;
  nav.count = 42;
  nav.selected = 8;
  check(nav.shortcut(8) == 3, "selected row shortcut");
  check(nav.shortcut(2) == 0, "other row has no shortcut");
  check(nav.digit(3) == 8, "digit resolves selected row");
  check(nav.digit(0) == nav.count, "zero is not candidate selection");
  std::cout << "PASS " << assertions << " shared spelling/consumption/navigation checks\n";
}
