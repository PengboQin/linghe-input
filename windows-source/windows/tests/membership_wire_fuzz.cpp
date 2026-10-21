// Deterministic synthetic mutation harness; no libFuzzer runtime is required.
#include "../sync/MembershipWire.h"
#include <fstream>
#include <iostream>
#include <iterator>
using namespace private_input::protocol;
namespace {
uint64_t state=0x4d656d6265727368ULL;size_t attempts=0,accepted=0;
size_t random(size_t n){state^=state<<13;state^=state>>7;state^=state<<17;return n?size_t(state%n):0;}
void exercise(const std::string& bytes){++attempts;try{auto value=decodeMembershipJSON(bytes);auto encoded=encodeMembershipJSON(value);auto roundtrip=decodeMembershipJSON(encoded);if(encodeMembershipJSON(roundtrip)!=encoded||value.canonical()!=roundtrip.canonical())throw std::runtime_error("Mutation roundtrip differs");++accepted;}catch(const MembershipWireError&){}catch(const MembershipError&){} }
}
int main(int argc,char** argv){try{
 if(argc!=2)throw std::runtime_error("Expected synthetic fixture directory");std::string dir=argv[1],kind,file;std::ifstream manifest(dir+"/manifest.txt");if(!manifest)throw std::runtime_error("Missing mutation corpus");
 while(manifest>>kind>>file){std::ifstream f(dir+"/"+file,std::ios::binary);if(!f)throw std::runtime_error("Missing mutation seed");std::string seed{std::istreambuf_iterator<char>(f),{}};exercise(seed);if(seed.size()>100000)continue;
  for(unsigned i=0;i<256;++i){auto mutated=seed;size_t at=random(mutated.size()+1);switch(i%6){case 0:if(at<mutated.size())mutated[at]=char(random(256));break;case 1:mutated.insert(at,1,char(random(256)));break;case 2:if(at<mutated.size())mutated.erase(at,1+random(std::min(size_t(16),mutated.size()-at)));break;case 3:mutated.resize(at);break;case 4:mutated.insert(at,seed.substr(random(seed.size()+1),random(16)));break;case 5:mutated.insert(at,"\\uD800");break;}exercise(mutated);}
 }
 std::cout<<"PASS deterministic mutation attempts="<<attempts<<" structurallyAccepted="<<accepted<<" seed=0x4d656d6265727368 ASanUBSan=true noLibFuzzerRuntime=true\n";return 0;
}catch(const std::exception& e){std::cerr<<"FAIL "<<e.what()<<"\n";return 1;}}
