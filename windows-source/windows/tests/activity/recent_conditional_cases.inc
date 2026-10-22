// Included by the actual GroupClient fixture; only DPAPI/WinHTTP boundaries are
// replaced. The optional reference path loads canonical server code directly.
void conditionalRecencyTests(){
 const auto aPath=fixtureRoot/"conditional-owner",bPath=fixtureRoot/"conditional-peer";
 GroupClient a(aPath),b(bPath);a.create("https://relay.example.invalid");
 a.consentContent(true,true);auto invite=a.makeTicket();b.join("https://relay.example.invalid",invite.at("code").str());check(a.pollAdmissions());b.pollJoin();b.consentContent(true,true);
 a.recordContent("tao bao","淘宝");b.recordContent("tian mao","天猫");
 auto sync=[](GroupClient&node){tick+=600001;node.syncContent();};
 sync(a);sync(b);sync(a);sync(b);sync(a);
 check(lastRecentHello.has("knownEvent")&&lastRecentPull.has("knownSnapshots"));
 auto saved=loadPrivate(aPath/"recent-v2.dpapi");check(saved.has("snapshotHints")&&!saved.at("snapshotHints").at("own").str().empty()&&!saved.at("snapshotHints").at("peers").fields.empty());
 const auto requests=recentRequests,pulls=pullAttempts;
 a.syncContent();check(recentRequests==requests&&pullAttempts>pulls);
 a.recordContent("lv ming","吕明");a.syncContent();check(recentRequests==requests);
 const auto own=recentOwnEnvelopes,peer=recentPeerEnvelopes;
 sync(a);check(recentOwnEnvelopes==own&&recentPeerEnvelopes==peer);
 b.recordContent("xin ci","新词");sync(b);auto beforePeer=recentPeerEnvelopes;sync(a);check(recentPeerEnvelopes==beforePeer+1);
 auto noChange=recentPeerEnvelopes;sync(a);check(recentPeerEnvelopes==noChange);
 // Persistence failure never acknowledges a peer's newer event as locally
 // present. A failed pass gets a 30-second retry, not the success interval.
 b.recordContent("xin xi","新习");sync(b);failSavePath=aPath/"recent-v2.dpapi";failSave=true;
 bool failed=false;try{sync(a);}catch(const JsonError&){failed=true;}check(failed&&!failSave);
 auto afterFailure=recentRequests;a.syncContent();check(recentRequests==afterFailure);
 tick+=31000;a.syncContent();check(recentRequests>afterFailure);
 auto recovered=a.contentSnapshot().at("archive");check(std::any_of(recovered.at("entries").items.begin(),recovered.at("entries").items.end(),[](const auto&e){return e.at("text").str()=="新习";}));
 // A missing archive cannot leave a stand-alone cursor suppressing recovery.
 fs::remove(aPath/"recent-v2.dpapi");GroupClient restored(aPath);auto ownBefore=recentOwnEnvelopes;sync(restored);check(!lastRecentHello.has("knownEvent")&&recentOwnEnvelopes>ownBefore);
 check(loadPrivate(aPath/"recent-v2.dpapi").has("snapshotHints"));
 sync(restored);auto conditionalStart=recentDownloadJSONBytes;sync(restored);auto conditionalBytes=recentDownloadJSONBytes-conditionalStart;
 // First hello always probes without optional fields. Emulate a legacy relay
 // by withholding capability and refusing any such fields at the boundary.
 legacyConditional=true;GroupClient legacy(aPath);sync(legacy);auto legacyStart=recentDownloadJSONBytes;sync(legacy);auto legacyBytes=recentDownloadJSONBytes-legacyStart;
 check(legacyBytes>conditionalBytes);
 check(!lastRecentHello.has("knownEvent")&&!lastRecentPull.has("knownSnapshots"));legacyConditional=false;
 std::cout<<"Synthetic unchanged recency response JSON bytes: conditional="<<conditionalBytes<<" legacy="<<legacyBytes<<" (application bodies only, not TLS/wire/device traffic)\n";
 std::cout<<"GroupClient conditional recency: capability probe, durable own/peer hints, no-change omission, unchanged v1 transport, 10-minute gate, 30-second failure retry, missing-cache recovery and legacy wire compatibility passed; realNetwork=false\n";
}
