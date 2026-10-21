#ifndef PRIVATE_INPUT_PINYIN_TEXT_H
#define PRIVATE_INPUT_PINYIN_TEXT_H
/* Spelling helpers shared by platform front ends. Pure ASCII input only;
   every function refuses anything it cannot interpret instead of guessing.

   Header-only on purpose: the Apple Xcode target, the Android CMake target and
   the engine test scripts each compile core/src/private_input.cpp as a single
   translation unit and do not list extra core sources. Keeping the helpers
   inline here leaves every existing build untouched. */
#include <algorithm>
#include <map>
#include <set>
#include <string>
#include <vector>
#ifdef __cplusplus
namespace private_input {
namespace pinyin {
namespace detail {
inline bool latin_text(const std::string &value) {
  return std::all_of(value.begin(), value.end(), [](char c) { return c >= 'a' && c <= 'z'; });
}
inline std::string cleaned(const std::string &input) {
  std::string out;
  for (char c : input) {
    if (c == ' ' || c == '\'') continue;
    out.push_back(c);
  }
  return out;
}
}  // namespace detail
/* lue/nue -> lve/nve; lower case; no other rewriting. */
inline std::string canonical_syllable(const std::string &value) {
  std::string out;
  for (size_t i = 0; i < value.size(); ++i) {
    unsigned char c = static_cast<unsigned char>(value[i]);
    // UTF-8 "ü" (C3 BC); the interface accepts it as v.
    if (c == 0xC3 && i + 1 < value.size() && static_cast<unsigned char>(value[i + 1]) == 0xBC) {
      out.push_back('v');
      ++i;
      continue;
    }
    if (c >= 'A' && c <= 'Z') out.push_back(char(c - 'A' + 'a'));
    else out.push_back(char(c));
  }
  if (out == "lue") return "lve";
  if (out == "nue") return "nve";
  return out;
}
/* Accepted spellings of one syllable (lve also accepts lue). */
inline std::vector<std::string> full_forms(const std::string &syllable) {
  const auto value = canonical_syllable(syllable);
  if (value == "lve") return {value, "lue"};
  if (value == "nve") return {value, "nue"};
  return {value};
}
inline std::vector<std::string> reading_parts(const std::string &reading) {
  std::vector<std::string> parts;
  std::string current;
  for (char c : reading) {
    if (c == ' ' || c == '\'') {
      if (!current.empty()) parts.push_back(current);
      current.clear();
    } else {
      current.push_back(char(c >= 'A' && c <= 'Z' ? c - 'A' + 'a' : c));
    }
  }
  if (!current.empty()) parts.push_back(current);
  return parts;
}
/* Whole input equals these syllables, no abbreviations. */
inline bool is_full_spelling(const std::string &input, const std::string &reading) {
  const auto raw = detail::cleaned(canonical_syllable(input));
  const auto parts = reading_parts(reading);
  if (raw.empty() || raw.size() > 128 || parts.empty()) return false;
  std::set<size_t> positions{0};
  for (const auto &part : parts) {
    std::set<size_t> next;
    for (size_t start : positions) {
      if (start > raw.size()) continue;
      for (const auto &form : full_forms(part))
        if (!form.empty() && raw.compare(start, form.size(), form) == 0) next.insert(start + form.size());
    }
    positions = next;
    if (positions.empty()) return false;
  }
  return positions.count(raw.size()) != 0;
}
/* Latin reading -> 2..9 digits; empty when the reading is not pure latin. */
inline std::string encode_nine(const std::string &reading) {
  static const char map[] = "22233344455566677778889999";
  std::string out;
  for (unsigned char c : reading) {
    if (c == ' ' || c == '\'') continue;
    if (c < 'a' || c > 'z') return {};
    out.push_back(map[c - 'a']);
  }
  return out;
}
/* Longest prefix of input consumed by these syllables, mixing full spellings
   and initials; trailing keys stay editable. -1 when nothing matches. */
inline int consumed_prefix(const std::string &input, const std::string &reading, bool nine_key) {
  const auto raw = canonical_syllable(input);
  const auto parts = reading_parts(reading);
  if (raw.empty() || raw.size() > 128 || parts.empty() || parts.size() > 64) return -1;
  const bool shaped = std::all_of(raw.begin(), raw.end(), [nine_key](char c) {
    return nine_key ? (c >= '2' && c <= '9') : (c >= 'a' && c <= 'z');
  });
  if (!shaped) return -1;
  std::set<size_t> positions{0};
  for (size_t index = 0; index < parts.size(); ++index) {
    const auto &part = parts[index];
    if (!detail::latin_text(part)) return -1;
    auto encode = [nine_key](const std::string &text) { return nine_key ? encode_nine(text) : text; };
    const auto full = encode(part);
    std::set<std::string> forms{encode(part.substr(0, 1))};
    for (const auto &form : full_forms(part)) forms.insert(encode(form));
    if (part.size() >= 2 && (part.compare(0, 2, "zh") == 0 || part.compare(0, 2, "ch") == 0 || part.compare(0, 2, "sh") == 0))
      forms.insert(encode(part.substr(0, 2)));
    std::set<size_t> next;
    for (size_t position : positions) {
      if (position >= raw.size()) continue;
      const auto suffix = raw.substr(position);
      if (index + 1 == parts.size() && !full.empty() && suffix.size() <= full.size() && full.compare(0, suffix.size(), suffix) == 0)
        next.insert(raw.size());
      for (const auto &form : forms) {
        if (form.empty()) continue;
        if (suffix.compare(0, form.size(), form) == 0) next.insert(position + form.size());
      }
    }
    positions = next;
    if (positions.empty()) return -1;
  }
  if (positions.empty()) return -1;
  return static_cast<int>(*positions.rbegin());
}
/* Whole input reachable with at most max_abbreviations initial-only parts. */
inline bool covers(const std::string &input, const std::string &reading, int max_abbreviations = 1000000) {
  const auto raw = detail::cleaned(canonical_syllable(input));
  const auto parts = reading_parts(reading);
  if (raw.empty() || raw.size() > 96 || parts.empty() || parts.size() > 32) return false;
  std::map<size_t, int> positions{{0, 0}};
  for (size_t index = 0; index < parts.size(); ++index) {
    const auto &part = parts[index];
    std::map<size_t, int> next;
    auto note = [&next](size_t end, int cost, int limit) {
      if (cost > limit) return;
      auto found = next.find(end);
      if (found == next.end() || cost < found->second) next[end] = cost;
    };
    for (const auto &entry : positions) {
      const size_t position = entry.first;
      if (position >= raw.size()) continue;
      const auto suffix = raw.substr(position);
      const auto forms_all = full_forms(part);
      std::set<std::string> forms{part.substr(0, 1)};
      for (const auto &form : forms_all) forms.insert(form);
      if (part.size() >= 2 && (part.compare(0, 2, "zh") == 0 || part.compare(0, 2, "ch") == 0 || part.compare(0, 2, "sh") == 0))
        forms.insert(part.substr(0, 2));
      if (index + 1 == parts.size() && suffix.size() <= part.size() && part.compare(0, suffix.size(), suffix) == 0)
        note(raw.size(), entry.second + (suffix == part ? 0 : 1), max_abbreviations);
      for (const auto &form : forms) {
        if (form.empty()) continue;
        if (suffix.compare(0, form.size(), form) != 0) continue;
        const bool full = std::find(forms_all.begin(), forms_all.end(), form) != forms_all.end();
        note(position + form.size(), entry.second + (full ? 0 : 1), max_abbreviations);
      }
    }
    positions = next;
    if (positions.empty()) return false;
  }
  return positions.count(raw.size()) != 0;
}
inline bool is_nine_code(const std::string &input) {
  if (input.empty()) return false;
  return std::all_of(input.begin(), input.end(), [](char c) { return c >= '2' && c <= '9'; });
}
}  // namespace pinyin
}  // namespace private_input
#endif
#endif
