#include "BackgroundTask.h"
#include <memory>
#ifdef PRIVATE_INPUT_BACKGROUND_TEST_DLL
extern "C" __declspec(dllexport) BOOL beginBlockingTask(HANDLE entered,HANDLE release,HANDLE completed){
 return private_input::BackgroundTask::start([entered,release,completed]{SetEvent(entered);WaitForSingleObject(release,INFINITE);SetEvent(completed);});
}
#else
#include <iostream>
int wmain(int argc,wchar_t**argv){
 if(argc!=2)return 2;
 auto dll=LoadLibraryW(argv[1]);if(!dll)return 3;
 using Start=BOOL(*)(HANDLE,HANDLE,HANDLE);
 auto start=reinterpret_cast<Start>(GetProcAddress(dll,"beginBlockingTask"));if(!start)return 4;
 auto entered=CreateEventW(nullptr,TRUE,FALSE,nullptr),release=CreateEventW(nullptr,TRUE,FALSE,nullptr),completed=CreateEventW(nullptr,TRUE,FALSE,nullptr);
 if(!start(entered,release,completed)||WaitForSingleObject(entered,5000)!=WAIT_OBJECT_0)return 5;
 FreeLibrary(dll);
 // The blocked job must retain executable code after the COM-style owner
 // releases its last loader reference, without pinning the DLL forever.
 if(GetModuleHandleW(argv[1])!=dll)return 6;
 SetEvent(release);if(WaitForSingleObject(completed,5000)!=WAIT_OBJECT_0)return 7;
 auto deadline=GetTickCount64()+5000;
 while(GetModuleHandleW(argv[1])&&GetTickCount64()<deadline)Sleep(1);
 const bool unloaded=GetModuleHandleW(argv[1])==nullptr;
 CloseHandle(entered);CloseHandle(release);CloseHandle(completed);
 if(!unloaded)return 8;
 std::cout<<"{\"passed\":true,\"blockedCallbackRetainsDLL\":true,\"DLLUnloadsAfterCallback\":true,\"productionIPCUsed\":false}\n";
 return 0;
}
#endif
