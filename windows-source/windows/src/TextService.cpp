#include "PrivateInputTSF.h"
#include "CandidateWindow.h"
#include "CandidateStream.h"
#include "ClipboardCandidatePolicy.h"
#include "../activity/ClipboardCandidateIPC.h"
#include "DesktopPreferences.h"
#include "EnglishSuggestions.h"
#include "SymbolPairing.h"
#include "GlyphFilter.h"
#include "pinyin_text.h"
#include "private_input.h"
#include "../activity/CaptureIPC.h"
#include "../activity/LearningIPC.h"
#include <algorithm>
#include <cmath>
#include <wrl/client.h>
#include <shlobj.h>
#include <shellapi.h>
#include <fstream>
#include <initguid.h>
#include <inputscope.h>
#include <filesystem>
#include <functional>
#include <string>
#include <optional>
#include "ShiftTapMode.h"
#include "../activity/Json.h"
using Microsoft::WRL::ComPtr;
HINSTANCE g_instance=nullptr;
std::atomic<long> g_objects{0},g_serverLocks{0};
namespace {
std::string utf8(const std::wstring &s){if(s.empty())return {};int n=WideCharToMultiByte(CP_UTF8,0,s.data(),int(s.size()),nullptr,0,nullptr,nullptr);std::string r(n,0);WideCharToMultiByte(CP_UTF8,0,s.data(),int(s.size()),r.data(),n,nullptr,nullptr);return r;}
std::wstring wide(const char *s){if(!s||!*s)return {};int n=MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,s,-1,nullptr,0);if(!n)return {};std::wstring r(n,0);MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,s,-1,r.data(),n);r.resize(n-1);return r;}
class EditJob final:public ITfEditSession {
  std::atomic<ULONG> refs{1};ComPtr<IUnknown> owner;std::function<HRESULT(TfEditCookie)> action;std::function<void()>completed;
public:
  EditJob(IUnknown *object,std::function<HRESULT(TfEditCookie)> callback,std::function<void()>finish={}):owner(object),action(std::move(callback)),completed(std::move(finish)){++g_objects;}
  ~EditJob(){if(completed)completed();--g_objects;}
  STDMETHODIMP QueryInterface(REFIID iid,void **out)override{if(!out)return E_POINTER;*out=nullptr;if(iid!=IID_IUnknown&&iid!=IID_ITfEditSession)return E_NOINTERFACE;*out=static_cast<ITfEditSession*>(this);AddRef();return S_OK;}
  STDMETHODIMP_(ULONG) AddRef()override{return ++refs;}
  STDMETHODIMP_(ULONG) Release()override{auto n=--refs;if(!n)delete this;return n;}
  STDMETHODIMP DoEditSession(TfEditCookie cookie)override{return action(cookie);}
};
enum class FieldScope {unknown,normal,privateField,password};
FieldScope scopeOf(ITfContext *ctx,TfEditCookie cookie){
  TF_SELECTION selected{};ULONG fetched=0;if(FAILED(ctx->GetSelection(cookie,TF_DEFAULT_SELECTION,1,&selected,&fetched))||!fetched)return FieldScope::unknown;
  ComPtr<ITfRange> range;range.Attach(selected.range);ComPtr<ITfReadOnlyProperty> property;
  if(FAILED(ctx->GetAppProperty(GUID_PROP_INPUTSCOPE,&property)))return FieldScope::unknown;
  VARIANT value;VariantInit(&value);FieldScope result=FieldScope::unknown;
  if(SUCCEEDED(property->GetValue(cookie,range.Get(),&value))&&value.vt==VT_UNKNOWN&&value.punkVal){
    ComPtr<ITfInputScope> scope;
    if(SUCCEEDED(value.punkVal->QueryInterface(IID_ITfInputScope,reinterpret_cast<void**>(scope.GetAddressOf())))){
      InputScope *items=nullptr;UINT count=0;
      if(SUCCEEDED(scope->GetInputScopes(&items,&count))&&items&&count<=128){result=FieldScope::normal;for(UINT i=0;i<count;++i)if(items[i]==IS_PASSWORD||items[i]==IS_NUMERIC_PASSWORD)result=FieldScope::password;else if(items[i]==IS_PRIVATE&&result!=FieldScope::password)result=FieldScope::privateField;}
      CoTaskMemFree(items);
    }
  }
  VariantClear(&value);return result;
}
uint32_t archiveFieldType(ITfContext*ctx,TfEditCookie cookie){
 TF_SELECTION selected{};ULONG fetched=0;if(FAILED(ctx->GetSelection(cookie,TF_DEFAULT_SELECTION,1,&selected,&fetched))||!fetched||!selected.range)return 0;ComPtr<ITfRange>range;range.Attach(selected.range);ComPtr<ITfReadOnlyProperty>property;if(FAILED(ctx->GetAppProperty(GUID_PROP_INPUTSCOPE,&property)))return 0;VARIANT value;VariantInit(&value);uint32_t result=0;
 if(SUCCEEDED(property->GetValue(cookie,range.Get(),&value))&&value.vt==VT_UNKNOWN&&value.punkVal){ComPtr<ITfInputScope>scope;if(SUCCEEDED(value.punkVal->QueryInterface(IID_ITfInputScope,reinterpret_cast<void**>(scope.GetAddressOf())))){InputScope*items=nullptr;UINT count=0;if(SUCCEEDED(scope->GetInputScopes(&items,&count))&&items&&count==1){switch(items[0]){case IS_DEFAULT:case IS_TEXT:case IS_CHAT:case IS_CHAT_WITHOUT_EMOJI:result=1;break;case IS_EMAIL_USERNAME:case IS_EMAIL_SMTPEMAILADDRESS:case IS_EMAILNAME_OR_ADDRESS:result=2;break;case IS_URL:result=3;break;case IS_DIGITS:case IS_NUMBER:case IS_NUMBER_FULLWIDTH:result=4;break;case IS_TELEPHONE_FULLTELEPHONENUMBER:case IS_TELEPHONE_COUNTRYCODE:case IS_TELEPHONE_AREACODE:case IS_TELEPHONE_LOCALNUMBER:result=5;break;case IS_SEARCH:case IS_SEARCH_INCREMENTAL:result=6;break;default:break;}}CoTaskMemFree(items);}}VariantClear(&value);return result;
}
bool disabled(ITfContext *ctx){
  TF_STATUS status{};if(SUCCEEDED(ctx->GetStatus(&status))&&(status.dwDynamicFlags&TF_SD_READONLY))return true;
  ComPtr<ITfCompartmentMgr> mgr;if(FAILED(ctx->QueryInterface(IID_ITfCompartmentMgr,reinterpret_cast<void**>(mgr.GetAddressOf()))))return false;
  ComPtr<ITfCompartment> item;if(FAILED(mgr->GetCompartment(GUID_COMPARTMENT_KEYBOARD_DISABLED,&item)))return false;
  VARIANT v;VariantInit(&v);bool result=false;if(SUCCEEDED(item->GetValue(&v)))result=(v.vt==VT_I4&&v.lVal!=0)||(v.vt==VT_BOOL&&v.boolVal!=VARIANT_FALSE);VariantClear(&v);return result;
}
struct CachedDesktopPreferences{private_input::DesktopCandidates layout;DesktopInputPreferences input;};
class TextService final:public ITfTextInputProcessorEx,public ITfKeyEventSink,public ITfCompositionSink,public ITfTextEditSink {
  std::atomic<ULONG> refs{1};ComPtr<ITfThreadMgr> manager;ComPtr<ITfKeystrokeMgr> keystrokes;
  ComPtr<ITfContext> compositionContext,pendingContext;ComPtr<ITfComposition> composition;
  TfClientId client=PrivateInputClientNull;PI_Session session=0;
  bool secure=false,english=false,privateSchema=false,degraded=false,finishPending=false,keySinkAdvised=false;
  private_input::ShiftTapMode shiftTap;
  std::shared_ptr<const CachedDesktopPreferences>desktopCache=std::make_shared<CachedDesktopPreferences>();
  unsigned ownEndDepth=0;std::string contextBefore,contextAfter;std::filesystem::path publicContextPath;
  private_input::activity::CaptureEmitter archiveEmitter;
  private_input::activity::LearningReader learningReader;std::vector<std::pair<std::wstring,std::wstring>>learningSelections;
  std::array<unsigned char,16> archiveSession{},archiveEditor{};
  ITfContext* archiveContext=nullptr;std::optional<LONG> archiveExpectedCaret;
  void renewArchiveEditor(ITfContext*ctx,bool force=false){if(!force&&archiveContext==ctx)return;archiveContext=ctx;archiveExpectedCaret.reset();GUID value{};if(SUCCEEDED(CoCreateGuid(&value)))memcpy(archiveEditor.data(),&value,sizeof(value));}
  std::optional<LONG> archiveCaret(ITfContext*ctx,TfEditCookie cookie){TF_SELECTION selection{};ULONG fetched=0;if(FAILED(ctx->GetSelection(cookie,TF_DEFAULT_SELECTION,1,&selection,&fetched))||fetched!=1||!selection.range)return {};ComPtr<ITfRange>range;range.Attach(selection.range);ComPtr<ITfRangeACP>acp;LONG at=0,length=0;if(FAILED(range.As(&acp))||FAILED(acp->GetExtent(&at,&length))||at<0||length!=0)return {};return at;}
  void observeArchiveCaret(ITfContext*ctx,TfEditCookie cookie){auto caret=archiveCaret(ctx,cookie);if(ctx!=archiveContext||!caret||!archiveExpectedCaret||*caret!=*archiveExpectedCaret)renewArchiveEditor(ctx,true);}
  void archiveCommit(ITfContext*ctx,TfEditCookie cookie,const std::wstring&text){if(secure||text.empty()||scopeOf(ctx,cookie)!=FieldScope::normal)return;ComPtr<ITfContextView> view;HWND hwnd=nullptr;if(FAILED(ctx->GetActiveView(&view))||FAILED(view->GetWnd(&hwnd))||!hwnd)return;renewArchiveEditor(ctx);archiveExpectedCaret=archiveCaret(ctx,cookie);archiveEmitter.emit(text,hwnd,archiveSession,archiveEditor,true,english?2:1,archiveFieldType(ctx,cookie));}
  private_input::ClipboardCandidatePolicy clipboardPolicy;private_input::activity::ClipboardCandidateReader clipboardReader;
  private_input::activity::ClipboardCandidateSnapshot clipboardOffer;ComPtr<ITfContext>clipboardContext;ComPtr<ITfRange>clipboardSelection;
  DWORD clipboardEditCookie=TF_INVALID_COOKIE;
  uint64_t clipboardPendingRequest=0,clipboardInFlightRequest=0,clipboardRequestCounter=0;
  HWND clipboardPollWindow=nullptr;bool clipboardVisible=false;
  static LRESULT CALLBACK clipboardPollProc(HWND hwnd,UINT message,WPARAM w,LPARAM l){auto*self=reinterpret_cast<TextService*>(GetWindowLongPtrW(hwnd,GWLP_USERDATA));if(message==WM_NCCREATE){self=static_cast<TextService*>(reinterpret_cast<CREATESTRUCTW*>(l)->lpCreateParams);SetWindowLongPtrW(hwnd,GWLP_USERDATA,reinterpret_cast<LONG_PTR>(self));}if(self&&message==WM_TIMER){self->pollClipboardCandidate();return 0;}return DefWindowProcW(hwnd,message,w,l);}
  void retireClipboard(uint32_t sequence=0){clipboardPendingRequest=0;if(clipboardEditCookie!=TF_INVALID_COOKIE&&clipboardContext){ComPtr<ITfSource>source;if(SUCCEEDED(clipboardContext.As(&source)))source->UnadviseSink(clipboardEditCookie);}clipboardEditCookie=TF_INVALID_COOKIE;clipboardPolicy.dismiss(sequence?sequence:clipboardOffer.sequence);clipboardOffer={};clipboardContext.Reset();clipboardSelection.Reset();if(clipboardVisible){clipboardVisible=false;words.clear();panel.hide();++revision;}}
  bool sameClipboardSelection(ITfContext*ctx,TfEditCookie cookie){if(!clipboardSelection||clipboardContext.Get()!=ctx)return false;TF_SELECTION selected{};ULONG count=0;if(FAILED(ctx->GetSelection(cookie,TF_DEFAULT_SELECTION,1,&selected,&count))||count!=1||!selected.range)return false;ComPtr<ITfRange>current;current.Attach(selected.range);LONG start=1,end=1;return SUCCEEDED(current->CompareStart(cookie,clipboardSelection.Get(),TF_ANCHOR_START,&start))&&SUCCEEDED(current->CompareEnd(cookie,clipboardSelection.Get(),TF_ANCHOR_END,&end))&&start==0&&end==0;}
  void pollClipboardCandidate(){
    if(secure||!session||!manager||clipboardInFlightRequest)return;auto snapshot=clipboardReader.read();
    if(clipboardPolicy.deleteHeld&&!((GetAsyncKeyState(VK_DELETE)|GetAsyncKeyState(VK_BACK))&0x8000))clipboardPolicy.releaseDelete();if(clipboardPolicy.deleteHeld||((GetAsyncKeyState(VK_DELETE)|GetAsyncKeyState(VK_BACK))&0x8000)){if(clipboardVisible)retireClipboard();return;}
    if(composing()||composition||finishPending||!pendingCommit.empty()){retireClipboard(snapshot.sequence);return;}
    ComPtr<ITfDocumentMgr>document;ComPtr<ITfContext>ctx;if(FAILED(manager->GetFocus(&document))||!document||FAILED(document->GetTop(&ctx))||!ctx||!focusedContext(ctx.Get())||snapshot.text.empty()){retireClipboard();return;}
    if(clipboardContext&&clipboardContext.Get()!=ctx.Get()){retireClipboard(snapshot.sequence);return;}
    const auto version=revision,requestID=++clipboardRequestCounter;clipboardPendingRequest=requestID;clipboardInFlightRequest=requestID;HRESULT result=E_FAIL;
    auto hr=request(ctx.Get(),TF_ES_ASYNCDONTCARE|TF_ES_READ,[this,ctx,snapshot=std::move(snapshot),version,requestID](TfEditCookie cookie){if(clipboardPendingRequest!=requestID)return S_FALSE;clipboardPendingRequest=0;auto current=clipboardReader.read();
      if(version!=revision||!focusedContext(ctx.Get())||composing()||composition||clipboardPolicy.deleteHeld||disabled(ctx.Get())||scopeOf(ctx.Get(),cookie)!=FieldScope::normal||snapshot.sequence!=current.sequence||snapshot.generation!=current.generation){if(clipboardVisible||!focusedContext(ctx.Get())||scopeOf(ctx.Get(),cookie)!=FieldScope::normal)retireClipboard(snapshot.sequence);return S_FALSE;}
      if(clipboardVisible&&clipboardOffer.sequence==snapshot.sequence&&!sameClipboardSelection(ctx.Get(),cookie)){retireClipboard(snapshot.sequence);return S_FALSE;}
      if(!clipboardPolicy.offer(snapshot.sequence,true,true,true,true))return S_FALSE;
      TF_SELECTION selected{};ULONG count=0;if(FAILED(ctx->GetSelection(cookie,TF_DEFAULT_SELECTION,1,&selected,&count))||count!=1||!selected.range){retireClipboard(snapshot.sequence);return S_FALSE;}
      ComPtr<ITfRange>selection;selection.Attach(selected.range);bool changed=!clipboardVisible||clipboardOffer.sequence!=snapshot.sequence;
      clipboardOffer=snapshot;clipboardContext=ctx;clipboardSelection=selection;if(clipboardEditCookie==TF_INVALID_COOKIE){ComPtr<ITfSource>source;if(SUCCEEDED(ctx.As(&source)))source->AdviseSink(IID_ITfTextEditSink,static_cast<ITfTextEditSink*>(this),&clipboardEditCookie);}clipboardVisible=true;panel.allowManagement(false);words={private_input::clipboardCandidatePreview(snapshot.text)};navigation.reset(1);if(changed)++revision;updatePanel(ctx.Get(),cookie);return S_OK;
    },&result,[this,requestID]{if(clipboardPendingRequest==requestID)clipboardPendingRequest=0;if(clipboardInFlightRequest==requestID)clipboardInFlightRequest=0;});if((FAILED(hr)||FAILED(result))&&clipboardPendingRequest==requestID)clipboardPendingRequest=0;
  }
  HRESULT pasteClipboardCandidate(ITfContext*ctx,TfEditCookie cookie,unsigned long long version){auto current=clipboardReader.read();if(!clipboardVisible||version!=revision||current.sequence!=clipboardOffer.sequence||current.generation!=clipboardOffer.generation||!focusedContext(ctx)||disabled(ctx)||scopeOf(ctx,cookie)!=FieldScope::normal||composing()||composition||!sameClipboardSelection(ctx,cookie)){retireClipboard();return S_FALSE;}
    const auto text=clipboardOffer.text;ComPtr<ITfInsertAtSelection>insert;if(FAILED(ctx->QueryInterface(IID_ITfInsertAtSelection,reinterpret_cast<void**>(insert.GetAddressOf()))))return E_FAIL;ComPtr<ITfRange>range;
    auto hr=insert->InsertTextAtSelection(cookie,TF_IAS_QUERYONLY,nullptr,0,&range);if(FAILED(hr))return hr;
    // Retire before writing: a failed host edit cannot later retry stale content.
    auto last=clipboardReader.read();if(last.sequence!=clipboardOffer.sequence||last.generation!=clipboardOffer.generation||!focusedContext(ctx)||scopeOf(ctx,cookie)!=FieldScope::normal||!sameClipboardSelection(ctx,cookie)){retireClipboard();return S_FALSE;}retireClipboard();learningSelections.clear();hr=range->SetText(cookie,0,text.data(),LONG(text.size()));if(FAILED(hr))return hr;
    ComPtr<ITfRange>caret;if(SUCCEEDED(range->Clone(&caret))&&SUCCEEDED(caret->Collapse(cookie,TF_ANCHOR_END))){TF_SELECTION selection{caret.Get(),{TF_AE_NONE,FALSE}};ctx->SetSelection(cookie,1,&selection);}
    ComPtr<ITfContextView>view;HWND host=nullptr;if(SUCCEEDED(ctx->GetActiveView(&view))&&SUCCEEDED(view->GetWnd(&host))&&host){renewArchiveEditor(ctx,true);archiveExpectedCaret=archiveCaret(ctx,cookie);archiveEmitter.emit(text,host,archiveSession,archiveEditor,true,english?2:1,archiveFieldType(ctx,cookie),true);}return S_OK;
  }
  unsigned long long revision=0;std::wstring pendingCommit;std::string englishInput;CandidateWindow panel;
  std::optional<PrivateInputEnginePaths> enginePaths;
  DesktopInputPreferences inputPreferences;CandidateGlyphFilter glyphFilter;private_input::DesktopCandidates navigation;private_input::CandidateStream candidates;std::vector<std::wstring> words;
  IUnknown *identity(){return static_cast<ITfTextInputProcessorEx*>(this);}
  bool composing()const{return !englishInput.empty()||(session&&*pi_preedit(session));}
  std::wstring markedText()const{return english?wide(englishInput.c_str()):wide(pi_preedit(session));}
  bool modeKey(WPARAM key)const{return (key==VK_SHIFT&&shiftTap.down&&!shiftTap.used)||(key==VK_SPACE&&GetKeyState(VK_CONTROL)<0&&GetKeyState(VK_SHIFT)<0&&GetKeyState(VK_MENU)>=0);}
  // Literal keys never block typing: they end the composition with the readable
  // raw spelling and are then handled by the host exactly as without this IME.
  std::wstring literalSymbol(WPARAM key)const{if(key<VK_SPACE||key>VK_OEM_102)return {};BYTE state[256]{};if(!GetKeyboardState(state))return {};wchar_t text[8]{};auto result=ToUnicodeEx(UINT(key),MapVirtualKeyW(UINT(key),MAPVK_VK_TO_VSC),state,text,8,4,GetKeyboardLayout(0));return result==1?std::wstring(text,1):std::wstring{};}
  bool pairKey(WPARAM key)const{if(!std::atomic_load(&desktopCache)->input.pairSymbols)return false;auto symbol=literalSymbol(key);return !symbol.empty()&&private_input::symbolPlan(symbol).text.size()>symbol.size();}
  bool endingLiteral(WPARAM key)const{
    return key==VK_OEM_1||key==VK_OEM_2||key==VK_OEM_3||key==VK_OEM_4||key==VK_OEM_5||key==VK_OEM_6||key==VK_OEM_7||
           key==VK_OEM_102||key==VK_OEM_COMMA||key==VK_OEM_PERIOD||key==VK_OEM_MINUS||key==VK_OEM_PLUS||
           (key>='0'&&key<='9'&&(GetKeyState(VK_SHIFT)<0||navigation.digit(unsigned(key-'0'))>=words.size()))||
           (key>=VK_NUMPAD0&&key<=VK_DIVIDE)||key==VK_TAB;
  }
  bool printable(WPARAM key)const{auto value=literalSymbol(key);return value.size()==1&&value[0]>=32&&value[0]!=127;}
  bool accepts(ITfContext *ctx,WPARAM key)const{
    if(!session||secure||!ctx||disabled(ctx))return false;if((key==VK_DELETE||key==VK_BACK)&&clipboardVisible&&!clipboardPolicy.deleteHeld)return true;if(modeKey(key))return true;
    if(GetKeyState(VK_CONTROL)<0||GetKeyState(VK_MENU)<0||GetKeyState(VK_LWIN)<0||GetKeyState(VK_RWIN)<0)return false;
    return finishPending||!pendingCommit.empty()||(key>='A'&&key<='Z')||(!composing()&&printable(key))||(composing()&&(key==VK_SPACE||key==VK_RETURN||key==VK_BACK||key==VK_ESCAPE||key==VK_LEFT||key==VK_RIGHT||key==VK_UP||key==VK_DOWN||key==VK_PRIOR||key==VK_NEXT||(key>='1'&&key<='9')||endingLiteral(key)));
  }
  bool startEngine(){
    std::filesystem::path shared,user;
    if(enginePaths){shared=enginePaths->shared;user=enginePaths->user;}
    else {
      wchar_t path[32768];DWORD n=GetModuleFileNameW(g_instance,path,32768);if(!n||n>=32768)return false;shared=std::filesystem::path(path).parent_path()/L"data"/L"rime";
      PWSTR data=nullptr;if(FAILED(SHGetKnownFolderPath(FOLDERID_LocalAppData,0,nullptr,&data)))return false;FILETIME created{},ended{},kernel{},userTime{};if(!GetProcessTimes(GetCurrentProcess(),&created,&ended,&kernel,&userTime)){CoTaskMemFree(data);return false;}ULARGE_INTEGER stamp{};stamp.LowPart=created.dwLowDateTime;stamp.HighPart=created.dwHighDateTime;user=std::filesystem::path(data)/L"PrivateInput"/L"RimeSessions"/(std::to_wstring(GetCurrentProcessId())+L"-"+std::to_wstring(stamp.QuadPart));CoTaskMemFree(data);
    }
    for(auto path=std::filesystem::absolute(user).lexically_normal();!path.empty();path=path.parent_path()){auto attributes=GetFileAttributesW(path.c_str());if(attributes!=INVALID_FILE_ATTRIBUTES&&(attributes&FILE_ATTRIBUTE_REPARSE_POINT))return false;if(path==path.parent_path())break;}std::error_code e;std::filesystem::create_directories(user,e);if(e)return false;if(!enginePaths){auto marker=user/L"linghe-generated-session-v1";if(!std::filesystem::exists(marker)){FILETIME created{},ended{},kernel{},userTime{};if(!GetProcessTimes(GetCurrentProcess(),&created,&ended,&kernel,&userTime))return false;ULARGE_INTEGER stamp{};stamp.LowPart=created.dwLowDateTime;stamp.HighPart=created.dwHighDateTime;std::ofstream output(marker,std::ios::binary);output<<"LingheInput generated stateless native session v1\n"<<GetCurrentProcessId()<<"\n"<<stamp.QuadPart<<"\n";if(!output)return false;}}
    if(!pi_initialize(utf8(shared.wstring()).c_str(),utf8(user.wstring()).c_str(),0))return false;session=pi_create_session();if(session&&!enginePaths&&!pi_set_private(session,1)){pi_destroy_session(session);session=0;}publicContextPath=shared.parent_path()/L"semantic"/L"continuation.bin";return session!=0;
  }
  HRESULT request(ITfContext *ctx,DWORD flags,std::function<HRESULT(TfEditCookie)> action,HRESULT *result,std::function<void()>completed={}){auto *job=new EditJob(identity(),std::move(action),std::move(completed));HRESULT hr=ctx->RequestEditSession(client,job,flags,result);job->Release();return hr;}
  void detachComposition(){
    auto old=composition;auto ctx=compositionContext;composition.Reset();compositionContext.Reset();finishPending=false;pendingCommit.clear();pendingContext.Reset();panel.hide();contextBefore.clear();contextAfter.clear();englishInput.clear();learningSelections.clear();if(session)pi_clear(session);++revision;
    if(old&&ctx){HRESULT result=E_FAIL;request(ctx.Get(),TF_ES_ASYNCDONTCARE|TF_ES_READWRITE,[old](TfEditCookie cookie){return old->EndComposition(cookie);},&result);}
  }
  bool selectionInside(ITfContext *ctx,TfEditCookie cookie){
    if(!composition||compositionContext.Get()!=ctx)return false;ComPtr<ITfRange> own;if(FAILED(composition->GetRange(&own)))return false;
    TF_SELECTION selected{};ULONG n=0;if(FAILED(ctx->GetSelection(cookie,TF_DEFAULT_SELECTION,1,&selected,&n))||!n)return false;ComPtr<ITfRange> chosen;chosen.Attach(selected.range);LONG start=0,end=0;
    return SUCCEEDED(chosen->CompareStart(cookie,own.Get(),TF_ANCHOR_START,&start))&&SUCCEEDED(chosen->CompareEnd(cookie,own.Get(),TF_ANCHOR_END,&end))&&start>=0&&end<=0;
  }
  bool focusedContext(ITfContext *ctx){
    if(!manager||!ctx)return false;ComPtr<ITfDocumentMgr> document;ComPtr<ITfContext> top;
    if(FAILED(manager->GetFocus(&document))||!document||FAILED(document->GetTop(&top))||!top)return false;
    ComPtr<IUnknown> current,wanted;
    return SUCCEEDED(top.As(&current))&&SUCCEEDED(ctx->QueryInterface(IID_IUnknown,reinterpret_cast<void**>(wanted.GetAddressOf())))&&current.Get()==wanted.Get();
  }
  void readContext(ITfContext*ctx,TfEditCookie cookie){contextBefore.clear();contextAfter.clear();if(secure||!focusedContext(ctx)||scopeOf(ctx,cookie)!=FieldScope::normal)return;ComPtr<ITfRange>base;if(composition&&compositionContext.Get()==ctx){if(FAILED(composition->GetRange(&base)))return;}else{TF_SELECTION selected{};ULONG count=0;if(FAILED(ctx->GetSelection(cookie,TF_DEFAULT_SELECTION,1,&selected,&count))||count!=1||!selected.range)return;base.Attach(selected.range);}auto read=[&](bool before){ComPtr<ITfRange>range;if(FAILED(base->Clone(&range))||FAILED(range->Collapse(cookie,before?TF_ANCHOR_START:TF_ANCHOR_END)))return std::string{};LONG moved=0;auto hr=before?range->ShiftStart(cookie,-40,&moved,nullptr):range->ShiftEnd(cookie,40,&moved,nullptr);if(FAILED(hr))return std::string{};wchar_t buffer[40]{};ULONG count=0;if(FAILED(range->GetText(cookie,0,buffer,40,&count))||count>40)return std::string{};std::wstring text(buffer,count);size_t start=0,end=text.size(),characters=0;if(before){while(start<end&&characters<20){--end;if(text[end]>=0xdc00&&text[end]<=0xdfff&&end>0&&text[end-1]>=0xd800&&text[end-1]<=0xdbff)--end;++characters;}text=text.substr(end);}else{end=0;while(end<text.size()&&characters<20){if(text[end]>=0xd800&&text[end]<=0xdbff&&end+1<text.size()&&text[end+1]>=0xdc00&&text[end+1]<=0xdfff)++end;++end;++characters;}text.resize(end);}int length=WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,text.data(),int(text.size()),nullptr,0,nullptr,nullptr);if(length<=0)return std::string{};std::string result(length,0);if(WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,text.data(),int(text.size()),result.data(),length,nullptr,nullptr)!=length)return std::string{};return result;};contextBefore=read(true);contextAfter=read(false);}
  HRESULT beginComposition(ITfContext *ctx,TfEditCookie cookie){
    if(finishPending)return E_PENDING; // Never reuse an already committed range.
    if(composition&&selectionInside(ctx,cookie))return S_OK;if(composition)detachComposition();
    observeArchiveCaret(ctx,cookie);
    ComPtr<ITfInsertAtSelection> insert;HRESULT hr=ctx->QueryInterface(IID_ITfInsertAtSelection,reinterpret_cast<void**>(insert.GetAddressOf()));if(FAILED(hr))return hr;
    ComPtr<ITfRange> range;hr=insert->InsertTextAtSelection(cookie,TF_IAS_QUERYONLY,nullptr,0,&range);if(FAILED(hr))return hr;
    ComPtr<ITfContextComposition> comp;hr=ctx->QueryInterface(IID_ITfContextComposition,reinterpret_cast<void**>(comp.GetAddressOf()));if(FAILED(hr))return hr;
    hr=comp->StartComposition(cookie,range.Get(),this,&composition);if(SUCCEEDED(hr))compositionContext=ctx;return hr;
  }
  HRESULT finishComposition(TfEditCookie cookie){
    if(!composition){finishPending=false;return S_OK;}
    auto done=composition;HRESULT hr;
    ++ownEndDepth;
#ifdef PRIVATE_INPUT_TSF_TEST_HOOKS
    if(enginePaths&&enginePaths->rejectCompositionEndsForTests){--enginePaths->rejectCompositionEndsForTests;hr=E_FAIL;}
    else
#endif
    hr=done->EndComposition(cookie);
    --ownEndDepth;
    if(SUCCEEDED(hr)){if(composition.Get()==done.Get()){composition.Reset();compositionContext.Reset();}finishPending=false;}
    else finishPending=true;
    panel.hide();return hr;
  }
  HRESULT setOwnText(ITfContext *ctx,TfEditCookie cookie,const std::wstring &text,bool finish){
    ComPtr<ITfRange> range;HRESULT hr;
    if(composition&&compositionContext.Get()==ctx)hr=composition->GetRange(&range);
    else{ComPtr<ITfInsertAtSelection> insert;hr=ctx->QueryInterface(IID_ITfInsertAtSelection,reinterpret_cast<void**>(insert.GetAddressOf()));if(FAILED(hr))return hr;hr=insert->InsertTextAtSelection(cookie,TF_IAS_QUERYONLY,nullptr,0,&range);}
    if(FAILED(hr))return hr;hr=range->SetText(cookie,0,text.data(),LONG(text.size()));if(FAILED(hr))return hr;
    ComPtr<ITfRange> caret;if(SUCCEEDED(range->Clone(&caret))){caret->Collapse(cookie,TF_ANCHOR_END);TF_SELECTION selection{caret.Get(),{TF_AE_NONE,FALSE}};ctx->SetSelection(cookie,1,&selection);}
    // Once SetText succeeds, never queue the same text again. A host that
    // refuses EndComposition is retried separately without another insertion.
    if(finish){archiveCommit(ctx,cookie,text);if(!enginePaths&&!secure&&scopeOf(ctx,cookie)==FieldScope::normal){size_t offset=0;ComPtr<ITfContextView>view;HWND hwnd=nullptr;if(SUCCEEDED(ctx->GetActiveView(&view)))view->GetWnd(&hwnd);for(const auto&selected:learningSelections){if(text.compare(offset,selected.second.size(),selected.second)==0){if(selected.second.find_first_of(L"\t\r\n")==std::wstring::npos)archiveEmitter.emitLearning(selected.first,selected.second,hwnd);offset+=selected.second.size();}}}learningSelections.clear();finishComposition(cookie);}return S_OK;
  }
  std::vector<private_input::CandidateChoice> readNative(size_t offset,size_t limit){
    std::vector<private_input::CandidateChoice> rows;const auto count=pi_load_candidate_batch(session,offset,limit);
    for(size_t i=0;i<count;++i)rows.push_back({pi_batch_candidate_text(session,i),pi_batch_candidate_index(session,i),SIZE_MAX,pi_batch_candidate_comment(session,i),false});return rows;
  }
  void reloadCandidates(){
    panel.allowManagement(true);
    if(english){
      candidates.rows.clear();candidates.nativeOffset=0;candidates.hasMoreNative=false;
      words.clear();for(const auto &value:private_input::englishCandidates(englishInput)){candidates.rows.push_back({value,SIZE_MAX,SIZE_MAX});words.push_back(wide(value.c_str()));}
      navigation.reset(words.size());return;
    }
    auto initial=readNative(0,128); // Also establishes the exact-spelling short circuit for repairs.
    std::vector<private_input::CandidateChoice> repairs;
    const auto count=pi_load_repair_candidates(session,16);
    for(size_t i=0;i<count;++i)repairs.push_back({pi_repair_candidate_text(session,i),SIZE_MAX,i,pi_repair_candidate_reading(session,i),false});
    candidates.reset([&](size_t,size_t){return std::move(initial);},std::move(repairs));
    candidates.rows.erase(std::remove_if(candidates.rows.begin(),candidates.rows.end(),[&](const auto&row){return !glyphFilter.supports(wide(row.text.c_str()));}),candidates.rows.end());
    auto learned=learningReader.read();auto contextModel=learningReader.model();auto contextHints=contextModel?contextModel->hints(contextBefore):std::vector<private_input::PublicContextModel::Hint>{};auto normalized=[](std::string source){std::string result;for(unsigned char c:source){if(c>='A'&&c<='Z')c+=32;if(c!=' '&&c!='\'')result.push_back(char(c));}return result;};auto input=normalized(pi_raw_input(session));const std::string rawInput=pi_raw_input(session);auto unselected=pi_unselected_input_start(session);auto rawTail=unselected<=rawInput.size()?rawInput.substr(unselected):rawInput;
    auto learnedWords=learned->spelling.find(normalized(rawTail));if(learnedWords!=learned->spelling.end()){size_t added=0;for(const auto&word:learnedWords->second){if(added>=64)break;bool duplicate=std::any_of(candidates.rows.begin(),candidates.rows.end(),[&](const auto&c){return c.text==word.text&&normalized(c.reading)==normalized(word.reading);});if(!duplicate&&glyphFilter.supports(wide(word.text.c_str()))){candidates.rows.push_back({word.text,SIZE_MAX,SIZE_MAX,word.reading,true});++added;}}}
    for(const auto&row:learned->personal){if(normalized(row.reading)!=input)continue;bool duplicate=std::any_of(candidates.rows.begin(),candidates.rows.end(),[&](const auto&c){return c.text==row.text;});if(!duplicate&&glyphFilter.supports(wide(row.text)))candidates.rows.insert(candidates.rows.begin(),{row.text,SIZE_MAX,SIZE_MAX,row.reading,true});}
    // Input-thread work is bounded in-memory lookups, never disk, crypto or HTTP.
    std::map<std::string,size_t>order;for(size_t i=0;i<candidates.rows.size();++i)order.emplace(private_input::activity::canonicalLearningReading(candidates.rows[i].reading)+char(31)+candidates.rows[i].text,i);
    auto eligible=[&](const private_input::CandidateChoice&row){return row.custom||private_input::pinyin::is_full_spelling(rawTail,row.reading)?3:(row.repair!=SIZE_MAX?2:1);};
    auto rank=[&](const private_input::CandidateChoice&row){auto key=private_input::activity::canonicalLearningReading(row.reading)+char(31)+row.text;bool explicitEntry=learned->explicitKeys.count(key)!=0;double base=explicitEntry?8000.0:4096.0/(1.0+double(order.at(key)));if(contextModel){base+=512.0*private_input::PublicContextModel::match(contextHints,row.text);if(!contextAfter.empty())base+=256.0*private_input::PublicContextModel::match(contextModel->hints(row.text),contextAfter);}auto found=learned->scores.find(key);if(found==learned->scores.end())return base;if(found->second.pinned)return 1e12;return base+(found->second.recent>=0?8192.0*found->second.recent:384.0*std::log2(1.0+double(found->second.frequency)));};
    for(auto&row:candidates.rows){row.rankingClass=eligible(row);row.rankingScore=rank(row);}
    std::stable_sort(candidates.rows.begin(),candidates.rows.end(),[](const auto&a,const auto&b){return a.rankingClass==b.rankingClass?a.rankingScore>b.rankingScore:a.rankingClass>b.rankingClass;});
    words.clear();for(const auto &row:candidates.rows)words.push_back(wide(row.text.c_str()));navigation.reset(words.size());
  }
  void prepareForwardNavigation(int direction,size_t step){
    if(direction<=0||!candidates.hasMoreNative||navigation.selected+step+navigation.pageSize()<words.size())return;
    const auto old=candidates.rows.size();
    if(candidates.appendNative([&](size_t offset,size_t limit){return readNative(offset,limit);})){
      candidates.rows.erase(std::remove_if(candidates.rows.begin()+old,candidates.rows.end(),[&](const auto&row){return !glyphFilter.supports(wide(row.text.c_str()));}),candidates.rows.end());
      for(size_t i=old;i<candidates.rows.size();++i)words.push_back(wide(candidates.rows[i].text.c_str()));
      navigation.count=words.size();++revision;
    }
  }
  void updatePanel(ITfContext *ctx,TfEditCookie cookie){
    if(words.empty()){panel.hide();return;}
    ComPtr<ITfContextView> view;RECT rect{};BOOL clipped=FALSE;ComPtr<ITfRange> range,caret;bool located=false;HWND host=nullptr;
    if(SUCCEEDED(ctx->GetActiveView(&view))){view->GetWnd(&host);if(clipboardVisible&&clipboardSelection&&SUCCEEDED(clipboardSelection->Clone(&caret))&&SUCCEEDED(caret->Collapse(cookie,TF_ANCHOR_END)))located=SUCCEEDED(view->GetTextExt(cookie,caret.Get(),&rect,&clipped))&&rect.bottom>rect.top;if(composition&&SUCCEEDED(composition->GetRange(&range))&&SUCCEEDED(range->Clone(&caret))&&SUCCEEDED(caret->Collapse(cookie,TF_ANCHOR_END))){located=SUCCEEDED(view->GetTextExt(cookie,caret.Get(),&rect,&clipped))&&rect.bottom>rect.top;}}
    // A host may temporarily deny layout during an edit. Keep a usable
    // candidate at that host's edge instead of making the whole input blind.
    if(!located){if(!host)host=GetForegroundWindow();if(!host||!GetWindowRect(host,&rect)){panel.hide();return;}rect.left+=16;rect.top+=40;rect.right=rect.left+1;rect.bottom=rect.top+20;}
    panel.show(g_instance,rect,words,revision,host?GetDpiForWindow(host):96,navigation);
  }
  // Native rows select their absolute engine index; repair rows replay their
  // spelling in a private probe and replace only the unselected suffix.
  HRESULT applyCandidate(ITfContext *ctx,TfEditCookie cookie,size_t index){
    if(index>=words.size())return E_FAIL;readContext(ctx,cookie);
    if(english){
      const auto committed=words[index];learningSelections.push_back({wide(englishInput.c_str()),committed});HRESULT hr=setOwnText(ctx,cookie,committed,true);
      if(FAILED(hr)){pendingCommit=committed;pendingContext=ctx;return hr;}
      englishInput.clear();++revision;reloadCandidates();updatePanel(ctx,cookie);return S_OK;
    }
    const auto choice=candidates.rows[index];auto previousSelections=learningSelections.size();if(!choice.reading.empty())learningSelections.push_back({wide(private_input::activity::canonicalLearningReading(choice.reading).c_str()),wide(choice.text.c_str())});
    if(choice.custom){auto committed=wide(pi_selected_prefix(session))+wide(choice.text.c_str());pi_clear(session);++revision;auto hr=setOwnText(ctx,cookie,committed,true);if(FAILED(hr)){pendingCommit=committed;pendingContext=ctx;return hr;}reloadCandidates();updatePanel(ctx,cookie);return S_OK;}
    if(choice.absolute!=SIZE_MAX){
      if(!pi_select_candidate_absolute(session,choice.absolute)){learningSelections.resize(previousSelections);return E_FAIL;}
      ++revision;return flushResult(ctx,cookie);
    }
    const auto committed=wide(pi_commit_repair_candidate(session,choice.repair));
    if(committed.empty()){learningSelections.resize(previousSelections);return E_FAIL;}
    ++revision;HRESULT hr=setOwnText(ctx,cookie,committed,true);
    if(FAILED(hr)){pendingCommit=committed;pendingContext=ctx;return hr;}
    reloadCandidates();updatePanel(ctx,cookie);return S_OK;
  }
  HRESULT flushResult(ITfContext *ctx,TfEditCookie cookie){
    auto commit=wide(pi_take_commit(session));HRESULT hr=S_OK;
    if(!commit.empty()){hr=setOwnText(ctx,cookie,commit,true);if(FAILED(hr)){pendingCommit=commit;pendingContext=ctx;return hr;}}
    auto text=wide(pi_preedit(session));if(!text.empty()){hr=beginComposition(ctx,cookie);if(SUCCEEDED(hr))hr=setOwnText(ctx,cookie,text,false);}
    else if(commit.empty())hr=setOwnText(ctx,cookie,L"",true);
    reloadCandidates();if(SUCCEEDED(hr))updatePanel(ctx,cookie);return hr;
  }
  HRESULT deliverPending(ITfContext *ctx,TfEditCookie cookie){
    if(pendingCommit.empty())return S_OK;
    if(pendingContext.Get()!=ctx||!composition||compositionContext.Get()!=ctx){detachComposition();return S_OK;}
    const bool wasEnglish=english;
    HRESULT hr=setOwnText(ctx,cookie,pendingCommit,true);
    if(SUCCEEDED(hr)){
      pendingCommit.clear();pendingContext.Reset();
      // Own EndComposition is not required to notify our sink. The committed
      // spelling must never survive as the next word's raw draft or candidates.
      if(wasEnglish){englishInput.clear();reloadCandidates();panel.hide();++revision;}
    }
    return hr;
  }
  HRESULT handleKey(ITfContext *ctx,TfEditCookie cookie,WPARAM key,bool *eaten){
    FieldScope scope=scopeOf(ctx,cookie);if(disabled(ctx)||scope==FieldScope::password){detachComposition();return S_OK;}if(scope==FieldScope::normal&&key!=VK_BACK&&key!=VK_DELETE&&printable(key)&&GetKeyState(VK_CONTROL)>=0&&GetKeyState(VK_MENU)>=0)clipboardPolicy.resumeEditing();
    // End a range already written to the host before reacting to a new caret
    // (a passed-through literal may have moved it beyond that old range).
    if(finishPending){HRESULT hr=finishComposition(cookie);if(FAILED(hr))return hr;}
    if(composition&&!selectionInside(ctx,cookie))detachComposition();readContext(ctx,cookie);
    if(!pendingCommit.empty()){HRESULT result=deliverPending(ctx,cookie);if(result!=S_OK)return result;degraded=false;if(finishPending)return S_OK;}
    // Draining a failed commit can be the only reason this key was routed.
    // Let the host handle literals and navigation once that work has finished.
    if(!composing()){auto cached=std::atomic_load(&desktopCache);inputPreferences=cached->input;panel.setTheme(inputPreferences.theme);navigation.configure(cached->layout.collapsed,cached->layout.columns,cached->layout.rows);}
    if(!accepts(ctx,key))return S_OK;
    // Return explicitly commits the typed spelling, never the highlighted
    // completion. Space and digits remain candidate-selection actions.
    if(key==VK_RETURN&&composing()){
      const std::string raw=pi_raw_input(session),prefix=pi_selected_prefix(session);
      const auto start=pi_unselected_input_start(session);
      const auto typed=english?englishInput:(prefix.empty()?raw:prefix+(start<=raw.size()?raw.substr(start):raw));
      HRESULT hr=setOwnText(ctx,cookie,wide(typed.c_str()),true);
      if(SUCCEEDED(hr)){pi_clear(session);englishInput.clear();++revision;panel.hide();*eaten=true;}
      return hr;
    }
    if(!composing()&&pairKey(key)){auto plan=private_input::symbolPlan(literalSymbol(key),inputPreferences.pairSymbols,inputPreferences.caretInside);auto hr=setOwnText(ctx,cookie,plan.text,true);if(FAILED(hr))return hr;if(plan.caretBack){TF_SELECTION selected{};ULONG count=0;if(SUCCEEDED(ctx->GetSelection(cookie,TF_DEFAULT_SELECTION,1,&selected,&count))&&count==1&&selected.range){ComPtr<ITfRange>caret;caret.Attach(selected.range);LONG moved=0;if(SUCCEEDED(caret->ShiftStart(cookie,-plan.caretBack,&moved,nullptr))&&moved== -plan.caretBack&&SUCCEEDED(caret->Collapse(cookie,TF_ANCHOR_START))){TF_SELECTION inside{caret.Get(),{TF_AE_NONE,FALSE}};ctx->SetSelection(cookie,1,&inside);}}}*eaten=true;return S_OK;}
    if(!composing()&&printable(key)&&!(key>='A'&&key<='Z')){if(scope==FieldScope::normal&&focusedContext(ctx)){auto text=literalSymbol(key);auto hr=setOwnText(ctx,cookie,text,true);if(SUCCEEDED(hr))*eaten=true;return hr;}return S_OK;}
    if(composing()&&endingLiteral(key)){
      if(scope==FieldScope::normal&&!words.empty()&&navigation.selected<candidates.rows.size()){const auto&choice=candidates.rows[navigation.selected];auto raw=std::string(pi_raw_input(session));auto start=pi_unselected_input_start(session);auto tail=start<=raw.size()?raw.substr(start):raw;if(english||choice.custom||private_input::pinyin::covers(tail,choice.reading)){auto hr=applyCandidate(ctx,cookie,navigation.selected);if(FAILED(hr))return hr;if(!composing()){if(!finishPending&&printable(key)){auto literal=literalSymbol(key);hr=setOwnText(ctx,cookie,literal,true);if(SUCCEEDED(hr))*eaten=true;return hr;}*eaten=false;return S_OK;}}}
      // An incomplete spelling keeps every readable remaining key before the
      // host receives its original punctuation or shortcut.
      const std::string rawInput=pi_raw_input(session),prefix=pi_selected_prefix(session);const auto start=pi_unselected_input_start(session);
      auto raw=english?wide(englishInput.c_str()):wide((prefix.empty()?rawInput:(start<=rawInput.size()?prefix+rawInput.substr(start):std::string(pi_preedit(session)))).c_str());
      HRESULT hr=setOwnText(ctx,cookie,raw,true);
      // If rewriting fails, preserve the already visible preedit and pass the
      // literal through. Queuing raw text here could later overwrite that key
      // or insert the spelling twice after the host has moved its selection.
      if(FAILED(hr)){detachComposition();return hr;}
      pi_clear(session);englishInput.clear();++revision;*eaten=false;return S_OK;
    }
    if(degraded){detachComposition();degraded=false;}
    if(modeKey(key)){if(composition){HRESULT hr=setOwnText(ctx,cookie,markedText(),true);if(FAILED(hr))return hr;pi_clear(session);englishInput.clear();}english=!english;++revision;reloadCandidates();panel.hide();*eaten=true;return S_OK;}
    const bool privateNow=!enginePaths||scope!=FieldScope::normal;
    if(privateNow!=privateSchema&&!composing()){if(!pi_set_private(session,privateNow))return E_FAIL;privateSchema=privateNow;}
    if(!english&&composing()&&words.empty()&&(key==VK_SPACE||key==VK_RETURN)){auto raw=wide(pi_preedit(session));auto hr=setOwnText(ctx,cookie,raw,true);if(SUCCEEDED(hr)){pi_clear(session);*eaten=true;++revision;panel.hide();}return hr;}
    if(composing()&&!words.empty()){
      if(key==VK_LEFT||key==VK_RIGHT||key==VK_UP||key==VK_DOWN||key==VK_PRIOR||key==VK_NEXT||(key==VK_ESCAPE&&navigation.expanded)){
        const int direction=(key==VK_RIGHT||key==VK_DOWN||key==VK_NEXT)?1:-1;
        const size_t step=key==VK_NEXT?navigation.pageSize():(key==VK_DOWN?size_t(navigation.columns):1);
        prepareForwardNavigation(direction,step);
        if(key==VK_LEFT||key==VK_RIGHT)navigation.horizontal(key==VK_LEFT?-1:1);
        else if(key==VK_UP||key==VK_DOWN)navigation.vertical(key==VK_UP?-1:1);
        else if(key==VK_ESCAPE)navigation.expanded=false;else navigation.page(key==VK_PRIOR?-1:1);
        *eaten=true;++revision;updatePanel(ctx,cookie);return S_OK;
      }
      if(key==VK_SPACE||key==VK_RETURN||(key>='1'&&key<='9')){
        const auto index=key>='1'&&key<='9'?navigation.digit(unsigned(key-'0')):navigation.selected;*eaten=true;
        if(index>=candidates.rows.size())return S_OK;
        HRESULT chosen=applyCandidate(ctx,cookie,index);if(FAILED(chosen))return chosen;return S_OK;
      }
    }
    if(english){
      auto next=englishInput;
      if(key>='A'&&key<='Z'){
        const bool upper=(GetKeyState(VK_SHIFT)<0)!=((GetKeyState(VK_CAPITAL)&1)!=0);
        // Bound a single marked word without trapping subsequent typing.
        if(next.size()==48){
          HRESULT hr=setOwnText(ctx,cookie,wide(next.c_str()),true);if(FAILED(hr))return hr;
          englishInput.clear();next.clear();++revision;reloadCandidates();panel.hide();
          // SetText may succeed while the host refuses EndComposition. Do not
          // replace that still-owned range with the 49th letter. Let this key
          // reach the host, then retry ending before opening another word.
          if(finishPending){*eaten=false;return S_OK;}
        }
        next.push_back(char(upper?key:key-'A'+'a'));
      }else if(key==VK_BACK&&!next.empty())next.pop_back();
      else if(key==VK_ESCAPE)next.clear();else return S_OK;
      HRESULT hr=beginComposition(ctx,cookie);if(FAILED(hr))return hr;
      hr=setOwnText(ctx,cookie,wide(next.c_str()),next.empty());if(FAILED(hr))return hr;
      englishInput=std::move(next);++revision;*eaten=true;reloadCandidates();updatePanel(ctx,cookie);return S_OK;
    }
    HRESULT hr=beginComposition(ctx,cookie);if(FAILED(hr))return hr;int code=int(key);
    if(key>='A'&&key<='Z')code=int(key-'A'+'a');
    else switch(key){case VK_BACK:code=0xff08;break;case VK_RETURN:code=0xff0d;break;case VK_ESCAPE:code=0xff1b;break;case VK_LEFT:code=0xff51;break;case VK_RIGHT:code=0xff53;break;case VK_UP:code=0xff52;break;case VK_DOWN:code=0xff54;break;case VK_PRIOR:code=0xff55;break;case VK_NEXT:code=0xff56;break;}
    *eaten=pi_process_key(session,code,0)!=0;++revision;return flushResult(ctx,cookie);
  }
  HRESULT handleArchivedKey(ITfContext*ctx,TfEditCookie cookie,WPARAM key,bool*handled){
    const bool diagnostic=!secure&&scopeOf(ctx,cookie)==FieldScope::normal&&archiveEmitter.diagnosticsEnabled();
    const std::string before=diagnostic?(english?englishInput:std::string(pi_raw_input(session))):"";
    const auto result=handleKey(ctx,cookie,key,handled);
    if(diagnostic&&*handled&&scopeOf(ctx,cookie)==FieldScope::normal){try{
      using private_input::activity::Json;
      const auto after=english?englishInput:std::string(pi_raw_input(session));
      auto payload=Json::object({{"action","key"},{"key",std::to_string(key)},{"raw_before",before},{"raw_after",after},{"committed",false}}).dump();
      if(payload.size()<=16384){ComPtr<ITfContextView>view;HWND host=nullptr;if(SUCCEEDED(ctx->GetActiveView(&view)))view->GetWnd(&host);
        archiveEmitter.emit(wide(payload.c_str()),host,archiveSession,archiveEditor,true,english?2:1,archiveFieldType(ctx,cookie),false,true);}
    }catch(...) {}}
    return result;
  }
  void choose(size_t index,unsigned long long version){
    if(clipboardVisible){auto ctx=clipboardContext;if(!ctx||index!=0||version!=revision)return;HRESULT result=E_FAIL;request(ctx.Get(),TF_ES_ASYNCDONTCARE|TF_ES_READWRITE,[this,ctx,version](TfEditCookie cookie){return pasteClipboardCandidate(ctx.Get(),cookie,version);},&result);return;}
    auto ctx=compositionContext;if(!focusedContext(ctx.Get())){panel.hide();return;}if(!ctx||version!=revision||index>=candidates.rows.size())return;HRESULT result=E_FAIL;
    request(ctx.Get(),TF_ES_ASYNCDONTCARE|TF_ES_READWRITE,[this,ctx,index,version](TfEditCookie cookie){
      if(!focusedContext(ctx.Get())){panel.hide();return S_FALSE;}
      if(version!=revision||!selectionInside(ctx.Get(),cookie)||disabled(ctx.Get())||scopeOf(ctx.Get(),cookie)==FieldScope::password)return S_FALSE;
      return applyCandidate(ctx.Get(),cookie,index);
    },&result);
  }
  void manageCandidate(size_t index,unsigned long long version,unsigned action){if(clipboardVisible)return;auto ctx=compositionContext;if(english||!ctx||!focusedContext(ctx.Get())||version!=revision||index>=candidates.rows.size())return;auto choice=candidates.rows[index];auto reading=private_input::activity::canonicalLearningReading(choice.reading);if(reading.empty())return;HRESULT result=E_FAIL;request(ctx.Get(),TF_ES_ASYNCDONTCARE|TF_ES_READ,[this,ctx,version,reading,word=choice.text,action](TfEditCookie cookie){if(!focusedContext(ctx.Get())||version!=revision||scopeOf(ctx.Get(),cookie)!=FieldScope::normal)return S_FALSE;ComPtr<ITfContextView>view;HWND hwnd=nullptr;if(SUCCEEDED(ctx->GetActiveView(&view)))view->GetWnd(&hwnd);archiveEmitter.emitLearning(wide(reading.c_str()),wide(word.c_str()),hwnd,action);return S_OK;},&result);}
public:
  TextService(const PrivateInputEnginePaths *paths):panel([this](size_t index,unsigned long long version){choose(index,version);},[this](int direction){auto ctx=compositionContext;const auto version=revision;if(!focusedContext(ctx.Get())){panel.hide();return;}HRESULT result=E_FAIL;request(ctx.Get(),TF_ES_ASYNCDONTCARE|TF_ES_READ,[this,ctx,direction,version](TfEditCookie cookie){if(!focusedContext(ctx.Get())){panel.hide();return S_FALSE;}if(version!=revision||!selectionInside(ctx.Get(),cookie)||disabled(ctx.Get())||scopeOf(ctx.Get(),cookie)==FieldScope::password)return S_FALSE;prepareForwardNavigation(direction,size_t(navigation.columns));navigation.vertical(direction);++revision;updatePanel(ctx.Get(),cookie);return S_OK;},&result);}){if(paths)enginePaths=*paths;panel.setManagement([this](size_t i,unsigned long long v,unsigned a){manageCandidate(i,v,a);},[this](size_t i){if(i>=candidates.rows.size())return false;auto snapshot=learningReader.read();auto&row=candidates.rows[i];auto key=private_input::activity::canonicalLearningReading(row.reading)+char(31)+row.text;auto found=snapshot->scores.find(key);return found!=snapshot->scores.end()&&found->second.pinned;});GUID archiveID{};if(SUCCEEDED(CoCreateGuid(&archiveID)))memcpy(archiveSession.data(),&archiveID,sizeof(archiveID));++g_objects;}
  ~TextService(){if(clipboardPollWindow)DestroyWindow(clipboardPollWindow);learningReader.stop();if(session)pi_destroy_session(session);--g_objects;}
  STDMETHODIMP QueryInterface(REFIID iid,void **out)override{
    if(!out)return E_POINTER;*out=nullptr;if(iid==IID_IUnknown||iid==IID_ITfTextInputProcessor||iid==IID_ITfTextInputProcessorEx)*out=static_cast<ITfTextInputProcessorEx*>(this);
    else if(iid==IID_ITfKeyEventSink)*out=static_cast<ITfKeyEventSink*>(this);else if(iid==IID_ITfCompositionSink)*out=static_cast<ITfCompositionSink*>(this);else if(iid==IID_ITfTextEditSink)*out=static_cast<ITfTextEditSink*>(this);if(!*out)return E_NOINTERFACE;AddRef();return S_OK;
  }
  STDMETHODIMP_(ULONG) AddRef()override{return ++refs;}
  STDMETHODIMP_(ULONG) Release()override{auto n=--refs;if(!n)delete this;return n;}
  STDMETHODIMP Activate(ITfThreadMgr *mgr,TfClientId id)override{return ActivateEx(mgr,id,0);}
  STDMETHODIMP ActivateEx(ITfThreadMgr *mgr,TfClientId id,DWORD flags)override{
    if(!mgr)return E_INVALIDARG;if(manager)return E_UNEXPECTED;manager=mgr;client=id;secure=(flags&TF_TMAE_SECUREMODE)!=0;
    // In a protected desktop do not subscribe to key events, load dictionaries,
    // or create any learning database. The OS retains its own input handling.
    if(secure)return S_OK;
    if(!enginePaths){WNDCLASSW cls{};cls.lpfnWndProc=clipboardPollProc;cls.hInstance=g_instance;cls.lpszClassName=L"LingheInput.ClipboardCandidatePoll";RegisterClassW(&cls);clipboardPollWindow=CreateWindowExW(0,cls.lpszClassName,L"",0,0,0,0,0,HWND_MESSAGE,nullptr,g_instance,this);if(clipboardPollWindow)SetTimer(clipboardPollWindow,1,250,nullptr);}
    archiveEmitter.start();if(!enginePaths){wchar_t module[32768]{};DWORD n=GetModuleFileNameW(g_instance,module,32768);if(n&&n<32768){auto broker=std::filesystem::path(module).parent_path()/L"LingheInputActivity.exe";if(std::filesystem::is_regular_file(broker))ShellExecuteW(nullptr,L"open",broker.c_str(),L"--background",broker.parent_path().c_str(),SW_HIDE);}}
    HRESULT hr=manager.As(&keystrokes);if(FAILED(hr)){manager.Reset();return hr;}
    if(!startEngine()){keystrokes.Reset();manager.Reset();return E_FAIL;}if(!enginePaths){auto resource=utf8((publicContextPath.parent_path().parent_path()/L"rime").wstring());PWSTR local=nullptr;std::filesystem::path preference;if(SUCCEEDED(SHGetKnownFolderPath(FOLDERID_LocalAppData,0,nullptr,&local))){preference=std::filesystem::path(local)/L"PrivateInput/desktop-candidate-layout-v1.json";CoTaskMemFree(local);}learningReader.start(publicContextPath,[resource]{pi_prepare_repair_resources(resource.c_str());},[this,preference]{auto next=std::make_shared<CachedDesktopPreferences>();next->layout=readDesktopLayout(preference);next->input=readDesktopInputPreferences(preference);std::shared_ptr<const CachedDesktopPreferences>frozen=next;std::atomic_store(&desktopCache,std::move(frozen));});}
#ifdef PRIVATE_INPUT_TSF_TEST_HOOKS
    // A synthetic text-store application receives an application TfClientId,
    // not the OS-assigned TIP id needed for real key-sink subscription. Its
    // explicit fixture drives this same key sink directly; daily DLLs do not
    // compile this bypass and always require OS AdviseKeyEventSink success.
    if(enginePaths&&enginePaths->directKeySinkOnlyForTests)return S_OK;
#endif
    hr=keystrokes->AdviseKeyEventSink(client,this,TRUE);keySinkAdvised=SUCCEEDED(hr);
    if(FAILED(hr)){if(session)pi_destroy_session(session);session=0;keystrokes.Reset();manager.Reset();}return hr;
  }
  STDMETHODIMP Deactivate()override{if(clipboardPollWindow){DestroyWindow(clipboardPollWindow);clipboardPollWindow=nullptr;}retireClipboard();clipboardReader.close();detachComposition();if(keystrokes&&keySinkAdvised)keystrokes->UnadviseKeyEventSink(client);keySinkAdvised=false;if(session)pi_destroy_session(session);session=0;keystrokes.Reset();manager.Reset();client=PrivateInputClientNull;return S_OK;}
  STDMETHODIMP OnCompositionTerminated(TfEditCookie,ITfComposition *ended)override{
    // Treat our own ending exactly like a host that never calls this sink;
    // explicit finish paths own cleanup. External termination still resets it.
    if(ownEndDepth)return S_OK;
    if(composition.Get()==ended){contextBefore.clear();contextAfter.clear();composition.Reset();compositionContext.Reset();finishPending=false;pendingCommit.clear();pendingContext.Reset();if(session)pi_clear(session);englishInput.clear();panel.hide();++revision;}return S_OK;}
  STDMETHODIMP OnEndEdit(ITfContext*,TfEditCookie,ITfEditRecord*)override{if(clipboardVisible)retireClipboard();return S_OK;}
  STDMETHODIMP OnSetFocus(BOOL foreground)override{if(!foreground){shiftTap.reset();retireClipboard();detachComposition();archiveContext=nullptr;archiveExpectedCaret.reset();}return S_OK;}
  STDMETHODIMP OnTestKeyDown(ITfContext *ctx,WPARAM key,LPARAM,BOOL *eaten)override{if(!eaten)return E_POINTER;if(key!=VK_SHIFT&&key!=VK_LSHIFT&&key!=VK_RSHIFT)shiftTap.otherKey();if(key=='V'&&GetKeyState(VK_CONTROL)<0)clipboardPolicy.resumeEditing();if(key!=VK_DELETE&&key!=VK_BACK&&key!=VK_SHIFT&&key!=VK_CONTROL&&key!=VK_MENU&&key!=VK_LWIN&&key!=VK_RWIN){retireClipboard(GetClipboardSequenceNumber());}*eaten=(key==VK_SHIFT&&!secure&&session&&ctx&&!disabled(ctx))||accepts(ctx,key);return S_OK;}
  STDMETHODIMP OnTestKeyUp(ITfContext *ctx,WPARAM key,LPARAM,BOOL *eaten)override{if(key==VK_DELETE||key==VK_BACK)clipboardPolicy.releaseDelete();if(!eaten)return E_POINTER;const bool toggle=key==VK_SHIFT&&shiftTap.ready(reinterpret_cast<uintptr_t>(ctx))&&!secure;if(key==VK_SHIFT&&!toggle)shiftTap.reset();*eaten=toggle;return S_OK;}
  STDMETHODIMP OnKeyDown(ITfContext *ctx,WPARAM key,LPARAM,BOOL *eaten)override{
    if(!eaten)return E_POINTER;*eaten=FALSE;if(key==VK_SHIFT){shiftTap.press(reinterpret_cast<uintptr_t>(ctx),secure||GetKeyState(VK_CONTROL)<0||GetKeyState(VK_MENU)<0||GetKeyState(VK_LWIN)<0||GetKeyState(VK_RWIN)<0);return S_OK;}shiftTap.otherKey();if((key==VK_DELETE||key==VK_BACK)&&clipboardVisible&&!clipboardPolicy.deleteHeld){clipboardPolicy.hideForDelete(clipboardOffer.sequence);retireClipboard();*eaten=TRUE;return S_OK;}if(key!=VK_DELETE&&key!=VK_BACK){retireClipboard(GetClipboardSequenceNumber());}if(!accepts(ctx,key))return S_OK;ComPtr<ITfContext> retained=ctx;bool handled=false;HRESULT result=E_FAIL;
    HRESULT hr=request(ctx,TF_ES_SYNC|TF_ES_READWRITE,[this,retained,key,&handled](TfEditCookie cookie){return handleArchivedKey(retained.Get(),cookie,key,&handled);},&result);
    if(FAILED(hr)||FAILED(result)){degraded=true;*eaten=handled?TRUE:FALSE;return S_OK;}*eaten=handled?TRUE:FALSE;return S_OK;
  }
  STDMETHODIMP OnKeyUp(ITfContext *ctx,WPARAM key,LPARAM,BOOL *eaten)override{
    if(!eaten)return E_POINTER;*eaten=FALSE;
    if(key==VK_DELETE||key==VK_BACK)clipboardPolicy.releaseDelete();
    if(key==VK_SHIFT){
      const bool toggle=shiftTap.ready(reinterpret_cast<uintptr_t>(ctx))&&!secure&&session&&ctx&&!disabled(ctx);
      if(toggle){ComPtr<ITfContext> retained=ctx;bool handled=false;HRESULT result=E_FAIL;
        const auto hr=request(ctx,TF_ES_SYNC|TF_ES_READWRITE,[this,retained,&handled](TfEditCookie cookie){return handleArchivedKey(retained.Get(),cookie,VK_SHIFT,&handled);},&result);
        if(SUCCEEDED(hr)&&SUCCEEDED(result))*eaten=handled;
      }
      shiftTap.reset();
    }
    return S_OK;
  }
  STDMETHODIMP OnPreservedKey(ITfContext *,REFGUID,BOOL *eaten)override{if(!eaten)return E_POINTER;*eaten=FALSE;return S_OK;}
};
}
HRESULT CreatePrivateInput(REFIID iid,void **result,const PrivateInputEnginePaths *paths){auto *service=new TextService(paths);auto hr=service->QueryInterface(iid,result);service->Release();return hr;}
BOOL WINAPI DllMain(HINSTANCE instance,DWORD reason,LPVOID){if(reason==DLL_PROCESS_ATTACH){g_instance=instance;DisableThreadLibraryCalls(instance);}return TRUE;}
