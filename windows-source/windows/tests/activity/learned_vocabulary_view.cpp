#include "../../activity/LearnedVocabularyView.h"
#include <cassert>
#include <iostream>
using namespace private_input::activity;
int main(){
 auto row=[](const char*t,uint64_t a,uint64_t b,bool deleted=false,bool pinned=false){return Json::object({{"text",t},{"reading","ni hao"},{"counts",Json::object({{"a",a},{"b",b}})},{"deleted",deleted},{"pinned",pinned}});};
 auto archive=Json::object({{"entries",Json::array({row("deleted",99,0,true),row("zero",0,0),row("low",1,2),row("high",4,5),row("pinned",0,0,false,true)})}});
 auto out=learnedVocabularyView(archive);assert(out.items.size()==3);assert(out.items[0].at("text").str()=="high");assert(out.items[0].at("frequency").num()==9);assert(out.items[1].at("frequency").num()==3);assert(out.items[2].at("pinned").boolean());assert(archive.at("entries").items.size()==5);
 auto huge=learnedVocabularyView(Json::object({{"entries",Json::array({row("big",UINT64_MAX,UINT64_MAX)})}}));assert(huge.items[0].at("frequency").num()==1000000000);
 assert(learnedVocabularyView(Json::object({{"entries",Json::array()}})).items.empty());std::cout<<"learned vocabulary projection passed\n";
}
