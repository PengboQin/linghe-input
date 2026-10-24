#pragma once
#include <cstdint>
#include <string>
#include <type_traits>

namespace private_input::registration {
inline constexpr std::int32_t EnumOk=0,EnumEnd=1;
inline constexpr std::int32_t EnumFailure=static_cast<std::int32_t>(0x80004005u);
inline constexpr std::int32_t EnumUnexpected=static_cast<std::int32_t>(0x8000ffffu);
inline constexpr std::int32_t EnumNotCalled=static_cast<std::int32_t>(0x8000000au);
inline constexpr std::int32_t EnumInvalidArgument=static_cast<std::int32_t>(0x80070057u);
// Process exit codes are not HRESULTs: positive nonzero must never be accepted
// as a successful catalog proof. Preserve actual failing HRESULT bit patterns.
inline std::int32_t catalogChildExitResult(std::uint32_t code){
 if(code==0||static_cast<std::int32_t>(code)<0)return static_cast<std::int32_t>(code);
 return static_cast<std::int32_t>(0x80070000u|(code&0xffffu));
}
enum EnumerationFlags:std::uint32_t { NextCalled=1,Complete=2,MalformedResult=4,MissingEnumerator=8 };

// Fixed exported ABI: eight 32-bit numeric fields, no pointers, GUIDs or text.
// stage4 matches bit1=own service; stage7 bit1=keyboard/bit2=systray;
// stage14 and stage15 bit2=systray. Raw HRESULT bit patterns are retained.
struct EnumerationDiagnostic {
 std::uint32_t byteSize=32,stage=0;
 std::int32_t enumerationHR=EnumNotCalled,nextHR=EnumNotCalled;
 std::uint32_t fetched=0,items=0,flags=0,matches=0;
 std::int32_t result()const {
  if(enumerationHR<0)return enumerationHR;
  if((flags&NextCalled)&&nextHR<0)return nextHR;
  if(flags&(MalformedResult|MissingEnumerator))return EnumUnexpected;
  return flags&Complete?EnumOk:EnumUnexpected;
 }
 std::int32_t requireMatches(std::uint32_t required)const {
  auto hr=result();return hr<0?hr:((matches&required)==required?EnumOk:EnumFailure);
 }
};
static_assert(sizeof(EnumerationDiagnostic)==32&&alignof(EnumerationDiagnostic)==4);
static_assert(std::is_standard_layout_v<EnumerationDiagnostic>&&std::is_trivially_copyable_v<EnumerationDiagnostic>);
inline std::int32_t copyEnumerationDiagnostic(const EnumerationDiagnostic&source,EnumerationDiagnostic*output){
 if(!output||output->byteSize!=32)return EnumInvalidArgument;
 *output=source;return EnumOk;
}

template<class Item,class Next,class Match>
EnumerationDiagnostic enumerateGuids(std::uint32_t stage,std::int32_t enumerationHR,bool available,Next next,Match match){
 EnumerationDiagnostic result;result.stage=stage;result.enumerationHR=enumerationHR;
 if(enumerationHR<0)return result;
 if(!available){result.flags|=MissingEnumerator;return result;}
 for(;;){
  Item item{};result.fetched=0;result.flags|=NextCalled;result.nextHR=next(item,result.fetched);
  if(result.nextHR<0)return result;
  if(result.nextHR==EnumEnd&&result.fetched==0){result.flags|=Complete;return result;}
  if(result.nextHR!=EnumOk||result.fetched!=1){result.flags|=MalformedResult;return result;}
  ++result.items;result.matches|=match(item);
 }
}
inline std::string enumerationDiagnosticSuffix(const EnumerationDiagnostic&value){
 if(value.byteSize!=32||value.stage==0)return {};
 return ".enum-stage-"+std::to_string(value.stage)+
  ".api-"+std::to_string(static_cast<std::uint32_t>(value.enumerationHR))+
  ".next-"+std::to_string(static_cast<std::uint32_t>(value.nextHR))+
  ".fetched-"+std::to_string(value.fetched)+".items-"+std::to_string(value.items)+
  ".flags-"+std::to_string(value.flags)+".matches-"+std::to_string(value.matches);
}
}
