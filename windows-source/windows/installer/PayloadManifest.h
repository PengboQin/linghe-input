#pragma once
// Shared by the native installer and host-side adversarial tests. No filesystem writes.
#include <algorithm>
#include <set>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>
namespace linghe::installer {
struct PayloadEntry { std::string sha256, path; };
enum class CleanupDisposition { AlreadyAbsent, RemoveVerified, PreserveUnknownOrChanged };
// Active upgrade/repair ownership requires EVERY pinned payload, not merely the DLL.
// Missing bytes are tolerated ONLY by uninstall cleanup retry; never by repair.
enum class PayloadPurpose { InstallOrRepair, CleanupRetry };
inline bool validOwnedPayload(const PayloadEntry& entry,bool exists,bool regular,
                              const std::string& actualHash,PayloadPurpose purpose) {
 if(!exists)return purpose==PayloadPurpose::CleanupRetry;
 return regular&&actualHash==entry.sha256;
}
inline CleanupDisposition cleanupDisposition(const std::vector<PayloadEntry>& entries,const std::string& relativePath,
                                            bool exists,const std::string& actualHash) {
 if(!exists)return CleanupDisposition::AlreadyAbsent;
 auto found=std::find_if(entries.begin(),entries.end(),[&](const auto& entry){return entry.path==relativePath;});
 return found!=entries.end() && actualHash==found->sha256 ? CleanupDisposition::RemoveVerified : CleanupDisposition::PreserveUnknownOrChanged;
}
// Only installer-created version directories are candidates for cleanup. Never
// use arbitrary registry paths, user profiles, or a recursive directory delete.
inline bool ownedVersionName(const std::string& value) {
 if(value.size()>32 || value.rfind("0.",0)!=0)return false;
 auto suffix=value.find("-win"); if(suffix==std::string::npos)return false;
 auto number=[](const std::string& s){return !s.empty()&&s.size()<=3&&std::all_of(s.begin(),s.end(),[](char c){return c>='0'&&c<='9';});};
 auto dot=value.find('.',2);
 return dot!=std::string::npos && number(value.substr(2,dot-2)) && number(value.substr(dot+1,suffix-dot-1)) &&
        number(value.substr(suffix+4)) && value[suffix+4]!='0';
}
inline bool recognizedSetupHash(const std::string& hash,const std::string& runningHash) {
 // Pinned exact earlier offline candidates. A neighbouring executable or a
 // rewritten manifest is not proof of ownership. Later releases extend this
 // explicitly instead of trusting a registry-provided executable.
 if(hash.size()!=64||!std::all_of(hash.begin(),hash.end(),[](char c){return (c>='0'&&c<='9')||(c>='a'&&c<='f');}))return false;
 return hash==runningHash || hash=="42eb3f60c8607199208a18f8adf57db60fbcce64807819fe3c8a5b9e28f09efa" ||
        hash=="96659520ad1019f76c792984f05755587dadfcbcbdb4eff150bd807c9e0d82d5" ||
        hash=="e5e4e51d2eb8a9fec9e82c8f2c3f6d6bd6afe9e431d36f907e997912a1dc98f4" ||
        hash=="2fb9008a52827443693b93652c13b5d62f31dd1e7f2e8ed8dc8e9becdccb2478" ||
        hash=="cb36a43905fc6142a555a46d0d7a9f787e438f36c686c09ac92b8c0b50257942" ||
        hash=="49861685e71bf0801413213855f5b525cfb19835b9980ad8ece1e1e64a2d1cb9" ||
        hash=="b18a5112a828ef40935c5d6b0df09cafb622c1f3588436257c2a15faa63695cd" ||
        hash=="1da3b45d5c4a7c715122c412b657201e2bc864bc8db522784d84c70a1d8bab20" ||
        hash=="310d1bc792f4aa8071b88d71e7372cd1a9e1d3bda076bb60f56fe505dc0f45d0" ||
        hash=="2c07b5c11a9c90431a4c25c4e6672e1bb5a64336eed81dc1921500eaf423643f" ||
        hash=="e348e7720ba45322b912b4098b4528edc677b4548be328859d8ab8a6dbd340b2" ||
        hash=="87cd19e618398c348aeac1224ccd6d17fc5849eeedf1f639a257c1ca9c4a010e" ||
        hash=="4290d63d340caa60caf2666a315e4703360869942016ce31415495055ccf1823" ||
        hash=="b046bb595ca36de6be52c11b1c036b3069e6d83499248fed4762d325110608d4" ||
        hash=="b67513fd913aa227eae199374552b7f443494f1fa60119cd49c2f8b3692d7b7d" ||
        hash=="6eaf456124102f37144b5cd715e09cb34f2b0c007fe2b0eab32897228dcb6b60" ||
        hash=="783c90c7b22582153fea86d9db3e5d4abd0a6250cbe741d9af3498d1d28efe51" ||
        hash=="d617c9572e89a92890689679c1ff6ea3d3333bd28e59e4fd6b522aa2159310ba" ||
        hash=="aad708921cb7deae91b9ebe6dac2dda09e1077235894cee43ec98da854680f12" ||
        hash=="4a09a75b70eb6dbf309afd8809669df04d11dcef427d3d8b55e54598aeb0b120" ||
        hash=="41924eba956d0d51221afa89ea59b99399736f9cc007518865bc5c2e2777414e" ||
        hash=="9358e5f3628913dd999db4512d74cf2aebe52c2f3fa8821113d7cb7833c47ce3" ||
        hash=="7ac45b49b4a1c7a14c7284b14135b51653107412eede25d0b79eddc91f86e561" ||
        hash=="82afe64c935d8c22536bd3c529c61ed4e5a9fdd55a76923188c52c95bf95465c" ||
        hash=="914a3c6a2f690a862caac4622d1fae2d951225e080638b8028b9720b97eb01b2" ||
        hash=="b20ee4911fc7f9f4f895fa93f874b332a6dc47e7e3661949aaff53cebbd600ab" ||
        // 062 public baseline: retained package and installed copy independently match.
        hash=="2d1a3d727ae7cd14ec68b76cb70670b2141517a1ee3f0ad855d4fd05aafecd75" ||
        hash=="95cb0caa8c869f60bdf38a6019dac968046858ee4feb597e0ce0d0bf32129d7e" ||
        hash=="7448c783c5374c2f4f5cd85a6cb9f4c2a52aa260b36cbb2a9f3a002505a60fb5" ||
        hash=="f55efde22ab08ec2abf4ca9d9889229c585005cf4c2be950242a39bf81c10c87" ||
        hash=="b64467fa3abff7bb34f81457f5a1bb18a64f6eb7e4b5fbd47f841953b2d8cd57" ||
        hash=="64f04b406dfddc6271bd2ed429275865d9b4c9a7e826f1c2c9a7855d2cb7fc45";
}
inline std::vector<PayloadEntry> parseManifest(const std::string& bytes, const std::string& version) {
 if(bytes.empty() || bytes.size()>256*1024 || bytes.find('\0')!=std::string::npos)throw std::runtime_error("Invalid manifest size");
 std::istringstream input(bytes); std::string line; std::getline(input,line); if(!line.empty()&&line.back()=='\r')line.pop_back();
 if(line!="version="+version)throw std::runtime_error("Manifest version mismatch");
 std::vector<PayloadEntry> entries; std::set<std::string> names; bool dll=false,settings=false,rime=false;
 while(std::getline(input,line)) {
  if(!line.empty()&&line.back()=='\r')line.pop_back();
  if(line.empty())continue;
  if(entries.size()>=256||line.size()<67||line.size()>1024||line[64]!=' '||line[65]!=' ')throw std::runtime_error("Invalid manifest line");
  auto sha=line.substr(0,64),path=line.substr(66);
  if(!std::all_of(sha.begin(),sha.end(),[](char c){return(c>='0'&&c<='9')||(c>='a'&&c<='f');}))throw std::runtime_error("Invalid SHA256");
  if(path.empty()||path.front()=='/'||path.back()=='/'||path.find("//")!=std::string::npos)throw std::runtime_error("Invalid payload path");
  for(unsigned char c:path)if(c<32||c>126||c==':'||c=='\\'||c=='"'||c=='<'||c=='>'||c=='|'||c=='?'||c=='*')throw std::runtime_error("Unsafe payload path");
  std::string folded=path; for(char&c:folded)if(c>='a'&&c<='z')c=char(c-'a'+'A');
  if(folded=="LINGHEINPUTSETUP.EXE")throw std::runtime_error("Payload may not replace cleanup executable");
  std::istringstream parts(folded); std::string part;
  while(std::getline(parts,part,'/')) {
   if(part.empty()||part=="."||part==".."||part.back()=='.'||part.back()==' ')throw std::runtime_error("Unsafe payload component");
   auto base=part.substr(0,part.find('.'));
   if(base=="CON"||base=="PRN"||base=="AUX"||base=="NUL"||(base.size()==4&&(base.rfind("COM",0)==0||base.rfind("LPT",0)==0)&&base[3]>='0'&&base[3]<='9'))throw std::runtime_error("DOS device name");
  }
  if(!names.insert(folded).second)throw std::runtime_error("Duplicate payload path");
  if(path=="AMD64/PrivateInputTSF.dll")dll=true;
  if(path=="AMD64/LingheInputSettings.exe")settings=true;
  if(path=="AMD64/librime.dll")rime=true;
  entries.push_back({sha,path});
 }
 for(const auto& name:names)for(auto separator=name.find('/');separator!=std::string::npos;separator=name.find('/',separator+1))
  if(names.count(name.substr(0,separator)))throw std::runtime_error("Payload file/directory collision");
 if(input.bad()||!dll||!settings||!rime)throw std::runtime_error("Missing required payload");
 return entries;
}
constexpr unsigned ManifestResource=1000, FirstFileResource=1001;
constexpr unsigned long MaxPayloadFile=256*1024*1024;
constexpr unsigned long long MaxPayloadTotal=512ull*1024*1024;
}
