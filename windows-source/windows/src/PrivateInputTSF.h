#pragma once
#include <windows.h>
#include <msctf.h>
#include <atomic>
#include <filesystem>
// LLVM-MinGW's TSF header omits the extended activation interface. Match the
// Microsoft WinSDK ABI; this is an interface declaration, not a replacement OS.
#ifndef __ITfTextInputProcessorEx_INTERFACE_DEFINED__
#define __ITfTextInputProcessorEx_INTERFACE_DEFINED__
struct ITfTextInputProcessorEx : public ITfTextInputProcessor {
  virtual HRESULT STDMETHODCALLTYPE ActivateEx(ITfThreadMgr *, TfClientId, DWORD) = 0;
};
inline constexpr IID IID_ITfTextInputProcessorEx = {0x6e4e2102,0xf9cd,0x433d,{0xb4,0x96,0x30,0x3c,0xe0,0x3a,0x65,0x07}};
#endif
inline constexpr TfClientId PrivateInputClientNull = 0;
extern HINSTANCE g_instance;
extern std::atomic<long> g_objects;
extern std::atomic<long> g_serverLocks;
// App-owned identity; does not replace or modify another input method.
inline constexpr GUID CLSID_PrivateInput = {0x46a94bf1,0x285e,0x41d7,{0x93,0xf2,0x8b,0x45,0xe7,0x70,0xc1,0x72}};
inline constexpr GUID GUID_PrivateInputProfile = {0x2d83f1a9,0x795d,0x4b7e,{0xa6,0x80,0x09,0x27,0x5d,0x65,0x71,0x37}};
// Internal factory configuration. The DLL's COM export always uses its normal
// app-owned paths; isolated hosts can supply their own synthetic storage.
struct PrivateInputEnginePaths {
  std::filesystem::path shared, user;
#ifdef PRIVATE_INPUT_TSF_TEST_HOOKS
  // Only isolated fixture builds compile this field/error injection. The COM
  // DLL, installer and normal production factory have no rejection hook.
  unsigned rejectCompositionEndsForTests=0;
  bool directKeySinkOnlyForTests=false;
#endif
};
HRESULT CreatePrivateInput(REFIID iid, void **result, const PrivateInputEnginePaths *paths = nullptr);
