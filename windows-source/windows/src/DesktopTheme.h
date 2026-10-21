#pragma once
#include <algorithm>
#include <cmath>
namespace private_input {
struct ThemeRGB {double red=0,green=0,blue=0;double luminance()const{auto linear=[](double c){return c<=.04045?c/12.92:std::pow((c+.055)/1.055,2.4);};return .2126*linear(red)+.7152*linear(green)+.0722*linear(blue);}double contrast(const ThemeRGB&o)const{auto a=luminance(),b=o.luminance();return (std::max(a,b)+.05)/(std::min(a,b)+.05);}};
struct DesktopTheme {int mode=0,accent=0;struct Palette{ThemeRGB background,text,selection,border;};Palette palette(bool systemDark=false)const{bool dark=mode==2||(mode==0&&systemDark);ThemeRGB accents[]={{.62,.18,.34},{.53,.32,.06},{.43,.27,.65},{.32,.35,.39}};auto chosen=accents[std::clamp(accent,0,3)];double amount=dark?.40:.86,base=dark?0:1;ThemeRGB selection{chosen.red*(1-amount)+base*amount,chosen.green*(1-amount)+base*amount,chosen.blue*(1-amount)+base*amount};return {dark?ThemeRGB{.10,.10,.11}:ThemeRGB{1,1,1},dark?ThemeRGB{.96,.96,.96}:ThemeRGB{.10,.10,.10},selection,dark?ThemeRGB{.35,.35,.35}:ThemeRGB{.82,.82,.82}};}};
}
