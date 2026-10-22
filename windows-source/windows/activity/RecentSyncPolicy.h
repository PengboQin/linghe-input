#pragma once
#include "ArchiveCore.h"
#include <algorithm>
#include <limits>

namespace private_input::activity {
// A separate budget for optional learning maintenance. Clipboard transport and
// its live worker do not consult this gate.
struct RecentSyncBudget {
  std::string scope;uint64_t last=0,next=0;bool conditional=false;
  void reset(){scope.clear();last=next=0;conditional=false;}
  bool begin(const std::string&context,uint64_t now){
    if(scope!=context||now<last){reset();scope=context;}
    last=now;if(now<next)return false;
    finish(now,false);return true;
  }
  void finish(uint64_t now,bool success){last=now;auto delay=success?600000u:30000u;next=now>std::numeric_limits<uint64_t>::max()-delay?std::numeric_limits<uint64_t>::max():now+delay;}
};

inline std::string recentHintID(const std::string&value){
  auto id=uuidText(parseId(value));std::transform(id.begin(),id.end(),id.begin(),[](unsigned char c){return char(c>='A'&&c<='F'?c+32:c);});return id;
}

// This ledger is stored atomically beside the validated archive, never in a
// stand-alone "seen" file which could survive loss of the merged local data.
struct RecentSnapshotHints {
  std::string scope,own;Json peers=Json::object();
  explicit RecentSnapshotHints(std::string context):scope(std::move(context)){}
  static RecentSnapshotHints restore(const Json&state,const std::string&context,bool archiveAvailable){
    RecentSnapshotHints result(context);
    try{
      if(!archiveAvailable||!state.has("snapshotHints"))return result;
      const auto&saved=state.at("snapshotHints");
      require(saved.at("version").num()==1&&saved.at("context").str()==context&&saved.at("peers").kind==Json::Kind::object&&saved.at("peers").fields.size()<=64,"recent hint scope");
      if(!saved.at("own").str().empty())result.own=recentHintID(saved.at("own").str());
      for(const auto&row:saved.at("peers").fields){auto sender=recentHintID(row.first),event=recentHintID(row.second.str());
        // Peer hints also need the durable authenticated receipt, not just a
        // remembered server cursor. Evicted receipts cause a safe full pull.
        auto receipt=uuidText(parseId(event));if(state.at("receipts").has(receipt))result.peers[sender]=event;
      }
    }catch(...){return RecentSnapshotHints(context);}
    return result;
  }
  void rememberPeer(const std::string&sender,const std::string&event){auto actor=recentHintID(sender);if(!peers.has(actor)&&peers.fields.size()>=64)peers.fields.erase(peers.fields.begin());peers[actor]=recentHintID(event);}
  Json encoded()const{return Json::object({{"version",1},{"context",scope},{"own",own},{"peers",peers}});}
};
}
