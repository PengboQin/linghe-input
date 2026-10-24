#include "../installer/PayloadManifest.h"
#include <cassert>
#include <iostream>
using namespace linghe::installer;
std::string line(const std::string& path) { return std::string(64,'a')+"  "+path+"\n"; }
const std::string base="version=0.2.3-win1\n"+line("AMD64/PrivateInputTSF.dll")+line("AMD64/LingheInputSettings.exe")+line("AMD64/librime.dll");
int main() {
 unsigned count=0;
 // Extending one release pin must never turn the ownership predicate into an
 // always-true expression. Unknown valid-length hashes remain untrusted.
 assert(!recognizedSetupHash(std::string(64,'0'),std::string(64,'a')));
 assert(!recognizedSetupHash(std::string(64,'f'),std::string(64,'a')));
 assert(recognizedSetupHash("d617c9572e89a92890689679c1ff6ea3d3333bd28e59e4fd6b522aa2159310ba",std::string(64,'a')));
 assert(recognizedSetupHash(std::string(64,'a'),std::string(64,'a')));
 for(const std::string pinned:{"41924eba956d0d51221afa89ea59b99399736f9cc007518865bc5c2e2777414e",
                              "82afe64c935d8c22536bd3c529c61ed4e5a9fdd55a76923188c52c95bf95465c",
                              "914a3c6a2f690a862caac4622d1fae2d951225e080638b8028b9720b97eb01b2",
                              "b20ee4911fc7f9f4f895fa93f874b332a6dc47e7e3661949aaff53cebbd600ab"}){
   assert(recognizedSetupHash(pinned,std::string(64,'a')));
   auto changed=pinned;changed[0]=changed[0]=='0'?'1':'0';
   assert(!recognizedSetupHash(changed,std::string(64,'a')));
 }

 auto reject=[&](const std::string& manifest) { bool failed=false; try{parseManifest(manifest,"0.2.3-win1");}catch(const std::runtime_error&){failed=true;} assert(failed);++count; };
 assert(parseManifest(base,"0.2.3-win1").size()==3);
 reject(""); reject("version=0.2.2-win1\n"+base.substr(base.find('\n')+1));
 for(const auto& path:{"../outside","/absolute","AMD64/../outside","AMD64/./bad","AMD64//bad","AMD64/bad/","AMD64/C:bad","AMD64/bad\\file","AMD64/NUL.txt","AMD64/com1","AMD64/LPT9.ext","AMD64/bad.","AMD64/bad ","AMD64/*.txt","AMD64/a?b","AMD64/<bad>","AMD64/a|b"})reject(base+line(path));
 reject(base+line("amd64/privateinputtsf.DLL"));
 reject(base+line("AMD64/data")+line("amd64/DATA/file.txt"));
 auto nul=base+line("AMD64/a");nul.insert(nul.size()-2,1,'\0');reject(nul);
 reject(base+std::string(64,'G')+"  AMD64/bad\n");
 reject(base+std::string(1025,'a')+"\n");reject(std::string(256*1024+1,'a'));
 reject("version=0.2.3-win1\n"+line("AMD64/librime.dll"));
 std::string many=base;for(unsigned i=0;i<254;++i)many+=line("AMD64/"+std::to_string(i));reject(many);
 std::string crlf;for(char c:base){if(c=='\n')crlf+='\r';crlf+=c;}assert(parseManifest(crlf,"0.2.3-win1").size()==3);
 std::cout<<"Manifest adversarial rejections passed: "<<count<<"; valid LF/CRLF packages passed\n";
}
