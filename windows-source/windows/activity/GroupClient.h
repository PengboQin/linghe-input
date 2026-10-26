#pragma once
#include "Platform.h"
#include "GroupProtocol.h"
#include "../sync/DeviceIdentity.h"
#include "ContentStore.h"
#include "RecentProtocol.h"
#include "RecentSyncPolicy.h"
#include <optional>
#include <memory>
namespace private_input::activity {
struct ContentSyncObservation {size_t received=0;bool drained=false;std::vector<Json>newShared,legacyShared;};
class GroupClient {
 std::filesystem::path root;GroupIdentity identity;Json state,personalReset;void completePersonalReset();
 Json recentState;bool recentLoaded=false,recentReady=false;uint64_t recentAnchorTime=0,recentAnchorTick=0,recentLastTick=0;
 RecentSyncBudget recentSyncBudget,cloudSyncBudget;
 Json cloudControlCache,cloudShadowCache;bool cloudCacheLoaded=false,cloudShadowLoaded=false;
 std::optional<std::filesystem::file_time_type>cloudPermissionStamp;uint64_t cloudAuthorizationSerial=0;
 std::vector<std::string>cloudProducerCache;
 std::vector<std::string> cloudOwnProducers();Json cloudRankingView();
 void invalidateCloudRank();std::string cloudScope()const;Json cloudRPC(uint8_t,const Json&);
 Id activeContentGroup()const{return connected()?group():identity.device;}
 void loadRecent();void saveRecent(const Json&);std::optional<uint64_t> recentDay();Json recentRPC(uint8_t,const Json&,const protocol::VerifiedMembership&);void syncRecent(const protocol::VerifiedMembership&,const Key&);
 std::unique_ptr<ContentStore> content;ContentStore& contentStore();protocol::VerifiedMembership verified()const;Key master()const;
 bool recentLearningRepairPending=false,recentLearningDirty=true;uint64_t recentLearningChangedTick=0;std::string recentLearningScope;std::vector<RecentLocalDelta>recentLocalDeltas;
 void ensureRecentLearningScope();void markRecentLearningDirty();
 void save();Json rpc(const Id&,uint8_t,const Json&body=Json());
public:
 explicit GroupClient(const std::filesystem::path&root);
 const GroupIdentity& keys()const{return identity;}
 const Json& current()const{return state;}
 bool connected()const{return state.has("membership")&&!state.has("registering");}
 bool joining()const{return state.has("joining");}
 Id group()const;void create(const std::string&server);void join(const std::string&server,const std::string&code);void pollJoin();void cancelJoining();void refresh();void leave();void localDeparture();
 void noteLegacyMigration(const std::string&status);
 std::string personalEpoch()const{return personalReset.at("epoch").str();}bool legacyRetired()const{return personalReset.at("retireLegacy").boolean();}bool legacyCleanupComplete()const;
 std::function<void()>willReset;std::function<bool(bool)>allowClipboardPublication;ContentSyncObservation lastContentSyncObservation;
 void importLegacyLearning(const std::string&nativeTSV,const std::string&expectedPersonalEpoch);
 bool clipboardLiveAuthorityMatches(const Json&);Json clipboardLiveAuthority(const std::string&scope,uint64_t issuedAt);Json clipboardLiveRevocation(const Json&certificate,uint64_t now);void sendClipboardCompatibility(const std::string&text,const Id&event,uint64_t expiresAt);
 uint64_t cloudTermGeneration(const std::string&,const std::string&,bool*deleted=nullptr);std::function<void(const char*,uint64_t,unsigned)> learningTiming;Json learningIntentAuthority();LearningIntentResult recordLearningIntent(const LearningIntent&,uint64_t now,std::function<void(LearningIntentStatus)>durable={});size_t retryLearningIntents(uint64_t now);void setLocalLearningEnabled(bool);
 void consentContent(bool learning,bool clipboard);void syncContent(std::function<void()> transportComplete={},bool learningMaintenance=true);bool flushRecentLearning(bool force=false);void changeCandidate(const std::string&reading,const std::string&text,unsigned action);void recordContent(const std::string&reading,const std::string&text);void sendSharedText(const std::string&,bool automatic=false);void cancelAutomaticSharedText(){contentStore().cancelAutomaticText();}Json contentSnapshot();
 Json makeTicket();void cancelTicket();bool pollAdmissions();
 // Explicit opt-in; shadow only until validated platform cutover. Other groups default off.
 bool refreshCloudRanking();void authorizeCloudRanking(bool enabled);
 void consentCloudLearning(bool enabled,bool configureGroup=false);void syncCloudShadow();Json cloudLearningStatus();
 Json archive(uint8_t op,const Json&body=Json::object());void setArchiveEndpoint(const std::string&server);
};
}
