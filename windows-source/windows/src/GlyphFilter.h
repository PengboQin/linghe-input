#pragma once
#include <windows.h>
#include <string>
#include <vector>
class CandidateGlyphFilter{
 HDC dc=nullptr;HFONT font=nullptr;HGDIOBJ previous=nullptr;
public:
 CandidateGlyphFilter(){dc=CreateCompatibleDC(nullptr);if(dc){font=CreateFontW(-16,0,0,0,FW_NORMAL,FALSE,FALSE,FALSE,DEFAULT_CHARSET,OUT_DEFAULT_PRECIS,CLIP_DEFAULT_PRECIS,CLEARTYPE_QUALITY,DEFAULT_PITCH,L"Microsoft YaHei UI");if(font)previous=SelectObject(dc,font);}}
 ~CandidateGlyphFilter(){if(dc&&previous)SelectObject(dc,previous);if(font)DeleteObject(font);if(dc)DeleteDC(dc);}
 bool supports(const std::wstring&text)const{if(!dc||!font||text.empty()||text.size()>4096)return false;std::vector<WORD>glyphs(text.size());if(GetGlyphIndicesW(dc,text.data(),int(text.size()),glyphs.data(),GGI_MARK_NONEXISTING_GLYPHS)==GDI_ERROR)return false;for(auto g:glyphs)if(g==0xffff)return false;return true;}
};
