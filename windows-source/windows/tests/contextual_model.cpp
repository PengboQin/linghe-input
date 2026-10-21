#include "PublicContextModel.h"
#include <cassert>
#include <iostream>
int main(int argc,char**argv){assert(argc==2);private_input::PublicContextModel model;assert(model.load(argv[1]));auto hints=model.hints("中国");assert(!hints.empty());auto score=private_input::PublicContextModel::match(hints,hints.front().text);assert(score>0);assert(private_input::PublicContextModel::match(hints,"这是完全不相关的词")==0);assert(model.hints("中国\n").empty());auto punctuation=model.hints("中国，");assert(!punctuation.empty());assert(model.hints(std::string("\xff",1)).empty());std::cout<<"public bounded context model: CJK suffix lookup, clause punctuation, newline boundary, unrelated/invalid input passed\n";}
