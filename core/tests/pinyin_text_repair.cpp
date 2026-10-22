#include "pinyin_repair.h"
#include "pinyin_text.h"
#include <fstream>
#include <iostream>
#include <set>
#include <string>
using namespace private_input::pinyin;
static int failures = 0;
static void check(bool ok, const std::string &what) {
  if (!ok) { std::cout << "FAIL " << what << "\n"; ++failures; }
}
static bool has(const std::vector<RepairProposal> &rows, const std::string &spelling) {
  for (const auto &row : rows) if (row.spelling == spelling) return true;
  return false;
}
int main(int argc, char **argv) {
  std::set<std::string> syllables;
  if (argc > 1) {
    std::ifstream in(argv[1]);
    std::string line;
    while (std::getline(in, line)) if (!line.empty()) syllables.insert(line);
  }
  std::cout << "syllables=" << syllables.size() << "\n";
  Corrector corrector(syllables);
  auto show = [&](const std::string &input) {
    const auto rows = corrector.proposals(input, 64);
    std::cout << input << " -> ";
    for (size_t i = 0; i < rows.size() && i < 12; ++i) std::cout << rows[i].spelling << "(" << rows[i].edits << "/" << rows[i].cost << ") ";
    std::cout << "\n";
    return rows;
  };
  // Apple acceptance inputs: linaxaing -> lianxiang, haoo -> hao, nihap -> nihao.
  check(has(show("linaxaing"), "lianxiang"), "linaxaing includes lianxiang");
  check(has(show("haoo"), "hao"), "haoo includes hao");
  check(!has(show("nihap"), "nihao"), "a substituted key is not claimed as a repair");
  check(has(show("nihaoo"), "nihao"), "nihaoo includes nihao");
  check(has(show("zhongguoo"), "zhongguo"), "zhongguoo includes zhongguo");
  check(has(show("shenm"), "shenme"), "shenm includes shenme");
  // Rejections: short, non-latin, and an already exact spelling.
  check(corrector.proposals("hao", 16).empty(), "three keys are not corrected");
  check(corrector.proposals("nih4o", 16).empty(), "digits are rejected");
  check(!has(corrector.proposals("nihao", 64), "nihao"), "exact spelling is not proposed");
  // Shared spelling contract.
  check(is_full_spelling("nihao", "ni hao"), "nihao is a full spelling");
  check(!is_full_spelling("nh", "ni hao"), "nh is not a full spelling");
  check(is_full_spelling("lue", "lve"), "lue matches lve");
  check(consumed_prefix("shih", "shi hou", false) == 4, "shih consumes the trailing initial");
  check(consumed_prefix("csm", "chi shen me", false) == 3, "csm consumes three initials");
  check(consumed_prefix("niha", "ni hao", false) == 4, "unfinished final stays pending");
  check(covers("nh", "ni hao", 2), "nh covers ni hao");
  check(!covers("nh", "ni hao", 1), "nh exceeds one abbreviation");
  check(encode_nine("zhong guo") == "94664486", "nine-key encoding");
  check(alphabetic_candidate_priority("nihao", "ni hao") == 3, "full spelling uses exact tier");
  check(alphabetic_candidate_priority("lue", "lve") == 3, "umlaut aliases remain exact");
  check(alphabetic_candidate_priority("csm", "chi shen me") == 2, "initials are an unedited path");
  check(alphabetic_candidate_priority("shih", "shi hou") == 2, "unfinished final is an unedited path");
  check(alphabetic_candidate_priority("shih", "shi", true) == 1, "deletion repair follows valid unfinished spelling");
  check(alphabetic_candidate_priority("linaxaing", "lian xiang", true) == 1, "transposition repair remains a fallback");
  check(alphabetic_candidate_priority("linaxaing", "li na xi ai neng gou") == 0, "many accidental initial matches do not defeat a full-pinyin typo repair");
  check(alphabetic_candidate_priority("nihao", "ni") == 0, "unconsumed prefix does not become an exact whole");
  check(alphabetic_candidate_priority("968", "you") == 0, "nine-key is outside alphabetic tier policy");
  check(is_nine_code("94664486") && !is_nine_code("94664a") && !is_nine_code(""),
        "nine-key code validation");
  std::cout << (failures ? "FAILURES " : "PASS ") << failures << "\n";
  return failures ? 1 : 0;
}
