#pragma once
#include <windows.h>
#include <textstor.h>
#include <olectl.h>
#include <wrl/client.h>
#include <atomic>
#include <algorithm>
#include <string>

// A real ACP text store for an app-owned synthetic document. TSF supplies the
// context, ranges, edit cookies and composition manager; none is mocked.
class SyntheticTextStore final : public ITextStoreACP {
  std::atomic<ULONG> refs{1};
  Microsoft::WRL::ComPtr<ITextStoreACPSink> sink;
  DWORD lock=0,queued=0;
  HWND window;
  TS_SELECTION_ACP selection{0,0,{TS_AE_NONE,FALSE}};
  bool readable()const{return (lock&TS_LF_READ)!=0;}
  bool writable()const{return (lock&TS_LF_READWRITE)==TS_LF_READWRITE;}
  bool range(LONG a,LONG b)const{return a>=0&&b>=a&&size_t(b)<=text.size();}
public:
  std::wstring text;
  unsigned writes=0,locks=0;
  unsigned failNextWrites=0;
  bool readonly=false;
  HRESULT textExtResult=S_OK;BOOL textExtClipped=FALSE;bool textExtEmpty=false;
  bool deferAsyncLayouts=false;DWORD deferredLayoutFlags=0;
  void releaseDeferredLayouts(){deferAsyncLayouts=false;if(deferredLayoutFlags){auto flags=deferredLayoutFlags;deferredLayoutFlags=0;HRESULT result=E_FAIL;RequestLock(flags,&result);}}
  unsigned textExtQueries=0;LONG lastTextExtStart=-1,lastTextExtEnd=-1,layoutWrapColumns=0;RECT lastTextExtRect{};
  void notifyLayout(){if(sink)sink->OnLayoutChange(TS_LC_CHANGE,1);}

  explicit SyntheticTextStore(HWND hwnd):window(hwnd){}
  void appCaret(LONG position){if(lock||!range(position,position))return;selection.acpStart=selection.acpEnd=position;if(sink)sink->OnSelectionChange();}
  void setReadOnly(bool value){readonly=value;if(sink)sink->OnStatusChange(TS_SD_READONLY);}
  void appInsert(WCHAR value){if(readonly||lock)return;LONG a=selection.acpStart,b=selection.acpEnd;text.replace(a,b-a,1,value);selection.acpStart=selection.acpEnd=a+1;TS_TEXTCHANGE change{a,b,a+1};if(sink){sink->OnTextChange(0,&change);sink->OnSelectionChange();}InvalidateRect(window,nullptr,TRUE);}
  STDMETHODIMP QueryInterface(REFIID iid,void **out)override{if(!out)return E_POINTER;*out=nullptr;if(iid!=IID_IUnknown&&iid!=IID_ITextStoreACP)return E_NOINTERFACE;*out=static_cast<ITextStoreACP*>(this);AddRef();return S_OK;}
  STDMETHODIMP_(ULONG) AddRef()override{return ++refs;}
  STDMETHODIMP_(ULONG) Release()override{auto n=--refs;if(!n)delete this;return n;}
  STDMETHODIMP AdviseSink(REFIID iid,IUnknown *object,DWORD)override{
    if(iid!=IID_ITextStoreACPSink||!object)return E_INVALIDARG;
    Microsoft::WRL::ComPtr<ITextStoreACPSink> incoming;
    HRESULT hr=object->QueryInterface(iid,reinterpret_cast<void**>(incoming.GetAddressOf()));if(FAILED(hr))return hr;
    if(sink&&sink.Get()!=incoming.Get())return CONNECT_E_ADVISELIMIT;
    sink=incoming;return S_OK;
  }
  STDMETHODIMP UnadviseSink(IUnknown *object)override{
    Microsoft::WRL::ComPtr<IUnknown> identity; if(sink)sink.As(&identity);
    if(!identity||identity.Get()!=object)return CONNECT_E_NOCONNECTION;sink.Reset();return S_OK;
  }
  STDMETHODIMP RequestLock(DWORD flags,HRESULT *session)override{
    if(!session)return E_POINTER;if(!sink)return E_UNEXPECTED;
    if(deferAsyncLayouts&&!(flags&TS_LF_SYNC)){deferredLayoutFlags|=flags;*session=TS_S_ASYNC;return S_OK;}
    if(lock){if(flags&TS_LF_SYNC){*session=TS_E_SYNCHRONOUS;return S_OK;}queued|=(flags&TS_LF_READWRITE);*session=TS_S_ASYNC;return S_OK;}
    lock=flags&TS_LF_READWRITE;++locks;*session=sink->OnLockGranted(flags);lock=0;
    while(queued){auto next=queued;queued=0;lock=next;++locks;sink->OnLockGranted(next);lock=0;}
    return S_OK;
  }
  STDMETHODIMP GetStatus(TS_STATUS *status)override{if(!status)return E_POINTER;status->dwDynamicFlags=readonly?TS_SD_READONLY:0;status->dwStaticFlags=TS_SS_NOHIDDENTEXT;return S_OK;}
  STDMETHODIMP QueryInsert(LONG a,LONG b,ULONG,LONG *start,LONG *end)override{if(!start||!end)return E_POINTER;if(!range(a,b))return TS_E_INVALIDPOS;*start=a;*end=b;return S_OK;}
  STDMETHODIMP GetSelection(ULONG index,ULONG count,TS_SELECTION_ACP *out,ULONG *fetched)override{if(!out||!fetched)return E_POINTER;*fetched=0;if(!readable())return TS_E_NOLOCK;if(index!=TS_DEFAULT_SELECTION&&index!=0)return E_INVALIDARG;if(count){*out=selection;*fetched=1;}return S_OK;}
  STDMETHODIMP SetSelection(ULONG count,const TS_SELECTION_ACP *value)override{if(!writable())return TS_E_NOLOCK;if(count!=1||!value||!range(value->acpStart,value->acpEnd))return E_INVALIDARG;selection=*value;return S_OK;}
  STDMETHODIMP GetText(LONG a,LONG b,WCHAR *plain,ULONG capacity,ULONG *plainCount,TS_RUNINFO *runs,ULONG runCapacity,ULONG *runCount,LONG *next)override{
    if(!plainCount||!runCount||!next)return E_POINTER;*plainCount=0;*runCount=0;if(!readable())return TS_E_NOLOCK;
    if(b==-1)b=LONG(text.size());if(!range(a,b))return TS_E_INVALIDPOS;
    ULONG amount=ULONG(b-a);if(capacity){if(!plain)return E_POINTER;amount=std::min(amount,capacity);std::copy_n(text.data()+a,amount,plain);*plainCount=amount;}
    if(runCapacity){if(!runs)return E_POINTER;runs[0]={amount,TS_RT_PLAIN};*runCount=1;}*next=a+LONG(amount);return S_OK;
  }
  STDMETHODIMP SetText(DWORD,LONG a,LONG b,const WCHAR *value,ULONG count,TS_TEXTCHANGE *change)override{
    if(!writable())return TS_E_NOLOCK;if(readonly)return TS_E_READONLY;if(!change||(count&&!value))return E_POINTER;if(!range(a,b))return TS_E_INVALIDPOS;
    if(failNextWrites){--failNextWrites;return E_FAIL;}
    text.replace(size_t(a),size_t(b-a),value?std::wstring(value,count):L"");*change={a,b,a+LONG(count)};++writes;InvalidateRect(window,nullptr,TRUE);return S_OK;
  }
  STDMETHODIMP GetFormattedText(LONG,LONG,IDataObject **out)override{if(out)*out=nullptr;return E_NOTIMPL;}
  STDMETHODIMP GetEmbedded(LONG,REFGUID,REFIID,IUnknown **out)override{if(out)*out=nullptr;return E_NOTIMPL;}
  STDMETHODIMP QueryInsertEmbedded(const GUID*,const FORMATETC*,BOOL *out)override{if(!out)return E_POINTER;*out=FALSE;return S_OK;}
  STDMETHODIMP InsertEmbedded(DWORD,LONG,LONG,IDataObject*,TS_TEXTCHANGE*)override{return E_NOTIMPL;}
  STDMETHODIMP InsertTextAtSelection(DWORD flags,const WCHAR *value,ULONG count,LONG *start,LONG *end,TS_TEXTCHANGE *change)override{
    if(!writable())return TS_E_NOLOCK;
    if(flags&TS_IAS_QUERYONLY){if(start)*start=selection.acpStart;if(end)*end=selection.acpEnd;return S_OK;}
    LONG a=selection.acpStart,b=selection.acpEnd;TS_TEXTCHANGE actual;
    HRESULT hr=SetText(0,a,b,value,count,&actual);if(FAILED(hr))return hr;selection.acpStart=selection.acpEnd=actual.acpNewEnd;
    if(start)*start=a;if(end)*end=actual.acpNewEnd;if(change)*change=actual;return S_OK;
  }
  STDMETHODIMP InsertEmbeddedAtSelection(DWORD,IDataObject*,LONG*,LONG*,TS_TEXTCHANGE*)override{return E_NOTIMPL;}
  STDMETHODIMP RequestSupportedAttrs(DWORD,ULONG,const TS_ATTRID*)override{return S_OK;}
  STDMETHODIMP RequestAttrsAtPosition(LONG,ULONG,const TS_ATTRID*,DWORD)override{return S_OK;}
  STDMETHODIMP RequestAttrsTransitioningAtPosition(LONG,ULONG,const TS_ATTRID*,DWORD)override{return S_OK;}
  STDMETHODIMP FindNextAttrTransition(LONG,LONG halt,ULONG,const TS_ATTRID*,DWORD,LONG *next,BOOL *found,LONG *offset)override{if(!next||!found||!offset)return E_POINTER;*next=halt;*found=FALSE;*offset=0;return S_OK;}
  STDMETHODIMP RetrieveRequestedAttrs(ULONG,TS_ATTRVAL*,ULONG *fetched)override{if(!fetched)return E_POINTER;*fetched=0;return S_OK;}
  STDMETHODIMP GetEndACP(LONG *end)override{if(!end)return E_POINTER;if(!readable())return TS_E_NOLOCK;*end=LONG(text.size());return S_OK;}
  STDMETHODIMP GetActiveView(TsViewCookie *view)override{if(!view)return E_POINTER;*view=1;return S_OK;}
  STDMETHODIMP GetACPFromPoint(TsViewCookie,const POINT*,DWORD,LONG *position)override{if(!position)return E_POINTER;*position=LONG(text.size());return S_OK;}
  STDMETHODIMP GetTextExt(TsViewCookie,LONG a,LONG b,RECT *rect,BOOL *clipped)override{if(!rect||!clipped)return E_POINTER;if(!readable())return TS_E_NOLOCK;if(!range(a,b))return TS_E_INVALIDPOS;++textExtQueries;lastTextExtStart=a;lastTextExtEnd=b;*rect={};*clipped=textExtClipped;if(textExtResult!=S_OK)return textExtResult;if(textExtEmpty){lastTextExtRect={};return S_OK;}LONG column=layoutWrapColumns>0?a%layoutWrapColumns:a,row=layoutWrapColumns>0?a/layoutWrapColumns:0;POINT p{16+column*14,45+row*24};ClientToScreen(window,&p);*rect={p.x,p.y,p.x+std::max<LONG>(2,(b-a)*14),p.y+24};lastTextExtRect=*rect;return S_OK;}
  STDMETHODIMP GetScreenExt(TsViewCookie,RECT *rect)override{if(!rect)return E_POINTER;GetWindowRect(window,rect);return S_OK;}
  STDMETHODIMP GetWnd(TsViewCookie,HWND *out)override{if(!out)return E_POINTER;*out=window;return S_OK;}
};
