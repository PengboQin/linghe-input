#include "private_input.h"
#include "private_pinyin_syllables.h"
#include "pinyin_repair.h"
#include "pinyin_text.h"
#include "rime_api.h"
#include "rime_levers_api.h"
#include <map>
#include <mutex>
#include <string>
#include <vector>
#include <algorithm>
#include <fstream>
#include <sstream>
#include <set>
#include <memory>
#include <functional>
#include <leveldb/db.h>
#include <cmath>
#include <unordered_map>

namespace {
struct StreamCandidate { std::string text, comment; size_t index; };
struct Syllable { std::string text; size_t start, consumed; bool complete = true; };
struct SyllableUndo { std::string before, after; };
struct RepairRow { std::string text, reading, spelling; size_t absolute = SIZE_MAX; int edits = 0; };
struct Snapshot { std::vector<Syllable> syllables; std::vector<SyllableUndo> syllable_undo; std::vector<StreamCandidate> batch, ranked; std::vector<RepairRow> repairs; bool ranked_ready = false; std::string preedit, input, commit, display_preedit, active_reading,selected_prefix; std::vector<std::string> candidates; std::vector<size_t> indices; int page = 0; bool next_page = false; bool nine_key = false, private_mode = false, exact_probe = false; };
std::recursive_mutex gate;
std::map<PI_Session, Snapshot> sessions;
RimeApi *api = nullptr;
std::string shared_path, user_path;
bool exact_probe_available=false;
const char *empty = "";
using Preferences = std::map<std::pair<std::string, std::string>, unsigned long long>;
Preferences preferences;
std::set<std::pair<std::string, std::string>> pinned_words;
/* Public syllables for the bounded repair lattice; empty when resources are
   absent, in which case no repair rows are offered (never guessed). */
private_input::pinyin::Corrector repair_corrector;
/* Repair validation joins syllables: the dictionary reading must equal the
   proposed spelling exactly, so a prefix word never masquerades as a repair. */
std::string joined_repair_reading(const std::string &reading) {
  std::string out;
  for (const auto &part : private_input::pinyin::reading_parts(reading)) out += part;
  return out;
}
/* Word weights from the pinned Rime essay.txt, used only to keep a common
   word above an obscure homophone in repair ranking. Bounded at load time. */
std::unordered_map<std::string, unsigned long long> word_weights;
/* Repair resources are loaded on first use only. Apple front ends never call
   the repair API, so they pay no startup cost or extra memory for it. */
bool repair_resources_loaded = false;
void load_word_weights(const std::string &shared) {
  std::ifstream stream(shared + "/essay.txt");
  if (!stream) return;
  std::string line; size_t loaded = 0;
  while (std::getline(stream, line) && loaded < 200000) {
    if (!line.empty() && line.back() == '\r') line.pop_back();
    const auto tab = line.rfind('\t');
    if (tab == std::string::npos || tab == 0 || tab + 1 >= line.size()) continue;
    unsigned long long weight = 0;
    try { weight = std::stoull(line.substr(tab + 1)); } catch (...) { continue; }
    if (weight < 500) continue;
    const auto text = line.substr(0, tab);
    if (text.empty() || text.size() > 64) continue;
    auto found = word_weights.find(text);
    if (found == word_weights.end()) { word_weights.emplace(text, weight); ++loaded; }
    else if (weight > found->second) found->second = weight;
  }
}
void load_repair_syllables(const std::string &shared) {
  std::set<std::string> syllables;
  for (const auto &candidate : {shared + "/../semantic/pinyin-syllables.txt", shared + "/semantic/pinyin-syllables.txt"}) {
    std::ifstream stream(candidate);
    if (!stream) continue;
    std::set<std::string> next; std::string line; bool valid = true;
    while (std::getline(stream, line) && next.size() <= 800) {
      if (!line.empty() && line.back() == '\r') line.pop_back();
      if (line.empty()) continue;
      if (line.size() > 8 || !std::all_of(line.begin(), line.end(), [](char c) { return c >= 'a' && c <= 'z'; })) { valid = false; break; }
      next.insert(line);
    }
    if (valid && next.size() >= 300 && next.size() <= 600) { syllables = std::move(next); break; }
  }
  repair_corrector = private_input::pinyin::Corrector(syllables);
}
std::string normalized_reading(const std::string &value) {
  std::string result, token;
  const auto flush = [&] {
    if(token=="lue") token="lve";
    else if(token=="nue") token="nve";
    result+=token;token.clear();
  };
  for (unsigned char c : value) {
    if (c == ' ' || c == '\'') {flush();continue;}
    if (c < 'a' || c > 'z') return {};
    token += c;
  }
  flush();
  return result;
}
bool read_preferences(const char *file, Preferences &next) {
  std::ifstream stream(file, std::ios::binary);
  if (!stream) return false;
  stream.seekg(0, std::ios::end); const auto size = stream.tellg();
  if (size < 0 || size > 2 * 1024 * 1024) return false;
  stream.seekg(0); std::string line; size_t records = 0;
  while (std::getline(stream, line)) {
    if (!line.empty() && line.back() == '\r') line.pop_back(); // Native Windows TSV line endings.
    if (line.empty() || line[0] == '#') continue;
    const auto first = line.find('\t'), last = line.rfind('\t');
    if (first == std::string::npos || first == last || line.find('\t', first + 1) != last) return false;
    const auto text = line.substr(0, first), reading = normalized_reading(line.substr(first + 1, last - first - 1));
    const auto number = line.substr(last + 1);
    if (text.empty() || text.size() > 1024 || text.find('\0') != std::string::npos || text.find('\r') != std::string::npos || reading.empty() || reading.size() > 128 || ++records > 5000) return false;
    long long count = 0; size_t consumed = 0;
    try { count = std::stoll(number, &consumed); } catch (...) { return false; }
    if (consumed != number.size() || count < -1 || count > 1000000000) return false;
    if (!next.emplace(std::make_pair(reading, text), count < 0 ? 0 : count).second) return false;
  }
  return stream.eof();
}
std::string nine_reading(const std::string &reading) {
  static const char *digits = "22233344455566677778889999";
  std::string result; for (char c : reading) { if (c >= 'a' && c <= 'z') result += digits[c - 'a']; else if (c >= '2' && c <= '9') result += c; else if (c != ' ' && c != '\'') return {}; }
  return result;
}
// Show the letters actually keyed for a valid native abbreviated candidate.
// Prefer whole syllables; an initial consumes exactly one key. This is display
// only and never expands the raw input or commits the suggested completion.
std::string abbreviated_nine_reading(const std::string &reading, const std::string &digits) {
  if (digits.empty() || digits.size() > 128) return {};
  std::istringstream stream(reading); std::vector<std::string> parts;
  for (std::string part; stream >> part;) {
    if (normalized_reading(part) != part || part.empty()) return {};
    parts.push_back(part);
  }
  if (parts.empty() || parts.size() > 128) return {};
  std::set<std::pair<size_t, size_t>> failed;
  std::function<bool(size_t, size_t, std::string &)> match = [&](size_t syllable, size_t offset, std::string &out) {
    if (offset == digits.size()) { out.clear(); return true; }
    if (syllable == parts.size() || failed.count({syllable, offset})) return false;
    const auto &part = parts[syllable]; const auto code = nine_reading(part);
    const size_t remaining = digits.size() - offset;
    if (remaining < code.size() && code.compare(0, remaining, digits, offset, remaining) == 0) {
      out = part.substr(0, remaining); return true;
    }
    std::string tail;
    if (digits.compare(offset, code.size(), code) == 0 && match(syllable + 1, offset + code.size(), tail)) {
      out = part + (tail.empty() ? "" : " " + tail); return true;
    }
    if (code[0] == digits[offset] && match(syllable + 1, offset + 1, tail)) {
      out = part.substr(0, 1) + (tail.empty() ? "" : " " + tail); return true;
    }
    failed.insert({syllable, offset}); return false;
  };
  std::string result; return match(0, 0, result) ? result : "";
}
void refresh(PI_Session id) {
  auto it = sessions.find(id);
  if (!api || it == sessions.end()) return;
  auto &s = it->second;
  s.preedit.clear(); s.active_reading.clear();s.selected_prefix.clear(); s.candidates.clear(); s.indices.clear(); s.batch.clear(); s.ranked.clear(); s.ranked_ready = false; s.repairs.clear();
  const char *raw = api->get_input(id); s.input = raw ? raw : ""; s.page = 0; s.next_page = false;
  s.syllables.clear();
  if (s.input.empty()) s.syllable_undo.clear();
  RimeContext context{}; RIME_STRUCT_INIT(RimeContext, context);
  if (api->get_context(id, &context)) {
    if (context.composition.preedit) s.preedit = context.composition.preedit;
    s.page = context.menu.page_no; s.next_page = !context.menu.is_last_page && context.menu.num_candidates > 0;
    for (int i = 0; i < context.menu.num_candidates; ++i)
      s.candidates.emplace_back(context.menu.candidates[i].text ? context.menu.candidates[i].text : "");
    const auto selected = static_cast<size_t>(std::max(0, context.composition.sel_start));
    s.active_reading = selected <= s.preedit.size() ? s.preedit.substr(selected) : "";
    if (selected<=s.preedit.size()) s.selected_prefix=s.preedit.substr(0,selected);
    api->free_context(&context);
    for (size_t i = 0; i < s.candidates.size(); ++i) s.indices.push_back(i);
    const char *input = api->get_input(id);
    const auto reading = s.nine_key ? nine_reading(input ? input : "") : normalized_reading(input ? input : "");
    if (!s.private_mode && !reading.empty() && !preferences.empty()) {
      const auto original = s.candidates;
      auto score = [&](size_t i) {
        if (!s.nine_key) { auto p = preferences.find({reading, original[i]}); return p == preferences.end() ? 0ULL : p->second; }
        unsigned long long result = 0; for (const auto &p : preferences) if (p.first.second == original[i] && nine_reading(p.first.first) == reading) result = std::max(result, p.second); return result;
      };
      std::stable_sort(s.indices.begin(), s.indices.end(), [&](size_t a, size_t b) { return score(a) > score(b); });
      for (size_t i = 0; i < s.indices.size(); ++i) s.candidates[i] = original[s.indices[i]];
    }
  }
}
RimeLeversApi *levers() {
  if (!api) return nullptr;
  auto *module = api->find_module("levers");
  return module && module->get_api ? reinterpret_cast<RimeLeversApi *>(module->get_api()) : nullptr;
}
}
extern "C" {
int pi_initialize(const char *shared_dir, const char *user_dir, int deploy) {
  std::lock_guard<std::recursive_mutex> lock(gate);
  if (!shared_dir || !user_dir || !*shared_dir || !*user_dir) return 0;
  if (api) return shared_path == shared_dir && user_path == user_dir;
  shared_path = shared_dir; user_path = user_dir;
  exact_probe_available=std::ifstream(shared_path+"/build/private_pinyin_exact.schema.yaml").good();
  api = rime_get_api();
  RimeTraits traits{}; RIME_STRUCT_INIT(RimeTraits, traits);
  traits.shared_data_dir = shared_path.c_str(); traits.user_data_dir = user_path.c_str();
  traits.distribution_name = "Private Input"; traits.distribution_code_name = "private-input";
  traits.distribution_version = "0.2.0"; traits.app_name = "rime.private-input";
  traits.min_log_level = 3; traits.log_dir = "";
  api->setup(&traits); api->initialize(&traits);
  if (deploy && api->start_maintenance(True)) api->join_maintenance_thread();
  return 1;
}
void pi_finalize() {
  std::lock_guard<std::recursive_mutex> lock(gate);
  if (api) api->finalize();
  sessions.clear(); preferences.clear(); pinned_words.clear(); word_weights.clear(); repair_corrector = private_input::pinyin::Corrector(); repair_resources_loaded = false; api = nullptr; shared_path.clear(); user_path.clear();
}
PI_Session pi_create_session() {
  std::lock_guard<std::recursive_mutex> lock(gate);
  if (!api) return 0;
  auto id = api->create_session();
  if (!id) return 0;
  sessions.emplace(id, Snapshot{});
  if (!api->select_schema(id, "private_pinyin")) { api->destroy_session(id); sessions.erase(id); return 0; }
  refresh(id); return id;
}
void pi_destroy_session(PI_Session id) {
  std::lock_guard<std::recursive_mutex> lock(gate);
  if (api && sessions.count(id)) api->destroy_session(id);
  sessions.erase(id);
}
size_t pi_active_session_count() {
  std::lock_guard<std::recursive_mutex> lock(gate); return sessions.size();
}
int pi_process_key(PI_Session id, int keycode, int mask) {
  std::lock_guard<std::recursive_mutex> lock(gate);
  if (!api || !sessions.count(id)) return 0;
  auto &snapshot = sessions.at(id);
  if (snapshot.nine_key && mask == 0 && !snapshot.syllable_undo.empty()) {
    const auto at_end = api->get_caret_pos(id) == snapshot.input.size();
    // Undo only when the latest filter is still the last input operation.
    // Characters typed after that filter are deleted normally first.
    if (keycode == 0xff08 && at_end && snapshot.input == snapshot.syllable_undo.back().after)
      return pi_nine_undo_syllable(id);
    if ((!at_end && (keycode == 0xff08 || (keycode >= 32 && keycode < 127))) || keycode == 0xffff)
      snapshot.syllable_undo.clear();
  }
  // Numeric and space selection must address the same visible candidate order.
  if (mask == 0 && !snapshot.indices.empty() && ((!snapshot.nine_key && keycode >= '1' && keycode <= '9') || keycode == ' ')) {
    const auto visible = keycode == ' ' ? size_t(0) : size_t(keycode - '1');
    if (visible < snapshot.indices.size()) {
      auto handled = api->select_candidate_on_current_page(id, snapshot.indices[visible]); refresh(id); return handled;
    }
  }
  auto handled = api->process_key(id, keycode, mask); refresh(id); return handled;
}
int pi_cursor_at_end(PI_Session id) {
  std::lock_guard<std::recursive_mutex> lock(gate);
  if (!api || !sessions.count(id)) return 0;
  const char* input=api->get_input(id);
  return input && api->get_caret_pos(id)==std::string(input).size();
}
int pi_move_pinyin_cursor(PI_Session id, int direction) {
  std::lock_guard<std::recursive_mutex> lock(gate);
  if (!api || !sessions.count(id) || sessions.at(id).nine_key || (direction != -1 && direction != 1)) return 0;
  const auto &input=sessions.at(id).input;
  if (input.empty() || !std::all_of(input.begin(), input.end(), [](unsigned char c){return c<128;})) return 0;
  auto caret=std::min(api->get_caret_pos(id),input.size());
  if (direction<0 && caret>0) --caret;
  if (direction>0 && caret<input.size()) ++caret;
  api->set_caret_pos(id,caret);refresh(id);return 1;
}
size_t pi_preedit_cursor_utf8(PI_Session id) {
  std::lock_guard<std::recursive_mutex> lock(gate);
  if (!api || !sessions.count(id)) return 0;
  RIME_STRUCT(RimeContext, context);
  if (!api->get_context(id, &context)) return 0;
  const auto cursor = size_t(std::max(0, context.composition.cursor_pos));
  const auto length = context.composition.preedit ? std::string(context.composition.preedit).size() : 0;
  api->free_context(&context);
  return std::min(cursor, length);
}
size_t pi_unselected_input_start(PI_Session id) {
  std::lock_guard<std::recursive_mutex> lock(gate);
  if (!api || !sessions.count(id) || !pi_cursor_at_end(id)) return SIZE_MAX;
  const auto &s=sessions.at(id);
  if (s.input.empty() || s.input.size()>128) return SIZE_MAX;
  const auto digits=s.nine_key ? nine_reading(s.active_reading):normalized_reading(s.active_reading);
  // A failed nine-key segmentation can have no active reading at all.
  // Keep its unselected numeric draft eligible for recovery; do not guess an
  // offset across a selected prefix or an explicitly locked syllable.
  if (digits.empty()) {
    if (s.nine_key && s.selected_prefix.empty() && std::all_of(s.input.begin(),s.input.end(),[](char c){return c>='2' && c<='9';})) return 0;
    return SIZE_MAX;
  }
  size_t start=s.input.size(),remaining=digits.size();
  while (start>0 && remaining>0) {
    const char c=s.input[--start];if (c=='\'' || c==' ') continue;
    const auto digit=s.nine_key ? nine_reading(std::string(1,c)):normalized_reading(std::string(1,c));
    if (digit.size()!=1 || digit[0]!=digits[remaining-1]) return SIZE_MAX;
    --remaining;
  }
  if (remaining) return SIZE_MAX;
  return start;
}
size_t pi_prediction_input_start(PI_Session id) {
  std::lock_guard<std::recursive_mutex> lock(gate);
  if (!sessions.count(id) || !sessions.at(id).nine_key) return SIZE_MAX;
  const auto start=pi_unselected_input_start(id);if (start==SIZE_MAX) return SIZE_MAX;
  const auto &s=sessions.at(id);size_t numeric=s.input.size();
  while (numeric>start && s.input[numeric-1]>='2' && s.input[numeric-1]<='9') --numeric;
  return numeric<s.input.size() ? numeric:SIZE_MAX;
}
const char *pi_selected_prefix(PI_Session id) {
  std::lock_guard<std::recursive_mutex> lock(gate);auto it=sessions.find(id);
  return it==sessions.end() ? empty:it->second.selected_prefix.c_str();
}
int pi_replace_pending_input(PI_Session id,const char *expected,const char *replacement) {
  std::lock_guard<std::recursive_mutex> lock(gate);
  if (!expected || !replacement || !api || !sessions.count(id)) return 0;
  const auto start=pi_prediction_input_start(id);
  if (start==SIZE_MAX) return 0;
  auto &s=sessions.at(id);const std::string next(replacement),before=s.input,prefix=s.selected_prefix;
  if (before!=expected || next.size()>128 || next.size()<=start || next.substr(0,start)!=before.substr(0,start)) return 0;
  if (!std::all_of(next.begin()+start,next.end(),[](char c){return c>='2' && c<='9';})) return 0;
  if (!api->set_input(id,next.c_str())) return 0;
  refresh(id);
  if (s.selected_prefix!=prefix) { api->set_input(id,before.c_str());refresh(id);return 0; }
  return 1;
}
int pi_set_prediction_input(PI_Session id,const char *input) {
  std::lock_guard<std::recursive_mutex> lock(gate);
  if (!input || !api || !sessions.count(id)) return 0;
  const auto &s=sessions.at(id);const std::string value(input);
  if (!s.private_mode || !s.nine_key || value.empty() || value.size()>128 ||
      !std::all_of(value.begin(),value.end(),[](char c){return (c>='2' && c<='9') || (c>='a' && c<='z') || c=='\'';})) return 0;
  const auto result=api->set_input(id,value.c_str());refresh(id);return result;
}
int pi_set_nine_initials_probe_input(PI_Session id,const char *input) {
  std::lock_guard<std::recursive_mutex> lock(gate);
  if (!input || !api || !sessions.count(id)) return 0;
  const auto &s=sessions.at(id);const std::string value(input);
  if (!s.private_mode || !s.nine_key || !s.input.empty() || value.size()<2 || value.size()>16 ||
      !std::all_of(value.begin(),value.end(),[](char c){return c>='2' && c<='9';})) return 0;
  if (!api->select_schema(id,"private_nine_initials")) return 0;
  const auto result=api->set_input(id,value.c_str());refresh(id);return result;
}
int pi_set_pinyin_probe_input(PI_Session id,const char *input) {
  std::lock_guard<std::recursive_mutex> lock(gate);
  if (!input || !api || !sessions.count(id)) return 0;
  auto &s=sessions.at(id);const std::string value(input);
  if (!s.private_mode || s.nine_key || value.empty() || value.size()>128 ||
      !std::all_of(value.begin(),value.end(),[](char c){return (c>='a' && c<='z') || c=='\'';})) return 0;
  // Abbreviation is valid for live input, but must not flood exact repair
  // verification with unrelated initial expansions. This schema never learns.
  if (exact_probe_available && !s.exact_probe) {
    s.exact_probe=api->select_schema(id,"private_pinyin_exact") != 0;
  }
  api->clear_composition(id);
  const auto result=api->set_input(id,value.c_str());refresh(id);return result;
}
int pi_stage_pinyin_input(PI_Session id,const char *input) {
  std::lock_guard<std::recursive_mutex> lock(gate);
  if (!input || !api || !sessions.count(id)) return 0;
  const auto &s=sessions.at(id);const std::string value(input);
  if (s.nine_key || !s.input.empty() || !s.selected_prefix.empty() || value.empty() || value.size()>1024 ||
      !std::all_of(value.begin(),value.end(),[](char c){return (c>='a' && c<='z') || c=='\'';})) return 0;
  const auto result=api->set_input(id,value.c_str());refresh(id);return result;
}
int pi_stage_nine_input(PI_Session id,const char *input) {
  std::lock_guard<std::recursive_mutex> lock(gate);
  if(!input || !api || !sessions.count(id))return 0;
  const auto &s=sessions.at(id);const std::string value(input);
  if(!s.nine_key || !s.input.empty() || !s.selected_prefix.empty() || value.empty() || value.size()>1024 ||
     !std::all_of(value.begin(),value.end(),[](char c){return (c>='a' && c<='z') || c=='\'';}))return 0;
  const auto result=api->set_input(id,value.c_str());refresh(id);return result;
}
int pi_select_candidate(PI_Session id, size_t index) {
  std::lock_guard<std::recursive_mutex> lock(gate);
  if (!api || !sessions.count(id)) return 0;
  const auto &indices = sessions.at(id).indices;
  if (index >= indices.size()) return 0;
  auto result = api->select_candidate_on_current_page(id, indices[index]); refresh(id); return result;
}
size_t pi_load_candidate_batch(PI_Session id, size_t offset, size_t limit) {
  std::lock_guard<std::recursive_mutex> lock(gate);
  if (!api || !sessions.count(id) || offset > 100000 || limit == 0 || limit > 128) return 0;
  auto &s = sessions.at(id); s.batch.clear();
  const auto input_reading = s.nine_key ? nine_reading(s.active_reading) : normalized_reading(s.active_reading);
  std::set<std::string> pinned;
  if (!s.private_mode) for (const auto &p : pinned_words)
    if (!input_reading.empty()) {
      const auto code = s.nine_key ? nine_reading(p.first) : p.first;
      if (code.compare(0, input_reading.size(), input_reading) == 0 || input_reading.compare(0, code.size(), code) == 0) pinned.insert(p.second);
    }
  // Discover promoted candidates only until every matching pin is found.
  // Cache their native indices, not an eagerly truncated candidate stream.
  if (!pinned.empty()) {
    if (!s.ranked_ready) {
      RimeCandidateListIterator all{};
      if (api->candidate_list_begin(id, &all)) {
        while (!pinned.empty() && api->candidate_list_next(&all)) {
          if (all.index < 0) break;
          const std::string text = all.candidate.text ? all.candidate.text : "";
          if (pinned.erase(text)) s.ranked.push_back({text, all.candidate.comment ? all.candidate.comment : "", static_cast<size_t>(all.index)});
        }
        api->candidate_list_end(&all);
      }
      s.ranked_ready = true;
    }
    const auto promoted = s.ranked.size();
    size_t logical = offset;
    while (logical < promoted && s.batch.size() < limit) s.batch.push_back(s.ranked[logical++]);
    if (s.batch.size() == limit) return s.batch.size();
    std::set<size_t> indices;
    for (const auto &c : s.ranked) indices.insert(c.index);
    size_t start = logical - promoted;
    for (const auto index : indices) if (index <= start) ++start;
    RimeCandidateListIterator tail{};
    if (api->candidate_list_from_index(id, &tail, static_cast<int>(start))) {
      while (s.batch.size() < limit && api->candidate_list_next(&tail)) {
        if (tail.index < 0) break;
        if (!indices.count(static_cast<size_t>(tail.index))) s.batch.push_back({tail.candidate.text ? tail.candidate.text : "", tail.candidate.comment ? tail.candidate.comment : "", static_cast<size_t>(tail.index)});
      }
      api->candidate_list_end(&tail);
    }
    return s.batch.size();
  }
  RimeCandidateListIterator iterator{};
  if (!api->candidate_list_from_index(id, &iterator, static_cast<int>(offset))) return 0;
  while (s.batch.size() < limit && api->candidate_list_next(&iterator)) {
    if (iterator.index < 0) break;
    s.batch.push_back({iterator.candidate.text ? iterator.candidate.text : "", iterator.candidate.comment ? iterator.candidate.comment : "", static_cast<size_t>(iterator.index)});
  }
  api->candidate_list_end(&iterator);
  const auto reading = s.nine_key ? nine_reading(s.active_reading) : normalized_reading(s.active_reading);
  std::map<std::string, unsigned long long> scores;
  if (!s.private_mode) for (const auto &p : preferences) if ((s.nine_key ? nine_reading(p.first.first) : p.first.first) == reading) scores[p.first.second] = std::max(scores[p.first.second], p.second);
  auto score = [&](const StreamCandidate &c) { auto p = scores.find(c.text); return p == scores.end() ? 0ULL : p->second; };
  std::stable_sort(s.batch.begin(), s.batch.end(), [&](const auto &a, const auto &b) { return score(a) > score(b); });
  return s.batch.size();
}
const char *pi_batch_candidate_text(PI_Session id, size_t index) {
  std::lock_guard<std::recursive_mutex> lock(gate);
  auto it = sessions.find(id); return it == sessions.end() || index >= it->second.batch.size() ? empty : it->second.batch[index].text.c_str();
}
const char *pi_batch_candidate_comment(PI_Session id, size_t index) {
  std::lock_guard<std::recursive_mutex> lock(gate);
  auto it = sessions.find(id); return it == sessions.end() || index >= it->second.batch.size() ? empty : it->second.batch[index].comment.c_str();
}
size_t pi_batch_candidate_index(PI_Session id, size_t index) {
  std::lock_guard<std::recursive_mutex> lock(gate);
  auto it = sessions.find(id); return it == sessions.end() || index >= it->second.batch.size() ? SIZE_MAX : it->second.batch[index].index;
}
int pi_select_candidate_absolute(PI_Session id, size_t index) {
  std::lock_guard<std::recursive_mutex> lock(gate);
  if (!api || !sessions.count(id)) return 0;
  auto result = api->select_candidate(id, index); sessions.at(id).syllable_undo.clear(); refresh(id); return result;
}
size_t pi_nine_syllable_count(PI_Session id) {
  std::lock_guard<std::recursive_mutex> lock(gate);
  if (!api || !sessions.count(id)) return 0;
  auto &s = sessions.at(id); s.syllables.clear();
  if (!s.nine_key || s.input.empty() || api->get_caret_pos(id) != s.input.size()) return 0;
  RimeContext context{}; RIME_STRUCT_INIT(RimeContext, context);
  if (!api->get_context(id, &context)) return 0;
  const std::string preedit = context.composition.preedit ? context.composition.preedit : "";
  const auto selected = static_cast<size_t>(std::max(0, context.composition.sel_start));
  api->free_context(&context);
  if (selected > preedit.size()) return 0;
  // Match the displayed unselected ASCII tail against raw input, rather than
  // counting UTF-8 Chinese characters as raw spelling positions.
  size_t start = 0;
  if (selected) {
    const auto tail = nine_reading(preedit.substr(selected));
    if (tail.empty()) return 0;
    start = s.input.size(); size_t matched = tail.size();
    while (start > 0 && matched > 0) {
      const char c = s.input[--start];
      if (c == '\'' || c == ' ') continue;
      const auto digit = nine_reading(std::string(1, c));
      if (digit.size() != 1 || digit[0] != tail[matched - 1]) return 0;
      --matched;
    }
    if (matched) return 0;
  }
  size_t token = 0, numeric = start, atom = start;
  while (numeric < s.input.size() && !(s.input[numeric] >= '2' && s.input[numeric] <= '9')) {
    if (s.input[numeric] == '\'') { ++token; atom = numeric + 1; }
    ++numeric;
  }
  if (numeric == s.input.size()) return 0;
  size_t end = numeric;
  while (end < s.input.size() && s.input[end] >= '2' && s.input[end] <= '9') ++end;
  const auto digits = s.input.substr(numeric, end - numeric);
  // A previous initial filter (d -> d84) is still part of this syllable,
  // unlike a completed filter (du' -> du'4). Keep it in both matching and
  // replacement offsets so later filtering never consumes the next segment.
  const auto prefix = s.input.substr(atom, numeric - atom);
  if (!std::all_of(prefix.begin(), prefix.end(), [](char c) { return c >= 'a' && c <= 'z'; })) return 0;
  auto append = [&](const std::string &syllable) {
    if (normalized_reading(syllable) != syllable || syllable.size() > 6) return;
    const auto code = nine_reading(syllable);
    if (syllable.compare(0, prefix.size(), prefix) != 0 || code.size() < prefix.size()) return;
    const auto suffix = code.substr(prefix.size());
    if (suffix.empty() || suffix.size() > digits.size() || digits.compare(0, suffix.size(), suffix) != 0) return;
    if (std::any_of(s.syllables.begin(), s.syllables.end(), [&](const auto &v) { return v.text == syllable; })) return;
    // A sole a/e/o key must remain extendable too (a -> ai, e -> en).
    const bool complete = !(prefix.empty() && syllable.size() == 1 && digits.size() == 1);
    s.syllables.push_back({syllable, atom, prefix.size() + suffix.size(), complete});
  };
  RimeCandidateListIterator iterator{};
  if (api->candidate_list_begin(id, &iterator)) {
   size_t visited = 0;
   while (++visited <= 256 && s.syllables.size() < 24 && api->candidate_list_next(&iterator)) {
    std::string comment = iterator.candidate.comment ? iterator.candidate.comment : "";
    std::replace(comment.begin(), comment.end(), '\'', ' ');
    std::istringstream stream(comment); std::string syllable;
    bool found = true;
    for (size_t i = 0; i <= token; ++i) if (!(stream >> syllable)) { found = false; break; }
    if (found) append(syllable);
   }
   api->candidate_list_end(&iterator);
  }
  // Word frequencies may order suggestions, but cannot veto valid manual choices.
  // Append every complete syllable matching the current raw prefix, without the
  // candidate scan/page limits. Selection consumes only that spelling's digits.
  for (const auto *syllable : private_input::pinyin_syllables) append(syllable);
  auto append_prefix = [&](const std::string &spelling) {
    if (spelling.size() <= prefix.size() || spelling.compare(0, prefix.size(), prefix) != 0) return;
    const auto suffix = nine_reading(spelling).substr(prefix.size());
    if (suffix.empty() || suffix.size() > digits.size() || digits.compare(0, suffix.size(), suffix) != 0) return;
    if (std::any_of(s.syllables.begin(), s.syllables.end(), [&](const auto &v) { return v.text == spelling; })) return;
    s.syllables.push_back({spelling, atom, spelling.size(), false});
  };
  // Candidate frequency cannot hide an unfinished but valid spelling. In
  // particular 3 must expose d/f before du(i)/fu/fo are fully typed. Every key
  // and every unselected sentence tail follows the same public inventory.
  for (const auto *entry : private_input::pinyin_syllables) {
    const std::string syllable(entry);
    if (syllable.size() <= prefix.size()) continue;
    append_prefix(syllable.substr(0, prefix.size() + 1));
    const auto length = prefix.size() + digits.size();
    if (length < syllable.size()) append_prefix(syllable.substr(0, length));
  }
  // Prefer a complete spelling that explains more of the pending keys. Keep
  // Rime's frequency order for equal matches, and retain unfinished prefixes
  // after complete spellings so manual narrowing never loses an option.
  std::stable_sort(s.syllables.begin(), s.syllables.end(), [](const auto &a, const auto &b) {
    if (a.complete != b.complete) return a.complete;
    return a.consumed > b.consumed;
  });
  return s.syllables.size();
}
const char *pi_nine_syllable_text(PI_Session id, size_t index) {
  std::lock_guard<std::recursive_mutex> lock(gate);
  auto it = sessions.find(id); return it == sessions.end() || index >= it->second.syllables.size() ? empty : it->second.syllables[index].text.c_str();
}
int pi_nine_select_syllable(PI_Session id, size_t index) {
  std::lock_guard<std::recursive_mutex> lock(gate);
  if (!api || !sessions.count(id)) return 0;
  auto &s = sessions.at(id);
  if (index >= s.syllables.size() || api->get_caret_pos(id) != s.input.size()) return 0;
  const auto option = s.syllables[index]; const auto before = s.input;
  auto tail = s.input.substr(option.start + option.consumed);
  if (option.complete && !tail.empty() && tail.front() == '\'') tail.erase(0, 1);
  const auto next = s.input.substr(0, option.start) + option.text + (option.complete ? "'" : "") + tail;
  if (!api->set_input(id, next.c_str())) return 0;
  api->process_key(id, 0xff57, 0); // End begins editing after a partial selection.
  s.syllable_undo.push_back({before, next}); refresh(id); return 1;
}
int pi_nine_can_undo_syllable(PI_Session id) {
  std::lock_guard<std::recursive_mutex> lock(gate);
  if (!api || !sessions.count(id)) return 0;
  auto &s = sessions.at(id);
  return api->get_caret_pos(id) == s.input.size() && !s.syllable_undo.empty() && s.input.compare(0, s.syllable_undo.back().after.size(), s.syllable_undo.back().after) == 0;
}
int pi_nine_undo_syllable(PI_Session id) {
  std::lock_guard<std::recursive_mutex> lock(gate);
  if (!pi_nine_can_undo_syllable(id)) return 0;
  auto &s = sessions.at(id); const auto undo = s.syllable_undo.back();
  const auto restored = undo.before + s.input.substr(undo.after.size());
  if (!api->set_input(id, restored.c_str())) return 0;
  api->process_key(id, 0xff57, 0); s.syllable_undo.pop_back(); refresh(id); return 1;
}
int pi_delete_candidate(PI_Session id, size_t index) {
  std::lock_guard<std::recursive_mutex> lock(gate);
  if (!api || !sessions.count(id)) return 0;
  const auto &indices = sessions.at(id).indices;
  if (index >= indices.size()) return 0;
  auto result = api->delete_candidate_on_current_page(id, indices[index]); refresh(id); return result;
}
void pi_clear(PI_Session id) {
  std::lock_guard<std::recursive_mutex> lock(gate);
  if (!api || !sessions.count(id)) return;
  api->clear_composition(id); refresh(id);
}
int pi_set_private(PI_Session id, int enabled) {
  std::lock_guard<std::recursive_mutex> lock(gate);
  if (!api || !sessions.count(id)) return 0;
  api->clear_composition(id);
  auto &s = sessions.at(id);
  const char *schema = s.nine_key ? (enabled ? "private_nine_private" : "private_nine") : (enabled ? "private_pinyin_private" : "private_pinyin");
  auto result = api->select_schema(id, schema);
  if (result) {s.private_mode = enabled != 0;s.exact_probe=false;}
  refresh(id); return result;
}
int pi_set_nine_key(PI_Session id, int enabled) {
  std::lock_guard<std::recursive_mutex> lock(gate);
  if (!api || !sessions.count(id) || !sessions.at(id).input.empty()) return 0;
  auto &s = sessions.at(id);
  const char *schema = enabled ? (s.private_mode ? "private_nine_private" : "private_nine") : (s.private_mode ? "private_pinyin_private" : "private_pinyin");
  auto result = api->select_schema(id, schema); if (result) {s.nine_key = enabled != 0;s.exact_probe=false;}
  refresh(id); return result;
}
const char *pi_preedit(PI_Session id) {
  std::lock_guard<std::recursive_mutex> lock(gate);
  auto it = sessions.find(id); return it == sessions.end() ? empty : it->second.preedit.c_str();
}
static const char *nine_display_preedit(PI_Session id, const char *reading, bool compact) {
  std::lock_guard<std::recursive_mutex> lock(gate);
  if (!api || !sessions.count(id)) return empty;
  auto &s = sessions.at(id); s.display_preedit = s.preedit;
  if (!s.nine_key || s.preedit.empty()) return s.display_preedit.c_str();
  RimeContext context{}; RIME_STRUCT_INIT(RimeContext, context);
  if (!api->get_context(id, &context)) return s.display_preedit.c_str();
  const auto selected = static_cast<size_t>(std::max(0, context.composition.sel_start));
  api->free_context(&context);
  if (selected > s.preedit.size()) return s.display_preedit.c_str();
  const auto pending = s.preedit.substr(selected), digits = nine_reading(pending);
  std::string hint = reading ? reading : "";
  std::replace(hint.begin(), hint.end(), '\'', ' ');
  const auto code = nine_reading(hint);
  std::string result;
  // The visible first candidate may cover only the first word. Find a longer
  // exact path before falling back; display lookup never changes the session.
  auto covers = [&](const std::string &value) {
    const auto encoded = nine_reading(value);
    return !normalized_reading(value).empty() && !digits.empty() &&
           encoded.compare(0, digits.size(), digits) == 0;
  };
  const auto abbreviated = covers(hint) ? std::string() : abbreviated_nine_reading(hint, digits);
  if (compact && !covers(hint) && abbreviated.empty()) {
    RimeCandidateListIterator iterator{};
    if (api->candidate_list_begin(id, &iterator)) {
      for (size_t i = 0; i < 64 && api->candidate_list_next(&iterator); ++i) {
        std::string value = iterator.candidate.comment ? iterator.candidate.comment : "";
        std::replace(value.begin(), value.end(), '\'', ' ');
        if (covers(value)) { hint = value; break; }
        const auto encoded = nine_reading(value), old = nine_reading(hint);
        if (!normalized_reading(value).empty() && digits.compare(0, encoded.size(), encoded) == 0 && encoded.size() > old.size()) hint = value;
      }
      api->candidate_list_end(&iterator);
    }
  }
  if (covers(hint)) {
    size_t remaining = digits.size();
    for (char c : hint) {
      if (!remaining) break;
      if (c == ' ') { if (!result.empty() && result.back() != ' ') result += ' '; }
      else { result += c == 'v' ? "ü" : std::string(1, c); --remaining; }
    }
  } else if (!abbreviated.empty()) {
    result = abbreviated;
  } else if (compact) {
    // Show one best verified partial reading and a single unresolved marker,
    // rather than multiplying each ambiguous key into three or four letters.
    const auto encoded = nine_reading(hint);
    if (!normalized_reading(hint).empty() && !encoded.empty() && digits.compare(0, encoded.size(), encoded) == 0) result = hint + " …";
    else {
      bool unresolved = false;
      for (char c : pending) {
        if (c >= '2' && c <= '9') { if (!unresolved) { if (!result.empty() && result.back() != ' ') result += ' '; result += "…"; } unresolved = true; }
        else if (c == '\'' || c == ' ') { if (!result.empty() && result.back() != ' ') result += ' '; }
        else if (c >= 'a' && c <= 'z') { result += c == 'v' ? "ü" : std::string(1, c); unresolved = false; }
      }
    }
  } else {
    // Unknown reading: preserve exact locked letters and show ambiguous letter
    // groups, rather than inventing a unique spelling or exposing key numbers.
    static const char *groups[] = {"abc", "def", "ghi", "jkl", "mno", "pqrs", "tuv", "wxyz"};
    for (char c : pending) {
      if (c >= '2' && c <= '9') { if (!result.empty() && result.back() != ' ') result += ' '; result += groups[c - '2']; result += ' '; }
      else if (c == '\'' || c == ' ') { if (!result.empty() && result.back() != ' ') result += ' '; }
      else if (c >= 'a' && c <= 'z') result += c == 'v' ? "ü" : std::string(1, c);
    }
  }
  while (!result.empty() && result.back() == ' ') result.pop_back();
  s.display_preedit = s.preedit.substr(0, selected);
  if (!s.display_preedit.empty() && !result.empty()) s.display_preedit += ' ';
  s.display_preedit += result;
  return s.display_preedit.c_str();
}
const char *pi_nine_display_preedit(PI_Session id, const char *reading) { return nine_display_preedit(id, reading, true); }
const char *pi_nine_readable_preedit(PI_Session id, const char *reading) { return nine_display_preedit(id, reading, false); }
const char *pi_raw_input(PI_Session id) {
  std::lock_guard<std::recursive_mutex> lock(gate);
  auto it = sessions.find(id); return it == sessions.end() ? empty : it->second.input.c_str();
}
int pi_page_number(PI_Session id) {
  std::lock_guard<std::recursive_mutex> lock(gate);
  auto it = sessions.find(id); return it == sessions.end() ? 0 : it->second.page;
}
int pi_has_next_page(PI_Session id) {
  std::lock_guard<std::recursive_mutex> lock(gate);
  auto it = sessions.find(id); return it != sessions.end() && it->second.next_page;
}
int pi_set_ascii_mode(PI_Session id, int enabled) {
  std::lock_guard<std::recursive_mutex> lock(gate);
  if (!api || !sessions.count(id)) return 0;
  api->set_option(id, "ascii_mode", enabled != 0); refresh(id);
  return api->get_option(id, "ascii_mode") == (enabled != 0);
}
size_t pi_candidate_count(PI_Session id) {
  std::lock_guard<std::recursive_mutex> lock(gate);
  auto it = sessions.find(id); return it == sessions.end() ? 0 : it->second.candidates.size();
}
const char *pi_candidate_text(PI_Session id, size_t index) {
  std::lock_guard<std::recursive_mutex> lock(gate);
  auto it = sessions.find(id);
  return it == sessions.end() || index >= it->second.candidates.size() ? empty : it->second.candidates[index].c_str();
}
const char *pi_take_commit(PI_Session id) {
  std::lock_guard<std::recursive_mutex> lock(gate);
  auto it = sessions.find(id); if (!api || it == sessions.end()) return empty;
  it->second.commit.clear();
  RimeCommit commit{}; RIME_STRUCT_INIT(RimeCommit, commit);
  if (api->get_commit(id, &commit)) {
    if (commit.text) it->second.commit = commit.text;
    api->free_commit(&commit);
  }
  return it->second.commit.c_str();
}
size_t pi_load_repair_candidates(PI_Session id, size_t limit) {
  std::lock_guard<std::recursive_mutex> lock(gate);
  if (!api || !sessions.count(id) || limit == 0 || limit > 32) return 0;
  auto &s = sessions.at(id);
  s.repairs.clear();
  if (s.nine_key) return 0;
  if (!repair_resources_loaded) {
    repair_resources_loaded = true;
    load_repair_syllables(shared_path);
    load_word_weights(shared_path);
  }
  if (!repair_corrector.ready()) return 0;
  const size_t start = pi_unselected_input_start(id);
  if (start == SIZE_MAX || start > s.input.size()) return 0;
  const auto tail = s.input.substr(start);
  if (tail.size() < 4 || tail.size() > 96) return 0;
  bool duplicate = false;
  for (size_t i = 1; i < tail.size(); ++i) if (tail[i] == tail[i - 1]) duplicate = true;
  // An exact full spelling keeps the native word-frequency order; repeated
  // keys still need repair because the tail may hide an extra letter.
  if (tail.size() < 10 && !duplicate)
    for (const auto &row : s.batch)
      if (private_input::pinyin::is_full_spelling(tail, row.comment)) return 0;
  const auto proposals = repair_corrector.proposals(tail, 64);
  if (proposals.empty()) return 0;
  const auto probe = pi_create_session();
  if (!probe) return 0;
  std::vector<std::pair<double, RepairRow>> ranked;
  if (pi_set_private(probe, 1) && pi_set_nine_key(probe, 0) && pi_set_ascii_mode(probe, 0)) {
    for (const auto &proposal : proposals) {
      if (!pi_set_pinyin_probe_input(probe, proposal.spelling.c_str())) continue;
      const auto count = pi_load_candidate_batch(probe, 0, 10);
      for (size_t i = 0; i < count; ++i) {
        const std::string text = pi_batch_candidate_text(probe, i);
        const std::string reading = pi_batch_candidate_comment(probe, i);
        if (text.empty() || joined_repair_reading(reading) != proposal.spelling) continue;
        double score = -proposal.cost * 3.0 - double(i) * 0.8;
        if (const auto weight = word_weights.find(text); weight != word_weights.end())
          score += std::min(4.0, std::log1p(double(weight->second)) * 0.5);
        // Private fields never read the user's preference or pinned words.
        if (!s.private_mode) {
          const auto preference = preferences.find({normalized_reading(reading), text});
          if (preference != preferences.end()) score += std::log1p(double(preference->second)) * 0.5;
          if (pinned_words.count({normalized_reading(reading), text})) score += 6;
        }
        ranked.push_back({score, {text, reading, proposal.spelling, pi_batch_candidate_index(probe, i), proposal.edits}});
      }
    }
  }
  pi_destroy_session(probe);
  std::stable_sort(ranked.begin(), ranked.end(), [](const auto &a, const auto &b) {
    return a.first == b.first ? a.second.text < b.second.text : a.first > b.first;
  });
  std::set<std::string> seen;
  for (const auto &entry : ranked) {
    if (s.repairs.size() >= limit) break;
    if (!seen.insert(entry.second.text).second) continue;
    s.repairs.push_back(entry.second);
  }
  return s.repairs.size();
}
const char *pi_repair_candidate_text(PI_Session id, size_t index) {
  std::lock_guard<std::recursive_mutex> lock(gate);
  auto it = sessions.find(id);
  return it == sessions.end() || index >= it->second.repairs.size() ? empty : it->second.repairs[index].text.c_str();
}
const char *pi_repair_candidate_reading(PI_Session id, size_t index) {
  std::lock_guard<std::recursive_mutex> lock(gate);
  auto it = sessions.find(id);
  return it == sessions.end() || index >= it->second.repairs.size() ? empty : it->second.repairs[index].reading.c_str();
}
const char *pi_repair_candidate_spelling(PI_Session id, size_t index) {
  std::lock_guard<std::recursive_mutex> lock(gate);
  auto it = sessions.find(id);
  return it == sessions.end() || index >= it->second.repairs.size() ? empty : it->second.repairs[index].spelling.c_str();
}
size_t pi_repair_candidate_edits(PI_Session id, size_t index) {
  std::lock_guard<std::recursive_mutex> lock(gate);
  auto it = sessions.find(id);
  return it == sessions.end() || index >= it->second.repairs.size() ? 0 : size_t(it->second.repairs[index].edits);
}
const char *pi_commit_repair_candidate(PI_Session id, size_t index) {
  std::lock_guard<std::recursive_mutex> lock(gate);
  if (!api || !sessions.count(id)) return empty;
  if (index >= sessions.at(id).repairs.size()) return empty;
  const auto row = sessions.at(id).repairs[index];
  const auto probe = pi_create_session();
  if (!probe) return empty;
  std::string committed;
  if (pi_set_private(probe, 1) && pi_set_nine_key(probe, 0) && pi_set_ascii_mode(probe, 0) &&
      pi_set_pinyin_probe_input(probe, row.spelling.c_str()) &&
      pi_select_candidate_absolute(probe, row.absolute))
    committed = pi_take_commit(probe);
  pi_destroy_session(probe);
  if (committed.empty()) return empty;
  // The typed suffix is replaced, not appended: drop the live composition.
  api->clear_composition(id);
  refresh(id);
  sessions.at(id).commit = committed;
  return sessions.at(id).commit.c_str();
}
int pi_export_learning(const char *file) {
  std::lock_guard<std::recursive_mutex> lock(gate);
  if (!sessions.empty()) return -2;
  auto *l = levers(); return l && file ? l->export_user_dict("private_pinyin", file) : -1;
}
int pi_import_learning(const char *file) {
  std::lock_guard<std::recursive_mutex> lock(gate);
  if (!sessions.empty()) return -2;
  auto *l = levers(); if (!l || !file) return -1;
  Preferences next; if (!read_preferences(file, next)) return -1;
  const auto imported = l->import_user_dict("private_pinyin", file);
  if (imported >= 0) preferences = std::move(next);
  return imported;
}
int pi_set_word_pinned(const char *reading, const char *text, int pinned) {
  std::lock_guard<std::recursive_mutex> lock(gate);
  if (!api || !reading || !text) return 0;
  const auto key = normalized_reading(reading);
  if (key.empty() || key.size() > 128 || !*text || std::string(text).size() > 1024) return 0;
  if (pinned) pinned_words.emplace(key, text); else pinned_words.erase({key, text});
  for (auto &s : sessions) refresh(s.first);
  return 1;
}
int pi_reset_word_frequency(const char *reading, const char *text, uint64_t count) {
  std::lock_guard<std::recursive_mutex> lock(gate);
  if (!sessions.empty()) return -2;
  if (!api || !reading || !text || count > 1000000000) return -1;
  std::string code(reading), word(text);
  if (normalized_reading(code).empty() || code.size() > 128 || word.empty() || word.size() > 1024 || word.find_first_of("\t\r\n") != std::string::npos) return -1;
  bool base_word = false;
  if (count == 0) {
    const auto probe = pi_create_session();
    if (!probe || !pi_set_private(probe, 1)) { if (probe) pi_destroy_session(probe); return -1; }
    const auto spelling = normalized_reading(code);
    for (char c : spelling) pi_process_key(probe, c, 0);
    RimeCandidateListIterator candidates{};
    if (api->candidate_list_begin(probe, &candidates)) {
      while (api->candidate_list_next(&candidates)) {
        if (candidates.candidate.text && word == candidates.candidate.text && candidates.candidate.comment && normalized_reading(candidates.candidate.comment) == spelling) { base_word = true; break; }
      }
      api->candidate_list_end(&candidates);
    }
    pi_destroy_session(probe);
  }
  // Version-pinned Rime userdb adapter: reset just one value, keeping the word,
  // schema metadata, other words and app identity. Never open a running DB.
  leveldb::DB *raw = nullptr; leveldb::Options options; options.create_if_missing = false;
  if (!leveldb::DB::Open(options, user_path + "/private_pinyin.userdb", &raw).ok()) return -1;
  std::unique_ptr<leveldb::DB> db(raw);
  while (!code.empty() && code.back() == ' ') code.pop_back();
  const auto key = code + " \t" + word;
  const auto value = "c=" + std::to_string(std::max<uint64_t>(1, count)) + " d=0 t=0";
  leveldb::WriteOptions write; write.sync = true;
  const auto status = base_word ? db->Delete(write, key) : db->Put(write, key, value);
  if (!status.ok()) return -1;
  preferences[{normalized_reading(code), word}] = count;
  return base_word ? 2 : 1;
}
const char *pi_engine_version() { return api ? api->get_version() : "not-initialized"; }
}
