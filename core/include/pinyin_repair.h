#ifndef PRIVATE_INPUT_PINYIN_REPAIR_H
#define PRIVATE_INPUT_PINYIN_REPAIR_H
/* Bounded syllable-aware repair lattice: missing, extra, wrong and swapped
   keys. Proposals are spellings only; a dictionary must still validate them.
   Ported from the Apple PinyinCorrection contract so both ends share one set
   of acceptance inputs.

   Header-only on purpose: Apple, Android and the engine test scripts compile
   core/src/private_input.cpp as one translation unit and do not list extra
   core sources, so the implementation must travel with this header. */
#include <algorithm>
#include <cmath>
#include <functional>
#include <set>
#include <string>
#include <unordered_map>
#include <vector>
#ifdef __cplusplus
namespace private_input {
namespace pinyin {
struct RepairProposal {
  std::string spelling;
  int edits = 0;
  double cost = 0;
};
namespace repair_detail {
inline std::string without(const std::string &value, size_t index) {
  std::string out = value;
  out.erase(out.begin() + static_cast<std::ptrdiff_t>(index));
  return out;
}
inline std::string swapped(const std::string &value, size_t index) {
  std::string out = value;
  std::swap(out[index], out[index + 1]);
  return out;
}
inline double penalty(double cost, int parts, double prior) { return cost + double(parts) * 0.03 - prior; }
}  // namespace repair_detail
class Corrector {
 public:
  using Frequency = std::function<unsigned long long(const std::string &)>;
  Corrector() = default;
  /* syllables: public complete syllables only (300...600 validated upstream). */
  Corrector(const std::set<std::string> &syllables, Frequency frequency = nullptr)
      : syllables_(syllables), frequency_(std::move(frequency)) {
    for (const auto &syllable : syllables_) {
      if (syllable.size() < 2) continue;
      if (syllable.size() >= 3) {
        for (size_t i = 0; i + 1 < syllable.size(); ++i) {
          for (size_t j = i + 1; j < syllable.size(); ++j) {
            auto missing = repair_detail::without(repair_detail::without(syllable, j), i);
            if (!missing.empty()) repairs_[missing].push_back({syllable, 2, 2});
          }
        }
      }
      for (size_t i = 0; i < syllable.size(); ++i) {
        auto missing = repair_detail::without(syllable, i);
        if (!missing.empty()) repairs_[missing].push_back({syllable, 1, 1});
        if (i + 1 < syllable.size() && syllable[i] != syllable[i + 1])
          repairs_[repair_detail::swapped(syllable, i)].push_back({syllable, 1.1, 1});
      }
    }
  }
  bool ready() const { return !syllables_.empty(); }
  const std::set<std::string> &syllables() const { return syllables_; }

  std::vector<RepairProposal> proposals(const std::string &input, size_t limit = 48) const {
    struct State {
      std::string spelling;
      int edits = 0;
      double cost = 0;
      int parts = 0;
      double prior = 0;
    };
    using repair_detail::penalty;
    if (!ready() || limit == 0) return {};
    const bool latin = !input.empty() && std::all_of(input.begin(), input.end(), [](char c) { return c >= 'a' && c <= 'z'; });
    if (input.size() < 4 || input.size() > 96 || !latin) return {};
    const int maximum_edits = input.size() >= 6 ? 2 : 1;
    std::vector<std::vector<State>> lattice(input.size() + 1);
    lattice[0].push_back({"", 0, 0, 0, 0});
    auto frequency_of = [this](const std::string &spelling) -> double {
      if (!frequency_) return 0;
      return std::log1p(double(frequency_(spelling))) * 0.003;
    };
    auto order = [](const State &a, const State &b) {
      const double left = penalty(a.cost, a.parts, a.prior), right = penalty(b.cost, b.parts, b.prior);
      return left == right ? a.spelling < b.spelling : left < right;
    };
    for (size_t position = 0; position < input.size(); ++position) {
      if (lattice[position].empty()) continue;
      for (size_t end = position + 1; end <= std::min(input.size(), position + 7); ++end) {
        const auto fragment = input.substr(position, end - position);
        std::vector<Edge> edges;
        if (syllables_.count(fragment)) edges.push_back({fragment, 0, 0});
        if (auto found = repairs_.find(fragment); found != repairs_.end())
          edges.insert(edges.end(), found->second.begin(), found->second.end());
        if (fragment.size() > 1) {
          for (size_t i = 0; i < fragment.size(); ++i) {
            auto shorter = repair_detail::without(fragment, i);
            if (syllables_.count(shorter)) edges.push_back({shorter, 1.05, 1});
          }
        }
        if (edges.empty()) continue;
        auto &target = lattice[end];
        for (const auto &state : lattice[position]) {
          for (const auto &edge : edges) {
            const int edits = state.edits + edge.edits;
            if (edits > maximum_edits) continue;
            State next{state.spelling + edge.syllable, edits, state.cost + edge.cost, state.parts + 1, 0};
            next.prior = state.prior + frequency_of(next.spelling);
            bool skip = false;
            for (auto it = target.begin(); it != target.end();) {
              if (it->spelling == next.spelling && it->edits == edits) {
                if (penalty(it->cost, it->parts, it->prior) <= penalty(next.cost, next.parts, next.prior)) {
                  skip = true;
                  break;
                }
                it = target.erase(it);
                continue;
              }
              ++it;
            }
            if (!skip) target.push_back(std::move(next));
          }
        }
        std::vector<State> kept;
        for (int edits = 0; edits <= maximum_edits; ++edits) {
          std::vector<State> bucket;
          for (const auto &state : target)
            if (state.edits == edits) bucket.push_back(state);
          std::sort(bucket.begin(), bucket.end(), order);
          if (bucket.size() > 48) bucket.resize(48);
          kept.insert(kept.end(), bucket.begin(), bucket.end());
        }
        target = std::move(kept);
      }
    }
    std::vector<State> ranked;
    for (const auto &state : lattice[input.size()])
      if (state.edits > 0 && state.spelling != input) ranked.push_back(state);
    std::sort(ranked.begin(), ranked.end(), order);
    std::vector<RepairProposal> swaps;
    if (input.size() <= 24) {
      std::set<std::string> seen;
      auto add = [&](const std::string &value, int edits) {
        if (value == input || !seen.insert(value).second || !valid_spelling(value)) return;
        swaps.push_back({value, edits, double(edits) * 1.1});
      };
      for (size_t i = 0; i + 1 < input.size(); ++i) {
        if (input[i] == input[i + 1]) continue;
        auto once = repair_detail::swapped(input, i);
        add(once, 1);
        if (maximum_edits >= 2) {
          for (size_t j = i + 1; j + 1 < once.size(); ++j) {
            if (once[j] == once[j + 1]) continue;
            add(repair_detail::swapped(once, j), 2);
          }
        }
      }
      std::sort(swaps.begin(), swaps.end(), [this](const RepairProposal &a, const RepairProposal &b) {
        const double left = (frequency_ ? std::log1p(double(frequency_(a.spelling))) : 0) - double(a.edits) * 0.2;
        const double right = (frequency_ ? std::log1p(double(frequency_(b.spelling))) : 0) - double(b.edits) * 0.2;
        return left == right ? a.spelling < b.spelling : left > right;
      });
    }
    std::vector<RepairProposal> deletions;
    {
      std::set<std::string> seen;
      for (size_t i = 0; i < input.size(); ++i) {
        auto value = repair_detail::without(input, i);
        if (!seen.insert(value).second || !valid_spelling(value)) continue;
        const bool repeated = (i > 0 && input[i - 1] == input[i]) || (i + 1 < input.size() && input[i + 1] == input[i]);
        deletions.push_back({value, 1, repeated ? 0.9 : 1.05});
      }
      std::sort(deletions.begin(), deletions.end(), [this](const RepairProposal &a, const RepairProposal &b) {
        const double left = (frequency_ ? std::log1p(double(frequency_(a.spelling))) : 0) - a.cost * 1.5;
        const double right = (frequency_ ? std::log1p(double(frequency_(b.spelling))) : 0) - b.cost * 1.5;
        return left == right ? a.spelling < b.spelling : left > right;
      });
    }
    const size_t ceiling = std::min<size_t>(64, limit);
    std::vector<RepairProposal> selected;
    auto append = [&selected, ceiling](const RepairProposal &value) {
      if (selected.size() >= ceiling) return;
      for (const auto &existing : selected)
        if (existing.spelling == value.spelling) return;
      selected.push_back(value);
    };
    size_t one_edit = 0;
    for (const auto &state : ranked) {
      if (state.edits != 1 || one_edit >= std::min<size_t>(ceiling, 32)) continue;
      append({state.spelling, state.edits, state.cost});
      ++one_edit;
    }
    const size_t two_budget = std::min<size_t>(48, ceiling) > selected.size() ? std::min<size_t>(48, ceiling) - selected.size() : 0;
    size_t two_edit = 0;
    for (const auto &state : ranked) {
      if (state.edits != 2 || two_edit >= two_budget) continue;
      append({state.spelling, state.edits, state.cost});
      ++two_edit;
    }
    for (size_t i = 0; i < deletions.size() && i < 4; ++i) {
      const auto &value = deletions[i];
      bool replaced = false;
      for (auto &existing : selected) {
        if (existing.spelling == value.spelling) {
          if (value.cost < existing.cost) existing = value;
          replaced = true;
          break;
        }
      }
      if (!replaced) append(value);
    }
    for (const auto &value : swaps) append(value);
    for (const auto &state : ranked) append({state.spelling, state.edits, state.cost});
    std::vector<RepairProposal> result;
    std::set<std::string> unique;
    for (const auto &value : selected)
      if (unique.insert(value.spelling).second) result.push_back(value);
    return result;
  }

 private:
  struct Edge {
    std::string syllable;
    double cost = 0;
    int edits = 1;
  };
  bool valid_spelling(const std::string &value) const {
    if (value.empty()) return false;
    std::set<size_t> reachable{0};
    for (size_t start = 0; start < value.size(); ++start) {
      if (!reachable.count(start)) continue;
      for (size_t end = start + 1; end <= std::min(value.size(), start + 6); ++end)
        if (syllables_.count(value.substr(start, end - start))) reachable.insert(end);
    }
    return reachable.count(value.size()) != 0;
  }
  std::set<std::string> syllables_;
  Frequency frequency_;
  std::unordered_map<std::string, std::vector<Edge>> repairs_;
};
}  // namespace pinyin
}  // namespace private_input
#endif
#endif
