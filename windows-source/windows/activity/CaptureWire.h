#pragma once
#include <array>
#include <cstdint>
#include <cstring>
#include <string>
namespace private_input::activity {
constexpr uint32_t CaptureMagic=0x3141484c;
struct CaptureHeader {uint32_t magic=CaptureMagic,version=1,kind=1,scope=0,utf16Count=0;uint64_t foreground=0,observedTick=0,observedAt=0,generation=0;std::array<unsigned char,16> session{},editor{};};
static_assert(sizeof(CaptureHeader)==88,"043 capture v1 ABI must remain stable");
struct CaptureContextWire {
 uint32_t magic=0x3258434c,bytes=sizeof(CaptureContextWire);
 uint16_t appBytes=0,nameBytes=0,versionBytes=0,buildBytes=0;
 uint32_t field=0,layout=0,provenance=0;
 char app[192]{},name[256]{},version[24]{},build[16]{};
};
static_assert(sizeof(CaptureContextWire)==516,"bounded capture v2 context ABI");
inline bool captureWireLabel(const char*value,size_t n,size_t capacity){if(n>=capacity||value[n]!=0)return false;for(size_t i=0;i<n;++i){auto c=static_cast<unsigned char>(value[i]);if(c<32||c==127||c=='/'||c=='\\'||c==':')return false;}return true;}
inline bool validCaptureContextWire(const CaptureContextWire&c){return c.magic==0x3258434c&&c.bytes==sizeof(c)&&c.field<=6&&c.layout<=2&&c.provenance<=2&&captureWireLabel(c.app,c.appBytes,sizeof(c.app))&&captureWireLabel(c.name,c.nameBytes,sizeof(c.name))&&captureWireLabel(c.version,c.versionBytes,sizeof(c.version))&&captureWireLabel(c.build,c.buildBytes,sizeof(c.build));}
inline std::string captureWireString(const char*value,size_t n){return std::string(value,n);}
struct CaptureFrame {CaptureHeader header;CaptureContextWire context;bool hasContext=false;size_t textOffset=sizeof(CaptureHeader),textBytes=0;};
inline bool decodeCaptureFrame(const char*data,size_t size,CaptureFrame&frame){
 if(!data||size<sizeof(CaptureHeader)||size>262144)return false;CaptureHeader header;std::memcpy(&header,data,sizeof(header));if(header.magic!=CaptureMagic||header.utf16Count>120000)return false;
 const auto end=sizeof(header)+uint64_t(header.utf16Count)*2;CaptureFrame next;next.header=header;next.textBytes=size_t(header.utf16Count)*2;
 if(header.version==1){if(end!=size)return false;}else if(header.version==2&&(header.kind==1||header.kind==2||header.kind==8||header.kind==9)){if(end+sizeof(CaptureContextWire)!=size)return false;std::memcpy(&next.context,data+end,sizeof(next.context));if(!validCaptureContextWire(next.context))return false;next.hasContext=true;}else return false;frame=next;return true;
}
}
