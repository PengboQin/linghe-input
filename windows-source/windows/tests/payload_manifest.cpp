#include "../installer/PayloadManifest.h"
#include <cassert>
#include <iostream>
using namespace linghe::installer;
std::string line(const std::string& path) { return std::string(64,'a')+"  "+path+"\n"; }
const std::string base="version=0.2.3-win1\n"+line("AMD64/PrivateInputTSF.dll")+line("AMD64/LingheInputSettings.exe")+line("AMD64/librime.dll");
int main() {
 unsigned count=0;
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
