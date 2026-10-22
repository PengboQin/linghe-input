// Parent backend alone owns credentials/consent. The independent thread receives
// a limited descriptor and only accesses its own DPAPI state and live endpoint.
constexpr UINT ClipboardLiveCacheMessage=WM_APP+9;
struct ClipboardLiveCacheUpdate {uint64_t generation;std::string scope;Json texts;};
std::string liveProcessIdentity;uint64_t lastLiveRevokeAttempt=0;Json liveParentState;std::shared_ptr<const ClipboardLiveAuthority>liveParentAuthority;
std::filesystem::path liveDirectory(){return privateRoot/L"ClipboardLive";}
void suspendLiveClipboard(){if(clipboardLive)clipboardLive->setAuthority({});}
ClipboardLiveContext liveClipboardContext(){auto generation=automaticClipboardGeneration.load(),serial=clipboardLocalSerial.load();auto sequence=GetClipboardSequenceNumber();return {generation,serial,sequence,automaticClipboardActive&&!automaticClipboardRequestedOff&&!automaticClipboardUserPaused&&!stopping,clipboardReadSafety.allows(sequence,generation)&&sequence==clipboardHandledSequence.load(),automaticPendingSerial!=0||legacyClipboardPending.load()};}
void initializeLiveClipboard(){
 if(fixtureMode)return;liveProcessIdentity=uuidText(newId());std::filesystem::create_directories(liveDirectory());ClipboardLiveCallbacks c;c.context=liveClipboardContext;c.authorize=[](const ClipboardLiveGrant&g){try{auto automatic=loadPrivate(privateRoot/L"auto-clipboard-v1.dpapi"),sharing=loadPrivate(privateRoot/L"content-v1.dpapi"),reset=loadPrivate(privateRoot/L"personal-reset-v1.dpapi");return automatic.at("enabled").boolean()&&automatic.at("group").str()==uuidText(g.group)&&automatic.at("epoch").num()==g.epoch&&automatic.at("personal").str()==g.personal&&sharing.at("clipboardEnabled").boolean()&&sharing.at("group").str()==uuidText(g.group)&&sharing.at("epoch").num()==g.epoch&&!reset.at("pending").boolean()&&reset.at("epoch").str()==g.personal;}catch(...){return false;}};c.load=[]{auto file=liveDirectory()/L"state-v1.dpapi";return std::filesystem::exists(file)?loadPrivate(file):Json();};c.save=[](const Json&j){savePrivate(liveDirectory()/L"state-v1.dpapi",j);};
 c.status=[](const ClipboardLiveGrant&g){return clipboardLiveHTTP(g.endpoint,"/clipboard-live/v1/status");};c.batch=[](const ClipboardLiveGrant&g,const Json&j){return clipboardLiveHTTP(g.endpoint,"/clipboard-live/v1/batch",&j);};
 c.apply=[](const Json&item,const ClipboardLiveContext&context){auto*request=new AutomaticApplyRequest{item,context.generation,context.serial,context.sequence,0};if(!PostMessageW(window,AutomaticClipboardApplyMessage,0,reinterpret_cast<LPARAM>(request)))delete request;};
 c.accepted=[](uint64_t serial){uint64_t expected=serial;automaticPendingSerial.compare_exchange_strong(expected,0);};
 c.cache=[](const Json&texts,const std::string&scope,uint64_t generation){auto*update=new ClipboardLiveCacheUpdate{generation,scope,texts};if(!PostMessageW(window,ClipboardLiveCacheMessage,0,reinterpret_cast<LPARAM>(update)))delete update;};
 c.compatibilityReady=[]{liveRefreshRequested=true;actionWake.notify_one();};c.health=[](int value){if(value==-2){automaticClipboardActive=false;advanceAutomaticGeneration();refreshClipboardCandidatePermission(false);suspendLiveClipboard();liveAuthorityRejected=true;liveRefreshRequested=true;actionWake.notify_one();}};
 clipboardLive=std::make_unique<ClipboardLiveWorker>(std::move(c));
}
void saveLiveParent(){savePrivate(liveDirectory()/L"parent-v1.dpapi",liveParentState);}
void retireLiveDescriptor(){
 suspendLiveClipboard();std::atomic_store(&liveParentAuthority,std::shared_ptr<const ClipboardLiveAuthority>{});if(liveParentState.kind==Json::Kind::null)return;
 auto next=liveParentState;if(next.at("descriptor").kind!=Json::Kind::null){auto&rows=next["revokes"].items;require(rows.size()<64,"live revoke quota");auto&g=next.at("descriptor");rows.push_back(Json::object({{"certificate",g.at("certificate")},{"endpoint",g.at("endpoint")}}));next["descriptor"]=Json();next["scope"]="";savePrivate(liveDirectory()/L"parent-v1.dpapi",next);liveParentState=next;}
}
void refreshLiveClipboard(){
 if(!clipboardLive||!client)return;auto file=liveDirectory()/L"parent-v1.dpapi";
 if(liveParentState.kind==Json::Kind::null){liveParentState=std::filesystem::exists(file)?loadPrivate(file):Json::object({{"version",1},{"lastIssuedAt",0},{"scope",""},{"descriptor",Json()},{"revokes",Json::array()}});require(liveParentState.at("version").num()==1&&liveParentState.at("revokes").items.size()<=64,"live parent state");}
 bool enabled=automaticClipboardActive&&!automaticClipboardRequestedOff&&!automaticClipboardUserPaused&&!stopping;
 auto descriptor=liveParentState.at("descriptor");bool matches=enabled&&descriptor.kind!=Json::Kind::null&&client->clipboardLiveAuthorityMatches(descriptor);
 bool renewing=matches&&descriptor.at("certificate").at("expiresAt").num()<=unixTime()+86400;
 if(!enabled||!matches||renewing){
  // Never replace a certificate while its sealed event is in flight. A normal
  // grant lasts 30 days; retry the renewal after that bounded outbox settles.
  if(renewing&&clipboardLive->pending())return;
  auto oldScope=liveParentState.at("scope").str();retireLiveDescriptor();
  if(enabled){auto next=liveParentState;auto issued=std::max(unixTime(),next.at("lastIssuedAt").num()+1);auto scope=renewing?oldScope:uuidText(newId());auto grant=client->clipboardLiveAuthority(scope,issued);next["lastIssuedAt"]=issued;next["scope"]=scope;next["descriptor"]=grant;savePrivate(file,next);liveParentState=next;descriptor=grant;matches=true;}
 }
 if(enabled&&matches){auto current=std::atomic_load(&liveParentAuthority);auto generation=automaticClipboardGeneration.load();if(!current||current->generation!=generation||current->grant->generation!=parseId(descriptor.at("generation").str())){auto authority=std::make_shared<ClipboardLiveAuthority>();authority->grant=std::make_shared<ClipboardLiveGrant>(ClipboardLiveGrant::decode(descriptor,unixTime()));authority->generation=generation;authority->incarnation=liveProcessIdentity;std::shared_ptr<const ClipboardLiveAuthority>immutable=authority;std::atomic_store(&liveParentAuthority,immutable);clipboardLive->setAuthority(immutable);}}
}
void maintainLiveClipboard(){
 if(!clipboardLive||!client)return;if(liveAuthorityRejected.exchange(false)){suspendLiveClipboard();client->refresh();retireLiveDescriptor();refreshAutomaticClipboard();}refreshLiveClipboard();liveRefreshRequested=false;
 if(automaticClipboardActive&&!automaticClipboardRequestedOff){auto snapshot=clipboardLive->snapshot();auto authority=std::atomic_load(&liveParentAuthority);if(authority&&snapshot->at("scope").str()==authority->grant->scope){for(const auto&row:snapshot->at("compat").items){if(row.at("expiresAt").num()<=unixTime())continue;client->sendClipboardCompatibility(row.at("text").str(),parseId(row.at("event").str()),row.at("expiresAt").num());if(!clipboardLive->knows(authority->grant->parent,parseId(row.at("event").str())))legacyClipboardPending=true;if(row.has("context")&&row.at("context").kind==Json::Kind::object&&row.at("context").at("generation").num()==automaticClipboardGeneration.load()&&row.at("context").has("incarnation")&&row.at("context").at("incarnation").str()==liveProcessIdentity){uint64_t expected=row.at("context").at("serial").num();automaticPendingSerial.compare_exchange_strong(expected,0);}clipboardLive->compatibilityQueued(parseId(row.at("event").str()));lastContentSync=0;}}}
 // Re-sign each retry with a fresh nonce/time. No child/TSF primary credentials.
 auto next=liveParentState;bool changed=false;for(auto at=next["revokes"].items.begin();at!=next["revokes"].items.end();){auto cert=at->at("certificate");if(cert.at("expiresAt").num()+300<=unixTime()||!client->connected()||cert.at("group").str()!=uuidText(client->group())||cert.at("epoch").num()!=client->current().at("membership").at("epoch").num()){at=next["revokes"].items.erase(at);changed=true;continue;}if(unixTime()-lastLiveRevokeAttempt<15)break;lastLiveRevokeAttempt=unixTime();try{auto request=client->clipboardLiveRevocation(cert,unixTime());clipboardLiveHTTP(at->at("endpoint").str(),"/clipboard-live/v1/revoke",&request);at=next["revokes"].items.erase(at);changed=true;}catch(...){++at;}break;}
 if(changed){savePrivate(liveDirectory()/L"parent-v1.dpapi",next);liveParentState=next;}
}
