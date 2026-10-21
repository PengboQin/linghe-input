#pragma once
#include <algorithm>
#include <cstdint>
#include <cmath>
#include <fstream>
#include <map>
#include <string>
#include <vector>
#include <filesystem>
namespace private_input {
// Immutable public word-prefix model. Never stores queries or user text.
class PublicContextModel {
 std::vector<unsigned char>data;size_t count=0,strings=0;
 uint64_t integer(size_t offset,unsigned size)const{uint64_t value=0;for(unsigned i=0;i<size;++i)value|=uint64_t(data.at(offset+i))<<(8*i);return value;}
 static std::vector<uint32_t>scalars(const std::string&s){std::vector<uint32_t>out;for(size_t i=0;i<s.size();){uint32_t c=uint8_t(s[i++]);unsigned extra=0;if(c>=0xc2&&c<=0xdf){c&=31;extra=1;}else if(c>=0xe0&&c<=0xef){c&=15;extra=2;}else if(c>=0xf0&&c<=0xf4){c&=7;extra=3;}else if(c>=128)return {};if(i+extra>s.size())return {};while(extra--){auto next=uint8_t(s[i++]);if((next&192)!=128)return {};c=(c<<6)|(next&63);}out.push_back(c);}return out;}
public:
 struct Hint{std::string text;double score;};
 bool load(const std::filesystem::path&path){std::ifstream in(path,std::ios::binary);if(!in)return false;in.seekg(0,std::ios::end);auto size=in.tellg();if(size<16||size>8388608)return false;in.seekg(0);data.assign(std::istreambuf_iterator<char>(in),{});if(std::string(data.begin(),data.begin()+8)!="PINEXT01")return false;count=size_t(integer(8,4));if(count>300000||integer(12,4)!=20||16+count*20>data.size())return false;strings=16+count*20;uint64_t previous=0;for(size_t i=0;i<count;++i){auto at=16+i*20;auto key=integer(at,8),offset=integer(at+8,4),length=integer(at+12,2);if(key<previous||length==0||length>12||strings+offset+length>data.size())return false;previous=key;}return true;}
 std::vector<Hint>hints(const std::string&before)const{if(data.empty()||before.empty()||before.back()=='\n')return {};auto chars=scalars(before);auto trailing=[](uint32_t c){return c==' '||c==','||c=='.'||c=='!'||c=='?'||c==';'||c==':'||c=='\"'||c=='\''||c==0xff0c||c==0x3002||c==0xff01||c==0xff1f||c==0xff1b||c==0xff1a||c==0x3001||c==0x2019||c==0x201d;};while(!chars.empty()&&trailing(chars.back()))chars.pop_back();std::vector<uint32_t>suffix;for(auto i=chars.rbegin();i!=chars.rend()&&suffix.size()<3&&*i>=0x4e00&&*i<=0x9fff;++i)suffix.insert(suffix.begin(),*i);std::map<std::string,double>scores;for(size_t size=1;size<=suffix.size();++size){uint64_t key=uint64_t(size)<<48;for(size_t i=suffix.size()-size;i<suffix.size();++i)key=(key&0xffff000000000000ull)|((key&0xffffffffffffull)<<16)|suffix[i];size_t lo=0,hi=count;while(lo<hi){size_t mid=(lo+hi)/2;if(integer(16+mid*20,8)<key)lo=mid+1;else hi=mid;}for(unsigned scanned=0;lo<count&&scanned<128&&integer(16+lo*20,8)==key;++lo,++scanned){auto at=16+lo*20;auto offset=integer(at+8,4),length=integer(at+12,2),frequency=integer(at+16,4);auto text=std::string(data.begin()+strings+offset,data.begin()+strings+offset+length);double score=double(size)*.7+std::log1p(double(frequency))*.08;scores[text]=std::max(scores[text],score);}}std::vector<Hint>result;for(const auto&p:scores)result.push_back({p.first,p.second});std::sort(result.begin(),result.end(),[](const auto&a,const auto&b){return a.score==b.score?a.text<b.text:a.score>b.score;});if(result.size()>24)result.resize(24);return result;}
 static double match(const std::vector<Hint>&hints,const std::string&candidate){double best=0;for(const auto&hint:hints)if(candidate.rfind(hint.text,0)==0)best=std::max(best,hint.score);return best;}
};
}
