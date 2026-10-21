#pragma once
#ifdef _WIN32
#include <windows.h>
#endif
#include "ArchiveCore.h"

namespace private_input::activity {
struct HTTPError:std::runtime_error {unsigned status;std::string code;HTTPError(unsigned status,std::string code):std::runtime_error("archive HTTP request failed"),status(status),code(std::move(code)){};};
class PersonalDataLock{std::filesystem::path root;void*handle=nullptr;public:explicit PersonalDataLock(const std::filesystem::path&);~PersonalDataLock();PersonalDataLock(const PersonalDataLock&)=delete;};
uint64_t monotonicMilliseconds();
std::string protect(const std::string&);std::string unprotect(const std::string&);
std::filesystem::path userRoot();
void savePrivate(const std::filesystem::path&,const Json&);Json loadPrivate(const std::filesystem::path&);
std::string endpoint(const std::string&);Json post(const std::string&origin,const std::string&path,const Json&body);
Json clipboardLiveHTTP(const std::string&origin,const std::string&path,const Json*body=nullptr);
std::wstring wide(std::string_view);std::string utf8(std::wstring_view);
}
