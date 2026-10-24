#pragma once
#include <string>
#include <cstdint>
namespace private_input {
struct SymbolPlan{std::wstring text;int caretBack=0;};
inline SymbolPlan symbolPlan(const std::wstring&symbol,bool pair=true,bool inside=true){if(!pair)return {symbol,0};const std::pair<const wchar_t*,const wchar_t*>pairs[]={{L"(",L")"},{L"（",L"）"},{L"[",L"]"},{L"【",L"】"},{L"{",L"}"},{L"《",L"》"},{L"〈",L"〉"},{L"「",L"」"},{L"『",L"』"},{L"“",L"”"},{L"‘",L"’"},{L"\"",L"\""}};for(const auto&p:pairs)if(symbol==p.first){std::wstring closing=p.second;return {symbol+closing,inside?int(closing.size()):0};}return {symbol,0};}
// Physical Chinese punctuation is a frontend policy. It never alters native
// candidate text, English spelling, number/address fields or a decimal point.
inline std::wstring punctuationSymbol(const std::wstring&symbol,bool chinese,bool asciiField=false,bool followsDigit=false){
 if(!chinese||asciiField)return symbol;
 if(symbol==L"."&&followsDigit)return symbol;
 const std::pair<const wchar_t*,const wchar_t*>map[]={{L",",L"，"},{L".",L"。"},{L"?",L"？"},{L"!",L"！"},{L":",L"："},{L";",L"；"},{L"(",L"（"},{L")",L"）"},{L"[",L"【"},{L"]",L"】"},{L"<",L"《"},{L">",L"》"},{L"\"",L"“"},{L"'",L"‘"}};
 for(const auto&entry:map)if(symbol==entry.first)return entry.second;
 return symbol;
}
inline bool plainPairBackspace(bool shift,bool control,bool alt,bool windows){return !shift&&!control&&!alt&&!windows;}
// Only an explicit automatic insertion can issue this capability. Equal text
// beside a caret (manual typing, paste or an edited/restored pair) is not enough.
class AutomaticPairReceipt {
 std::uintptr_t context=0;std::wstring inserted;
public:
 void invalidate(){context=0;inserted.clear();}
 void record(std::uintptr_t owner,const std::wstring&text){context=owner;inserted=text;}
 bool active()const{return context!=0&&!inserted.empty();}
 bool permits(std::uintptr_t owner,const std::wstring&actual,bool sameCaret)const{return active()&&owner==context&&sameCaret&&actual==inserted;}
};
}
