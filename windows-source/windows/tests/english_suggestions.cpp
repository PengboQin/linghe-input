#include "EnglishSuggestions.h"
#include <cassert>
#include <iostream>
#include <set>
using namespace private_input;
int main(){
 auto contains=[](const std::string &input,const std::string &word){auto rows=englishCandidates(input);assert(!rows.empty()&&rows.front()==input);assert(std::find(rows.begin(),rows.end(),word)!=rows.end());};
 contains("appl","apple");contains("aoole","apple");contains("aplpe","apple");contains("aple","apple");contains("appple","apple");contains("helo","hello");contains("hel","hello");contains("AOOLE","APPLE");contains("Aoole","Apple");
 assert(englishCandidates("apple").front()=="apple");assert(englishCandidates("Unknownname").front()=="Unknownname");
 for(const auto &value:{"","a@b","https://","apple pie","1.4","中文", "apple\nsecret"})assert(englishCandidates(value).empty());
 assert(englishCandidates(std::string(49,'a')).empty());assert(englishCandidates("hello",0).empty());assert(englishCandidates("hel",1)==std::vector<std::string>{"hel"});
 assert(!std::isfinite(englishCorrectionCost("abc","world")));assert(!std::isfinite(englishCorrectionCost("hello","hello")));
 assert(englishCorrectionCost("aoole","apple")<englishCorrectionCost("azple","apple"));
 for(const auto &word:englishVocabulary()){
  auto input=englishLower(word);auto rows=englishCandidates(input);assert(!rows.empty()&&rows.front()==input&&rows.size()<=12);std::set<std::string> unique;
  for(const auto &row:rows){assert(englishLetters(row));assert(unique.insert(row).second);assert(row.find(' ')==std::string::npos);}
 }
 std::cout<<"{\"offlineEnglish\":true,\"rawSpellingPreserved\":true,\"completion\":true,\"neighborOmissionInsertionSwap\":true,\"capitalization\":true,\"boundedAsciiOnly\":true}\n";
}
