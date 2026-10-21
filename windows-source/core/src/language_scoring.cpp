#include "private_input.h"
#include "../../vendor/librime-octagram/src/octagram.h"
#include <rime/config.h>
#include <utf8.h>
#include <cmath>
#include <filesystem>
#include <mutex>
#if defined(__APPLE__)
#include <mach/mach.h>
#include <TargetConditionals.h>
#if TARGET_OS_IPHONE
#include <os/proc.h>
#endif
#endif

namespace {
std::mutex language_gate;
std::string model_path;
std::unique_ptr<rime::OctagramComponent> component;
std::unique_ptr<rime::Octagram> grammar;
}
extern "C" {
void pi_language_release() {
  std::lock_guard<std::mutex> lock(language_gate);
  grammar.reset();component.reset();model_path.clear();
}
uint64_t pi_process_memory_footprint() {
#if defined(__APPLE__)
  task_vm_info_data_t info{};mach_msg_type_number_t count=TASK_VM_INFO_COUNT;
  return task_info(mach_task_self(),TASK_VM_INFO,reinterpret_cast<task_info_t>(&info),&count)==KERN_SUCCESS ? info.phys_footprint : 0;
#else
  return 0;
#endif
}
uint64_t pi_process_peak_memory_footprint() {
#if defined(__APPLE__)
  task_vm_info_data_t info{};mach_msg_type_number_t count=TASK_VM_INFO_COUNT;
  if(task_info(mach_task_self(),TASK_VM_INFO,reinterpret_cast<task_info_t>(&info),&count)!=KERN_SUCCESS)return 0;
  return info.ledger_phys_footprint_peak>0 ? static_cast<uint64_t>(info.ledger_phys_footprint_peak):info.phys_footprint;
#else
  return 0;
#endif
}
uint64_t pi_available_memory() {
#if defined(__APPLE__) && TARGET_OS_IPHONE
  return os_proc_available_memory();
#else
  return 0;
#endif
}
int pi_language_initialize(const char* directory) {
  std::lock_guard<std::mutex> lock(language_gate);
  if (!directory) return 0;
  const auto path = std::filesystem::path(directory) / "private_zh_hans_compact";
  if (grammar && model_path == path.string()) return 1;
  grammar.reset(); component.reset(); model_path.clear();
  if (!std::filesystem::is_regular_file(path.string() + ".gram")) return 0;
  // Absolute resource ID restricts loading to the signed bundle, not user overrides.
  rime::Config config;
  config.SetString("grammar/language", path.string());
  component = std::make_unique<rime::OctagramComponent>();
  if (!component->GetDb(path.string())) { component.reset(); return 0; }
  grammar.reset(component->Create(&config)); model_path = path.string(); return 1;
}
double pi_language_score(const char* preceding, const char* text) {
  std::lock_guard<std::mutex> lock(language_gate);
  if (!grammar || !preceding || !text) return NAN;
  const std::string context(preceding), word(text);
  if (context.size() > 128 || word.empty() || word.size() > 1024 ||
      !utf8::is_valid(context.begin(), context.end()) || !utf8::is_valid(word.begin(), word.end())) return NAN;
  // Per-boundary mean avoids rewarding or penalizing phrases solely by length.
  std::string left = context; double total = 0; size_t count = 0;
  auto cursor = word.begin();
  while (cursor != word.end()) {
    auto start = cursor; utf8::next(cursor, word.end());
    const std::string next(start, cursor);
    if (!left.empty()) { total += grammar->Query(left, std::string(start,word.end()), false); ++count; }
    left += next;
  }
  // No observed boundary is missing evidence, not an unlikely word.
  return count ? total / count : NAN;
}
}
