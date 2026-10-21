#include "../installer/PayloadManifest.h"
#include <cassert>
#include <iostream>
using namespace linghe::installer;
int main() {
 unsigned cases=0;
 for(const auto& value:{"0.2.3-win1","0.2.4-win1","0.999.999-win999"}) { assert(ownedVersionName(value)); ++cases; }
 for(const auto& value:{"",".","..","0.2.4-win0","0.2.4-win01","0.2.4-win","0.2.4-win1/..","0.2.4-win1\\AMD64","0.2.4-win1 ","1.2.4-win1","0.2.4-win1:stream","0.2.4-win1\n","0.2.4.1-win1","0.2.4-win1000"}) { assert(!ownedVersionName(value)); ++cases; }
 const std::string ownHash(64,'a'),changedHash(64,'b');
 assert(recognizedSetupHash(ownHash,ownHash)); ++cases;
 assert(!recognizedSetupHash(changedHash,ownHash)); ++cases;
 assert(!recognizedSetupHash("","")); ++cases;
 assert(!recognizedSetupHash(std::string(64,'G'),ownHash)); ++cases;
 assert(recognizedSetupHash("42eb3f60c8607199208a18f8adf57db60fbcce64807819fe3c8a5b9e28f09efa",ownHash)); ++cases;
 assert(recognizedSetupHash("96659520ad1019f76c792984f05755587dadfcbcbdb4eff150bd807c9e0d82d5",ownHash)); ++cases;
 assert(recognizedSetupHash("e5e4e51d2eb8a9fec9e82c8f2c3f6d6bd6afe9e431d36f907e997912a1dc98f4",ownHash)); ++cases;
 assert(recognizedSetupHash("2fb9008a52827443693b93652c13b5d62f31dd1e7f2e8ed8dc8e9becdccb2478",ownHash)); ++cases;
 assert(recognizedSetupHash("cb36a43905fc6142a555a46d0d7a9f787e438f36c686c09ac92b8c0b50257942",ownHash)); ++cases;
 assert(recognizedSetupHash("1da3b45d5c4a7c715122c412b657201e2bc864bc8db522784d84c70a1d8bab20",ownHash)); ++cases;
 assert(recognizedSetupHash("310d1bc792f4aa8071b88d71e7372cd1a9e1d3bda076bb60f56fe505dc0f45d0",ownHash)); ++cases;
 assert(recognizedSetupHash("2c07b5c11a9c90431a4c25c4e6672e1bb5a64336eed81dc1921500eaf423643f",ownHash)); ++cases;
 assert(!recognizedSetupHash("0c07b5c11a9c90431a4c25c4e6672e1bb5a64336eed81dc1921500eaf423643f",ownHash)); ++cases;
 assert(!recognizedSetupHash("0da3b45d5c4a7c715122c412b657201e2bc864bc8db522784d84c70a1d8bab20",ownHash)); ++cases;
 assert(recognizedSetupHash("e348e7720ba45322b912b4098b4528edc677b4548be328859d8ab8a6dbd340b2",ownHash)); ++cases;
 assert(!recognizedSetupHash("0348e7720ba45322b912b4098b4528edc677b4548be328859d8ab8a6dbd340b2",ownHash)); ++cases;
 assert(recognizedSetupHash("87cd19e618398c348aeac1224ccd6d17fc5849eeedf1f639a257c1ca9c4a010e",ownHash)); ++cases;
 assert(!recognizedSetupHash("07cd19e618398c348aeac1224ccd6d17fc5849eeedf1f639a257c1ca9c4a010e",ownHash)); ++cases;
 assert(recognizedSetupHash("4290d63d340caa60caf2666a315e4703360869942016ce31415495055ccf1823",ownHash)); ++cases;
 assert(!recognizedSetupHash("0290d63d340caa60caf2666a315e4703360869942016ce31415495055ccf1823",ownHash)); ++cases;
 assert(recognizedSetupHash("b046bb595ca36de6be52c11b1c036b3069e6d83499248fed4762d325110608d4",ownHash)); ++cases;
 assert(!recognizedSetupHash("0046bb595ca36de6be52c11b1c036b3069e6d83499248fed4762d325110608d4",ownHash)); ++cases;
 auto line=[&](const std::string& path){return ownHash+"  "+path+"\n";};
 const std::string manifest="version=0.2.4-win1\n"+line("AMD64/PrivateInputTSF.dll")+line("AMD64/LingheInputSettings.exe")+line("AMD64/librime.dll");
 auto entries=parseManifest(manifest,"0.2.4-win1");
 assert(cleanupDisposition(entries,"AMD64/PrivateInputTSF.dll",true,ownHash)==CleanupDisposition::RemoveVerified); ++cases;
 assert(cleanupDisposition(entries,"AMD64/PrivateInputTSF.dll",false,"")==CleanupDisposition::AlreadyAbsent); ++cases;
 assert(cleanupDisposition(entries,"AMD64/PrivateInputTSF.dll",true,changedHash)==CleanupDisposition::PreserveUnknownOrChanged); ++cases;
 for(const auto& path:{"AMD64/user.txt","../LocalAppData/LingheInput/words","AMD64/../../user.txt","C:/Users/Example","LingheInputSetup.exe","AMD64/PrivateInputTSF.dll:stream","amd64/PrivateInputTSF.dll"}) {
  assert(cleanupDisposition(entries,path,true,ownHash)==CleanupDisposition::PreserveUnknownOrChanged); ++cases;
 }
 auto reject=[&](const std::string& bytes,const std::string& version) { bool failed=false;try{parseManifest(bytes,version);}catch(...){failed=true;}assert(failed);++cases; };
 reject(manifest,"0.2.3-win1");
 reject(manifest+line("LingheInputSetup.exe"),"0.2.4-win1");
 reject(manifest+line("lingheinputsetup.EXE"),"0.2.4-win1");
 reject(manifest+line("../LocalAppData/words"),"0.2.4-win1");
 std::cout<<"Uninstall version/ownership/tampering/path/retry policy cases passed: "<<cases<<"\n";
}
