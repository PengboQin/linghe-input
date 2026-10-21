#pragma once
#include "../../sync/Membership.h"
#include <string>
#include <algorithm>
namespace membership_fixture {
using namespace private_input::protocol;
inline Data hex(const std::string& text){Data out;for(size_t i=0;i<text.size();i+=2)out.push_back(static_cast<unsigned char>(std::stoul(text.substr(i,2),nullptr,16)));return out;}
template<size_t N> inline std::array<unsigned char,N> fixed(const std::string& text){auto bytes=hex(text);if(bytes.size()!=N)throw std::runtime_error("Fixture length");std::array<unsigned char,N> out{};std::copy(bytes.begin(),bytes.end(),out.begin());return out;}
inline SignedMembership initial(){SignedMembership value;
value.group=fixed<16>("00000000000040008000000000000001");
value.ownerID=fixed<16>("00000000000040008000000000000006");
value.ownerPublic=fixed<32>("2543b92ff1095511476adc8369db6ddc933665a11978dda1404ee1066ca9559d");
value.revision=1;value.epoch=1;
value.members.push_back({fixed<16>("00000000000040008000000000000002"),fixed<32>("03a107bff3ce10be1d70dd18e74bc09967e4d6309ba50d5f1ddc8664125531b8"),fixed<32>("493e82fc74464a59268817623d2053c5eb8e2cc4a988b4fee179ec6b010d531d"),3});
value.signature=hex("fb95489316d6588e7050964df53c11cb98ca8d57d714191d8c66c5fff7aaa69b577f5a1b3c3babacf74fe4ed382ed1225fa5705082a23bf157fb1c447ed7510a");return value;}
inline SignedMembership paired(){SignedMembership value;
value.group=fixed<16>("00000000000040008000000000000001");
value.ownerID=fixed<16>("00000000000040008000000000000006");
value.ownerPublic=fixed<32>("2543b92ff1095511476adc8369db6ddc933665a11978dda1404ee1066ca9559d");
value.revision=2;value.epoch=2;
value.members.push_back({fixed<16>("00000000000040008000000000000002"),fixed<32>("03a107bff3ce10be1d70dd18e74bc09967e4d6309ba50d5f1ddc8664125531b8"),fixed<32>("493e82fc74464a59268817623d2053c5eb8e2cc4a988b4fee179ec6b010d531d"),3});
value.members.push_back({fixed<16>("00000000000040008000000000000004"),fixed<32>("174553b456dddfc6908ecab1c101fe6ab21e2baa0617795b7d43a63482993fd5"),fixed<32>("605a725d2a4adfeeb1a29e17edd621c1b7593ee8cdbc44ac6c4ab6e2f805d23c"),3});
value.signature=hex("54b036c73dc46435ade72bff748343b404afaabeca2deda3388c017c416feefc725e31e0e274e84c9607b911d6da5aaa5580e9255fee34da0e8ba1729c57e504");return value;}
}
