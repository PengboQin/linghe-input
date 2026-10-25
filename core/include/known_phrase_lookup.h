#pragma once
// Known-phrase lookup for automatic phrase collection. The preset vocabulary
// (essay.txt) is byte-sorted "text\tweight" lines; a bounded binary search over
// the file avoids loading ~425k words into keyboard-extension memory.
#include "mainland_candidate_policy.h"
#include <cstdint>
#include <fstream>
#include <string>

namespace private_input::known_phrase {

enum class Status : int { unavailable = -1, known = 1, eligible_new = 2, not_eligible = 0 };

// Reads the first line starting at or after offset: its key (text before the
// tab), its start offset, and the offset where the following line begins.
inline bool line_at(std::ifstream &file, std::streamoff offset, std::streamoff size, std::string &key, std::streamoff &start, std::streamoff &next) {
 if (offset >= size) return false;
 file.clear();
 if (offset > 0) {
  file.seekg(offset - 1); char previous = 0;
  if (!file.get(previous)) return false;
  if (previous != '\n') { std::string skip; if (!std::getline(file, skip)) return false; }
 } else file.seekg(0);
 start = file.tellg(); if (start < 0 || start >= size) return false;
 std::string line; if (!std::getline(file, line)) return false;
 next = start + static_cast<std::streamoff>(line.size()) + 1;
 if (!line.empty() && line.back() == '\r') line.pop_back();
 key = line.substr(0, line.find('\t'));
 return true;
}

// Binary search over line starts in [low, high); the file must be byte-sorted.
inline Status lookup(const std::string &vocabulary_path, const std::string &text) {
 std::ifstream file(vocabulary_path, std::ios::binary);
 if (!file) return Status::unavailable;
 file.seekg(0, std::ios::end); const std::streamoff size = file.tellg();
 if (size <= 0) return Status::unavailable;
 std::streamoff low = 0, high = size;
 for (int step = 0; step < 96 && low < high; ++step) {
  const std::streamoff middle = low + (high - low) / 2;
  std::string key; std::streamoff start = 0, next = 0;
  if (!line_at(file, middle, size, key, start, next) || start >= high) {
   // No line begins in [middle, high): search the lower half only.
   if (middle == low) break;
   high = middle; continue;
  }
  if (key == text) return Status::known;
  if (key < text) low = next; else high = start;
 }
 return Status::not_eligible;
}

inline size_t utf8_scalars(const std::string &text) {
 size_t count = 0; for (unsigned char c : text) if ((c & 0xC0) != 0x80) ++count; return count;
}

inline bool han_only(const std::string &text) {
 for (size_t i = 0; i < text.size();) {
  const unsigned char c = static_cast<unsigned char>(text[i]);
  if (c < 0xE0 || c >= 0xF0 || i + 2 >= text.size()) return false;
  const uint32_t code = ((c & 0x0F) << 12) | ((static_cast<unsigned char>(text[i + 1]) & 0x3F) << 6) | (static_cast<unsigned char>(text[i + 2]) & 0x3F);
  if (code < 0x4E00 || code > 0x9FFF) return false;
  i += 3;
 }
 return !text.empty();
}

// A committed phrase is a candidate for automatic collection only when it is
// 2-8 standard simplified Han characters that the preset vocabulary lacks.
// Literal text, symbols, single characters and long sentences never qualify.
inline Status classify(const std::string &vocabulary_path, const std::string &text) {
 const size_t length = utf8_scalars(text);
 if (length < 2 || length > 8 || !han_only(text) || !mainland::candidate_allowed(text)) return Status::not_eligible;
 const Status found = lookup(vocabulary_path, text);
 if (found == Status::unavailable || found == Status::known) return found;
 return Status::eligible_new;
}

} // namespace private_input::known_phrase
