#pragma once
#include <algorithm>
#include <array>
#include <cmath>
#include <limits>
#include <sstream>
#include <string>
#include <vector>
namespace private_input {
// Reviewed C++ port of this project's EnglishWordSuggestions.swift and its
// hand-authored MixedEnglishLexicon. No imported corpus, host text or learning.
inline bool englishLetters(const std::string &value){return !value.empty()&&value.size()<=48&&std::all_of(value.begin(),value.end(),[](unsigned char c){return (c>='a'&&c<='z')||(c>='A'&&c<='Z');});}
inline std::string englishLower(std::string value){for(auto &c:value)if(c>='A'&&c<='Z')c=char(c-'A'+'a');return value;}
inline bool englishNear(unsigned char a,unsigned char b){
 auto location=[](unsigned char c){const char *rows[]={"qwertyuiop","asdfghjkl","zxcvbnm"};const double offsets[]={0,.25,.75};for(int r=0;r<3;++r){auto p=std::string(rows[r]).find(char(c));if(p!=std::string::npos)return std::array<double,2>{double(p)+offsets[r],double(r)};}return std::array<double,2>{100,100};};
 auto x=location(a),y=location(b);return std::hypot(x[0]-y[0],x[1]-y[1])<=1.3;
}
inline double englishCorrectionCost(const std::string &input,const std::string &word){
 const auto impossible=std::numeric_limits<double>::infinity();
 if(input.size()<3||word.size()<2||!englishLetters(input)||!englishLetters(word)||englishLower(input)!=input||englishLower(word)!=word||std::abs(int(input.size())-int(word.size()))>2)return impossible;
 const size_t budget=input.size()>=5?2:1,n=input.size(),m=word.size();
 std::vector<double> costs((n+1)*(m+1)*(budget+1),impossible);
 auto at=[&](size_t i,size_t j,size_t used)->double&{return costs[(i*(m+1)+j)*(budget+1)+used];};at(0,0,0)=0;
 auto add=[&](size_t i,size_t j,size_t fromI,size_t fromJ,double extra,size_t edit){for(size_t used=0;used+edit<=budget;++used)at(i,j,used+edit)=std::min(at(i,j,used+edit),at(fromI,fromJ,used)+extra);};
 for(size_t i=0;i<=n;++i)for(size_t j=0;j<=m;++j){if(i+j==0)continue;
  if(i)add(i,j,i-1,j,i>1&&input[i-1]==input[i-2]?.55:1,1);
  if(j)add(i,j,i,j-1,j>1&&word[j-1]==word[j-2]?.55:1,1);
  if(i&&j){bool equal=input[i-1]==word[j-1];add(i,j,i-1,j-1,equal?0:(englishNear(input[i-1],word[j-1])?.55:1.25),equal?0:1);}
  if(i>1&&j>1&&input[i-1]==word[j-2]&&input[i-2]==word[j-1])add(i,j,i-2,j-2,.65,1);
 }
 double value=impossible;for(size_t used=0;used<=budget;++used)value=std::min(value,at(n,m,used));
 double ceiling=n>=5?2.1:(n==4?1.3:.8);return value>0&&value<=ceiling?value:impossible;
}
inline const std::vector<std::string>& englishVocabulary(){
 static const auto words=[](){std::istringstream source(R"words(
    API AI UI UX ID IP IT OK PDF URL USB CPU GPU SQL HTML HTTP HTTPS JSON XML CSS SDK IDE
    App WiFi iPhone iPad iOS macOS Mac Xcode Swift GitHub GitLab WeChat QQ
    Excel Word PowerPoint Office Chrome Safari Docker Linux Windows Python Java JavaScript TypeScript
    OpenAI ChatGPT Notion Markdown Unicode UTF VPN DNS TCP UDP LAN WAN RAM ROM SSD HDD NFC GPS QR
    review meeting hello world thanks thank please sorry welcome goodbye morning afternoon evening
    today tomorrow yesterday online offline email mail message chat call video audio photo image
    file folder document text code data database server client cloud local backup restore update
    upload download install uninstall build debug test release version feature issue bug fix TODO
    design layout color style keyboard input output space enter delete clear copy paste save cancel
    open close start stop pause resume restart refresh search find select edit add remove import export
    share sync link address account password token key login logout sign support help feedback
    project product plan task work team office home school friend family time date week month year
    good great nice happy ready done yes no true false first next last new old small large fast slow
    application apple about after again also back before between change check click connect continue
    default detail device different display example information language list model name network
    number option page phone position result screen service setting simple system table value view
)words");std::vector<std::string> result;std::string word;while(source>>word)result.push_back(std::move(word));return result;}();return words;
}
inline std::string englishCase(const std::string &word,const std::string &input){
 auto result=englishLower(word);bool allUpper=std::all_of(input.begin(),input.end(),[](char c){return c>='A'&&c<='Z';});
 if(allUpper){for(auto &c:result)c=char(c-'a'+'A');}else if(input[0]>='A'&&input[0]<='Z')result[0]=char(result[0]-'a'+'A');return result;
}
// Always preserve the user's exact spelling as an explicit first choice. This
// makes arbitrary names/codes typable while keeping corrections selectable.
inline std::vector<std::string> englishCandidates(const std::string &input,size_t limit=12){
 if(!englishLetters(input)||!limit)return {};std::vector<std::string> result{input};if(input.size()<2||limit==1)return result;
 const auto lower=englishLower(input);std::vector<std::string> completions;struct Repair{std::string word;double cost;};std::vector<Repair> repairs;
 for(const auto &word:englishVocabulary()){auto normalized=englishLower(word);if(normalized==lower)continue;
  if(normalized.rfind(lower,0)==0)completions.push_back(word);
  else {auto cost=englishCorrectionCost(lower,normalized);if(std::isfinite(cost))repairs.push_back({word,cost});}
 }
 std::stable_sort(repairs.begin(),repairs.end(),[](const Repair &a,const Repair &b){return a.cost<b.cost;});
 auto append=[&](const std::string &word){auto value=englishCase(word,input);if(result.size()<std::min(limit,size_t(24))&&std::find(result.begin(),result.end(),value)==result.end())result.push_back(std::move(value));};
 const auto head=std::min(completions.size(),std::min(size_t(6),std::max(size_t(1),limit>3?limit-3:1)));
 for(size_t i=0;i<head;++i)append(completions[i]);
 if(!repairs.empty())for(const auto &repair:repairs)if(repair.cost<=repairs.front().cost+.6)append(repair.word);
 for(size_t i=head;i<completions.size();++i)append(completions[i]);return result;
}
} // namespace private_input
