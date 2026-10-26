// Included in GroupClient.cpp's activity namespace. All calls execute on the
// existing backend serial owner; no input callback performs HTTP or full merges.
void GroupClient::invalidateCloudRank(){cloudCacheLoaded=false;
#ifdef _WIN32
 if(root.lexically_normal()==(userRoot()/L"Activity").lexically_normal())revokeCloudRankIPC();
#endif
}
std::string GroupClient::cloudScope()const{require(connected(),"cloud requires group");return Json::object({{"endpoint",state.at("relayEndpoint")},{"group",uuidText(group())},{"epoch",state.at("membership").at("epoch")},{"personal",personalEpoch()},{"installation",state.at("installation")},{"key",base64(raw(publicKey(identity.signingSeed)))}}).dump();}
Json GroupClient::cloudRPC(uint8_t operation,const Json&body){auto envelope=cloudLearningRequest(group(),identity,operation,body,unixTime());auto response=post(state.at("relayEndpoint").str(),"/v1/learning/rpc",envelope);require(response.at("version").num()==1&&response.at("operation").num()==operation,"cloud response operation");return response.at("result");}
Json GroupClient::cloudLearningStatus(){auto p=root/L"cloud-learning-permission-v1.dpapi";if(!std::filesystem::exists(p))return Json::object({{"enabled",false},{"shadowOnly",true},{"pendingRevoke",false}});auto control=loadPrivate(p);bool valid=connected()&&control.at("scope").str()==cloudScope();return Json::object({{"enabled",valid&&control.at("enabled").boolean()},{"shadowOnly",true},{"pendingRevoke",control.at("pendingRevoke").boolean()}});}
void GroupClient::consentCloudLearning(bool enabled,bool configureGroup){auto permission=root/L"cloud-learning-permission-v1.dpapi";Json control=std::filesystem::exists(permission)?loadPrivate(permission):Json::object({{"version",1},{"scope",connected()?cloudScope():""},{"enabled",false},{"pendingRevoke",false}});
 if(!enabled){control["enabled"]=false;control["rankAuthorized"]=false;control["rankToken"]=uuidText(newId());control["pendingRevoke"]=true;{PersonalDataLock lock(root);savePrivate(permission,control);}
#ifdef _WIN32
 if(root.lexically_normal()==(userRoot()/L"Activity").lexically_normal())revokeCloudRankIPC();
#endif
 cloudCacheLoaded=false;cloudSyncBudget.reset();syncCloudShadow();return;}
 require(connected()&&contentStore().learningEnabled(),"enable learning sharing before cloud shadow");
 const auto scope=cloudScope();
 // A durable attempt token prevents an in-flight enable from overwriting a
 // later local disable (including another same-user CLI/process).
 auto attempt=Json::object({{"version",1},{"scope",scope},{"enabled",false},{"pendingRevoke",false},{"attempt",uuidText(newId())}});
 {PersonalDataLock lock(root);savePrivate(permission,attempt);}invalidateCloudRank();
 auto unchanged=[&]{require(cloudScope()==scope&&loadPrivate(permission).dump()==attempt.dump(),"cloud opt-in superseded");};
 auto request=[&](uint8_t op,const Json&body){unchanged();auto result=cloudRPC(op,body);unchanged();return result;};
 try{
  auto status=request(1,Json::object());
  require(status.at("algorithm_version").str()=="shared-lexeme-decay-v2","cloud algorithm unsupported");
  if(!status.at("enabled").boolean()){
   require(configureGroup,"cloud group disabled");
   status=request(2,Json::object({{"expected_version",status.at("policy_version")},{"enabled",true}}));
  }
  auto c=status.at("consent");
  status=request(3,Json::object({{"expected_version",c.kind==Json::Kind::null?Json(0):c.at("version")},{"enabled",true},{"installation_id",state.at("installation")}}));
  require(status.at("enabled").boolean(),"cloud consent group changed");c=status.at("consent");
  require(c.at("enabled").boolean()&&c.at("installation_id").str()==state.at("installation").str(),"cloud consent binding");
  control=Json::object({{"version",1},{"scope",scope},{"enabled",true},{"pendingRevoke",false},{"generation",status.at("generation")},{"consent",c.at("version")}});
  {PersonalDataLock lock(root);unchanged();savePrivate(permission,control);savePrivate(root/L"cloud-learning-shadow-v1.dpapi",CloudLearningShadow::initial(scope));}
  cloudSyncBudget.reset();
 }catch(...){
  // A server-side enable may have succeeded before a lost response. Keep a
  // durable cleanup request, without reviving a superseding local choice.
  try{PersonalDataLock lock(root);auto latest=loadPrivate(permission);if(latest.dump()==attempt.dump()){latest["pendingRevoke"]=true;savePrivate(permission,latest);invalidateCloudRank();}}catch(...){}
  throw;
 }
}
// Local, metadata-only trace of the optional cloud pass (no words/readings):
// why a device never reaches shadowReady was previously invisible.
static void cloudTrace(const std::filesystem::path&root,const std::string&line){try{auto file=root/L"cloud-learning-trace.txt";if(std::filesystem::exists(file)&&std::filesystem::file_size(file)>65536)std::filesystem::remove(file);std::ofstream out(file,std::ios::app|std::ios::binary);out<<std::time(nullptr)<<' '<<line<<'\n';}catch(...){}}
void GroupClient::syncCloudShadow(){auto permission=root/L"cloud-learning-permission-v1.dpapi";if(!connected()||!std::filesystem::exists(permission))return;auto control=loadPrivate(permission);const auto scope=cloudScope();if(control.at("scope").str()!=scope){if(control.at("enabled").boolean()){control["enabled"]=false;control["pendingRevoke"]=true;PersonalDataLock lock(root);savePrivate(permission,control);invalidateCloudRank();}return;}if(!control.at("enabled").boolean()&&!control.at("pendingRevoke").boolean())return;if(!cloudSyncBudget.begin(scope+control.dump(),monotonicMilliseconds()))return;cloudTrace(root,std::string("attempt enabled=")+(control.at("enabled").boolean()?"1":"0"));
 try{auto status=cloudRPC(1,Json::object());if(!control.at("enabled").boolean()){auto c=status.at("consent");if(c.kind!=Json::Kind::null&&c.at("enabled").boolean())cloudRPC(3,Json::object({{"expected_version",c.at("version")},{"enabled",false},{"installation_id",state.at("installation")}}));auto latest=loadPrivate(permission);require(latest.at("scope").str()==scope&&!latest.at("enabled").boolean(),"cloud revocation changed");latest["pendingRevoke"]=false;{PersonalDataLock lock(root);savePrivate(permission,latest);invalidateCloudRank();}cloudSyncBudget.finish(monotonicMilliseconds(),true);return;}
 auto c=status.at("consent");require(status.at("enabled").boolean()&&status.at("algorithm_version").str()=="shared-lexeme-decay-v2"&&status.at("generation").num()==control.at("generation").num()&&c.kind==Json::Kind::object&&c.at("enabled").boolean()&&c.at("version").num()==control.at("consent").num()&&c.at("installation_id").str()==state.at("installation").str(),"cloud authorization requires explicit renewal");
 const auto membership=verified().canonicalBytes();auto fence=[&]{require(cloudScope()==scope&&contentStore().learningEnabled(),"cloud local scope changed");auto disk=loadPrivate(permission);require(disk.dump()==control.dump()&&disk.at("enabled").boolean(),"cloud locally revoked");auto reset=loadPrivate(root/L"personal-reset-v1.dpapi");require(!reset.at("pending").boolean()&&reset.at("epoch").str()==personalEpoch(),"cloud personal reset");auto saved=loadPrivate(root/L"group.dpapi");require(verified().anchor().verify(protocol::decodeMembershipJSON(saved.at("membership").dump())).canonicalBytes()==membership,"cloud membership changed");auto sharing=loadPrivate(root/L"content-v1.dpapi");require(sharing.at("learningEnabled").boolean(),"cloud learning sharing revoked");};
 fence();auto shadowFile=root/L"cloud-learning-shadow-v1.dpapi";auto saved=std::filesystem::exists(shadowFile)?loadPrivate(shadowFile):CloudLearningShadow::initial(scope);if(saved.at("scope").str()!=scope)saved=CloudLearningShadow::initial(scope);CloudLearningShadow shadow(saved,[&](const Json&next){PersonalDataLock lock(root);fence();savePrivate(shadowFile,next);cloudShadowCache=next;cloudShadowLoaded=true;});std::vector<std::string>producers{uuidText(identity.device)};auto legacy=root/L"legacy-rime-replica-v1.dpapi";if(!legacyRetired()&&std::filesystem::exists(legacy)){auto seed=loadPrivate(legacy);require(seed.at("version").num()==1,"legacy cloud producer version");auto actor=uuidText(parseId(seed.at("replica").str()));if(actor!=producers.front())producers.push_back(actor);}
 shadow.synchronize(contentStore().current().at("archive"),producers,control.at("generation").num(),control.at("consent").num(),state.at("installation").str(),[&](uint8_t op,const Json&body){fence();auto result=cloudRPC(op,body);fence();return result;});cloudSyncBudget.finish(monotonicMilliseconds(),shadow.state.has("localComponentsComplete")&&shadow.state.at("localComponentsComplete").boolean());cloudTrace(root,std::string("shadow complete=")+(shadow.state.has("localComponentsComplete")&&shadow.state.at("localComponentsComplete").boolean()?"1":"0")+" ready="+(shadow.state.has("shadowReady")&&shadow.state.at("shadowReady").boolean()?"1":"0"));
 // P5 personal records (ops 8/9): pull, then upload records the server has not
 // acknowledged. Fully isolated: no failure here may revoke cloud learning.
 try{
  auto personalFile=root/L"cloud-personal-v1.dpapi";const auto personalScope=scope+"/"+std::to_string(control.at("generation").num())+"/"+std::to_string(control.at("consent").num())+"/"+personalEpoch();
  Json progress=std::filesystem::exists(personalFile)?loadPrivate(personalFile):Json();
  if(!progress.has("scope")||progress.at("scope").str()!=personalScope)progress=Json::object({{"version",1},{"scope",personalScope},{"pulled",0},{"acked",Json::object()}});
  auto recordDigest=[](const Json&r){auto h=sha256(bytes(r.dump()));return base64(Data(h.begin(),h.end()));};
  auto base=Json::object({{"generation",control.at("generation")},{"consent_version",control.at("consent")},{"installation_id",state.at("installation")}});
  auto save=[&]{PersonalDataLock lock(root);fence();savePrivate(personalFile,progress);};
  for(int page=0;page<16;page++){
   auto body=base;body["after_version"]=progress.at("pulled");body["limit"]=256;fence();auto pulled=cloudRPC(9,body);fence();
   Json incoming=Json::object();for(const auto&row:pulled.at("records").items){auto r=row;auto id=r.at("id").str();r.fields.erase("id");progress["acked"][id]=recordDigest(r);incoming[id]=r;}
   if(!incoming.fields.empty()){auto archive=contentStore().current().at("archive");archive["entries"]=Json::array();archive["personalLexicon"]=Json::object({{"version",1},{"records",incoming}});contentStore().mergeRemoteLearning(archive);}
   progress["pulled"]=pulled.at("next_version");save();if(!pulled.at("has_more").boolean())break;
  }
  auto archive=contentStore().current().at("archive");std::vector<Json>pending;
  auto upload=[&]{if(pending.empty())return;auto body=base;body["records"]=Json::array(pending);fence();auto result=cloudRPC(8,body);fence();require(result.at("accepted").boolean(),"cloud personal rejected");for(auto r:pending){auto id=r.at("id").str();r.fields.erase("id");progress["acked"][id]=recordDigest(r);}pending.clear();save();};
  if(archive.has("personalLexicon")&&archive.at("personalLexicon").kind==Json::Kind::object)for(const auto&p:archive.at("personalLexicon").at("records").fields){
   if(progress.at("acked").has(p.first)&&progress.at("acked").at(p.first).str()==recordDigest(p.second))continue;
   auto r=p.second;r["id"]=p.first;pending.push_back(r);if(pending.size()==256)upload();}
  upload();
 }catch(...){}
 }catch(...){cloudSyncBudget.finish(monotonicMilliseconds(),false);try{throw;}catch(const HTTPError&e){cloudTrace(root,"error http="+std::to_string(e.status)+" "+e.code);}catch(const std::exception&e){cloudTrace(root,std::string("error ")+e.what());}catch(...){cloudTrace(root,"error unknown");}try{throw;}catch(const HTTPError&e){if(e.status==403||e.status==409){auto latest=loadPrivate(permission);if(latest.at("scope").str()==scope){latest["enabled"]=false;latest["pendingRevoke"]=true;PersonalDataLock lock(root);savePrivate(permission,latest);invalidateCloudRank();}}}catch(const JsonError&e){if(std::string(e.what())=="cloud authorization requires explicit renewal"){auto latest=loadPrivate(permission);if(latest.at("scope").str()==scope){latest["enabled"]=false;latest["pendingRevoke"]=true;PersonalDataLock lock(root);savePrivate(permission,latest);invalidateCloudRank();}}}catch(...){} // Optional shadow failures never block clipboard/archival transport.
 }
}

std::vector<std::string> GroupClient::cloudOwnProducers(){std::vector<std::string>out{uuidText(identity.device)};auto legacy=root/L"legacy-rime-replica-v1.dpapi";if(!legacyRetired()&&std::filesystem::exists(legacy)){auto seed=loadPrivate(legacy);require(seed.at("version").num()==1,"cloud rank legacy producer");auto actor=uuidText(parseId(seed.at("replica").str()));if(actor!=out.front())out.push_back(actor);}return out;}
bool GroupClient::refreshCloudRanking(){auto path=root/L"cloud-learning-permission-v1.dpapi";std::optional<std::filesystem::file_time_type>stamp;if(std::filesystem::exists(path))stamp=std::filesystem::last_write_time(path);if(cloudCacheLoaded&&stamp==cloudPermissionStamp)return false;auto old=cloudControlCache;cloudPermissionStamp=stamp;cloudCacheLoaded=true;cloudShadowLoaded=false;cloudShadowCache=Json();cloudProducerCache.clear();
#ifdef _WIN32
 const auto serialBefore=cloudRankRevocationSerial();
#else
 const auto serialBefore=0;
#endif
 try{cloudControlCache=stamp?loadPrivate(path):Json();}catch(...){cloudControlCache=Json();}
 cloudAuthorizationSerial=uint32_t(serialBefore);
#ifdef _WIN32
 if(cloudRankRevocationSerial()!=serialBefore){cloudControlCache=Json();cloudCacheLoaded=false;}
#endif
#ifdef _WIN32
 if((cloudControlCache.kind!=Json::Kind::object||!cloudControlCache.at("enabled").boolean()||!cloudControlCache.has("rankAuthorized")||!cloudControlCache.at("rankAuthorized").boolean())&&root.lexically_normal()==(userRoot()/L"Activity").lexically_normal())revokeCloudRankIPC();
#endif
 return old.dump()!=cloudControlCache.dump();}
Json GroupClient::cloudRankingView(){try{if(!cloudCacheLoaded)refreshCloudRanking();const auto&c=cloudControlCache;if(!connected()||c.kind!=Json::Kind::object||!c.at("enabled").boolean()||!c.has("rankAuthorized")||!c.at("rankAuthorized").boolean()||c.at("scope").str()!=cloudScope()||!contentStore().current().at("localLearningEnabled").boolean())return Json();if(!cloudShadowLoaded){auto path=root/L"cloud-learning-shadow-v1.dpapi";if(!std::filesystem::exists(path))return Json();cloudShadowCache=loadPrivate(path);cloudShadowLoaded=true;}require(cloudShadowCache.at("scope").str()==cloudScope()&&cloudShadowCache.at("model").at("generation").num()==c.at("generation").num(),"cloud rank scope");if(cloudProducerCache.empty())cloudProducerCache=cloudOwnProducers();auto view=cloudRankProjection(cloudShadowCache,contentStore().current().at("archive"),cloudProducerCache);view["token"]=c.at("rankToken");view["authorizationSerial"]=cloudAuthorizationSerial;return view;}catch(...){return Json();}}
void GroupClient::authorizeCloudRanking(bool enabled){require(connected(),"cloud rank requires group");auto path=root/L"cloud-learning-permission-v1.dpapi";auto c=loadPrivate(path);const auto expectedControl=c.dump();require(c.at("scope").str()==cloudScope(),"cloud rank scope");if(enabled){require(c.at("enabled").boolean(),"cloud learning disabled");auto shadow=loadPrivate(root/L"cloud-learning-shadow-v1.dpapi");require(shadow.at("scope").str()==cloudScope()&&shadow.at("shadowReady").boolean(),"cloud rank requires full model ACK");(void)cloudRankProjection(shadow,contentStore().current().at("archive"),cloudOwnProducers());}c["rankAuthorized"]=enabled;c["rankToken"]=uuidText(newId());{PersonalDataLock lock(root);auto latest=loadPrivate(path);require(latest.dump()==expectedControl,"cloud rank scope changed");if(enabled)require(latest.at("enabled").boolean(),"cloud rank locally revoked");savePrivate(path,c);}
#ifdef _WIN32
 if(root.lexically_normal()==(userRoot()/L"Activity").lexically_normal())revokeCloudRankIPC();
#endif
 cloudCacheLoaded=false;refreshCloudRanking();}

uint64_t GroupClient::cloudTermGeneration(const std::string&reading,const std::string&text,bool*deleted){
 if(deleted)*deleted=false;
 if(!connected())return 0;auto path=root/L"cloud-learning-shadow-v1.dpapi";auto permission=root/L"cloud-learning-permission-v1.dpapi";if(!std::filesystem::exists(path)||!std::filesystem::exists(permission))return 0;
 auto control=loadPrivate(permission);if(control.at("scope").str()!=cloudScope()||!control.has("generation"))return 0;
 if(!cloudShadowLoaded){cloudShadowCache=loadPrivate(path);cloudShadowLoaded=true;}const auto&saved=cloudShadowCache;if(saved.at("scope").str()!=cloudScope()||saved.at("model").kind!=Json::Kind::object)return 0;const auto&model=saved.at("model");require(model.at("generation").num()==control.at("generation").num(),"cloud forget generation scope");validateCloudStagedModel(model);uint64_t generation=0;auto code=reading;std::transform(code.begin(),code.end(),code.begin(),[](unsigned char c){return c>='A'&&c<='Z'?char(c+32):char(c);});
 for(const auto*name:{"terms","tombstones"})for(const auto&e:model.at(name).items)if(e.at("reading").str()==code&&e.at("text").str()==text){generation=std::max(generation,e.at("term_generation").num());if(deleted)*deleted=std::string(name)=="tombstones";}return generation;
}
