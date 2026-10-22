#pragma once
#include "RecoveryTransaction.h"
#include <cstdint>
#include <limits>

namespace linghe::installer::recovery {
namespace codec {
constexpr std::size_t Max=1024*1024;
struct Writer {
 std::string data;
 void number(std::uint32_t n){for(unsigned i=0;i<4;++i)data+=char((n>>(8*i))&255);bound();}
 void bytes(const std::string&s){if(s.size()>Max)throw std::runtime_error("repair field bound");number(static_cast<std::uint32_t>(s.size()));data+=s;bound();}
 void bound(){if(data.size()>Max)throw std::runtime_error("repair journal bound");}
};
struct Reader {
 const std::string&data;std::size_t offset=0;
 explicit Reader(const std::string&s):data(s){if(s.empty()||s.size()>Max)throw std::runtime_error("repair journal bound");}
 std::uint32_t number(){if(data.size()-offset<4)throw std::runtime_error("repair truncated number");std::uint32_t n=0;for(unsigned i=0;i<4;++i)n|=std::uint32_t(static_cast<unsigned char>(data[offset++]))<<(8*i);return n;}
 std::string bytes(){auto size=number();if(size>Max||size>data.size()-offset)throw std::runtime_error("repair truncated field");auto value=data.substr(offset,size);offset+=size;return value;}
 void end()const{if(offset!=data.size())throw std::runtime_error("repair trailing data");}
};
inline bool hash(const std::string&s){return s.size()==64&&s.find_first_not_of("0123456789abcdef")==std::string::npos;}
inline void validate(const Journal&j){
 if(j.schema!=1||j.transaction.size()!=36||j.ownerSid.size()>192||j.ownerSid.rfind("S-1-",0)!=0||
    !hash(j.sourceSetupHash)||!hash(j.targetSetupHash)||j.targetVersion.empty()||j.targetVersion.size()>32||
    static_cast<unsigned>(j.phase)>static_cast<unsigned>(Phase::RecoveryRequired)||j.intent>=static_cast<unsigned>(Slot::Count))throw std::runtime_error("repair journal identity");
}
}
inline std::string encodeJournal(const Journal&j){codec::validate(j);codec::Writer out;out.bytes("LingheInput explicit repair v1");out.number(j.schema);out.bytes(j.transaction);out.bytes(j.ownerSid);out.bytes(j.sourceSetupHash);out.bytes(j.targetSetupHash);out.bytes(j.targetVersion);out.number(static_cast<unsigned>(j.phase));out.number(j.intent);for(const auto&v:j.before.slots)out.bytes(v);for(const auto&v:j.desired.slots)out.bytes(v);return out.data;}
inline Journal decodeJournal(const std::string&data){codec::Reader in(data);if(in.bytes()!="LingheInput explicit repair v1")throw std::runtime_error("repair journal magic");Journal j;j.schema=in.number();j.transaction=in.bytes();j.ownerSid=in.bytes();j.sourceSetupHash=in.bytes();j.targetSetupHash=in.bytes();j.targetVersion=in.bytes();j.phase=static_cast<Phase>(in.number());j.intent=in.number();for(auto&v:j.before.slots)v=in.bytes();for(auto&v:j.desired.slots)v=in.bytes();in.end();codec::validate(j);return j;}
}
