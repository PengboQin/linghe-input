#pragma once
#include "../../activity/Platform.h"
namespace private_input::activity {
// Native test observer only: immutable bytes from a newly-created fixture file.
// Share delete so observation cannot prevent the owner's atomic replacement;
// close before DPAPI/JSON work. Never use this helper for production inspection.
inline Json syntheticSnapshot(const std::filesystem::path&file){
 require(file.filename()==L"content-v1.dpapi"&&file.parent_path().filename()==L"isolated-device"&&file.parent_path().parent_path().parent_path().filename()==L"fixtures","synthetic snapshot scope");
 HANDLE h=CreateFileW(file.c_str(),GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,nullptr,OPEN_EXISTING,FILE_FLAG_OPEN_REPARSE_POINT,nullptr);require(h!=INVALID_HANDLE_VALUE,"synthetic shared snapshot open");BY_HANDLE_FILE_INFORMATION info{};LARGE_INTEGER size{};if(!GetFileInformationByHandle(h,&info)||(info.dwFileAttributes&FILE_ATTRIBUTE_REPARSE_POINT)||!GetFileSizeEx(h,&size)||size.QuadPart<=0||size.QuadPart>12582912){CloseHandle(h);throw JsonError("synthetic shared snapshot size");}std::string bytes(size_t(size.QuadPart),0);DWORD got=0;bool okay=ReadFile(h,bytes.data(),DWORD(bytes.size()),&got,nullptr)&&got==bytes.size();CloseHandle(h);require(okay,"synthetic shared snapshot read");return Json::parse(unprotect(bytes),8388608,32,524288);
}
}
