#pragma once
#include <windows.h>
#include <functional>
#include <memory>

namespace private_input {
// A background job owns its state and a module reference. A TSF owner can retire
// it without joining on the host's input thread. Windows releases the DLL only
// after the callback and all captured C++ objects have finished destruction.
class BackgroundTask {
  struct Job { HMODULE module; std::function<void()> action; };
  static void CALLBACK invoke(PTP_CALLBACK_INSTANCE instance, void* context) noexcept {
    std::unique_ptr<Job> job(static_cast<Job*>(context));
    FreeLibraryWhenCallbackReturns(instance, job->module);
    CallbackMayRunLong(instance);
    try { job->action(); } catch (...) {}
  }
public:
  static bool start(std::function<void()> action) noexcept {
    HMODULE module=nullptr;
    if(!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS,
        reinterpret_cast<LPCWSTR>(&invoke), &module)) return false;
    try {
      auto job=std::make_unique<Job>(Job{module,std::move(action)});
      if(TrySubmitThreadpoolCallback(invoke,job.get(),nullptr)){job.release();return true;}
    } catch (...) {}
    FreeLibrary(module);
    return false;
  }
};
}
