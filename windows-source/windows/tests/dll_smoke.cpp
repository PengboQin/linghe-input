#include "PrivateInputTSF.h"
#include <filesystem>
#include <iostream>
#include <stdexcept>
void check(bool ok,const char *reason){if(!ok)throw std::runtime_error(reason);}
int main(int argc,char **argv){
  HMODULE dll=nullptr;
  try{
    check(SUCCEEDED(CoInitializeEx(nullptr,COINIT_APARTMENTTHREADED)),"COM apartment unavailable");
    check(argc==2,"usage: dll_smoke OWN_TSF_DLL");
    const auto path=std::filesystem::absolute(argv[1]).wstring();
    dll=LoadLibraryExW(path.c_str(),nullptr,LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR|LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
    check(dll!=nullptr,"DLL load failed");
    using Getter=HRESULT(WINAPI*)(REFCLSID,REFIID,void**);
    using Unload=HRESULT(WINAPI*)();
    auto get=reinterpret_cast<Getter>(GetProcAddress(dll,"DllGetClassObject"));
    auto unload=reinterpret_cast<Unload>(GetProcAddress(dll,"DllCanUnloadNow"));
    check(get&&unload,"COM exports missing");check(unload()==S_OK,"initial unload state invalid");
    IClassFactory *factory=nullptr;
    check(SUCCEEDED(get(CLSID_PrivateInput,IID_IClassFactory,reinterpret_cast<void**>(&factory))),"factory unavailable");
    check(unload()==S_FALSE,"live factory lifetime not counted");
    ITfTextInputProcessorEx *extended=nullptr;
    check(SUCCEEDED(factory->CreateInstance(nullptr,IID_ITfTextInputProcessorEx,reinterpret_cast<void**>(&extended))),"extended activation interface unavailable");
    ITfTextInputProcessor *base=nullptr;ITfKeyEventSink *sink=nullptr;ITfCompositionSink *composition=nullptr;
    check(SUCCEEDED(extended->QueryInterface(IID_ITfTextInputProcessor,reinterpret_cast<void**>(&base))),"base TIP interface unavailable");
    check(SUCCEEDED(extended->QueryInterface(IID_ITfKeyEventSink,reinterpret_cast<void**>(&sink))),"key sink interface unavailable");
    check(SUCCEEDED(extended->QueryInterface(IID_ITfCompositionSink,reinterpret_cast<void**>(&composition))),"composition sink interface unavailable");
    IUnknown *one=nullptr,*two=nullptr;
    extended->QueryInterface(IID_IUnknown,reinterpret_cast<void**>(&one));sink->QueryInterface(IID_IUnknown,reinterpret_cast<void**>(&two));
    check(one&&one==two,"COM identity differs between interfaces");
    ITfThreadMgr *manager=nullptr;TfClientId client=0;
    check(SUCCEEDED(CoCreateInstance(CLSID_TF_ThreadMgr,nullptr,CLSCTX_INPROC_SERVER,IID_ITfThreadMgr,reinterpret_cast<void**>(&manager))),"OS TSF manager unavailable");
    check(SUCCEEDED(manager->Activate(&client)),"OS TSF manager activation failed");
    check(SUCCEEDED(extended->ActivateEx(manager,client,TF_TMAE_SECUREMODE)),"secure activation failed");
    BOOL eaten=TRUE;
    check(SUCCEEDED(sink->OnTestKeyDown(nullptr,'N',0,&eaten))&&!eaten,"secure mode intercepted input");
    eaten=TRUE;
    check(SUCCEEDED(sink->OnKeyDown(nullptr,'N',0,&eaten))&&!eaten,"secure mode consumed input");
    check(SUCCEEDED(extended->Deactivate()),"secure deactivation failed");
    manager->Deactivate();manager->Release();
    one->Release();two->Release();composition->Release();sink->Release();base->Release();extended->Release();factory->Release();
    check(unload()==S_OK,"component references leaked");
    FreeLibrary(dll);
    CoUninitialize();
    std::cout<<"PASS: COM/composition interfaces and lifetime; real OS TSF secure activation passes keys through; no registration or UI input\n";
    return 0;
  }catch(const std::exception &e){if(dll)FreeLibrary(dll);std::cerr<<"FAIL: "<<e.what()<<" code="<<GetLastError()<<"\n";return 1;}
}
