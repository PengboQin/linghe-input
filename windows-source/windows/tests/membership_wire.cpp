#include "../sync/MembershipWire.h"
#include <fstream>
#include <iostream>
#include <iterator>
#include <limits>
using namespace private_input::protocol;
namespace {
size_t checks=0,rejections=0;
void require(bool ok,const char* why){++checks;if(!ok)throw std::runtime_error(why);}
template<class F> void reject(F action){++checks;++rejections;try{action();}catch(const MembershipWireError&){return;}catch(const MembershipError&){return;}throw std::runtime_error("Malformed wire accepted");}
std::string read(const std::string& path){std::ifstream f(path,std::ios::binary);if(!f)throw std::runtime_error("Fixture unavailable");return {std::istreambuf_iterator<char>(f),{}};}
void write(const std::string& path,const std::string& value){std::ofstream f(path,std::ios::binary);f<<value;if(!f)throw std::runtime_error("Output unavailable");}
void same(const SignedMembership& a,const SignedMembership& b){require(a.canonical()==b.canonical()&&a.signature==b.signature&&a.history.has_value()==b.history.has_value(),"Roundtrip differs");if(a.history){require(a.history->size()==b.history->size(),"History roundtrip differs");for(size_t i=0;i<a.history->size();++i)same((*a.history)[i],(*b.history)[i]);}}
}
int main(int argc,char** argv){try{
 require(argc==2,"Expected synthetic fixture directory");const std::string dir=argv[1];
 auto root=decodeMembershipJSON(read(dir+"/swift-v1.json")),v2=decodeMembershipJSON(read(dir+"/swift-v2.json"));MembershipAnchor anchor{root.group,root.ownerID,root.ownerPublic};auto initial=anchor.verify(root),second=anchor.verify(v2,&initial);
 for(const auto& name:{"swift-v1","swift-v2","swift-paired"}){auto value=decodeMembershipJSON(read(dir+"/"+name+".json"));(void)anchor.verify(value);auto encoded=encodeMembershipJSON(value);same(value,decodeMembershipJSON(encoded));write(dir+"/cpp-"+name+".json",encoded);}
 require(second.statement().revision==2,"Swift v2 verification");
 std::ifstream manifest(dir+"/manifest.txt");require(bool(manifest),"Manifest unavailable");std::string disposition,file;size_t accepted=0;while(manifest>>disposition>>file){auto wire=read(dir+"/"+file);std::cout<<"CORPUS "<<disposition<<" "<<file<<"\n";if(disposition=="reject"){reject([&]{(void)decodeMembershipJSON(wire);});}else{auto value=decodeMembershipJSON(wire);same(value,decodeMembershipJSON(encodeMembershipJSON(value)));if(disposition=="verify")require(anchor.verify(value).anchor()==anchor,"Valid wire verification failed");else if(disposition=="untrusted"){++rejections;++checks;try{anchor.verify(value);throw std::runtime_error("Untrusted template accepted");}catch(const MembershipError&){}}++accepted;}}
 // Hard byte boundary includes JSON whitespace; never trim before accounting.
 auto bytes=encodeMembershipJSON(root);bytes.append(MembershipWireLimits::maximumBytes-bytes.size(),' ');same(root,decodeMembershipJSON(bytes));bytes+=' ';reject([&]{decodeMembershipJSON(bytes);});
 MembershipWireLimits l;l.nodes=14;same(root,decodeMembershipJSON(encodeMembershipJSON(root,l),l));l.nodes=13;reject([&]{decodeMembershipJSON(encodeMembershipJSON(root),l);});reject([&]{encodeMembershipJSON(root,l);});
 l={};l.depth=4;same(root,decodeMembershipJSON(encodeMembershipJSON(root,l),l));l.depth=3;reject([&]{decodeMembershipJSON(encodeMembershipJSON(root),l);});reject([&]{encodeMembershipJSON(root,l);});
 l={};l.depth=5;reject([&]{decodeMembershipJSON(encodeMembershipJSON(v2),l);});reject([&]{encodeMembershipJSON(v2,l);});
 for(int which=0;which<3;++which){l={};if(which==0)l.bytes=MembershipWireLimits::maximumBytes+1;else if(which==1)l.depth=7;else l.nodes=65537;reject([&]{decodeMembershipJSON("{}",l);});reject([&]{encodeMembershipJSON(root,l);});}
 l={};l.bytes=1;reject([&]{encodeMembershipJSON(root,l);});
 auto boundary=root;boundary.members.clear();for(unsigned i=0;i<64;++i){GroupMember m;m.device[15]=uint8_t(i);m.signingPublic[31]=uint8_t(i);m.exchangePublic[31]=uint8_t(i);boundary.members.push_back(m);}same(boundary,decodeMembershipJSON(encodeMembershipJSON(boundary)));boundary.members.push_back(root.members[0]);reject([&]{encodeMembershipJSON(boundary);});
 boundary=v2;boundary.history=std::vector<SignedMembership>(1024,root);same(boundary,decodeMembershipJSON(encodeMembershipJSON(boundary)));boundary.history->push_back(root);reject([&]{encodeMembershipJSON(boundary);});boundary=v2;(*boundary.history)[0].history=std::vector<SignedMembership>{};reject([&]{encodeMembershipJSON(boundary);});
 // Encoding also enforces the byte cap before returning any output. This
 // legal typed shape has >2MiB of public predecessors, without nested history.
 boundary=v2;auto big=root;big.members.clear();for(unsigned i=0;i<64;++i){GroupMember m;m.device[15]=uint8_t(i);m.signingPublic[31]=uint8_t(i);m.exchangePublic[31]=uint8_t(i);big.members.push_back(m);}boundary.history=std::vector<SignedMembership>(1024,big);reject([&]{encodeMembershipJSON(boundary);});
 auto maximum=root;maximum.revision=maximum.epoch=std::numeric_limits<uint64_t>::max();same(maximum,decodeMembershipJSON(encodeMembershipJSON(maximum)));
 // Signature mutation is structurally decodable, but must never authenticate.
 auto tampered=v2;tampered.signature[0]^=1;auto decoded=decodeMembershipJSON(encodeMembershipJSON(tampered));++checks;++rejections;try{anchor.verify(decoded);throw std::runtime_error("Tampered signature trusted");}catch(const MembershipError&){}
 std::cout<<"PASS membership wire checks="<<checks<<" rejectionCases="<<rejections<<" acceptedCorpus="<<accepted<<" maxBytes=2097152 maxDepth=6 maxNodes=65536 history=1024 members=64 SwiftWireAndVerifier=v1,v2 WindowsExecuted=false\n";return 0;
}catch(const std::exception& error){std::cerr<<"FAIL: "<<error.what()<<"\n";return 1;}}
