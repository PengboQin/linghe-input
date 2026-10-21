#include "../sync/SecureProtocol.h"
#include "public-protocol-vector.h"
#include <iostream>
#include <stdexcept>
using namespace private_input::protocol;
void require(bool value,const char* text){if(!value)throw std::runtime_error(text);}
template<class Action> void rejected(Action action){bool failed=false;try{action();}catch(const std::exception&){failed=true;}require(failed,"Invalid fixture accepted");}
int main(){try{
 auto message=fixtureMessage();auto trust=fixtureTrust();auto master=fixtureMaster();auto seed=fixtureSeed();auto expected=fixturePayload();Ledger ledger;
 auto opened=openOpaquePayload(message,master,trust,ledger,1010);require(opened.payload==expected,"CryptoKit plaintext mismatch");
 auto sealed=sealOpaquePayload(expected,message,master,seed,trust);require(sealed.ciphertext==message.ciphertext,"CryptoKit canonical ciphertext mismatch");
 require(openOpaquePayload(sealed,master,trust,ledger,1010).payload==expected,"Produced signature rejected");
 rejected([&]{openOpaquePayload(message,master,trust,opened.ledger,1010);});
 auto altered=message;altered.ciphertext[0]^=1;rejected([&]{openOpaquePayload(altered,master,trust,ledger,1010);});
 altered=message;altered.sequence++;rejected([&]{openOpaquePayload(altered,master,trust,ledger,1010);});
 auto unknown=trust;unknown.members.clear();rejected([&]{openOpaquePayload(message,master,unknown,ledger,1010);});
 rejected([&]{openOpaquePayload(message,master,trust,ledger,1600);});
 Data invalid={0xc0,0xaf};rejected([&]{sealOpaquePayload(invalid,message,master,seed,trust);});
 invalid={0xed,0xa0,0x80};rejected([&]{sealOpaquePayload(invalid,message,master,seed,trust);});
 require(ledger.empty(),"Failure mutated the supplied ledger");
 std::cout<<"PASS: PUBLIC CryptoKit vector exact ciphertext/open, valid signatures, tamper, replay, expiry, unknown sender, invalid UTF-8\n";
 std::cout<<"PUBLIC_SIGNATURE_HEX ";const char* hex="0123456789abcdef";for(auto byte:sealed.signature)std::cout<<hex[byte>>4]<<hex[byte&15];std::cout<<"\n";return 0;
}catch(const std::exception& error){std::cerr<<"FAIL: "<<error.what()<<"\n";return 1;}}
