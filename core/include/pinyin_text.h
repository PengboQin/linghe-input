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
/* Alphabetic typing preserves the supplied spelling before edit proposals.
   Scores (context, personal frequency) only compare within one tier. Initials
   and an unfinished final are valid unedited paths, not misspellings. Nine-key
   digit codes deliberately have no alphabetic tier: their multi-path ranking
   is a different policy. These numbers are ordering classes, not word ranks. */
inline int alphabetic_candidate_priority(const std::string &input,
                                        const std::string &reading,
                                        bool corrected = false) {
  const auto raw = detail::cleaned(canonical_syllable(input));
  if (raw.empty() || !detail::latin_text(raw)) return 0;
  if (corrected) return 1;
  if (is_full_spelling(raw, reading)) return 3;
  // Long vowel-bearing drafts are mostly full pinyin. An arbitrary sentence
  // assembled from many initials is not stronger evidence than a real typo
  // correction (linaxaing must not be locked to li na xi ai neng gou).
  const bool mostly_full = raw.size() >= 7 && raw.find_first_of("aeiouv") != std::string::npos;
  if (covers(raw, reading, mostly_full ? 1 : 1000000)) return 2;
  return 0;
}
/* A native choice owns its consumption range. A same-text corrected choice
   must not replace a complete native reading or discard a valid unfinished
   next syllable (zheged -> 这个 + d). A complete extra vowel or transposed
   letters remain repairable (haoo / shijei). */
inline bool preserves_native_consumption(const std::string &input, const std::string &reading,
                                         const std::set<std::string> &syllables) {
  if (covers(input, reading)) return true;
  const int consumed = consumed_prefix(input, reading, false);
  if (consumed <= 0 || static_cast<size_t>(consumed) >= input.size()) return false;
  const auto pending = canonical_syllable(input.substr(static_cast<size_t>(consumed)));
  if (syllables.count(pending)) return false;
  const auto next = syllables.lower_bound(pending);
  return next != syllables.end() && next->compare(0, pending.size(), pending) == 0;
}
/* Soft continuity of one observed full nine-key reading. It never rewrites raw
   input or locks alternatives. A partial choice may consume whole syllables
   only; an ambiguous boundary drops the hint instead of guessing. */
struct NinePath {
  std::string reading, input, text;
  void clear() { reading.clear(); input.clear(); text.clear(); }
  static std::vector<std::string> characters(const std::string &value) {
    std::vector<std::string> out;
    for(size_t i=0;i<value.size();){const auto c=static_cast<unsigned char>(value[i]);const size_t n=c<0x80?1:c>=0xc2&&c<=0xdf?2:c>=0xe0&&c<=0xef?3:c>=0xf0&&c<=0xf4?4:0;
      if(!n||i+n>value.size())return{};for(size_t j=1;j<n;++j)if((static_cast<unsigned char>(value[i+j])&0xc0)!=0x80)return{};
      out.push_back(value.substr(i,n));i+=n;
    }return out;
  }
  static size_t distance(const std::string &a,const std::string &b) {
    if(a.size()>128||b.size()>130)return 131;
    std::vector<size_t> row(b.size()+1);for(size_t j=0;j<row.size();++j)row[j]=j;
    for(size_t i=1;i<=a.size();++i){size_t previous=row[0];row[0]=i;for(size_t j=1;j<=b.size();++j){const auto old=row[j];row[j]=std::min({row[j]+1,row[j-1]+1,previous+(a[i-1]!=b[j-1])});previous=old;}}
    return row.back();
  }
  std::string code() const { return encode_nine(reading); }
  void adapt(const std::string &current) {
    const auto known = input.empty() ? code():input;
    if (known.empty() || current.empty()) { clear(); return; }
    if (current.compare(0, known.size(), known) == 0) return;
    if (known.compare(0, current.size(), current) != 0) { clear(); return; }
    // Deleting inside an edited mapping cannot prove the original syllable
    // boundary cheaply. Drop this optional hint; leave every real key intact.
    if (known != code()) { clear(); return; }
    std::string kept; size_t length = 0;
    for (const auto &part : reading_parts(reading)) {
      length += encode_nine(part).size();
      if (length > current.size()) break;
      kept += (kept.empty() ? "" : " ") + part;
    }
    if(!text.empty()){
      const auto chars=characters(text);const auto count=reading_parts(kept).size();
      if(chars.size()!=reading_parts(reading).size())text.clear();
      else{std::string shortened;for(size_t i=0;i<count;++i)shortened+=chars[i];text=std::move(shortened);}
    }
    reading = kept;input=encode_nine(kept);
  }
  void consume(size_t keys) {
    const auto raw=input.empty()?code():input,canonical=code();
    if(keys>raw.size()){clear();return;}
    const auto rest_input=raw.substr(keys);
    if(raw!=canonical){
      // Accept a mapping boundary only when *all* optimal edit paths agree on
      // its canonical position. A repeated digit can otherwise eat the tail.
      const size_t n=raw.size(),m=canonical.size();
      if(n>128||m>130){clear();return;}
      std::vector<std::vector<size_t>> f(n+1,std::vector<size_t>(m+1)),r=f;
      for(size_t i=0;i<=n;++i)f[i][0]=i;
      for(size_t j=0;j<=m;++j)f[0][j]=j;
      for(size_t i=1;i<=n;++i)for(size_t j=1;j<=m;++j)f[i][j]=std::min({f[i-1][j]+1,f[i][j-1]+1,f[i-1][j-1]+size_t(raw[i-1]!=canonical[j-1])});
      for(size_t i=0;i<=n;++i)r[i][m]=n-i;
      for(size_t j=0;j<=m;++j)r[n][j]=m-j;
      for(size_t i=n;i-->0;)for(size_t j=m;j-->0;)r[i][j]=std::min({r[i+1][j]+1,r[i][j+1]+1,r[i+1][j+1]+size_t(raw[i]!=canonical[j])});
      size_t mapped=0,count=0;
      for(size_t j=0;j<=m;++j)if(f[keys][j]+r[keys][j]==f[n][m]){mapped=j;++count;}
      if(count!=1){clear();return;}keys=mapped;
    }
    std::string rest; size_t length = 0; bool boundary = keys == 0;
    for (const auto &part : reading_parts(reading)) {
      if (length >= keys) rest += (rest.empty() ? "" : " ") + part;
      length += encode_nine(part).size();
      if (length == keys) boundary = true;
    }
    if(!text.empty()){
      const auto chars=characters(text);const auto count=reading_parts(reading).size(),remaining=reading_parts(rest).size();
      if(!boundary||chars.size()!=count)text.clear();
      else{std::string suffix;for(size_t i=count-remaining;i<count;++i)suffix+=chars[i];text=std::move(suffix);}
    }
    reading = boundary ? rest : "";input=reading.empty()?"":rest_input;
  }
  // Exact remaining path, compatible shorter word, unrelated/unknown.
  int priority(const std::string &candidate) const {
    const auto expected = reading_parts(reading), actual = reading_parts(candidate);
    if (expected.empty() || actual.empty()) return 2;
    const auto n = std::min(expected.size(), actual.size());
    for (size_t i = 0; i < n; ++i) if (expected[i] != actual[i]) return 2;
    return actual.size() == expected.size() ? 0 : actual.size() < expected.size() ? 1 : 2;
  }
};
}  // namespace pinyin
}  // namespace private_input
#endif
#endif
