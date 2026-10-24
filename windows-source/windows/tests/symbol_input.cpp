#include "SymbolPairing.h"
#include <iostream>
#include <stdexcept>
using namespace private_input;
static int checks;
static void check(bool okay,const char*message){if(!okay)throw std::runtime_error(message);++checks;}
int main(){
 for(const auto&row:{std::pair<const wchar_t*,const wchar_t*>{L",",L"，"},{L".",L"。"},{L"?",L"？"},{L"!",L"！"},{L":",L"："},{L";",L"；"},{L"\"",L"“"},{L"'",L"‘"},{L"(",L"（"},{L")",L"）"},{L"[",L"【"},{L"]",L"】"}}){
  check(punctuationSymbol(row.first,true)==row.second,"Chinese physical punctuation");
  check(punctuationSymbol(row.first,false)==row.first,"English remains literal");
  check(punctuationSymbol(row.first,true,true)==row.first,"Numeric/URL/email field remains ASCII");
 }
 check(punctuationSymbol(L".",true,false,true)==L".","1.4 and version decimals");
 for(auto symbol:{L"@",L"#",L"$",L"%",L"^",L"&",L"*",L"+",L"-",L"/",L"="})check(punctuationSymbol(symbol,true)==symbol,"Shift digits/operators are not globally fullwidth");
 auto plan=symbolPlan(punctuationSymbol(L"(",true));check(plan.text==L"（）"&&plan.caretBack==1,"Map before pairing");
 check(symbolPlan(punctuationSymbol(L"\"",true)).text==L"“”","Chinese quotation pairing");
 check(symbolPlan(L"(",false).text==L"(","Pair disabled");
 check(symbolPlan(L"(",true,false).caretBack==0,"Outside caret setting retained");
 check(plainPairBackspace(false,false,false,false),"Bare Backspace allowed");
 check(!plainPairBackspace(true,false,false,false),"Shift Backspace passes through");
 check(!plainPairBackspace(false,true,false,false),"Ctrl Backspace passes through");
 check(!plainPairBackspace(false,false,true,false),"Alt Backspace passes through");
 check(!plainPairBackspace(false,false,false,true),"Windows Backspace passes through");
 AutomaticPairReceipt receipt;
 check(!receipt.permits(1,L"（）",true),"Manual/pasted adjacent pair has no capability");
 receipt.record(1,L"（）");check(receipt.permits(1,L"（）",true),"Own unchanged empty pair");
 check(!receipt.permits(2,L"（）",true),"Different host rejected");
 check(!receipt.permits(1,L"（）",false),"Caret or selection moved");
 check(!receipt.permits(1,L"（x）",true),"Edited contents rejected");
 receipt.invalidate();check(!receipt.permits(1,L"（）",true),"Edited then restored text is not new authority");
 receipt.record(1,L"()");receipt.invalidate();check(!receipt.permits(1,L"()",true),"Movement away and back remains invalid");
 receipt.record(1,L"()");check(receipt.permits(1,L"()",true),"English pair receipt");receipt.invalidate();
 check(!receipt.permits(1,L"()",true),"Second Backspace cannot replay deletion");
 std::cout<<"symbol input: "<<checks<<" assertions passed\n";
}
