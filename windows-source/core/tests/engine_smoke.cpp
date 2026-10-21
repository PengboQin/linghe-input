#include "private_input.h"
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>
namespace fs = std::filesystem;
void require(bool ok, const char *message) { if (!ok) throw std::runtime_error(message); }
void type(PI_Session session, const std::string &text) { for (unsigned char c : text) pi_process_key(session, c, 0); }
int find(PI_Session session, const std::string &text) {
  for (size_t i = 0; i < pi_candidate_count(session); ++i) if (text == pi_candidate_text(session, i)) return int(i);
  return -1;
}
std::string read(const fs::path &path) { std::ifstream f(path); return {std::istreambuf_iterator<char>(f), {}}; }
int main(int argc, char **argv) {
  try {
    require(argc == 3 || argc == 4, "usage: engine_smoke SHARED_DIR APP_OWNED_TEST_DIR [NO_DEPLOY]");
    const fs::path shared = fs::absolute(argv[1]), user = fs::absolute(argv[2]);
    require(!fs::exists(user), "Test directory must be fresh; do not overwrite user input data");
    fs::create_directories(user);
    require(pi_initialize(shared.string().c_str(), user.string().c_str(), argc == 3 ? 1 : 0), "Engine initialization failed");
    auto s = pi_create_session(); require(s, "Session creation failed");
    const auto blocked = user / "must-not-write-while-active.tsv";
    require(pi_active_session_count() == 1, "Active session count mismatch");
    require(pi_export_learning(blocked.string().c_str()) == -2, "Active database export was not rejected");
    require(pi_import_learning(blocked.string().c_str()) == -2, "Active database import was not rejected");
    require(!fs::exists(blocked), "Busy snapshot operation wrote a file");
    type(s, "nihao"); require(find(s, "你好") >= 0, "Offline nihao candidate missing");
    const int choice = find(s, "你好"); require(pi_select_candidate(s, choice), "Candidate selection failed");
    require(std::string(pi_take_commit(s)) == "你好", "Committed text mismatch");
    require(std::string(pi_take_commit(s)).empty(), "Commit replayed twice");
    type(s, "shijie"); require(find(s, "世界") >= 0, "Second candidate missing");
    pi_process_key(s, 0xff08, 0); require(std::string(pi_preedit(s)).find('e') == std::string::npos, "Backspace did not edit input");
    pi_clear(s); require(std::string(pi_preedit(s)).empty(), "Composition did not clear");
    pi_destroy_session(s);
    const auto before = user / "before.tsv", after = user / "after.tsv";
    const auto learned = pi_export_learning(before.string().c_str()); require(learned > 0, "Learning export failed");
    s = pi_create_session(); require(s && pi_set_private(s, 1), "Private schema failed");
    type(s, "ceshi"); const auto index = find(s, "测试"); require(index >= 0, "Private mode offline candidate missing");
    require(pi_select_candidate(s, index), "Private candidate selection failed");
    require(std::string(pi_take_commit(s)) == "测试", "Private commit mismatch");
    pi_destroy_session(s);
    require(pi_export_learning(after.string().c_str()) == learned, "Private mode changed learned entry count");
    require(read(before) == read(after), "Private mode changed learned content");
    require(pi_import_learning(before.string().c_str()) >= 0, "Learning import failed");
    const auto bad = user / "bad.tsv";
    { std::ofstream output(bad); output << "bad\tni hao\t1\tunexpected\n"; }
    require(pi_import_learning(bad.string().c_str()) == -1, "Malformed learning reached the engine importer");
    const auto windowsLines = user / "crlf.tsv";
    { std::ofstream output(windowsLines, std::ios::binary); output << "拟好\tni hao\t12\r\n"; }
    require(pi_import_learning(windowsLines.string().c_str()) >= 0, "CRLF learning import rejected");
    s = pi_create_session(); type(s, "nihao");
    require(std::string(pi_candidate_text(s, 0)) == "拟好", "Imported preference was not ranked first");
    require(pi_select_candidate(s, 0), "Preferred index selection failed");
    require(std::string(pi_take_commit(s)) == "拟好", "Preferred index committed another word");
    type(s, "nihao");
    require(pi_process_key(s, ' ', 0), "Preferred space selection failed");
    require(std::string(pi_take_commit(s)) == "拟好", "Preferred visible selection committed another word");
    pi_destroy_session(s);
    pi_finalize();
    std::cout << "PASS: offline candidates, selection, exactly-once commit, editing, learning export/import, private-mode non-learning\n";
    return 0;
  } catch (const std::exception &error) { pi_finalize(); std::cerr << "FAIL: " << error.what() << "\n"; return 1; }
}
