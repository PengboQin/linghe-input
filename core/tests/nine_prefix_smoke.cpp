#include "private_input.h"
#include "private_pinyin_syllables.h"
#include <algorithm>
#include <filesystem>
#include <iostream>
#include <set>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

void require(bool value, const std::string &message) { if (!value) throw std::runtime_error(message); }
void type(PI_Session session, const std::string &text) {
  for (char c : text) require(pi_process_key(session, c, 0), "Unhandled key in " + text);
}
std::set<std::string> options(PI_Session session) {
  std::set<std::string> result;
  const auto count = pi_nine_syllable_count(session);
  for (size_t i = 0; i < count; ++i) result.emplace(pi_nine_syllable_text(session, i));
  return result;
}
std::vector<std::string> ordered_options(PI_Session session) {
  std::vector<std::string> result;
  const auto count = pi_nine_syllable_count(session);
  for (size_t i = 0; i < count; ++i) result.emplace_back(pi_nine_syllable_text(session, i));
  return result;
}
void longer_first(PI_Session session, const std::string &longer, const std::string &shorter) {
  const auto rows = ordered_options(session);
  const auto a = std::find(rows.begin(), rows.end(), longer), b = std::find(rows.begin(), rows.end(), shorter);
  require(a != rows.end() && b != rows.end(), "Missing manual reading in " + std::string(pi_raw_input(session)));
  require(a < b, "Short reading " + shorter + " precedes longer match " + longer);
}
void preserves_native_ties(PI_Session session, const std::string &digits) {
  const auto rows = ordered_options(session);
  const std::string mapping = "22233344455566677778889999";
  std::vector<std::string> native;
  for (size_t offset = 0; offset < 256; offset += 128) {
    const auto count = pi_load_candidate_batch(session, offset, 128);
    for (size_t i = 0; i < count; ++i) {
      std::string comment(pi_batch_candidate_comment(session, i));
      std::replace(comment.begin(), comment.end(), '\'', ' ');
      std::istringstream stream(comment); std::string reading;
      if (!(stream >> reading) || reading.size() != digits.size()) continue;
      std::string code;
      for (char c : reading) if (c >= 'a' && c <= 'z') code += mapping[c - 'a'];
      if (code == digits && std::find(rows.begin(), rows.end(), reading) != rows.end() &&
          std::find(native.begin(), native.end(), reading) == native.end()) native.push_back(reading);
    }
    if (count < 128) break;
  }
  require(native.size() >= 2, "Tie fixture must expose multiple native complete readings");
  size_t previous = 0;
  for (size_t i = 0; i < native.size(); ++i) {
    const auto index = static_cast<size_t>(std::find(rows.begin(), rows.end(), native[i]) - rows.begin());
    require(i == 0 || index > previous, "Equal-length matching changed native frequency order");
    previous = index;
  }
}
void filter(PI_Session session, const std::string &wanted) {
  const auto count = pi_nine_syllable_count(session);
  for (size_t i = 0; i < count; ++i) if (wanted == pi_nine_syllable_text(session, i)) {
    require(pi_nine_select_syllable(session, i), "Cannot select " + wanted);
    require(std::string(pi_take_commit(session)).empty(), "Filter committed host text");
    return;
  }
  throw std::runtime_error("Missing filter: " + wanted + " in " + pi_raw_input(session));
}
size_t candidate(PI_Session session, const std::string &wanted) {
  const auto count = pi_load_candidate_batch(session, 0, 128);
  for (size_t i = 0; i < count; ++i)
    if (wanted == pi_batch_candidate_text(session, i)) return pi_batch_candidate_index(session, i);
  throw std::runtime_error("Missing candidate " + wanted + " in " + pi_raw_input(session));
}
int main(int argc, char **argv) {
  try {
    require(argc == 3, "Usage: nine_prefix_smoke RESOURCES FRESH_DATA");
    require(!std::filesystem::exists(argv[2]), "Synthetic directory must be new");
    std::filesystem::create_directories(argv[2]);
    require(pi_initialize(argv[1], argv[2], 0), "Initialize");
    const auto session = pi_create_session();
    require(session && pi_set_nine_key(session, 1), "Nine-key schema");
    const std::string mapping = "22233344455566677778889999";
    size_t initials = 0;
    for (char digit = '2'; digit <= '9'; ++digit) {
      std::set<std::string> expected;
      for (const char *entry : private_input::pinyin_syllables)
        if (mapping[entry[0] - 'a'] == digit) expected.emplace(1, entry[0]);
      for (const auto &letter : expected) {
        pi_clear(session); type(session, std::string(1, digit));
        require(options(session).count(letter), "Single key hides initial " + letter);
        filter(session, letter);
        require(std::string(pi_raw_input(session)) == letter, "Initial inserted a premature boundary");
        require(pi_process_key(session, 0xff08, 0), "Initial backspace");
        require(std::string(pi_raw_input(session)) == std::string(1, digit), "Initial undo lost raw key");
        ++initials;
      }
    }
    pi_clear(session); type(session, "3"); filter(session, "d"); type(session, "84");
    require(std::string(pi_raw_input(session)) == "d84", "Follow-up digits were split from d");
    candidate(session, "对"); filter(session, "dui");
    require(std::string(pi_raw_input(session)) == "dui'", "Full filter did not complete mixed spelling");
    require(pi_select_candidate_absolute(session, candidate(session, "对")), "Commit 对");
    require(std::string(pi_take_commit(session)) == "对", "Wrong commit after initial narrowing");
    require(!pi_nine_can_undo_syllable(session), "Committed initial left undo state");

    pi_clear(session); type(session, "368"); filter(session, "d"); filter(session, "do");
    require(std::string(pi_raw_input(session)) == "do8", "Second unfinished filter split the current syllable");
    candidate(session, "都"); filter(session, "dou");
    for (const auto &expected : {"do8", "d68", "368"}) {
      require(pi_process_key(session, 0xff08, 0), "Nested prefix backspace");
      require(std::string(pi_raw_input(session)) == expected, "Nested prefix undo changed tail");
    }

    // A two-letter unfinished spelling uses the same path, not a d/f special case.
    pi_clear(session); type(session, "74"); filter(session, "sh"); type(session, "4");
    candidate(session, "是"); filter(session, "shi");
    require(std::string(pi_raw_input(session)) == "shi'", "sh prefix did not finish shi");
    pi_clear(session); type(session, "3"); filter(session, "e"); type(session, "6");
    filter(session, "en"); require(std::string(pi_raw_input(session)) == "en'", "Single e could not extend to en");

    // Longer complete matches precede their shorter alternatives, regardless
    // of a word's candidate frequency; both readings remain selectable.
    for (const auto &example : std::vector<std::vector<std::string>>{
        {"2426", "chao", "chan", "cha"}, {"9426", "zhao", "zhan", "zha"}}) {
      pi_clear(session); type(session, example[0]);
      longer_first(session, example[1], example[3]);
      longer_first(session, example[2], example[3]);
      preserves_native_ties(session, example[0]);
      const auto rows = ordered_options(session);
      const auto initial = example[3].substr(0, 1);
      const auto unfinished = std::find(rows.begin(), rows.end(), initial);
      require(unfinished != rows.end(), "Unfinished initial disappeared after sorting");
      require(std::find(rows.begin(), rows.end(), example[1]) < unfinished, "Unfinished prefix displaced complete match");
      filter(session, example[3]);
      require(std::string(pi_raw_input(session)) == example[3] + "'6", "Shorter filter consumed the remaining key");
      require(pi_process_key(session, 0xff08, 0), "Undo sorted short filter");
      require(std::string(pi_raw_input(session)) == example[0], "Sorted filter undo changed raw keys");
      filter(session, initial);
      require(std::string(pi_raw_input(session)) == initial + example[0].substr(1), "Unfinished filter inserted a boundary");
      longer_first(session, example[1], example[3]);
      filter(session, example[1]);
      require(std::string(pi_raw_input(session)) == example[1] + "'", "Long filter did not consume its exact keys");
    }

    // The same priority applies to a later sentence segment. Selecting its
    // longer reading consumes only that segment and preserves all following keys.
    pi_clear(session); type(session, "7826242638474666"); filter(session, "quan");
    longer_first(session, "chao", "cha"); filter(session, "chao");
    require(std::string(pi_raw_input(session)) == "quan'chao'38474666", "Sorted second reading changed sentence tail");
    require(pi_process_key(session, 0xff08, 0), "Undo sorted sentence reading");
    require(std::string(pi_raw_input(session)) == "quan'242638474666", "Sorted sentence undo lost locked prefix");

    pi_clear(session); type(session, "644262426384"); filter(session, "ni"); filter(session, "hao");
    require(pi_select_candidate_absolute(session, candidate(session, "你好")), "Select sorted-test Chinese prefix");
    require(std::string(pi_take_commit(session)).empty(), "Sorted-test prefix committed too early");
    longer_first(session, "chao", "cha"); filter(session, "chao");
    require(std::string(pi_preedit(session)).find("你好") == 0, "Sorting withdrew selected Chinese prefix");
    const std::string sorted_prefix_raw(pi_raw_input(session));
    require(sorted_prefix_raw.size() >= 8 && sorted_prefix_raw.substr(sorted_prefix_raw.size() - 8) == "chao'384", "Sorted selected-prefix filter changed remaining keys");

    pi_clear(session); type(session, "782638474472666"); filter(session, "quan");
    filter(session, "d");
    require(std::string(pi_raw_input(session)) == "quan'd8474472666", "Long sentence initial lost prefix or tail");
    filter(session, "dui");
    require(std::string(pi_raw_input(session)) == "quan'dui'74472666", "Long sentence full filter ate tail");
    require(pi_process_key(session, 0xff08, 0), "Full filter undo");
    require(std::string(pi_raw_input(session)) == "quan'd8474472666", "Full filter undo lost fixed initial");
    require(pi_process_key(session, 0xff08, 0), "Initial filter undo");
    require(std::string(pi_raw_input(session)) == "quan'38474472666", "Initial undo lost ambiguous sentence");

    // Host-selected Chinese prefix and its following single key stay independent.
    pi_clear(session); type(session, "644263"); filter(session, "ni"); filter(session, "hao");
    require(pi_select_candidate_absolute(session, candidate(session, "你好")), "Select prefix 你好");
    require(std::string(pi_take_commit(session)).empty(), "Prefix committed too early");
    for (const auto &letter : {"d", "e", "f"}) require(options(session).count(letter), "Selected prefix hides " + std::string(letter));
    filter(session, "d"); type(session, "84"); filter(session, "dui");
    require(std::string(pi_preedit(session)).find("你好") == 0, "Initial filter withdrew selected Chinese prefix");
    require(pi_select_candidate_absolute(session, candidate(session, "对")), "Select tail 对");
    require(std::string(pi_take_commit(session)) == "你好对", "Selected prefix final commit was altered");

    require(pi_set_private(session, 1), "Private nine-key schema");
    type(session, "3"); filter(session, "f"); type(session, "68"); filter(session, "fou"); candidate(session, "否");
    // Every finite algebra split (1..5 fixed letters) must retain one syllable.
    const std::string longest = "zhuang", longest_code = "948264";
    for (size_t split = 1; split < longest.size(); ++split) {
      pi_clear(session);
      const auto mixed = longest.substr(0, split) + longest_code.substr(split);
      require(pi_set_prediction_input(session, mixed.c_str()), "Set isolated mixed-code probe");
      candidate(session, "装"); filter(session, "zhuang");
      require(std::string(pi_raw_input(session)) == "zhuang'", "Finite prefix split changed phonetic boundaries");
    }
    pi_destroy_session(session); pi_finalize();
    std::cout << "PASS: " << initials << " public initials across 2..9; d84/dui, sh4/shi, e6/en; longest complete readings first, shorter/incomplete choices and undo retained; locked and selected sentence prefixes; exact commit/undo/private schema; all 1..5 mixed-code algebra splits\n";
  } catch (const std::exception &error) { std::cerr << error.what() << '\n'; return 1; }
}
