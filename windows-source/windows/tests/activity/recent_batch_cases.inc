void recentBatchPersistenceTests(){
 auto path=fixtureRoot/"recent-batch";const std::string text="合成批次",reading="he cheng pi ci";unsigned flushes=0;uint64_t datedBeforeRestart=0;
 auto row=[&](const Json&state){for(const auto&e:state.at("archive").at("entries").items)if(e.at("word").at("text").str()==text)return e;throw JsonError("synthetic recent batch row missing");};
 auto dates=[&](const Json&entry){uint64_t n=0;for(const auto&b:entry.at("buckets").items)for(const auto&c:b.at("counts").fields)n+=c.second.num();return n;};
 {
  GroupClient owner(path);owner.create("https://relay.example.invalid");owner.consentContent(true,true);tick+=600001;owner.syncContent();const auto original=loadPrivate(path/"recent-v2.dpapi").dump();owner.learningTiming=[&](const char*stage,uint64_t,unsigned){if(std::string(stage)=="recent_flush")++flushes;};
  for(unsigned i=0;i<3;++i)owner.recordContent(reading,text);check(flushes==0&&loadPrivate(path/"recent-v2.dpapi").dump()==original);check(owner.flushRecentLearning(true)&&flushes==1);auto once=loadPrivate(path/"recent-v2.dpapi");check(dates(row(once))==3);
  owner.recordContent(reading,text);failSavePath=path/"recent-v2.dpapi";afterContentSave=[]{throw JsonError("synthetic post-rename derived failure");};bool failed=false;try{owner.flushRecentLearning(true);}catch(const JsonError&){failed=true;}check(failed);auto committed=loadPrivate(path/"recent-v2.dpapi");check(dates(row(committed))==4);check(owner.flushRecentLearning(true));check(loadPrivate(path/"recent-v2.dpapi").dump()==committed.dump());
  owner.recordContent(reading,text);datedBeforeRestart=dates(row(committed));
 }
 {GroupClient reopened(path);check(reopened.flushRecentLearning(true));auto saved=loadPrivate(path/"recent-v2.dpapi");auto entry=row(saved);uint64_t total=0;for(const auto&c:entry.at("word").at("counts").fields)total+=c.second.num();check(total==5&&dates(entry)==datedBeforeRestart);}
 std::cout<<"PASS actual GroupClient per-event durable counts, batched derived save, ambiguous-save idempotence, restart-undated recovery\n";
}

void clipboardDuringLearningDeferralTests(){
 GroupClient a(fixtureRoot/"deferred-learning-owner"),b(fixtureRoot/"deferred-learning-peer");a.create("https://relay.example.invalid");auto ticket=a.makeTicket();b.join("https://relay.example.invalid",ticket.at("code").str());check(a.pollAdmissions());b.pollJoin();a.consentContent(true,true);b.consentContent(true,true);a.recordContent("he cheng","合成");a.sendSharedText("合成剪贴板");auto before=recentRequests;a.syncContent({},false);b.syncContent({},false);auto received=b.contentSnapshot();check(received.at("texts").items.size()==1&&received.at("texts").items.front().at("text").str()=="合成剪贴板");check(received.at("archive").at("entries").items.empty()&&recentRequests==before);a.syncContent();b.syncContent();check(b.contentSnapshot().at("archive").at("entries").items.size()==1&&recentRequests>before);a.consentContent(true,false);offline=true;a.syncContent({},false);offline=false;std::cout<<"PASS clipboard domain continues while old learning transport/recency is deferred; later learning sync resumes\n";
}
