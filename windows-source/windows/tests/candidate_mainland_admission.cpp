#include "CandidateAdmission.h"
#include "CandidateStream.h"
#include <algorithm>
#include <iostream>
#include <stdexcept>

int main(){
  unsigned checks=0;
  const auto require=[&](bool value,const char*why){if(!value)throw std::runtime_error(why);++checks;};
  const auto present=[](const std::string&){return true;};
  for(const auto*text:{"有","猫猫","淘宝","天猫","吕明","深圳","apple","GPT-5.2","☀️"})
    require(private_input::candidateAllowedForDisplay(text,present),"ordinary simplified/name/platform/ASCII candidate rejected");
  for(const auto*text:{"貓貓","臺灣","𨈖","","\U000323B0","\U0003FFFD","一\U000E0101"}){
    unsigned glyphCalls=0;
    require(!private_input::candidateAllowedForDisplay(text,[&](const auto&){++glyphCalls;return true;}),"render provider bypassed shared native admission");
    require(glyphCalls==0,"rejected candidate still entered glyph work");
  }
  require(!private_input::candidateAllowedForDisplay("猫猫",[](const auto&){return false;}),"device glyph failure must remain an independent veto");
  private_input::CandidateStream stream;
  stream.reset([](size_t,size_t){return std::vector<private_input::CandidateChoice>{{"貓貓",7,SIZE_MAX,"mao mao",false},{"猫猫",19,SIZE_MAX,"mao mao",false}};},{});
  stream.rows.push_back({"臺灣",SIZE_MAX,SIZE_MAX,"tai wan",true});
  stream.rows.push_back({"淘宝",SIZE_MAX,SIZE_MAX,"tao bao",true});
  stream.rows.erase(std::remove_if(stream.rows.begin(),stream.rows.end(),[&](const auto&row){return !private_input::candidateAllowedForDisplay(row.text,present);}),stream.rows.end());
  require(stream.rows.size()==2,"final merge did not filter native and custom sources alike");
  require(stream.rows[0].text=="猫猫"&&stream.rows[0].absolute==19,"visible filtering changed native absolute candidate identity");
  require(stream.rows[1].text=="淘宝"&&stream.rows[1].custom,"ordinary personal candidate did not survive final merge");
  std::cout<<"PASS "<<checks<<" actual shared ABI/Windows admission/stream checks; nativeSessions=false WindowsHost=false\n";
}
