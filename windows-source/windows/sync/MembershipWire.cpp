#include "MembershipWire.h"
#include <sodium.h>
#include <algorithm>
#include <limits>

namespace private_input::protocol {namespace {
[[noreturn]] void fail(const char* why){throw MembershipWireError(why);}
void require(bool ok,const char* why){if(!ok)fail(why);}
void limitsOK(const MembershipWireLimits& l){require(l.bytes&&l.bytes<=MembershipWireLimits::maximumBytes&&l.depth&&l.depth<=MembershipWireLimits::maximumDepth&&l.nodes&&l.nodes<=MembershipWireLimits::maximumNodes,"Invalid Membership wire budgets");}
// Validate the whole buffer before parsing; no overlong encodings, surrogates,
// truncated sequences, out-of-range scalars or non-UTF8 bytes are accepted.
void utf8(std::string_view s){
 for(size_t i=0;i<s.size();){unsigned c=static_cast<unsigned char>(s[i++]);if(c<0x80)continue;
  unsigned n=0,value=0,minimum=0;if(c>=0xc2&&c<=0xdf){n=1;value=c&31;minimum=0x80;}else if(c>=0xe0&&c<=0xef){n=2;value=c&15;minimum=0x800;}else if(c>=0xf0&&c<=0xf4){n=3;value=c&7;minimum=0x10000;}else fail("Invalid UTF8");
  require(n<=s.size()-i,"Truncated UTF8");for(unsigned k=0;k<n;++k){unsigned b=static_cast<unsigned char>(s[i++]);require((b&0xc0)==0x80,"Invalid UTF8 continuation");value=(value<<6)|(b&63);}
  require(value>=minimum&&value<=0x10ffff&&!(value>=0xd800&&value<=0xdfff),"Invalid UTF8 scalar");
 }
}
int hex(char c){if(c>='0'&&c<='9')return c-'0';if(c>='a'&&c<='f')return c-'a'+10;if(c>='A'&&c<='F')return c-'A'+10;return -1;}
Id uuid(const std::string& s){require(s.size()==36,"Invalid UUID length");Id result{};size_t j=0;for(size_t i=0;i<36;){if(i==8||i==13||i==18||i==23){require(s[i++]=='-',"Invalid UUID separator");continue;}int a=hex(s[i++]),b=hex(s[i++]);require(a>=0&&b>=0,"Invalid UUID digit");result[j++]=uint8_t((a<<4)|b);}return result;}
Data base64(const std::string& s,size_t size,bool empty=false){
 if(empty&&s.empty())return {};
 require(s.size()==sodium_base64_ENCODED_LEN(size,sodium_base64_VARIANT_ORIGINAL)-1,"Invalid base64 length");Data result(size);size_t written=0;const char* end=nullptr;
 require(sodium_base642bin(result.data(),result.size(),s.data(),s.size(),nullptr,&written,&end,sodium_base64_VARIANT_ORIGINAL)==0&&written==size&&end==s.data()+s.size(),"Invalid base64 encoding");return result;
}
Key key(const std::string& s){auto bytes=base64(s,32);Key value{};std::copy(bytes.begin(),bytes.end(),value.begin());return value;}
void structural(const SignedMembership& v,bool predecessor){
 // canonical() owns identity, integer metadata, member uniqueness and permission
 // rules. History shape is bounded here; signatures are verified by the anchor.
 (void)v.canonical();require(v.signature.empty()||v.signature.size()==64,"Invalid signature length");
 require(!predecessor||!v.history,"Nested Membership history");
 require(!v.history||v.history->size()<=SignedMembership::maxHistory,"Too much Membership history");
}
class Parser {
 std::string_view input;MembershipWireLimits limits;size_t at=0,nodes=0;
 void ws(){while(at<input.size()&&(input[at]==' '||input[at]=='\t'||input[at]=='\r'||input[at]=='\n'))++at;}
 char peek(){ws();return at<input.size()?input[at]:'\0';}
 bool take(char c){if(peek()==c){++at;return true;}return false;}
 void expect(char c){require(take(c),"Unexpected Membership JSON token");}
 void node(size_t depth){require(depth<=limits.depth,"Membership JSON depth budget exceeded");require(++nodes<=limits.nodes,"Membership JSON node budget exceeded");}
 unsigned unit(){require(input.size()-at>=4,"Truncated Unicode escape");unsigned value=0;for(unsigned i=0;i<4;++i){int digit=hex(input[at++]);require(digit>=0,"Invalid Unicode escape");value=(value<<4)|unsigned(digit);}return value;}
 void scalar(std::string& out,unsigned value){
  if(value<0x80)out.push_back(char(value));else if(value<0x800){out.push_back(char(0xc0|(value>>6)));out.push_back(char(0x80|(value&63)));}else if(value<0x10000){out.push_back(char(0xe0|(value>>12)));out.push_back(char(0x80|((value>>6)&63)));out.push_back(char(0x80|(value&63)));}else{out.push_back(char(0xf0|(value>>18)));out.push_back(char(0x80|((value>>12)&63)));out.push_back(char(0x80|((value>>6)&63)));out.push_back(char(0x80|(value&63)));}
 }
 std::string string(size_t bound){expect('"');std::string out;while(at<input.size()){
  unsigned char c=static_cast<unsigned char>(input[at++]);if(c=='"')return out;require(c>=32,"Unescaped JSON control");
  if(c=='\\'){require(at<input.size(),"Truncated JSON escape");switch(input[at++]){
   case '"':out+='"';break;case '\\':out+='\\';break;case '/':out+='/';break;case 'b':out+='\b';break;case 'f':out+='\f';break;case 'n':out+='\n';break;case 'r':out+='\r';break;case 't':out+='\t';break;
   case 'u':{unsigned value=unit();if(value>=0xd800&&value<=0xdbff){require(input.size()-at>=2&&input[at]=='\\'&&input[at+1]=='u',"Missing low surrogate");at+=2;unsigned low=unit();require(low>=0xdc00&&low<=0xdfff,"Invalid low surrogate");value=0x10000+((value-0xd800)<<10)+(low-0xdc00);}else require(!(value>=0xdc00&&value<=0xdfff),"Unpaired low surrogate");scalar(out,value);break;}
   default:fail("Invalid JSON escape");}
  }else out.push_back(char(c));require(out.size()<=bound,"Membership JSON string budget exceeded");
 }fail("Unterminated JSON string");}
 std::string text(size_t depth){node(depth);return string(88);}
 uint64_t number(size_t depth){node(depth);ws();require(at<input.size()&&input[at]>='0'&&input[at]<='9',"Unsigned integer required");const size_t start=at;uint64_t value=0;while(at<input.size()&&input[at]>='0'&&input[at]<='9'){
  unsigned digit=unsigned(input[at++]-'0');require(value<=(std::numeric_limits<uint64_t>::max()-digit)/10,"UInt64 overflow");value=value*10+digit;
 }require(at-start==1||input[start]!='0',"Leading zero in integer");require(at==input.size()||(input[at]!='.'&&input[at]!='e'&&input[at]!='E'),"Floating point forbidden");return value;}
 bool null(size_t depth){if(peek()!='n')return false;node(depth);require(input.substr(at,4)=="null","Invalid null token");at+=4;return true;}
 template<class F> void object(size_t depth,F field){node(depth);expect('{');unsigned seen=0;if(take('}'))return;
  for(;;){auto name=string(64);expect(':');unsigned bit=field(name,seen);require(bit!=0,"Unknown Membership field");seen|=bit;if(take('}'))break;expect(',');}
 }
 // Field callbacks reject duplicates BEFORE consuming their value. Escaped and
 // literal spellings of a key therefore share one presence bit.
 static void unique(unsigned seen,unsigned bit){require(!(seen&bit),"Duplicate Membership field");}
 GroupMember member(size_t depth){GroupMember v;unsigned present=0;object(depth,[&](const std::string& name,unsigned seen){
  unsigned bit=name=="device"?1:name=="signingPublic"?2:name=="exchangePublic"?4:name=="permissions"?8:0;require(bit,"Unknown member field");unique(seen,bit);present|=bit;
  if(bit==1)v.device=uuid(text(depth+1));else if(bit==2)v.signingPublic=key(text(depth+1));else if(bit==4)v.exchangePublic=key(text(depth+1));else {auto n=number(depth+1);require(n>=1&&n<=3,"Invalid permissions");v.permissions=uint8_t(n);}return bit;
 });require(present==15,"Missing member field");return v;}
 std::vector<GroupMember> members(size_t depth){node(depth);expect('[');std::vector<GroupMember> result;if(take(']'))return result;for(;;){require(result.size()<SignedMembership::maxMembers,"Too many members");result.push_back(member(depth+1));if(take(']'))break;expect(',');}return result;}
 std::vector<SignedMembership> history(size_t depth){node(depth);expect('[');std::vector<SignedMembership> result;if(take(']'))return result;for(;;){require(result.size()<SignedMembership::maxHistory,"Too much history");result.push_back(statement(depth+1,true));if(take(']'))break;expect(',');}return result;}
 SignedMembership statement(size_t depth,bool predecessor){SignedMembership v;unsigned present=0;object(depth,[&](const std::string& name,unsigned seen){
  const char* fields[]={"version","group","ownerID","ownerPublic","revision","epoch","members","signature","issuer","parent","history"};unsigned bit=0;for(unsigned i=0;i<11;++i)if(name==fields[i]){bit=1u<<i;break;}require(bit,"Unknown Membership field");unique(seen,bit);present|=bit;
  switch(bit){case 1:{auto n=number(depth+1);require(n==1||n==2,"Invalid Membership version");v.version=uint8_t(n);break;}case 2:v.group=uuid(text(depth+1));break;case 4:v.ownerID=uuid(text(depth+1));break;case 8:v.ownerPublic=key(text(depth+1));break;case 16:v.revision=number(depth+1);break;case 32:v.epoch=number(depth+1);break;case 64:v.members=members(depth+1);break;case 128:v.signature=base64(text(depth+1),64,true);break;
   case 256:if(!null(depth+1))v.issuer=uuid(text(depth+1));break;case 512:if(!null(depth+1))v.parent=key(text(depth+1));break;
   case 1024:if(!null(depth+1)){require(!predecessor,"Nested Membership history");v.history=history(depth+1);}break;default:fail("Unknown Membership field");}return bit;
 });require((present&255)==255,"Missing Membership field");structural(v,predecessor);return v;}
public:
 Parser(std::string_view s,MembershipWireLimits l):input(s),limits(l){limitsOK(l);require(s.size()<=l.bytes,"Membership JSON byte budget exceeded");utf8(s);}
 SignedMembership parse(){auto result=statement(1,false);ws();require(at==input.size(),"Trailing Membership JSON data");return result;}
};
std::string uuidText(const Id& id){const char* digits="0123456789ABCDEF";std::string out;for(size_t i=0;i<16;++i){if(i==4||i==6||i==8||i==10)out+='-';out+=digits[id[i]>>4];out+=digits[id[i]&15];}return out;}
template<class T> std::string b64Text(const T& value){std::string out(sodium_base64_ENCODED_LEN(value.size(),sodium_base64_VARIANT_ORIGINAL),'\0');sodium_bin2base64(out.data(),out.size(),value.data(),value.size(),sodium_base64_VARIANT_ORIGINAL);out.pop_back();return out;}
class Writer {
 MembershipWireLimits limits;std::string out;size_t nodes=0;
 void append(std::string_view s){require(s.size()<=limits.bytes-out.size(),"Membership JSON byte budget exceeded");out.append(s);}
 void node(size_t depth){require(depth<=limits.depth,"Membership JSON depth budget exceeded");require(++nodes<=limits.nodes,"Membership JSON node budget exceeded");}
 void text(const std::string& s,size_t depth){node(depth);append("\"");append(s);append("\"");}
 void number(uint64_t n,size_t depth){node(depth);append(std::to_string(n));}
 void statement(const SignedMembership& v,size_t depth,bool predecessor){structural(v,predecessor);node(depth);append("{\"epoch\":");number(v.epoch,depth+1);append(",\"group\":");text(uuidText(v.group),depth+1);
  if(v.history){append(",\"history\":[");node(depth+1);bool first=true;for(const auto& item:*v.history){if(!first)append(",");first=false;statement(item,depth+2,true);}append("]");}
  if(v.issuer){append(",\"issuer\":");text(uuidText(*v.issuer),depth+1);}append(",\"members\":[");node(depth+1);bool first=true;
  for(const auto& m:v.members){if(!first)append(",");first=false;node(depth+2);append("{\"device\":");text(uuidText(m.device),depth+3);append(",\"exchangePublic\":");text(b64Text(m.exchangePublic),depth+3);append(",\"permissions\":");number(m.permissions,depth+3);append(",\"signingPublic\":");text(b64Text(m.signingPublic),depth+3);append("}");}append("],\"ownerID\":");text(uuidText(v.ownerID),depth+1);append(",\"ownerPublic\":");text(b64Text(v.ownerPublic),depth+1);
  if(v.parent){append(",\"parent\":");text(b64Text(*v.parent),depth+1);}append(",\"revision\":");number(v.revision,depth+1);append(",\"signature\":");text(b64Text(v.signature),depth+1);append(",\"version\":");number(v.version,depth+1);append("}");
 }
public:explicit Writer(MembershipWireLimits l):limits(l){limitsOK(l);}std::string encode(const SignedMembership& v){statement(v,1,false);return std::move(out);}
};
}
SignedMembership decodeMembershipJSON(std::string_view bytes,MembershipWireLimits limits){return Parser(bytes,limits).parse();}
std::string encodeMembershipJSON(const SignedMembership& value,MembershipWireLimits limits){return Writer(limits).encode(value);}
}
