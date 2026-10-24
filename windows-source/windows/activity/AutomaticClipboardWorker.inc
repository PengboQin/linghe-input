// Included only inside Worker's private namespace. Main-thread clipboard I/O
// and backend disk/network work communicate through immutable fenced requests.
constexpr UINT AutomaticClipboardApplyMessage=WM_APP+6;
constexpr UINT_PTR AutomaticClipboardRetryTimer=0x4c48;
constexpr UINT ClipboardBaselineProbeMessage=WM_APP+8;
constexpr UINT_PTR ClipboardReadRetryTimer=0x4c4a;
struct ClipboardBaselineProbe {uint64_t generation=0;DWORD sequence=0;};
void probeClipboardBaseline(uint64_t,DWORD);void scheduleClipboardReadRetry(DWORD,uint64_t,bool=false);void cancelClipboardReadRetry();
std::unique_ptr<AutomaticClipboard>automaticClipboard;
std::atomic<bool>automaticClipboardActive{false},automaticClipboardUserPaused{false},automaticClipboardRequestedOff{false};
std::atomic<uint64_t>automaticPreferenceRevision{0};
std::atomic<uint64_t>automaticClipboardGeneration{1},clipboardLocalSerial{0},automaticPendingSerial{0};
uint64_t advanceAutomaticGeneration(){auto generation=++automaticClipboardGeneration;clipboardReadSafety.invalidate(generation);return generation;}
std::atomic<DWORD>automaticBaselineSequence{0},archiveBaselineSequence{0},clipboardHandledSequence{0};
struct PendingAutomaticCopy{uint64_t generation=0,serial=0;std::string text;};
std::optional<PendingAutomaticCopy>pendingAutomaticCopy,latestAutomaticCopy;std::mutex automaticCopySlotMutex;
uint64_t lastAutomaticSyncSerial=0,lastContentAttempt=0;
struct AutomaticApplyRequest{Json item;uint64_t generation=0,serial=0;DWORD sequence=0;unsigned retries=0;};
std::unique_ptr<AutomaticApplyRequest>pendingAutomaticApply;
std::array<unsigned char,16>automaticEchoNonce{};
DWORD automaticWriteSequence=0;
std::string automaticWriteEvent,automaticWriteHash;
struct AutomaticClipboardMarker{uint32_t magic=0x3441484c;std::array<unsigned char,16>nonce{};char event[37]{},hash[45]{};uint32_t version=2;char sender[37]{};};
UINT automaticMarkerFormat(){static auto value=RegisterClipboardFormatW(L"LingheInput.AutomaticClipboard.v1");return value;}
bool safeClipboardSource();bool clipboardMetadataAllowed();void updateContent();
void automaticClipboardReset(){suspendLiveClipboard();clipboardReadSafety.invalidate();refreshClipboardCandidatePermission(false);automaticClipboardActive=false;advanceAutomaticGeneration();automaticPendingSerial=0;pendingAutomaticCopy.reset();{std::lock_guard<std::mutex>lock(automaticCopySlotMutex);latestAutomaticCopy.reset();}automaticClipboard.reset();}
void refreshAutomaticClipboard(){
 if(!client||stopping){automaticClipboardActive=false;refreshClipboardCandidatePermission(false);return;}try{auto snapshot=client->contentSnapshot();auto group=client->connected()?uuidText(client->group()):"";auto epoch=client->connected()?client->current().at("membership").at("epoch").num():0;auto personal=client->personalEpoch();auto persisted=loadPrivate(privateRoot/L"content-v1.dpapi");require(persisted.at("group").str()==snapshot.at("group").str()&&persisted.at("epoch").num()==snapshot.at("epoch").num()&&persisted.at("clipboardEnabled").boolean()==snapshot.at("clipboardEnabled").boolean(),"auto clipboard persisted sharing changed");
 if(!automaticClipboard){auto file=privateRoot/L"auto-clipboard-v1.dpapi";automaticClipboard=std::make_unique<AutomaticClipboard>(std::filesystem::exists(file)?loadPrivate(file):Json(),[file](const Json&j){PersonalDataLock lock(privateRoot);auto reset=loadPrivate(privateRoot/L"personal-reset-v1.dpapi");require(client&&!reset.at("pending").boolean()&&reset.at("epoch").str()==j.at("personal").str()&&client->personalEpoch()==j.at("personal").str(),"auto clipboard personal epoch changed");require(client->connected()?j.at("group").str()==uuidText(client->group())&&j.at("epoch").num()==client->current().at("membership").at("epoch").num():j.at("group").str().empty(),"auto clipboard membership changed");savePrivate(file,j);});}
 bool permission=false;if(client->connected())for(const auto&member:client->current().at("membership").at("members").items)if(parseId(member.at("device").str())==client->keys().device)permission=(member.at("permissions").num()&2)!=0;bool changed=automaticClipboard->configure(group,epoch,personal,client->connected()&&permission&&snapshot.at("clipboardEnabled").boolean());if(!automaticClipboard->enabled()||automaticClipboardRequestedOff)client->cancelAutomaticSharedText();bool active=automaticClipboard->active()&&!automaticClipboardUserPaused;refreshClipboardCandidatePermission(active&&!automaticClipboardRequestedOff);
 if(changed||automaticClipboardActive.load()!=active){automaticClipboardActive=false;const auto newGeneration=advanceAutomaticGeneration();clipboardReadSafety.invalidate();automaticBaselineSequence=GetClipboardSequenceNumber();automaticPendingSerial=0;pendingAutomaticCopy.reset();{std::lock_guard<std::mutex>lock(automaticCopySlotMutex);latestAutomaticCopy.reset();}lastAutomaticSyncSerial=clipboardLocalSerial.load();automaticClipboardActive=active;if(active&&!fixtureMode){auto*probe=new ClipboardBaselineProbe{newGeneration,automaticBaselineSequence.load()};if(!PostMessageW(window,ClipboardBaselineProbeMessage,0,reinterpret_cast<LPARAM>(probe)))delete probe;}}
 refreshLiveClipboard();
 }catch(...){suspendLiveClipboard();refreshClipboardCandidatePermission(false);automaticClipboardActive=false;advanceAutomaticGeneration();throw;}
}
bool clipboardSharingPending(){auto snapshot=client->contentSnapshot();for(const auto&wire:snapshot.at("outgoing").items)if(wire.at("domain").num()==2&&(!clipboardLive||!clipboardLive->knows(parseId(wire.at("sender").str()),parseId(wire.at("event").str())))){legacyClipboardPending=true;return true;}legacyClipboardPending=false;return false;}
bool queueAutomaticCopy(){
 if(!pendingAutomaticCopy)return false;const auto copy=*pendingAutomaticCopy;
 if(!automaticClipboardActive||copy.generation!=automaticClipboardGeneration||copy.serial!=clipboardLocalSerial){pendingAutomaticCopy.reset();uint64_t expected=copy.serial;automaticPendingSerial.compare_exchange_strong(expected,0);return false;}
 try{client->sendSharedText(copy.text,true);}catch(const JsonError&e){if(std::string(e.what())=="content outbox full")return false;throw;}
 pendingAutomaticCopy.reset();uint64_t expected=copy.serial;automaticPendingSerial.compare_exchange_strong(expected,0);return true;
}
void takeAutomaticCopy(){std::optional<PendingAutomaticCopy>copy;{std::lock_guard<std::mutex>lock(automaticCopySlotMutex);copy=std::move(latestAutomaticCopy);latestAutomaticCopy.reset();}if(!copy)return;refreshAutomaticClipboard();if(automaticClipboardActive&&copy->generation==automaticClipboardGeneration&&copy->serial==clipboardLocalSerial){pendingAutomaticCopy=std::move(copy);queueAutomaticCopy();lastContentSync=0;}else{uint64_t expected=copy->serial;automaticPendingSerial.compare_exchange_strong(expected,0);}}
void automaticReceived(uint64_t generation,uint64_t serial,DWORD sequence,bool localActivity){
 refreshAutomaticClipboard();if(!automaticClipboard||!automaticClipboard->active()||!automaticClipboardActive)return;
 const auto&observation=client->lastContentSyncObservation;if(clipboardLive){auto context=liveClipboardContext();for(const auto&wire:observation.legacyShared)clipboardLive->importLegacy(wire,false,context);}
 std::vector<Json>unique;for(const auto&row:observation.newShared)if(!clipboardLive||!clipboardLive->knows(parseId(row.at("sender").str()),parseId(row.at("event").str())))unique.push_back(row);bool blocked=!clipboardReadSafety.allows(sequence,generation)||localActivity||generation!=automaticClipboardGeneration||serial!=clipboardLocalSerial||sequence!=GetClipboardSequenceNumber()||automaticPendingSerial!=0||pendingAutomaticCopy.has_value()||clipboardSharingPending();
 auto candidate=automaticClipboard->observe(unique,observation.drained&&observation.received==0,blocked,uuidText(client->keys().device));
 if(candidate&&!fixtureMode){auto*request=new AutomaticApplyRequest{*candidate,generation,serial,sequence,0};if(!PostMessageW(window,AutomaticClipboardApplyMessage,0,reinterpret_cast<LPARAM>(request)))delete request;}
 lastAutomaticSyncSerial=clipboardLocalSerial.load();
}
void syncContentWithAutomaticClipboard(){
 lastContentAttempt=unixTime();refreshAutomaticClipboard();const auto generation=automaticClipboardGeneration.load(),serial=clipboardLocalSerial.load();const auto sequence=GetClipboardSequenceNumber();
 bool localActivity=!clipboardReadSafety.allows(sequence,generation)||sequence!=clipboardHandledSequence.load()||serial!=lastAutomaticSyncSerial||automaticPendingSerial!=0||pendingAutomaticCopy.has_value()||clipboardSharingPending();client->lastContentSyncObservation={};
 queueAutomaticCopy();
 bool observed=false;try{client->syncContent([&]{observed=true;automaticReceived(generation,serial,sequence,localActivity);});}catch(...){if(!observed)automaticReceived(generation,serial,sequence,localActivity);throw;}
 if(!observed)automaticReceived(generation,serial,sequence,localActivity);if(queueAutomaticCopy())lastContentSync=0;
}
// Provider history/cloud-monitoring hints do not alter this application's
// independently authorized clipboard collection or group forwarding. Actual
// clipboard access, password/desktop checks and generation fences stay below.
bool automaticMarkerMatches(const std::string&text){
 auto actualDigest=sha256(bytes(text));auto actualHash=base64(Data(actualDigest.begin(),actualDigest.end()));if(GetClipboardOwner()==window&&!automaticWriteEvent.empty()&&actualHash==automaticWriteHash)return true;HANDLE h=GetClipboardData(automaticMarkerFormat());if(!h||GlobalSize(h)<sizeof(AutomaticClipboardMarker)||GlobalSize(h)>4096)return false;auto*p=static_cast<AutomaticClipboardMarker*>(GlobalLock(h));if(!p)return false;auto marker=*p;GlobalUnlock(h);if(marker.magic!=0x3441484c||marker.nonce!=automaticEchoNonce||!memchr(marker.event,0,sizeof(marker.event))||!memchr(marker.hash,0,sizeof(marker.hash)))return false;
 auto digest=sha256(bytes(text));auto hash=base64(Data(digest.begin(),digest.end()));const bool same=automaticWriteHash==marker.hash&&hash==marker.hash;return clipboardEchoFence(GetClipboardSequenceNumber(),automaticWriteSequence,same,automaticWriteEvent==marker.event&&marker.nonce==automaticEchoNonce);
}
bool automaticRequestCurrent(const AutomaticApplyRequest&r){return clipboardReadSafety.allows(r.sequence,r.generation)&&GetClipboardSequenceNumber()==clipboardHandledSequence.load()&&clipboardApplyFence(automaticClipboardActive,automaticClipboardGeneration,r.generation,clipboardLocalSerial,r.serial,GetClipboardSequenceNumber(),r.sequence,automaticPendingSerial!=0,r.sequence==0);}
void applyAutomaticClipboard(std::unique_ptr<AutomaticApplyRequest>request){
 if(!request||!automaticRequestCurrent(*request))return;if(!safeClipboardSource()||!automaticMarkerFormat()){clipboardReadSafety.observe(request->sequence,GetClipboardSequenceNumber(),request->generation,automaticClipboardGeneration,ClipboardReadSafety::Observation::denied);clearClipboardCandidate();return;}
 auto text=request->item.at("text").str();if(!private_input::clipboardCandidateTextAllowed(text))return;auto value=wide(text);
 HGLOBAL data=GlobalAlloc(GMEM_MOVEABLE|GMEM_ZEROINIT,(value.size()+1)*sizeof(wchar_t)),metadata=GlobalAlloc(GMEM_MOVEABLE|GMEM_ZEROINIT,sizeof(AutomaticClipboardMarker));if(!data||!metadata){if(data)GlobalFree(data);if(metadata)GlobalFree(metadata);return;}
 auto*characters=static_cast<wchar_t*>(GlobalLock(data));auto*marker=static_cast<AutomaticClipboardMarker*>(GlobalLock(metadata));if(!characters||!marker){if(characters)GlobalUnlock(data);if(marker)GlobalUnlock(metadata);GlobalFree(data);GlobalFree(metadata);return;}
 memcpy(characters,value.c_str(),(value.size()+1)*sizeof(wchar_t));*marker={};marker->nonce=automaticEchoNonce;auto event=request->item.at("event").str(),sender=request->item.at("sender").str(),hash=request->item.at("hash").str();if(event.size()!=36||sender.size()!=36||hash.size()!=44){GlobalUnlock(data);GlobalUnlock(metadata);GlobalFree(data);GlobalFree(metadata);return;}memcpy(marker->event,event.c_str(),37);memcpy(marker->sender,sender.c_str(),37);memcpy(marker->hash,hash.c_str(),45);GlobalUnlock(data);GlobalUnlock(metadata);
 if(!OpenClipboard(window)){clipboardReadSafety.observe(request->sequence,GetClipboardSequenceNumber(),request->generation,automaticClipboardGeneration,ClipboardReadSafety::Observation::denied);clearClipboardCandidate();scheduleClipboardReadRetry(request->sequence,request->generation,request->sequence==automaticBaselineSequence.load());GlobalFree(data);GlobalFree(metadata);return;}
 if(!automaticRequestCurrent(*request)||!safeClipboardSource()||!clipboardMetadataAllowed()){clipboardReadSafety.observe(request->sequence,GetClipboardSequenceNumber(),request->generation,automaticClipboardGeneration,ClipboardReadSafety::Observation::denied);clearClipboardCandidate();CloseClipboard();GlobalFree(data);GlobalFree(metadata);return;}
 // A second channel/owner may already have applied this exact event. Check
 // its board-bound origin and actual text while the same clipboard version is
 // still held. Adoption updates arbitration only: no OS write/candidate publish.
 bool alreadyApplied=false;HANDLE origin=GetClipboardData(automaticMarkerFormat());auto*old=origin&&GlobalSize(origin)>=sizeof(AutomaticClipboardMarker)&&GlobalSize(origin)<=4096?static_cast<AutomaticClipboardMarker*>(GlobalLock(origin)):nullptr;
 if(old){auto m=*old;GlobalUnlock(origin);if(m.magic==0x3441484c&&memchr(m.event,0,sizeof(m.event))&&memchr(m.sender,0,sizeof(m.sender))&&memchr(m.hash,0,sizeof(m.hash))){HANDLE original=GetClipboardData(CF_UNICODETEXT);auto size=original?GlobalSize(original):0;auto*body=size>=2&&size<=131074&&size%2==0?static_cast<const wchar_t*>(GlobalLock(original)):nullptr;bool sameText=false;if(body){size_t count=0;while(count<size/2&&body[count])++count;sameText=count<size/2&&count==value.size()&&std::equal(value.begin(),value.end(),body);GlobalUnlock(original);}alreadyApplied=clipboardOriginMatches(m.version,m.event,m.sender,m.hash,event,sender,hash,sameText,GetClipboardSequenceNumber(),request->sequence);}}
 if(alreadyApplied&&automaticRequestCurrent(*request)){automaticWriteEvent=event;automaticWriteHash=hash;automaticWriteSequence=request->sequence;clipboardSequence=request->sequence;clipboardHandledSequence=request->sequence;CloseClipboard();GlobalFree(data);GlobalFree(metadata);return;}
 if(!automaticRequestCurrent(*request)||!safeClipboardSource()||!clipboardMetadataAllowed()){clipboardReadSafety.observe(request->sequence,GetClipboardSequenceNumber(),request->generation,automaticClipboardGeneration,ClipboardReadSafety::Observation::denied);clearClipboardCandidate();CloseClipboard();GlobalFree(data);GlobalFree(metadata);return;}
 bool okay=EmptyClipboard()!=FALSE;if(okay)okay=SetClipboardData(CF_UNICODETEXT,data)!=nullptr;if(okay){data=nullptr;if(SetClipboardData(automaticMarkerFormat(),metadata))metadata=nullptr;automaticWriteEvent=event;automaticWriteHash=hash;automaticWriteSequence=GetClipboardSequenceNumber();clipboardSequence=automaticWriteSequence;clipboardHandledSequence=automaticWriteSequence;}CloseClipboard();if(okay){bool safe=clipboardReadSafety.observe(automaticWriteSequence,GetClipboardSequenceNumber(),request->generation,automaticClipboardGeneration,ClipboardReadSafety::Observation::stableText);cancelClipboardReadRetry();if(safe)publishClipboardCandidate(value,text,automaticWriteSequence);}else{clipboardReadSafety.observe(GetClipboardSequenceNumber(),GetClipboardSequenceNumber(),request->generation,automaticClipboardGeneration,ClipboardReadSafety::Observation::denied);clearClipboardCandidate();}if(data)GlobalFree(data);if(metadata)GlobalFree(metadata);
}
