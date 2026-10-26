#include "PhraseNotice.h"
#include "PrivateInputTSF.h"
#include "learning_capacity_profiles.h"
#include "CandidateWindow.h"
#include "CandidateAnchorPolicy.h"
#include "TsfLayoutSink.h"
#include <textstor.h>
#include "LearningSnapshotBoundary.h"
#include "CandidateStream.h"
#include "CandidateAdmission.h"
#include "ClipboardCandidatePolicy.h"
#include "../activity/ClipboardCandidateIPC.h"
#include "DesktopPreferences.h"
#include "EnglishSuggestions.h"
#include "SymbolPairing.h"
#include "TechnicalInputScope.h"
#include "BackgroundTask.h"
#include "NativeInputScope.h"
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
  ComPtr<ITfContextView>nativeView;HWND nativeWindow=nullptr;
  if(SUCCEEDED(ctx->GetActiveView(&nativeView))&&nativeView&&SUCCEEDED(nativeView->GetWnd(&nativeWindow))){
    if(private_input::nativePasswordWindow(nativeWindow))return FieldScope::password;
    const auto focus=GetFocus();if(focus&&(focus==nativeWindow||IsChild(nativeWindow,focus))&&private_input::nativePasswordWindow(focus))return FieldScope::password;
  }
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
bool technicalInputField(ITfContext*ctx,TfEditCookie cookie){
  TF_SELECTION selected{};ULONG fetched=0;
  if(FAILED(ctx->GetSelection(cookie,TF_DEFAULT_SELECTION,1,&selected,&fetched))||fetched!=1||!selected.range)return false;
  ComPtr<ITfRange>range;range.Attach(selected.range);ComPtr<ITfReadOnlyProperty>property;
  if(FAILED(ctx->GetAppProperty(GUID_PROP_INPUTSCOPE,&property)))return false;
  VARIANT value;VariantInit(&value);bool literal=false;
  if(SUCCEEDED(property->GetValue(cookie,range.Get(),&value))&&value.vt==VT_UNKNOWN&&value.punkVal){
    ComPtr<ITfInputScope>scope;
    if(SUCCEEDED(value.punkVal->QueryInterface(IID_PPV_ARGS(&scope)))){
      InputScope*items=nullptr;UINT count=0;
      if(SUCCEEDED(scope->GetInputScopes(&items,&count))&&items&&count&&count<=128){
        private_input::PhysicalFieldScope fields[128]{};
        for(UINT i=0;i<count;++i){using Field=private_input::PhysicalFieldScope;
          switch(items[i]){
            case IS_URL:fields[i]=Field::url;break;
            case IS_EMAIL_USERNAME:case IS_EMAIL_SMTPEMAILADDRESS:case IS_EMAILNAME_OR_ADDRESS:fields[i]=Field::email;break;
            case IS_DIGITS:fields[i]=Field::digits;break;
            case IS_PRIVATE:fields[i]=Field::privateField;break;
            case IS_PASSWORD:case IS_NUMERIC_PASSWORD:fields[i]=Field::password;break;
            default:fields[i]=Field::ordinary;break;
          }
        }
        literal=private_input::literalTechnicalScope(fields,count);
      }
      CoTaskMemFree(items);
    }
  }
  VariantClear(&value);return literal;
}
bool disabled(ITfContext *ctx){
  TF_STATUS status{};if(SUCCEEDED(ctx->GetStatus(&status))&&(status.dwDynamicFlags&TF_SD_READONLY))return true;
  ComPtr<ITfCompartmentMgr> mgr;if(FAILED(ctx->QueryInterface(IID_ITfCompartmentMgr,reinterpret_cast<void**>(mgr.GetAddressOf()))))return false;
  ComPtr<ITfCompartment> item;if(FAILED(mgr->GetCompartment(GUID_COMPARTMENT_KEYBOARD_DISABLED,&item)))return false;
  VARIANT v;VariantInit(&v);bool result=false;if(SUCCEEDED(item->GetValue(&v)))result=(v.vt==VT_I4&&v.lVal!=0)||(v.vt==VT_BOOL&&v.boolVal!=VARIANT_FALSE);VariantClear(&v);return result;
}
struct CachedDesktopPreferences{private_input::DesktopCandidates layout;DesktopInputPreferences input;};
struct DesktopPreferenceSnapshot{std::shared_ptr<const CachedDesktopPreferences> value=std::make_shared<CachedDesktopPreferences>();};
class TextService final:public ITfTextInputProcessorEx,public ITfKeyEventSink,public ITfCompositionSink,public ITfTextEditSink,public ITfTextLayoutSink {
  std::atomic<ULONG> refs{1};ComPtr<ITfThreadMgr> manager;ComPtr<ITfKeystrokeMgr> keystrokes;
  ComPtr<ITfContext> compositionContext,pendingContext;ComPtr<ITfComposition> composition;
  TfClientId client=PrivateInputClientNull;PI_Session session=0;
  private_input::CandidateAnchorPolicy anchorPolicy;ComPtr<ITfContext>layoutContext;ComPtr<IUnknown>anchorViewIdentity,layoutViewIdentity,destroyedViewIdentity;DWORD layoutSinkCookie=TF_INVALID_COOKIE;uint64_t layoutEpoch=0;bool layoutRefreshPending=false,layoutDestroyed=false;HWND anchorLeaseWindow=nullptr;private_input::CandidateAnchorLease anchorLease;
  static LRESULT CALLBACK anchorLeaseProc(HWND hwnd,UINT message,WPARAM w,LPARAM l){auto*self=reinterpret_cast<TextService*>(GetWindowLongPtrW(hwnd,GWLP_USERDATA));if(message==WM_NCCREATE){self=static_cast<TextService*>(reinterpret_cast<CREATESTRUCTW*>(l)->lpCreateParams);SetWindowLongPtrW(hwnd,GWLP_USERDATA,reinterpret_cast<LONG_PTR>(self));}if(self&&message==WM_TIMER&&w==1){KillTimer(hwnd,1);auto remaining=self->anchorLease.timer(GetTickCount64());if(!remaining)return 0;if(*remaining&&SetTimer(hwnd,1,UINT(*remaining),nullptr))return 0;self->clearAnchor();self->panel.hide();return 0;}return DefWindowProcW(hwnd,message,w,l);}
  void clearAnchor(){if(anchorLeaseWindow)KillTimer(anchorLeaseWindow,1);anchorLease.clear();anchorPolicy.clear();anchorViewIdentity.Reset();}
  bool expireAnchorLease(){auto remaining=anchorPolicy.leaseRemaining(GetTickCount64());if(!remaining)return false;if(!anchorLeaseWindow){WNDCLASSW cls{};cls.lpfnWndProc=anchorLeaseProc;cls.hInstance=g_instance;cls.lpszClassName=L"LingheInput.AnchorLease";RegisterClassW(&cls);anchorLeaseWindow=CreateWindowExW(0,cls.lpszClassName,L"",0,0,0,0,0,HWND_MESSAGE,nullptr,g_instance,this);}if(!anchorLeaseWindow)return false;auto now=GetTickCount64();remaining=anchorPolicy.leaseRemaining(now);if(!remaining)return false;anchorLease.arm(now,remaining);return SetTimer(anchorLeaseWindow,1,UINT(remaining),nullptr)!=0;}

  void unwatchLayout(){++layoutEpoch;layoutRefreshPending=false;layoutDestroyed=false;clearAnchor();layoutViewIdentity.Reset();destroyedViewIdentity.Reset();auto ctx=layoutContext;auto cookie=layoutSinkCookie;layoutSinkCookie=TF_INVALID_COOKIE;layoutContext.Reset();if(ctx&&cookie!=TF_INVALID_COOKIE){ComPtr<ITfSource>source;if(SUCCEEDED(ctx.As(&source)))source->UnadviseSink(cookie);}}
  void watchLayout(ITfContext*ctx){if(layoutContext.Get()==ctx)return;unwatchLayout();ComPtr<ITfSource>source;if(!ctx||FAILED(ctx->QueryInterface(IID_PPV_ARGS(&source))))return;DWORD cookie=TF_INVALID_COOKIE;if(SUCCEEDED(source->AdviseSink(IID_ITfTextLayoutSink,static_cast<ITfTextLayoutSink*>(this),&cookie))){layoutContext=ctx;layoutSinkCookie=cookie;}}
  void refreshLayout(ITfContext*ctx){
    if(layoutRefreshPending||!ctx||layoutContext.Get()!=ctx||compositionContext.Get()!=ctx||!composition||finishPending||words.empty())return;
    // Until the read job verifies current geometry, an old caret has only its
    // original short lease. A denied/stalled async request cannot keep it forever.
    if(!expireAnchorLease()){clearAnchor();panel.hide();}
    layoutRefreshPending=true;auto epoch=layoutEpoch;ComPtr<ITfContext>retained=ctx;auto own=composition;HRESULT result=E_FAIL;
    request(ctx,TF_ES_ASYNC|TF_ES_READ,[this,retained,own,epoch](TfEditCookie cookie){if(epoch!=layoutEpoch)return S_FALSE;if(layoutContext.Get()!=retained.Get()||compositionContext.Get()!=retained.Get()||composition.Get()!=own.Get()||finishPending||!focusedContext(retained.Get())){clearAnchor();panel.hide();return S_FALSE;}updatePanel(retained.Get(),cookie);return S_OK;},&result,[this,epoch]{if(epoch==layoutEpoch)layoutRefreshPending=false;});
  }

  bool secure=false,english=false,privateSchema=false,degraded=false,finishPending=false,keySinkAdvised=false;
  private_input::ShiftTapMode shiftTap;
  private_input::AutomaticPairReceipt automaticPair;
  ComPtr<ITfContext>pairContext;ComPtr<ITfRange>pairRange,pairCaret;DWORD pairEditCookie=TF_INVALID_COOKIE;
  bool pairOwnRequest=false,pairPendingArm=false;std::wstring pairInserted;
  void clearAutomaticPair(){automaticPair.invalidate();pairPendingArm=false;pairInserted.clear();auto ctx=pairContext;auto cookie=pairEditCookie;pairEditCookie=TF_INVALID_COOKIE;pairContext.Reset();pairRange.Reset();pairCaret.Reset();if(ctx&&cookie!=TF_INVALID_COOKIE){ComPtr<ITfSource>source;if(SUCCEEDED(ctx.As(&source)))source->UnadviseSink(cookie);}}
  void completeAutomaticPairRequest(bool success){if(pairPendingArm&&success&&pairContext&&pairRange&&pairCaret)automaticPair.record(reinterpret_cast<uintptr_t>(pairContext.Get()),pairInserted);else if(pairPendingArm)clearAutomaticPair();pairPendingArm=false;pairOwnRequest=false;}
  void rememberAutomaticPair(ITfContext*ctx,TfEditCookie cookie,const private_input::SymbolPlan&plan,const std::wstring&symbol){
    if(plan.text.size()<=symbol.size()||finishPending||scopeOf(ctx,cookie)!=FieldScope::normal)return;
    TF_SELECTION selected{};ULONG count=0;if(FAILED(ctx->GetSelection(cookie,TF_DEFAULT_SELECTION,1,&selected,&count))||count!=1||!selected.range)return;
    ComPtr<ITfRange>end;end.Attach(selected.range);BOOL empty=FALSE;if(FAILED(end->IsEmpty(cookie,&empty))||!empty)return;
    // Caret placement remains available even when the host refuses a text
    // read or sink subscription. Those only revoke the deletion capability.
    LONG moved=0;ComPtr<ITfRange>caret;if(FAILED(end->Clone(&caret)))return;
    if(plan.caretBack&&(FAILED(caret->ShiftStart(cookie,-plan.caretBack,&moved,nullptr))||moved!= -plan.caretBack||FAILED(caret->Collapse(cookie,TF_ANCHOR_START))))return;
    TF_SELECTION inside{caret.Get(),{TF_AE_NONE,FALSE}};if(FAILED(ctx->SetSelection(cookie,1,&inside)))return;
    ComPtr<ITfRange>span;if(FAILED(end->Clone(&span)))return;if(FAILED(span->ShiftStart(cookie,-LONG(plan.text.size()),&moved,nullptr))||moved!= -LONG(plan.text.size()))return;
    wchar_t actual[8]{};ULONG length=0;if(FAILED(span->GetText(cookie,0,actual,8,&length))||std::wstring(actual,length)!=plan.text)return;
    ComPtr<ITfSource>source;DWORD token=TF_INVALID_COOKIE;if(FAILED(ctx->QueryInterface(IID_PPV_ARGS(&source)))||FAILED(source->AdviseSink(IID_ITfTextEditSink,static_cast<ITfTextEditSink*>(this),&token)))return;
    pairContext=ctx;pairEditCookie=token;pairRange=span;pairCaret=caret;pairInserted=plan.text;pairPendingArm=true;
  }
  HRESULT eraseAutomaticPair(ITfContext*ctx,TfEditCookie cookie,bool*eaten){
    if(!automaticPair.active())return S_FALSE;
    TF_SELECTION selected{};ULONG count=0;ComPtr<ITfRange>caret;BOOL empty=FALSE;LONG start=1,end=1;
    if(ctx!=pairContext.Get()||!focusedContext(ctx)||scopeOf(ctx,cookie)!=FieldScope::normal||FAILED(ctx->GetSelection(cookie,TF_DEFAULT_SELECTION,1,&selected,&count))||count!=1||!selected.range){clearAutomaticPair();return S_FALSE;}
    caret.Attach(selected.range);wchar_t buffer[8]{};ULONG size=0;
    const bool exactCaret=SUCCEEDED(caret->IsEmpty(cookie,&empty))&&empty&&SUCCEEDED(caret->CompareStart(cookie,pairCaret.Get(),TF_ANCHOR_START,&start))&&SUCCEEDED(caret->CompareEnd(cookie,pairCaret.Get(),TF_ANCHOR_END,&end))&&!start&&!end;
    const bool readable=pairRange&&SUCCEEDED(pairRange->GetText(cookie,0,buffer,8,&size));
    if(!readable||!automaticPair.permits(reinterpret_cast<uintptr_t>(ctx),std::wstring(buffer,size),exactCaret)){clearAutomaticPair();return S_FALSE;}
    auto range=pairRange;clearAutomaticPair();auto hr=range->SetText(cookie,0,L"",0);if(FAILED(hr))return hr;
    *eaten=true; // A later selection failure must never replay this deletion.
    if(SUCCEEDED(range->Collapse(cookie,TF_ANCHOR_START))){TF_SELECTION after{range.Get(),{TF_AE_NONE,FALSE}};ctx->SetSelection(cookie,1,&after);}return S_OK;
  }
  ComPtr<ITfContext>literalDigitContext;ComPtr<ITfRange>literalDigitCaret;
  void clearLiteralDigit(){literalDigitContext.Reset();literalDigitCaret.Reset();}
  bool followsOwnLiteralDigit(ITfContext*ctx,TfEditCookie cookie){
    if(literalDigitContext.Get()!=ctx||!literalDigitCaret)return false;
    TF_SELECTION selected{};ULONG count=0;if(FAILED(ctx->GetSelection(cookie,TF_DEFAULT_SELECTION,1,&selected,&count))||count!=1||!selected.range)return false;
    ComPtr<ITfRange>caret;caret.Attach(selected.range);LONG start=1,end=1;
    return SUCCEEDED(caret->CompareStart(cookie,literalDigitCaret.Get(),TF_ANCHOR_START,&start))&&SUCCEEDED(caret->CompareEnd(cookie,literalDigitCaret.Get(),TF_ANCHOR_END,&end))&&!start&&!end;
  }
  void rememberLiteralDigit(ITfContext*ctx,TfEditCookie cookie){
    TF_SELECTION selected{};ULONG count=0;if(FAILED(ctx->GetSelection(cookie,TF_DEFAULT_SELECTION,1,&selected,&count))||count!=1||!selected.range)return;
    ComPtr<ITfRange>caret;caret.Attach(selected.range);BOOL empty=FALSE;if(FAILED(caret->IsEmpty(cookie,&empty))||!empty)return;
    literalDigitContext=ctx;literalDigitCaret=caret;
  }
  HRESULT insertPhysicalSymbol(ITfContext*ctx,TfEditCookie cookie,WPARAM key,bool*eaten){
    if(finishPending)return S_FALSE;const auto scope=scopeOf(ctx,cookie);if(scope==FieldScope::password||scope==FieldScope::privateField)return S_FALSE;auto symbol=literalSymbol(key);if(symbol.empty())return S_FALSE;readContext(ctx,cookie);
    const auto field=archiveFieldType(ctx,cookie);const bool asciiField=field>=2&&field<=5;
    const bool digit=(!contextBefore.empty()&&contextBefore.back()>='0'&&contextBefore.back()<='9')||followsOwnLiteralDigit(ctx,cookie);clearLiteralDigit();
    symbol=private_input::punctuationSymbol(symbol,!english,asciiField,digit);
    // Unknown fields may type punctuation, but gain no context or pair capability.
    auto plan=private_input::symbolPlan(symbol,scope==FieldScope::normal&&inputPreferences.pairSymbols,inputPreferences.caretInside);
    clearAutomaticPair();auto hr=setOwnText(ctx,cookie,plan.text,true);if(FAILED(hr))return hr;*eaten=true;rememberAutomaticPair(ctx,cookie,plan,symbol);if(symbol.size()==1&&symbol[0]>=L'0'&&symbol[0]<=L'9')rememberLiteralDigit(ctx,cookie);return S_OK;
  }

  std::shared_ptr<DesktopPreferenceSnapshot>desktopCache=std::make_shared<DesktopPreferenceSnapshot>();
  unsigned ownEndDepth=0;std::string contextBefore,contextAfter;std::filesystem::path publicContextPath;
  private_input::activity::CaptureEmitter archiveEmitter;
  std::optional<private_input::activity::DecisionCapture>activeDecision;
  std::string decisionComposition,decisionClock,lastMarkedText,lastMarkedStatus,lastDecisionSnapshot;bool decisionCommitted=false,diagnosticSafe=false;HWND diagnosticHost=nullptr;uint32_t diagnosticField=0;
  static std::string diagnosticID(){GUID id{};if(FAILED(CoCreateGuid(&id)))return {};wchar_t text[40]{};StringFromGUID2(id,text,40);return utf8(text);}
  static uint64_t diagnosticUS(){return GetTickCount64()*1000;}
  void startDecision(size_t index,const char*method,const char*key){
    if(secure||!diagnosticSafe||!archiveEmitter.diagnosticsEnabled())return;
    try{if(decisionComposition.empty())decisionComposition=diagnosticID();if(decisionClock.empty())decisionClock=diagnosticID();
      private_input::activity::DecisionCapture d;d.link.composition=decisionComposition;d.link.state=decisionComposition+":"+std::to_string(revision);d.link.decision=diagnosticID();d.clock=decisionClock;d.revision=revision;d.monotonicUS=diagnosticUS();d.pressUS=d.monotonicUS;d.pressState=d.link.state;d.snapshot=d.link.state;d.method=method;d.key=key;d.before=english?englishInput:std::string(pi_raw_input(session));if(d.before.size()>4096)return;
      auto item=[&](size_t i){const auto&r=candidates.rows[i];return private_input::activity::DecisionCandidate{d.snapshot+":"+std::to_string(i),r.text,r.reading,uint64_t(i)};};
      for(size_t i=0;i<std::min(size_t(5),candidates.rows.size());++i){auto c=item(i);if(c.text.size()<=256&&c.reading.size()<=256)d.preview.push_back(std::move(c));}
      if(index<candidates.rows.size()){auto selected=item(index);if(selected.text.size()<=256&&selected.reading.size()<=256)d.selected=std::move(selected);else{d.reason="selected_text_too_large";d.selectedID=selected.id;d.selectedRank=selected.rank;}}
      d.truncated=candidates.hasMoreNative||d.preview.size()<candidates.rows.size();activeDecision=std::move(d);decisionCommitted=false;
    }catch(...){activeDecision.reset();}
  }
  void endDecision(ITfContext*ctx,TfEditCookie cookie,HRESULT result,const char*reason=""){
    if(!activeDecision)return;auto d=std::move(*activeDecision);activeDecision.reset();
    if(secure||scopeOf(ctx,cookie)!=FieldScope::normal||!archiveEmitter.diagnosticsEnabled())return;
    d.after=english?englishInput:std::string(pi_raw_input(session));if(d.after.size()>4096)return;
    d.stage=decisionCommitted?"commit":FAILED(result)?"error":"selection";d.monotonicUS=diagnosticUS();if(*reason){d.reason=reason;if(!decisionCommitted)d.stage="cancel";}d.markedText=lastMarkedText;d.markedStatus=lastMarkedStatus;d.includePreview=d.snapshot!=lastDecisionSnapshot;lastDecisionSnapshot=d.snapshot;
    archiveEmitter.emitDecision(d,diagnosticHost,archiveSession,archiveEditor,english?2:1,diagnosticField);
  }
  void observeCandidate(size_t index,unsigned long long version,bool released,bool valid){
    if(!released){startDecision(index,"mouse","mouse");return;}
    if(!activeDecision)return;activeDecision->releaseUS=diagnosticUS();activeDecision->releaseState=decisionComposition+":"+std::to_string(version);
    if(valid)return;auto ctx=compositionContext;if(!ctx){activeDecision.reset();return;}auto id=activeDecision->link.decision;HRESULT result=E_FAIL;
    request(ctx.Get(),TF_ES_ASYNCDONTCARE|TF_ES_READ,[this,ctx,id](TfEditCookie cookie){if(activeDecision&&activeDecision->link.decision==id)endDecision(ctx.Get(),cookie,S_FALSE,"pointer_cancelled");return S_OK;},&result);
  }

  private_input::activity::LearningReader learningReader;std::shared_ptr<const private_input::activity::LearningSnapshot>sessionLearning;std::vector<std::pair<std::wstring,std::wstring>>learningSelections;
  std::array<unsigned char,16> archiveSession{},archiveEditor{};
  ITfContext* archiveContext=nullptr;std::optional<LONG> archiveExpectedCaret;
  void renewArchiveEditor(ITfContext*ctx,bool force=false){if(!force&&archiveContext==ctx)return;archiveContext=ctx;archiveExpectedCaret.reset();GUID value{};if(SUCCEEDED(CoCreateGuid(&value)))memcpy(archiveEditor.data(),&value,sizeof(value));}
  std::optional<LONG> archiveCaret(ITfContext*ctx,TfEditCookie cookie){TF_SELECTION selection{};ULONG fetched=0;if(FAILED(ctx->GetSelection(cookie,TF_DEFAULT_SELECTION,1,&selection,&fetched))||fetched!=1||!selection.range)return {};ComPtr<ITfRange>range;range.Attach(selection.range);ComPtr<ITfRangeACP>acp;LONG at=0,length=0;if(FAILED(range.As(&acp))||FAILED(acp->GetExtent(&at,&length))||at<0||length!=0)return {};return at;}
  void observeArchiveCaret(ITfContext*ctx,TfEditCookie cookie){auto caret=archiveCaret(ctx,cookie);if(ctx!=archiveContext||!caret||!archiveExpectedCaret||*caret!=*archiveExpectedCaret)renewArchiveEditor(ctx,true);}
  void archiveCommit(ITfContext*ctx,TfEditCookie cookie,const std::wstring&text){if(secure||text.empty()||scopeOf(ctx,cookie)!=FieldScope::normal)return;ComPtr<ITfContextView> view;HWND hwnd=nullptr;if(FAILED(ctx->GetActiveView(&view))||FAILED(view->GetWnd(&hwnd))||!hwnd)return;renewArchiveEditor(ctx);archiveExpectedCaret=archiveCaret(ctx,cookie);if(activeDecision)decisionCommitted=true;const auto*link=activeDecision?&activeDecision->link:nullptr;archiveEmitter.emit(text,hwnd,archiveSession,archiveEditor,true,english?2:1,archiveFieldType(ctx,cookie),false,false,nullptr,link);}
  private_input::ClipboardCandidatePolicy clipboardPolicy;private_input::activity::ClipboardCandidateReader clipboardReader;
  private_input::activity::ClipboardCandidateSnapshot clipboardOffer;ComPtr<ITfContext>clipboardContext;ComPtr<ITfRange>clipboardSelection;
  DWORD clipboardEditCookie=TF_INVALID_COOKIE;
  uint64_t clipboardPendingRequest=0,clipboardInFlightRequest=0,clipboardRequestCounter=0;
  HWND clipboardPollWindow=nullptr;bool clipboardVisible=false;
  static LRESULT CALLBACK clipboardPollProc(HWND hwnd,UINT message,WPARAM w,LPARAM l){auto*self=reinterpret_cast<TextService*>(GetWindowLongPtrW(hwnd,GWLP_USERDATA));if(message==WM_NCCREATE){self=static_cast<TextService*>(reinterpret_cast<CREATESTRUCTW*>(l)->lpCreateParams);SetWindowLongPtrW(hwnd,GWLP_USERDATA,reinterpret_cast<LONG_PTR>(self));}if(self&&message==WM_TIMER){self->pollClipboardCandidate();return 0;}return DefWindowProcW(hwnd,message,w,l);}
  void retireClipboard(uint32_t sequence=0){clipboardPendingRequest=0;if(clipboardEditCookie!=TF_INVALID_COOKIE&&clipboardContext){ComPtr<ITfSource>source;if(SUCCEEDED(clipboardContext.As(&source)))source->UnadviseSink(clipboardEditCookie);}clipboardEditCookie=TF_INVALID_COOKIE;clipboardPolicy.dismiss(sequence?sequence:clipboardOffer.sequence);clipboardOffer={};clipboardContext.Reset();clipboardSelection.Reset();if(clipboardVisible){clipboardVisible=false;words.clear();panel.hide();++revision;}}
  bool sameClipboardSelection(ITfContext*ctx,TfEditCookie cookie){if(!clipboardSelection||clipboardContext.Get()!=ctx)return false;TF_SELECTION selected{};ULONG count=0;if(FAILED(ctx->GetSelection(cookie,TF_DEFAULT_SELECTION,1,&selected,&count))||count!=1||!selected.range)return false;ComPtr<ITfRange>current;current.Attach(selected.range);LONG start=1,end=1;return SUCCEEDED(current->CompareStart(cookie,clipboardSelection.Get(),TF_ANCHOR_START,&start))&&SUCCEEDED(current->CompareEnd(cookie,clipboardSelection.Get(),TF_ANCHOR_END,&end))&&start==0&&end==0;}
  void pollClipboardCandidate(){
 // Desktop clipboard sync must not show a candidate or read/poll clipboard offers.
 // This does not suppress ordinary pinyin/English conversion candidates.
 if(clipboardVisible)retireClipboard();
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
  // Automatic phrase notice: segmented selections paired with their readings; last caret anchor for the card.
  PhraseNotice phraseNotice;std::vector<std::string> phraseTexts,phraseReadings;bool phraseBroken=false;std::wstring lastFlushCommit;RECT lastAnchor{};UINT lastAnchorDpi=96;
  void phraseReset(){phraseTexts.clear();phraseReadings.clear();phraseBroken=false;}
  static std::string joined(const std::vector<std::string>&parts,const char *separator){std::string out;for(size_t i=0;i<parts.size();++i){if(i)out+=separator;out+=parts[i];}return out;}
  static bool firstAnnouncement(const std::wstring &key){HKEY store=nullptr;if(RegCreateKeyExW(HKEY_CURRENT_USER,L"Software\\LingheInput\\AutoPhraseAnnounced",0,nullptr,0,KEY_QUERY_VALUE|KEY_SET_VALUE,nullptr,&store,nullptr)!=ERROR_SUCCESS)return false;bool fresh=RegQueryValueExW(store,key.c_str(),nullptr,nullptr,nullptr,nullptr)==ERROR_FILE_NOT_FOUND;if(fresh){DWORD one=1;fresh=RegSetValueExW(store,key.c_str(),0,REG_DWORD,reinterpret_cast<const BYTE*>(&one),sizeof(one))==ERROR_SUCCESS;}RegCloseKey(store);return fresh;}
  // Called after a Rime candidate commit; mirrors Android/Apple AutoPhraseTracker semantics.
  void autoPhraseAfter(const std::string &prefix,const std::string &text,const std::string &reading){
    if(prefix.empty())phraseReset();else if(phraseBroken||prefix!=joined(phraseTexts,"")){phraseBroken=true;return;}
    if(text.empty()||reading.empty()){phraseBroken=true;return;}
    phraseTexts.push_back(text);phraseReadings.push_back(reading);
    if(lastFlushCommit.empty())return;
    const auto commit=utf8(lastFlushCommit);const bool match=!phraseBroken&&commit==joined(phraseTexts,"");const auto fullReading=joined(phraseReadings," ");phraseReset();
    if(!match||privateSchema||pi_auto_phrase_status(commit.c_str())!=2||!firstAnnouncement(lastFlushCommit+L"\x1f"+wide(fullReading.c_str())))return;
    phraseNotice.show(g_instance,lastAnchor,lastAnchorDpi,lastFlushCommit,[commit,fullReading]{pi_forget_phrase(fullReading.c_str(),commit.c_str());});
  }
  std::optional<PrivateInputEnginePaths> enginePaths;
  DesktopInputPreferences inputPreferences;CandidateGlyphFilter glyphFilter;private_input::DesktopCandidates navigation;private_input::CandidateStream candidates;std::vector<std::wstring> words;
  bool candidateDisplayable(const std::string&text){return private_input::candidateAllowedForDisplay(text,[this](const auto&value){return glyphFilter.supports(wide(value.c_str()));});}
  IUnknown *identity(){return static_cast<ITfTextInputProcessorEx*>(this);}
  bool composing()const{return !englishInput.empty()||(session&&*pi_preedit(session));}
  std::wstring markedText()const{return english?wide(englishInput.c_str()):wide(pi_preedit(session));}
  bool modeKey(WPARAM key)const{return (key==VK_SHIFT&&shiftTap.down&&!shiftTap.used)||(key==VK_SPACE&&GetKeyState(VK_CONTROL)<0&&GetKeyState(VK_SHIFT)<0&&GetKeyState(VK_MENU)>=0);}
  // Literal keys never block typing: they end the composition with the readable
  // raw spelling and are then handled by the host exactly as without this IME.
  std::wstring literalSymbol(WPARAM key)const{if(key<VK_SPACE||key>VK_OEM_102)return {};BYTE state[256]{};if(!GetKeyboardState(state))return {};wchar_t text[8]{};auto result=ToUnicodeEx(UINT(key),MapVirtualKeyW(UINT(key),MAPVK_VK_TO_VSC),state,text,8,4,GetKeyboardLayout(0));return result==1?std::wstring(text,1):std::wstring{};}
  bool endingLiteral(WPARAM key)const{
    return key==VK_OEM_1||key==VK_OEM_2||key==VK_OEM_3||key==VK_OEM_4||key==VK_OEM_5||key==VK_OEM_6||key==VK_OEM_7||
           key==VK_OEM_102||key==VK_OEM_COMMA||key==VK_OEM_PERIOD||key==VK_OEM_MINUS||key==VK_OEM_PLUS||
           (key>='0'&&key<='9'&&(GetKeyState(VK_SHIFT)<0||navigation.digit(unsigned(key-'0'))>=words.size()))||
           (key>=VK_NUMPAD0&&key<=VK_DIVIDE)||key==VK_TAB;
  }
  bool printable(WPARAM key)const{auto value=literalSymbol(key);return value.size()==1&&value[0]>=32&&value[0]!=127;}
  bool modifiedBackspace(WPARAM key)const{return key==VK_BACK&&!private_input::plainPairBackspace(GetKeyState(VK_SHIFT)<0,GetKeyState(VK_CONTROL)<0,GetKeyState(VK_MENU)<0,GetKeyState(VK_LWIN)<0||GetKeyState(VK_RWIN)<0);}
  bool accepts(ITfContext *ctx,WPARAM key)const{
    if(!session||secure||!ctx||disabled(ctx)||modifiedBackspace(key))return false;if((key==VK_DELETE||key==VK_BACK)&&clipboardVisible&&!clipboardPolicy.deleteHeld)return true;if(modeKey(key))return true;
    if(GetKeyState(VK_CONTROL)<0||GetKeyState(VK_MENU)<0||GetKeyState(VK_LWIN)<0||GetKeyState(VK_RWIN)<0)return false;
    if(key==VK_BACK&&automaticPair.active())return true;
    return finishPending||!pendingCommit.empty()||(key>='A'&&key<='Z')||(!composing()&&printable(key))||(composing()&&(key==VK_SPACE||key==VK_RETURN||key==VK_BACK||key==VK_ESCAPE||key==VK_LEFT||key==VK_RIGHT||key==VK_UP||key==VK_DOWN||key==VK_PRIOR||key==VK_NEXT||(key>='1'&&key<='9')||endingLiteral(key)));
  }
  bool technicalIdlePassThrough(ITfContext*ctx){
    // A positive preflight is unnecessary when the host has explicitly marked
    // an idle address/code field. Ask only for a synchronous read cookie: a
    // refused read keeps the existing guarded OnKeyDown fallback, never an
    // asynchronous callback into these stack locals or a guessed field type.
    if(!ctx||secure||!session||composition||composing()||finishPending||!pendingCommit.empty()||disabled(ctx))return false;
    ComPtr<ITfContext>retained=ctx;bool literal=false;HRESULT result=E_FAIL;
    auto hr=request(ctx,TF_ES_SYNC|TF_ES_READ,[this,retained,&literal](TfEditCookie cookie){
      literal=focusedContext(retained.Get())&&scopeOf(retained.Get(),cookie)==FieldScope::normal&&technicalInputField(retained.Get(),cookie);return S_OK;
    },&result);
    return SUCCEEDED(hr)&&SUCCEEDED(result)&&literal;
  }
  bool startEngine(){
    std::filesystem::path shared,user;
    if(enginePaths){shared=enginePaths->shared;user=enginePaths->user;}
    else {
      wchar_t path[32768];DWORD n=GetModuleFileNameW(g_instance,path,32768);if(!n||n>=32768)return false;shared=std::filesystem::path(path).parent_path()/L"data"/L"rime";
      PWSTR data=nullptr;if(FAILED(SHGetKnownFolderPath(FOLDERID_LocalAppData,0,nullptr,&data)))return false;FILETIME created{},ended{},kernel{},userTime{};if(!GetProcessTimes(GetCurrentProcess(),&created,&ended,&kernel,&userTime)){CoTaskMemFree(data);return false;}ULARGE_INTEGER stamp{};stamp.LowPart=created.dwLowDateTime;stamp.HighPart=created.dwHighDateTime;user=std::filesystem::path(data)/L"PrivateInput"/L"RimeSessions"/(std::to_wstring(GetCurrentProcessId())+L"-"+std::to_wstring(stamp.QuadPart));CoTaskMemFree(data);
    }
    for(auto path=std::filesystem::absolute(user).lexically_normal();!path.empty();path=path.parent_path()){auto attributes=GetFileAttributesW(path.c_str());if(attributes!=INVALID_FILE_ATTRIBUTES&&(attributes&FILE_ATTRIBUTE_REPARSE_POINT))return false;if(path==path.parent_path())break;}std::error_code e;std::filesystem::create_directories(user,e);if(e)return false;if(!enginePaths){auto marker=user/L"linghe-generated-session-v1";if(!std::filesystem::exists(marker)){FILETIME created{},ended{},kernel{},userTime{};if(!GetProcessTimes(GetCurrentProcess(),&created,&ended,&kernel,&userTime))return false;ULARGE_INTEGER stamp{};stamp.LowPart=created.dwLowDateTime;stamp.HighPart=created.dwHighDateTime;std::ofstream output(marker,std::ios::binary);output<<"LingheInput generated stateless native session v1\n"<<GetCurrentProcessId()<<"\n"<<stamp.QuadPart<<"\n";if(!output)return false;}}
    const auto&learningProfile=private_input::learning_capacity::expanded_10000;if(!pi_initialize(utf8(shared.wstring()).c_str(),utf8(user.wstring()).c_str(),0)||pi_set_learning_capacity_profile(learningProfile.id.data(),learningProfile.version)!=1)return false;session=pi_create_session();if(session&&!enginePaths&&!pi_set_private(session,1)){pi_destroy_session(session);session=0;}publicContextPath=shared.parent_path()/L"semantic"/L"continuation.bin";return session!=0;
  }
  HRESULT request(ITfContext *ctx,DWORD flags,std::function<HRESULT(TfEditCookie)> action,HRESULT *result,std::function<void()>completed={}){auto *job=new EditJob(identity(),std::move(action),std::move(completed));HRESULT hr=ctx->RequestEditSession(client,job,flags,result);job->Release();return hr;}
  void detachComposition(){
    clearLiteralDigit();clearAutomaticPair();
    unwatchLayout();auto old=composition;auto ctx=compositionContext;composition.Reset();compositionContext.Reset();finishPending=false;pendingCommit.clear();pendingContext.Reset();panel.hide();contextBefore.clear();contextAfter.clear();englishInput.clear();learningSelections.clear();if(session)pi_clear(session);++revision;
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
    observeArchiveCaret(ctx,cookie);if(!activeDecision||decisionComposition.empty())decisionComposition=diagnosticSafe?diagnosticID():"";lastMarkedText.clear();lastMarkedStatus="not_used";
    ComPtr<ITfInsertAtSelection> insert;HRESULT hr=ctx->QueryInterface(IID_ITfInsertAtSelection,reinterpret_cast<void**>(insert.GetAddressOf()));if(FAILED(hr))return hr;
    ComPtr<ITfRange> range;hr=insert->InsertTextAtSelection(cookie,TF_IAS_QUERYONLY,nullptr,0,&range);if(FAILED(hr))return hr;
    ComPtr<ITfContextComposition> comp;hr=ctx->QueryInterface(IID_ITfContextComposition,reinterpret_cast<void**>(comp.GetAddressOf()));if(FAILED(hr))return hr;
    hr=comp->StartComposition(cookie,range.Get(),this,&composition);if(SUCCEEDED(hr)){compositionContext=ctx;watchLayout(ctx);}return hr;
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
    if(SUCCEEDED(hr)){if(composition.Get()==done.Get()){unwatchLayout();composition.Reset();compositionContext.Reset();}finishPending=false;}
    else finishPending=true;
    clearAnchor();panel.hide();return hr;
  }
  HRESULT setOwnText(ITfContext *ctx,TfEditCookie cookie,const std::wstring &text,bool finish){
    ComPtr<ITfRange> range;HRESULT hr;
    if(composition&&compositionContext.Get()==ctx)hr=composition->GetRange(&range);
    else{ComPtr<ITfInsertAtSelection> insert;hr=ctx->QueryInterface(IID_ITfInsertAtSelection,reinterpret_cast<void**>(insert.GetAddressOf()));if(FAILED(hr))return hr;hr=insert->InsertTextAtSelection(cookie,TF_IAS_QUERYONLY,nullptr,0,&range);}
    if(FAILED(hr))return hr;hr=range->SetText(cookie,0,text.data(),LONG(text.size()));if(!finish&&diagnosticSafe){lastMarkedText=utf8(text);if(lastMarkedText.size()>4096){lastMarkedText.clear();lastMarkedStatus="unknown";}else lastMarkedStatus=FAILED(hr)?"host_rejected":"host_acknowledged";}if(FAILED(hr))return hr;
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
      words.clear();for(const auto &value:private_input::englishCandidates(englishInput))if(candidateDisplayable(value)){candidates.rows.push_back({value,SIZE_MAX,SIZE_MAX});words.push_back(wide(value.c_str()));}
      navigation.reset(words.size());return;
    }
    auto initial=readNative(0,128); // Also establishes the exact-spelling short circuit for repairs.
    std::vector<private_input::CandidateChoice> repairs;
    const auto count=pi_load_repair_candidates(session,16);
    for(size_t i=0;i<count;++i)repairs.push_back({pi_repair_candidate_text(session,i),SIZE_MAX,i,pi_repair_candidate_reading(session,i),false});
    candidates.reset([&](size_t,size_t){return std::move(initial);},std::move(repairs));
    auto learned=sessionLearning?sessionLearning:learningReader.read();auto contextModel=learningReader.model();auto contextHints=contextModel?contextModel->hints(contextBefore):std::vector<private_input::PublicContextModel::Hint>{};auto normalized=[](std::string source){std::string result;for(unsigned char c:source){if(c>='A'&&c<='Z')c+=32;if(c!=' '&&c!='\'')result.push_back(char(c));}return result;};auto input=normalized(pi_raw_input(session));const std::string rawInput=pi_raw_input(session);auto unselected=pi_unselected_input_start(session);auto rawTail=unselected<=rawInput.size()?rawInput.substr(unselected):rawInput;
    auto learnedWords=learned->spelling.find(normalized(rawTail));if(learnedWords!=learned->spelling.end()){size_t added=0;for(const auto&word:learnedWords->second){if(added>=64)break;bool duplicate=std::any_of(candidates.rows.begin(),candidates.rows.end(),[&](const auto&c){return c.text==word.text&&normalized(c.reading)==normalized(word.reading);});if(!duplicate&&candidateDisplayable(word.text)){candidates.rows.push_back({word.text,SIZE_MAX,SIZE_MAX,word.reading,true});++added;}}}
    for(const auto&row:learned->personal){if(normalized(row.reading)!=input)continue;bool duplicate=std::any_of(candidates.rows.begin(),candidates.rows.end(),[&](const auto&c){return c.text==row.text;});if(!duplicate&&candidateDisplayable(row.text))candidates.rows.insert(candidates.rows.begin(),{row.text,SIZE_MAX,SIZE_MAX,row.reading,true});}
    // All automatic sources, including custom learned/personal additions,
    // pass the same final product and device-glyph policy before ranking.
    candidates.rows.erase(std::remove_if(candidates.rows.begin(),candidates.rows.end(),[&](const auto&row){return !candidateDisplayable(row.text);}),candidates.rows.end());
    // Input-thread work is bounded in-memory lookups, never disk, crypto or HTTP.
    std::map<std::string,size_t>order;for(size_t i=0;i<candidates.rows.size();++i)order.emplace(private_input::activity::canonicalLearningReading(candidates.rows[i].reading)+char(31)+candidates.rows[i].text,i);
    auto eligible=[&](const private_input::CandidateChoice&row){return row.custom?3:private_input::pinyin::alphabetic_candidate_priority(rawTail,row.reading,row.repair!=SIZE_MAX);};
    auto rank=[&](const private_input::CandidateChoice&row){auto key=private_input::activity::canonicalLearningReading(row.reading)+char(31)+row.text;bool explicitEntry=learned->explicitKeys.count(key)!=0;double base=explicitEntry?8000.0:4096.0/(1.0+double(order.at(key)));if(contextModel){base+=512.0*private_input::PublicContextModel::match(contextHints,row.text);if(!contextAfter.empty())base+=256.0*private_input::PublicContextModel::match(contextModel->hints(row.text),contextAfter);}auto found=learned->scores.find(key);if(found==learned->scores.end())return base;if(found->second.pinned)return 1e12;return base+(found->second.recent>=0?8192.0*found->second.recent:384.0*std::log2(1.0+double(found->second.frequency)));};
    for(auto&row:candidates.rows){row.rankingClass=eligible(row);row.rankingScore=rank(row);}
    std::stable_sort(candidates.rows.begin(),candidates.rows.end(),private_input::candidateRankingBefore);
    words.clear();for(const auto &row:candidates.rows)words.push_back(wide(row.text.c_str()));navigation.reset(words.size());
  }
  void prepareForwardNavigation(int direction,size_t step){
    if(direction<=0||!candidates.hasMoreNative||navigation.selected+step+navigation.pageSize()<words.size())return;
    const auto old=candidates.rows.size();
    if(candidates.appendNative([&](size_t offset,size_t limit){return readNative(offset,limit);})){
      candidates.rows.erase(std::remove_if(candidates.rows.begin()+old,candidates.rows.end(),[&](const auto&row){return !candidateDisplayable(row.text);}),candidates.rows.end());
      for(size_t i=old;i<candidates.rows.size();++i)words.push_back(wide(candidates.rows[i].text.c_str()));
      navigation.count=words.size();++revision;
    }
  }
  void updatePanel(ITfContext *ctx,TfEditCookie cookie){
    if(diagnosticSafe)diagnosticSafe=!secure&&scopeOf(ctx,cookie)==FieldScope::normal;diagnosticField=diagnosticSafe?archiveFieldType(ctx,cookie):0;
    if(words.empty()||secure||finishPending||!composition||compositionContext.Get()!=ctx||!focusedContext(ctx)||disabled(ctx)||scopeOf(ctx,cookie)==FieldScope::password){clearAnchor();panel.hide();return;}
    ComPtr<ITfContextView>view;ComPtr<IUnknown>viewIdentity;ComPtr<ITfRange>range,caret;RECT rect{};BOOL clipped=FALSE;HWND host=nullptr;HRESULT geometry=E_FAIL;
    if(FAILED(ctx->GetActiveView(&view))||FAILED(view.As(&viewIdentity))||FAILED(view->GetWnd(&host))||!host||!IsWindow(host)||FAILED(composition->GetRange(&range))||FAILED(range->Clone(&caret))||FAILED(caret->Collapse(cookie,TF_ANCHOR_END))){clearAnchor();panel.hide();return;}
    if(!private_input::candidateViewMayRecover(layoutDestroyed,reinterpret_cast<uintptr_t>(destroyedViewIdentity.Get()),reinterpret_cast<uintptr_t>(viewIdentity.Get()))){clearAnchor();panel.hide();return;}
    if(layoutDestroyed){layoutDestroyed=false;destroyedViewIdentity.Reset();clearAnchor();}
    layoutViewIdentity=viewIdentity;geometry=view->GetTextExt(cookie,caret.Get(),&rect,&clipped);POINT origin{};if(!ClientToScreen(host,&origin)){clearAnchor();panel.hide();return;}auto dpi=GetDpiForWindow(host);if(!dpi){clearAnchor();panel.hide();return;}
    private_input::CandidateAnchorIdentity key{reinterpret_cast<uintptr_t>(ctx),reinterpret_cast<uintptr_t>(viewIdentity.Get()),reinterpret_cast<uintptr_t>(composition.Get()),reinterpret_cast<uintptr_t>(host),layoutEpoch,dpi,origin.x,origin.y};
    auto observation=geometry==S_OK&&!clipped?private_input::CandidateAnchorObservation::Verified:((geometry==TS_E_NOLAYOUT||geometry==E_FAIL)&&!clipped)?private_input::CandidateAnchorObservation::TemporaryUnavailable:private_input::CandidateAnchorObservation::Invalid;
    auto anchor=anchorPolicy.resolve(key,observation,{rect.left,rect.top,rect.right,rect.bottom},GetTickCount64(),true,true);
    if(!anchor){clearAnchor();panel.hide();return;}
    if(observation==private_input::CandidateAnchorObservation::Verified){anchorLease.clear();if(anchorLeaseWindow)KillTimer(anchorLeaseWindow,1);}else if(!expireAnchorLease()){clearAnchor();panel.hide();return;}
    anchorViewIdentity=viewIdentity;rect={anchor->left,anchor->top,anchor->right,anchor->bottom};diagnosticHost=host;
    lastAnchor=rect;lastAnchorDpi=dpi;panel.show(g_instance,rect,words,revision,dpi,navigation);
  }

  // Native rows select their absolute engine index; repair rows replay their
  // spelling in a private probe and replace only the unselected suffix.
  HRESULT applyCandidate(ITfContext *ctx,TfEditCookie cookie,size_t index){
    clearAutomaticPair();
    if(index>=words.size()||index>=candidates.rows.size()||!candidateDisplayable(candidates.rows[index].text))return E_FAIL;readContext(ctx,cookie);auto currentLearning=learningReader.read();if(sessionLearning&&currentLearning->scopeGeneration!=sessionLearning->scopeGeneration&&candidates.rows[index].custom){sessionLearning=currentLearning;reloadCandidates();updatePanel(ctx,cookie);return S_FALSE;}
    if(english){
      const auto committed=words[index];learningSelections.push_back({wide(englishInput.c_str()),committed});HRESULT hr=setOwnText(ctx,cookie,committed,true);
      if(FAILED(hr)){pendingCommit=committed;pendingContext=ctx;return hr;}
      englishInput.clear();++revision;reloadCandidates();updatePanel(ctx,cookie);return S_OK;
    }
    const auto choice=candidates.rows[index];auto previousSelections=learningSelections.size();if(!choice.reading.empty())learningSelections.push_back({wide(private_input::activity::canonicalLearningReading(choice.reading).c_str()),wide(choice.text.c_str())});
    if(choice.custom){auto committed=wide(pi_selected_prefix(session))+wide(choice.text.c_str());pi_clear(session);++revision;auto hr=setOwnText(ctx,cookie,committed,true);if(FAILED(hr)){pendingCommit=committed;pendingContext=ctx;return hr;}reloadCandidates();updatePanel(ctx,cookie);return S_OK;}
    if(choice.absolute!=SIZE_MAX){
      const std::string phrasePrefix=pi_selected_prefix(session);
      if(!pi_select_candidate_absolute(session,choice.absolute)){learningSelections.resize(previousSelections);return E_FAIL;}
      ++revision;lastFlushCommit.clear();auto flushed=flushResult(ctx,cookie);
      if(SUCCEEDED(flushed))autoPhraseAfter(phrasePrefix,choice.text,private_input::activity::canonicalLearningReading(choice.reading));
      return flushed;
    }
    const auto committed=wide(pi_commit_repair_candidate(session,choice.repair));
    if(committed.empty()){learningSelections.resize(previousSelections);return E_FAIL;}
    ++revision;HRESULT hr=setOwnText(ctx,cookie,committed,true);
    if(FAILED(hr)){pendingCommit=committed;pendingContext=ctx;return hr;}
    reloadCandidates();updatePanel(ctx,cookie);return S_OK;
  }
  HRESULT flushResult(ITfContext *ctx,TfEditCookie cookie){
    auto commit=wide(pi_take_commit(session));HRESULT hr=S_OK;lastFlushCommit=commit;
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
    // Address/code fields belong to their host: do not turn https into a
    // Chinese/English candidate, select that candidate before ':' or pair '/' .
    // Keep the global language mode unchanged. If a host changes its declared
    // scope while we own a draft, finish that draft literally before releasing
    // this key; never replace a visible draft with an inferred candidate.
    if(scope==FieldScope::normal&&focusedContext(ctx)&&technicalInputField(ctx,cookie)){
      clearAutomaticPair();panel.hide();
      if(composing()){
        const std::string raw=pi_raw_input(session),prefix=pi_selected_prefix(session);
        const auto start=pi_unselected_input_start(session);
        const auto literal=english?englishInput:(prefix.empty()?raw:prefix+(start<=raw.size()?raw.substr(start):raw));
        auto hr=setOwnText(ctx,cookie,wide(literal.c_str()),true);
        if(FAILED(hr)){detachComposition();return hr;}
        pi_clear(session);englishInput.clear();learningSelections.clear();words.clear();candidates.rows.clear();++revision;
      }
      *eaten=false;return S_OK;
    }
    // Draining a failed commit can be the only reason this key was routed.
    // Let the host handle literals and navigation once that work has finished.
    sessionLearning=private_input::freezeLearningSnapshot(learningReader.read(),sessionLearning,!composing());
    if(!composing()){auto cached=std::atomic_load(&desktopCache->value);inputPreferences=cached->input;panel.setTheme(inputPreferences.theme);navigation.configure(cached->layout.collapsed,cached->layout.columns,cached->layout.rows);}
    if(!accepts(ctx,key))return S_OK;
    if(key==VK_BACK&&!composing()&&automaticPair.active()){auto hr=eraseAutomaticPair(ctx,cookie,eaten);if(hr!=S_FALSE)return hr;}
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
    if(!composing()&&printable(key)&&!(key>='A'&&key<='Z')){if((scope==FieldScope::normal||scope==FieldScope::unknown)&&focusedContext(ctx))return insertPhysicalSymbol(ctx,cookie,key,eaten);return S_OK;}
    if(composing()&&endingLiteral(key)){
      if((scope==FieldScope::normal||scope==FieldScope::unknown)&&!words.empty()&&navigation.selected<candidates.rows.size()){const auto&choice=candidates.rows[navigation.selected];auto raw=std::string(pi_raw_input(session));auto start=pi_unselected_input_start(session);auto tail=start<=raw.size()?raw.substr(start):raw;if(english||choice.custom||private_input::pinyin::covers(tail,choice.reading)){auto hr=applyCandidate(ctx,cookie,navigation.selected);if(FAILED(hr))return hr;if(!composing()){if(!finishPending&&printable(key))return insertPhysicalSymbol(ctx,cookie,key,eaten);*eaten=false;return S_OK;}}}
      // An incomplete spelling keeps every readable remaining key before the
      // host receives its original punctuation or shortcut.
      const std::string rawInput=pi_raw_input(session),prefix=pi_selected_prefix(session);const auto start=pi_unselected_input_start(session);
      auto raw=english?wide(englishInput.c_str()):wide((prefix.empty()?rawInput:(start<=rawInput.size()?prefix+rawInput.substr(start):std::string(pi_preedit(session)))).c_str());
      HRESULT hr=setOwnText(ctx,cookie,raw,true);
      // If rewriting fails, preserve the already visible preedit and pass the
      // literal through. Queuing raw text here could later overwrite that key
      // or insert the spelling twice after the host has moved its selection.
      if(FAILED(hr)){detachComposition();return hr;}
      pi_clear(session);englishInput.clear();++revision;if(!finishPending&&printable(key))return insertPhysicalSymbol(ctx,cookie,key,eaten);*eaten=false;return S_OK;
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
    const bool diagnostic=!secure&&scopeOf(ctx,cookie)==FieldScope::normal&&archiveEmitter.diagnosticsEnabled();diagnosticSafe=diagnostic;
    const auto before=diagnostic?(english?englishInput:std::string(pi_raw_input(session))):std::string{};
    if(activeDecision)endDecision(ctx,cookie,S_FALSE,"input_changed");
    if(diagnostic&&!words.empty()&&(key==VK_SPACE||key==VK_RETURN||(key>='1'&&key<='9'))){const auto index=key>='1'&&key<='9'?navigation.digit(unsigned(key-'0')):navigation.selected;startDecision(index,key==VK_SPACE?"space":key==VK_RETURN?"enter":"number",key==VK_SPACE?"space":key==VK_RETURN?"enter":"number");if(key==VK_RETURN&&activeDecision){activeDecision->selected.reset();activeDecision->reason="literal_commit";}}
    else if(diagnostic&&key==VK_ESCAPE&&!before.empty())startDecision(SIZE_MAX,"unknown","escape");
    const auto result=handleKey(ctx,cookie,key,handled);
    // Preserve the existing separately authorized raw v1 stream. JSON/SQLite
    // remain on the archive worker; new v2 snapshots are terminal-only.
    if(diagnostic&&*handled&&!secure&&scopeOf(ctx,cookie)==FieldScope::normal){private_input::activity::DecisionCapture raw;raw.legacyOnly=true;raw.before=before;raw.after=english?englishInput:std::string(pi_raw_input(session));raw.key=std::to_string(key);archiveEmitter.emitDecision(raw,diagnosticHost,archiveSession,archiveEditor,english?2:1,archiveFieldType(ctx,cookie));}
    if(activeDecision)endDecision(ctx,cookie,result,!*handled?"not_handled":key==VK_ESCAPE?"explicit_cancel":"");return result;
  }
  void choose(size_t index,unsigned long long version){
    if(clipboardVisible){auto ctx=clipboardContext;if(!ctx||index!=0||version!=revision)return;HRESULT result=E_FAIL;request(ctx.Get(),TF_ES_ASYNCDONTCARE|TF_ES_READWRITE,[this,ctx,version](TfEditCookie cookie){return pasteClipboardCandidate(ctx.Get(),cookie,version);},&result);return;}
    auto ctx=compositionContext;if(!focusedContext(ctx.Get())){activeDecision.reset();panel.hide();return;}if(!ctx||version!=revision||index>=candidates.rows.size()){activeDecision.reset();return;}const auto decisionID=activeDecision?activeDecision->link.decision:std::string{};HRESULT result=E_FAIL;
    request(ctx.Get(),TF_ES_ASYNCDONTCARE|TF_ES_READWRITE,[this,ctx,index,version,decisionID](TfEditCookie cookie){
      if(!focusedContext(ctx.Get())){activeDecision.reset();panel.hide();return S_FALSE;}
      if(!decisionID.empty()&&(!activeDecision||activeDecision->link.decision!=decisionID))return S_FALSE;
      if(version!=revision||!selectionInside(ctx.Get(),cookie)||disabled(ctx.Get())||scopeOf(ctx.Get(),cookie)==FieldScope::password){endDecision(ctx.Get(),cookie,S_FALSE,"stale_state");return S_FALSE;}
      const auto result=applyCandidate(ctx.Get(),cookie,index);endDecision(ctx.Get(),cookie,result);return result;
    },&result);
  }
  void manageCandidate(size_t index,unsigned long long version,unsigned action){if(clipboardVisible)return;auto ctx=compositionContext;if(english||!ctx||!focusedContext(ctx.Get())||version!=revision||index>=candidates.rows.size())return;auto choice=candidates.rows[index];auto reading=private_input::activity::canonicalLearningReading(choice.reading);if(reading.empty())return;HRESULT result=E_FAIL;request(ctx.Get(),TF_ES_ASYNCDONTCARE|TF_ES_READ,[this,ctx,version,reading,word=choice.text,action](TfEditCookie cookie){if(!focusedContext(ctx.Get())||version!=revision||scopeOf(ctx.Get(),cookie)!=FieldScope::normal)return S_FALSE;ComPtr<ITfContextView>view;HWND hwnd=nullptr;if(SUCCEEDED(ctx->GetActiveView(&view)))view->GetWnd(&hwnd);archiveEmitter.emitLearning(wide(reading.c_str()),wide(word.c_str()),hwnd,action);return S_OK;},&result);}
public:
  TextService(const PrivateInputEnginePaths *paths):panel([this](size_t index,unsigned long long version){choose(index,version);},[this](int direction){auto ctx=compositionContext;const auto version=revision;if(!focusedContext(ctx.Get())){panel.hide();return;}HRESULT result=E_FAIL;request(ctx.Get(),TF_ES_ASYNCDONTCARE|TF_ES_READ,[this,ctx,direction,version](TfEditCookie cookie){if(!focusedContext(ctx.Get())){panel.hide();return S_FALSE;}if(version!=revision||!selectionInside(ctx.Get(),cookie)||disabled(ctx.Get())||scopeOf(ctx.Get(),cookie)==FieldScope::password)return S_FALSE;prepareForwardNavigation(direction,size_t(navigation.columns));navigation.vertical(direction);++revision;updatePanel(ctx.Get(),cookie);return S_OK;},&result);}){panel.setObservation([this](size_t i,unsigned long long v,bool released,bool valid){observeCandidate(i,v,released,valid);});if(paths)enginePaths=*paths;panel.setManagement([this](size_t i,unsigned long long v,unsigned a){manageCandidate(i,v,a);},[this](size_t i){if(i>=candidates.rows.size())return false;auto snapshot=learningReader.read();auto&row=candidates.rows[i];auto key=private_input::activity::canonicalLearningReading(row.reading)+char(31)+row.text;auto found=snapshot->scores.find(key);return found!=snapshot->scores.end()&&found->second.pinned;});GUID archiveID{};if(SUCCEEDED(CoCreateGuid(&archiveID)))memcpy(archiveSession.data(),&archiveID,sizeof(archiveID));++g_objects;}
  ~TextService(){if(anchorLeaseWindow)DestroyWindow(anchorLeaseWindow);if(clipboardPollWindow)DestroyWindow(clipboardPollWindow);learningReader.stop();if(session)pi_destroy_session(session);--g_objects;}
  STDMETHODIMP QueryInterface(REFIID iid,void **out)override{
    if(!out)return E_POINTER;*out=nullptr;if(iid==IID_IUnknown||iid==IID_ITfTextInputProcessor||iid==IID_ITfTextInputProcessorEx)*out=static_cast<ITfTextInputProcessorEx*>(this);
    else if(iid==IID_ITfKeyEventSink)*out=static_cast<ITfKeyEventSink*>(this);else if(iid==IID_ITfCompositionSink)*out=static_cast<ITfCompositionSink*>(this);else if(iid==IID_ITfTextEditSink)*out=static_cast<ITfTextEditSink*>(this);else if(iid==IID_ITfTextLayoutSink)*out=static_cast<ITfTextLayoutSink*>(this);if(!*out)return E_NOINTERFACE;AddRef();return S_OK;
  }
  STDMETHODIMP_(ULONG) AddRef()override{return ++refs;}
  STDMETHODIMP_(ULONG) Release()override{auto n=--refs;if(!n)delete this;return n;}
  STDMETHODIMP Activate(ITfThreadMgr *mgr,TfClientId id)override{return ActivateEx(mgr,id,0);}
  STDMETHODIMP ActivateEx(ITfThreadMgr *mgr,TfClientId id,DWORD flags)override{
    if(!mgr)return E_INVALIDARG;if(manager)return E_UNEXPECTED;manager=mgr;client=id;secure=(flags&TF_TMAE_SECUREMODE)!=0;
    // In a protected desktop do not subscribe to key events, load dictionaries,
    // or create any learning database. The OS retains its own input handling.
    if(secure)return S_OK;
    // Desktop clipboard has no IME offer and requires no UI polling timer.
    archiveEmitter.start();if(!enginePaths){wchar_t module[32768]{};DWORD n=GetModuleFileNameW(g_instance,module,32768);if(n&&n<32768){auto broker=std::filesystem::path(module).parent_path()/L"LingheInputActivity.exe";private_input::BackgroundTask::start([broker]{
      // Worker startup must not wait on shell extensions or file inspection in
      // the host's TSF activation callback. Launch only this existing executable
      // with the caller's token; the worker keeps its normal singleton gate.
      std::error_code error;if(!std::filesystem::is_regular_file(broker,error))return;
      std::wstring command=L"\""+broker.wstring()+L"\" --background";STARTUPINFOW startup{};startup.cb=sizeof(startup);startup.dwFlags=STARTF_USESHOWWINDOW;startup.wShowWindow=SW_HIDE;PROCESS_INFORMATION process{};
      if(CreateProcessW(broker.c_str(),command.data(),nullptr,nullptr,FALSE,0,nullptr,broker.parent_path().c_str(),&startup,&process)){CloseHandle(process.hThread);CloseHandle(process.hProcess);}
    });}}
    HRESULT hr=manager.As(&keystrokes);if(FAILED(hr)){manager.Reset();return hr;}
    if(!startEngine()){keystrokes.Reset();manager.Reset();return E_FAIL;}if(!enginePaths){auto resource=utf8((publicContextPath.parent_path().parent_path()/L"rime").wstring());PWSTR local=nullptr;std::filesystem::path preference;if(SUCCEEDED(SHGetKnownFolderPath(FOLDERID_LocalAppData,0,nullptr,&local))){preference=std::filesystem::path(local)/L"PrivateInput/desktop-candidate-layout-v1.json";CoTaskMemFree(local);}auto nextCache=std::make_shared<DesktopPreferenceSnapshot>();nextCache->value=std::atomic_load(&desktopCache->value);desktopCache=std::move(nextCache);learningReader.start(publicContextPath,[resource]{pi_prepare_repair_resources(resource.c_str());},[cache=desktopCache,preference]{auto next=std::make_shared<CachedDesktopPreferences>();next->layout=readDesktopLayout(preference);next->input=readDesktopInputPreferences(preference);std::shared_ptr<const CachedDesktopPreferences>frozen=next;std::atomic_store(&cache->value,std::move(frozen));});}
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
  STDMETHODIMP Deactivate()override{learningReader.stop();if(anchorLeaseWindow){DestroyWindow(anchorLeaseWindow);anchorLeaseWindow=nullptr;}if(clipboardPollWindow){DestroyWindow(clipboardPollWindow);clipboardPollWindow=nullptr;}retireClipboard();clipboardReader.close();detachComposition();if(keystrokes&&keySinkAdvised)keystrokes->UnadviseKeyEventSink(client);keySinkAdvised=false;if(session)pi_destroy_session(session);session=0;keystrokes.Reset();manager.Reset();client=PrivateInputClientNull;return S_OK;}
  STDMETHODIMP OnCompositionTerminated(TfEditCookie,ITfComposition *ended)override{
    // Treat our own ending exactly like a host that never calls this sink;
    // explicit finish paths own cleanup. External termination still resets it.
    if(ownEndDepth)return S_OK;clearAutomaticPair();
    if(composition.Get()==ended){unwatchLayout();contextBefore.clear();contextAfter.clear();composition.Reset();compositionContext.Reset();finishPending=false;pendingCommit.clear();pendingContext.Reset();if(session)pi_clear(session);englishInput.clear();panel.hide();++revision;}return S_OK;}
  STDMETHODIMP OnLayoutChange(ITfContext*ctx,TfLayoutCode code,ITfContextView*view)override{
    if(layoutContext.Get()!=ctx)return S_OK;
    ComPtr<IUnknown>notified,activeIdentity;ComPtr<ITfContextView>activeView;
    if(view)view->QueryInterface(IID_PPV_ARGS(&notified));if(SUCCEEDED(ctx->GetActiveView(&activeView)))activeView.As(&activeIdentity);
    using private_input::CandidateViewEvent;using private_input::CandidateViewAction;
    const auto event=code==TF_LC_DESTROY?CandidateViewEvent::Destroy:code==TF_LC_CREATE?CandidateViewEvent::Create:CandidateViewEvent::Change;
    const auto action=private_input::candidateViewAction(event,reinterpret_cast<uintptr_t>(notified.Get()),reinterpret_cast<uintptr_t>(activeIdentity.Get()),reinterpret_cast<uintptr_t>(layoutViewIdentity.Get()));
    if(action==CandidateViewAction::Ignore)return S_OK;
    if(action==CandidateViewAction::Retire){++layoutEpoch;layoutRefreshPending=false;layoutDestroyed=true;destroyedViewIdentity=notified?notified:activeIdentity?activeIdentity:layoutViewIdentity;clearAnchor();panel.hide();return S_OK;}
    if(action==CandidateViewAction::Restart){++layoutEpoch;layoutRefreshPending=false;layoutDestroyed=false;destroyedViewIdentity.Reset();clearAnchor();if(activeIdentity)layoutViewIdentity=activeIdentity;else layoutViewIdentity=notified;}
    else if(event==CandidateViewEvent::Destroy){
      // An old view can be destroyed after the new active view's CREATE. Do
      // not retire that new generation or cancel its already queued read job.
      if(activeIdentity)layoutViewIdentity=activeIdentity;
      if(anchorViewIdentity&&anchorViewIdentity.Get()==layoutViewIdentity.Get())return S_OK;
      clearAnchor();
    }
    // Notification geometry is never used: this read job queries active view.
    refreshLayout(ctx);return S_OK;
  }

  STDMETHODIMP OnEndEdit(ITfContext*ctx,TfEditCookie,ITfEditRecord*)override{if(pairContext.Get()==ctx&&!pairOwnRequest)clearAutomaticPair();if(clipboardVisible)retireClipboard();return S_OK;}
  STDMETHODIMP OnSetFocus(BOOL foreground)override{phraseNotice.hide();if(!foreground){shiftTap.reset();retireClipboard();detachComposition();archiveContext=nullptr;archiveExpectedCaret.reset();}return S_OK;}
  STDMETHODIMP OnTestKeyDown(ITfContext *ctx,WPARAM key,LPARAM,BOOL *eaten)override{if(key!=VK_OEM_PERIOD&&key!=VK_DECIMAL)clearLiteralDigit();if(!eaten)return E_POINTER;if(key!=VK_BACK||modifiedBackspace(key))clearAutomaticPair();if(key!=VK_SHIFT&&key!=VK_LSHIFT&&key!=VK_RSHIFT)shiftTap.otherKey();if(key=='V'&&GetKeyState(VK_CONTROL)<0)clipboardPolicy.resumeEditing();if(key!=VK_DELETE&&key!=VK_BACK&&key!=VK_SHIFT&&key!=VK_CONTROL&&key!=VK_MENU&&key!=VK_LWIN&&key!=VK_RWIN){retireClipboard(GetClipboardSequenceNumber());}if(key!=VK_SHIFT&&technicalIdlePassThrough(ctx)){*eaten=FALSE;return S_OK;}*eaten=(key==VK_SHIFT&&!secure&&session&&ctx&&!disabled(ctx))||accepts(ctx,key);return S_OK;}
  STDMETHODIMP OnTestKeyUp(ITfContext *ctx,WPARAM key,LPARAM,BOOL *eaten)override{if(key==VK_DELETE||key==VK_BACK)clipboardPolicy.releaseDelete();if(!eaten)return E_POINTER;const bool toggle=key==VK_SHIFT&&shiftTap.ready(reinterpret_cast<uintptr_t>(ctx))&&!secure;if(key==VK_SHIFT&&!toggle)shiftTap.reset();*eaten=toggle;return S_OK;}
  STDMETHODIMP OnKeyDown(ITfContext *ctx,WPARAM key,LPARAM,BOOL *eaten)override{if(phraseNotice.visible())phraseNotice.hide();if(key!=VK_OEM_PERIOD&&key!=VK_DECIMAL)clearLiteralDigit();
    if(!eaten)return E_POINTER;*eaten=FALSE;if(modifiedBackspace(key)){clearAutomaticPair();return S_OK;}if(key==VK_SHIFT){shiftTap.press(reinterpret_cast<uintptr_t>(ctx),secure||GetKeyState(VK_CONTROL)<0||GetKeyState(VK_MENU)<0||GetKeyState(VK_LWIN)<0||GetKeyState(VK_RWIN)<0);return S_OK;}shiftTap.otherKey();if((key==VK_DELETE||key==VK_BACK)&&clipboardVisible&&!clipboardPolicy.deleteHeld){clipboardPolicy.hideForDelete(clipboardOffer.sequence);retireClipboard();*eaten=TRUE;return S_OK;}if(key!=VK_DELETE&&key!=VK_BACK){retireClipboard(GetClipboardSequenceNumber());}if(!accepts(ctx,key))return S_OK;ComPtr<ITfContext> retained=ctx;bool handled=false;HRESULT result=E_FAIL;
    pairOwnRequest=true;
    HRESULT hr=request(ctx,TF_ES_SYNC|TF_ES_READWRITE,[this,retained,key,&handled](TfEditCookie cookie){return handleArchivedKey(retained.Get(),cookie,key,&handled);},&result);
    completeAutomaticPairRequest(SUCCEEDED(hr)&&SUCCEEDED(result)&&handled);
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
