// Included by group_client_host.cpp: the product GroupClient, ContentStore,
// protocol crypto and SQLite relay all execute. Only WinHTTP and DPAPI OS
// boundaries are replaced, with paths restricted to a new owned fixture.
namespace {
struct RecoveryPair {
 fs::path ownerPath,receiverPath;
 std::unique_ptr<GroupClient>owner,receiver;
 uint64_t sequence=1000;Json firstTicket;
 RecoveryPair(const std::string&name):ownerPath(fixtureRoot/(name+"-owner")),receiverPath(fixtureRoot/(name+"-receiver")),owner(new GroupClient(ownerPath)),receiver(new GroupClient(receiverPath)){
  // Each independent scenario has a fresh disposable relay database. Reusing
  // the previous scenario's pairing budget would exercise the unchanged
  // five-attempt rate limit rather than this scenario's recovery condition.
  // No relay process is alive between bridge calls, and these exact files can
  // only be underneath this host's freshly created fixture namespace.
  check(fixtureRoot.filename()=="group-fixture");
  for(const char*name:{"relay.sqlite","relay.sqlite-wal","relay.sqlite-shm"})fs::remove(fixtureRoot/name);
  owner->create("https://relay.example.invalid");owner->consentContent(true,true);
  auto ticket=owner->makeTicket();firstTicket=ticket;receiver->join("https://relay.example.invalid",ticket.at("code").str());check(owner->pollAdmissions());receiver->pollJoin();receiver->consentContent(true,true);
 }
 Json wire(const std::string&payload,unsigned domain=2){
  auto membership=anchorOf(owner->current().at("anchor")).verify(private_input::protocol::decodeMembershipJSON(owner->current().at("membership").dump()));
  auto raw=unbase64(owner->current().at("groupKey").str(),32);Key master;std::copy(raw.begin(),raw.end(),master.begin());
  private_input::protocol::Envelope e;e.group=owner->group();e.sender=owner->keys().device;e.event=newId();e.epoch=membership.statement().epoch;e.sequence=sequence++;e.domain=uint8_t(domain);e.issuedAt=unixTime();e.expiresAt=e.issuedAt+(domain==1?604800:600);
  return encodeContentEnvelope(private_input::protocol::sealOpaquePayload(bytes(payload),e,master,owner->keys().signingSeed,membership.trust(domain==1?private_input::protocol::MembershipDomain::learning:private_input::protocol::MembershipDomain::clipboard)));
 }
 void deliver(const Json&value){auto accepted=post("https://relay.example.invalid","/v1/groups/"+uuidText(owner->group())+"/events",value);check(accepted.at("accepted").boolean());}
 void text(const std::string&value){deliver(wire(value));}
 Json queue(){return post("https://relay.example.invalid","/_fixture/queue",Json::object({{"group",uuidText(owner->group())},{"recipient",uuidText(receiver->keys().device)}}));}
};
template<class F>void rejectsRecovery(F f){bool failed=false;try{f();}catch(const std::exception&){failed=true;}check(failed);}
template<class F>void quotaRecovery(F f){bool failed=false;try{f();}catch(const HTTPError&e){failed=e.status==429&&e.code=="quota";}check(failed);}
std::string bigRecoveryArchive(){
 auto archive=emptyLearning();auto entries=Json::array();
 for(unsigned i=0;i<850;++i){auto reading=std::string("z ");unsigned n=i;do{reading+=char('a'+n%26);n/=26;}while(n);entries.items.push_back(Json::object({{"reading",reading},{"text",std::string(900,'x')},{"generation",0},{"deleted",false},{"counts",Json::object()},{"pinned",false},{"pinVersion",Json::object({{"sequence",0},{"device",""}})}}));}
 archive["entries"]=entries;return validateLearning(archive).dump();
}
void fillRecoveryQueue(RecoveryPair&pair,bool tinyHead){
 if(tinyHead){pair.text("tiny-first");pair.text("tiny-second");}
 const auto large=bigRecoveryArchive();
 for(unsigned i=0;i<64;++i){try{pair.deliver(pair.wire(large,1));}catch(const HTTPError&e){check(e.status==429&&e.code=="quota");break;}}
 for(size_t size:{size_t(65536),size_t(1024)})for(unsigned i=0;i<128;++i){try{pair.text(std::string(size,'p'));}catch(const HTTPError&e){check(e.status==429&&e.code=="quota");break;}}
 auto queue=pair.queue();check(queue.at("messages").num()<256&&queue.at("bytes").num()>32*1024*1024-4096&&queue.at("bytes").num()<=32*1024*1024);
}
}
void queueRecoveryTests(){
 recency=false;
 {
  RecoveryPair pair("full-queue");fillRecoveryQueue(pair,false);pair.receiver->sendSharedText(std::string(65536,'r'));
  auto original=pair.receiver->contentSnapshot().at("outgoing");check(original.items.size()==1);quotaRecovery([&]{pair.deliver(original.items[0]);});
  requestTrace.clear();auto before=pair.queue();pair.receiver->syncContent();auto after=pair.queue();
  check(!requestTrace.empty()&&requestTrace[0]=="pull");auto firstPush=std::find(requestTrace.begin(),requestTrace.end(),"push");check(firstPush!=requestTrace.end()&&std::count(requestTrace.begin(),firstPush,"ack")==2);
  check(pair.receiver->contentSnapshot().at("outgoing").items.empty()&&after.at("bytes").num()<before.at("bytes").num());
  std::cout<<"queue recovery: actual 32 MiB quota, authenticated receive+durable ACK precedes blocked publication passed\n";
 }
 {
  RecoveryPair pair("still-quota");fillRecoveryQueue(pair,true);pair.receiver->sendSharedText(std::string(65536,'r'));auto original=pair.receiver->contentSnapshot().at("outgoing").dump();
  requestTrace.clear();auto acknowledgements=ackAttempts;quotaRecovery([&]{pair.receiver->syncContent();});
  check(ackAttempts==acknowledgements+2&&pair.receiver->contentSnapshot().at("outgoing").dump()==original);
  check(pair.receiver->contentSnapshot().at("texts").items.size()==2);pair.receiver->syncContent();check(pair.receiver->contentSnapshot().at("outgoing").items.empty());
  std::cout<<"queue recovery: still-quota propagates, exact outbox survives and next drain recovers passed\n";
 }
 {
  RecoveryPair pair("bad-signature");pair.text("authenticated-original");pair.receiver->sendSharedText("retained-local-outbox");auto original=pair.receiver->contentSnapshot().at("outgoing").dump();
  corruptPull=true;auto acks=ackAttempts,pushes=pushAttempts;rejectsRecovery([&]{pair.receiver->syncContent();});
  check(ackAttempts==acks&&pushAttempts==pushes&&pair.queue().at("recipients").num()==1&&pair.receiver->contentSnapshot().at("outgoing").dump()==original);pair.receiver->syncContent();check(pair.receiver->contentSnapshot().at("texts").items.size()==1);
  std::cout<<"queue recovery: corrupted authenticated envelope is neither persisted nor ACKed passed\n";
 }
 {
  RecoveryPair pair("disk-failure");pair.text("persist-before-ack");failSavePath=pair.receiverPath/"content-v1.dpapi";failSave=true;
  auto acks=ackAttempts;rejectsRecovery([&]{pair.receiver->syncContent();});auto disk=loadPrivate(failSavePath);
  check(ackAttempts==acks&&disk.at("texts").items.empty()&&disk.at("receipts").fields.empty()&&pair.queue().at("recipients").num()==1);
  failSavePath.clear();pair.receiver->syncContent();check(pair.receiver->contentSnapshot().at("texts").items.size()==1);
  std::cout<<"queue recovery: atomic persistence failure retains server recipient without ACK passed\n";
 }
 {
  RecoveryPair pair("lost-ack");pair.text("persisted-exact-duplicate");loseBeforeAck=true;lost([&]{pair.receiver->syncContent();});
  auto disk=loadPrivate(pair.receiverPath/"content-v1.dpapi");check(disk.at("texts").items.size()==1&&pair.queue().at("recipients").num()==1);
  pair.receiver.reset(new GroupClient(pair.receiverPath));pair.receiver->syncContent();check(pair.receiver->contentSnapshot().at("texts").items.size()==1&&pair.queue().at("recipients").num()==0);
  std::cout<<"queue recovery: restart exact replay reuses durable receipt, ACKs once without duplicate text passed\n";
 }
 {
  RecoveryPair pair("revoked-consent");pair.text("revoked-before-import");afterPull=[&]{pair.receiver->consentContent(false,false);};auto acks=ackAttempts;
  rejectsRecovery([&]{pair.receiver->syncContent();});auto disk=loadPrivate(pair.receiverPath/"content-v1.dpapi");check(ackAttempts==acks&&!disk.at("learningEnabled").boolean()&&!disk.at("clipboardEnabled").boolean()&&disk.at("texts").items.empty()&&pair.queue().at("recipients").num()==1);
  std::cout<<"queue recovery: UI consent revoked during pull is not ACKed passed\n";
 }
 {
  RecoveryPair pair("persisted-revocation");pair.text("revoked-after-import");failSavePath=pair.receiverPath/"content-v1.dpapi";
  afterContentSave=[&]{GroupClient other(pair.receiverPath);other.consentContent(false,false);};auto acks=ackAttempts;rejectsRecovery([&]{pair.receiver->syncContent();});auto disk=loadPrivate(failSavePath);
  check(ackAttempts==acks&&!disk.at("clipboardEnabled").boolean()&&disk.at("texts").items.empty()&&pair.queue().at("recipients").num()==1);failSavePath.clear();
  std::cout<<"queue recovery: independently persisted revocation fences ACK even after memory accepted import passed\n";
 }
 {
  RecoveryPair pair("changed-membership");pair.text("old-epoch-envelope");auto thirdPath=fixtureRoot/"queue-epoch-third";std::unique_ptr<GroupClient>third;bool rotated=false;auto beforeEpoch=pair.receiver->current().at("membership").at("epoch").num();
  afterPull=[&]{third.reset(new GroupClient(thirdPath));auto ticket=pair.owner->makeTicket();third->join("https://relay.example.invalid",ticket.at("code").str());check(pair.owner->pollAdmissions());third->pollJoin();pair.receiver->refresh();rotated=pair.receiver->current().at("membership").at("epoch").num()>beforeEpoch;};auto acks=ackAttempts;
  rejectsRecovery([&]{pair.receiver->syncContent();});check(rotated&&ackAttempts==acks&&loadPrivate(pair.receiverPath/"content-v1.dpapi").at("texts").items.empty());
  std::cout<<"queue recovery: real signed admission rotates membership epoch during pull, old import is not ACKed passed\n";
 }
 {
  RecoveryPair pair("changed-personal-epoch");pair.text("personal-epoch-fence");afterPull=[&]{auto p=pair.receiverPath/"personal-reset-v1.dpapi";auto next=loadPrivate(p);next["epoch"]=uuidText(newId());savePrivate(p,next);};auto acks=ackAttempts;
  rejectsRecovery([&]{pair.receiver->syncContent();});check(ackAttempts==acks&&loadPrivate(pair.receiverPath/"content-v1.dpapi").at("texts").items.empty()&&pair.queue().at("recipients").num()==1);
  std::cout<<"queue recovery: personal reset epoch change during WinHTTP wait fences import and ACK passed\n";
 }
 {
  RecoveryPair pair("repeat-invitation");auto afterFirst=loadPrivate(pair.ownerPath/"group.dpapi");check(!afterFirst.has("ticket")&&!afterFirst.has("ticketRequest")&&!afterFirst.has("pendingAdmission"));
  auto second=pair.owner->makeTicket();check(second.at("ticket").str()!=pair.firstTicket.at("ticket").str()&&second.at("code").str()!=pair.firstTicket.at("code").str());
  GroupClient third(fixtureRoot/"repeat-invitation-third");third.join("https://relay.example.invalid",second.at("code").str());
  failSavePath=pair.ownerPath/"group.dpapi";afterAdmission=[]{failSave=true;};rejectsRecovery([&]{pair.owner->pollAdmissions();});
  auto pending=loadPrivate(failSavePath);check(pending.has("pendingAdmission")&&pending.has("ticketRequest")&&pending.has("ticket"));
  check(pair.owner->current().has("pendingAdmission")&&pair.owner->current().at("pendingAdmission").dump()==pending.at("pendingAdmission").dump());
  failSavePath.clear();check(pair.owner->pollAdmissions());third.pollJoin();check(third.connected());auto completed=loadPrivate(pair.ownerPath/"group.dpapi");
  check(!completed.has("pendingAdmission")&&!completed.has("ticketRequest")&&!completed.has("ticket")&&completed.at("membership").at("members").items.size()==3);
  std::cout<<"admission recovery: same sponsor admits two distinct devices with new code, final disk failure preserves exact retry, ticket/request retire atomically passed\n";
 }
 recency=true;
}

// New 044 GroupClient path, run independently of the expensive quota fixtures.
void automaticPublicationTests(){
 recency=false;
 {
  RecoveryPair pair("auto-publication");pair.receiver->sendSharedText("automatic-raw-text",true);
  auto exact=pair.receiver->contentSnapshot().at("outgoing").dump();auto pushes=pushAttempts;unsigned callbacks=0;
  pair.receiver->allowClipboardPublication=[&](bool automatic){check(automatic);++callbacks;return false;};
  rejectsRecovery([&]{pair.receiver->syncContent();});check(callbacks==1&&pushAttempts==pushes&&pair.receiver->contentSnapshot().at("outgoing").dump()==exact);
  pair.receiver->cancelAutomaticSharedText();pair.receiver->sendSharedText("manual-remains-enabled");
  pair.receiver->allowClipboardPublication=[&](bool automatic){check(!automatic);++callbacks;return true;};pair.receiver->syncContent();
  check(pair.receiver->contentSnapshot().at("outgoing").items.empty()&&callbacks==2);
  std::cout<<"automatic publication: final network consent fence retains exact automatic outbox; cancellation leaves manual domain usable passed\n";
 }
 {
  RecoveryPair pair("auto-observation");pair.text("fresh-durable-observation");pair.receiver->syncContent();auto first=pair.receiver->lastContentSyncObservation;
  check(first.received==1&&first.drained&&first.newShared.size()==1&&first.newShared[0].at("text").str()=="fresh-durable-observation");
  pair.receiver->syncContent();auto empty=pair.receiver->lastContentSyncObservation;check(empty.received==0&&empty.drained&&empty.newShared.empty());
  pair.text("failed-storage-no-observation");failSavePath=pair.receiverPath/"content-v1.dpapi";failSave=true;auto acks=ackAttempts;rejectsRecovery([&]{pair.receiver->syncContent();});
  check(pair.receiver->lastContentSyncObservation.received==1&&pair.receiver->lastContentSyncObservation.newShared.empty()&&ackAttempts==acks);failSavePath.clear();
  std::cout<<"automatic observation: full-pass old backlog count, empty drain barrier and failed durable import never eligible passed\n";
 }
}
