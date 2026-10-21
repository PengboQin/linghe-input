#pragma once
#include <string>
namespace private_input {
struct SymbolPlan{std::wstring text;int caretBack=0;};
inline SymbolPlan symbolPlan(const std::wstring&symbol,bool pair=true,bool inside=true){if(!pair)return {symbol,0};const std::pair<const wchar_t*,const wchar_t*>pairs[]={{L"(",L")"},{L"（",L"）"},{L"[",L"]"},{L"【",L"】"},{L"{",L"}"},{L"《",L"》"},{L"〈",L"〉"},{L"「",L"」"},{L"『",L"』"},{L"“",L"”"},{L"‘",L"’"},{L"\"",L"\""}};for(const auto&p:pairs)if(symbol==p.first){std::wstring closing=p.second;return {symbol+closing,inside?int(closing.size()):0};}return {symbol,0};}
}
