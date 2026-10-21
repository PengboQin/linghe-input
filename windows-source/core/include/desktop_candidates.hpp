#pragma once
#include <algorithm>
#include <cstddef>
namespace private_input {
struct DesktopCandidates {
 int collapsed=6,columns=6,rows=6;std::size_t count=0,selected=0;bool expanded=false;
 void configure(int a,int b,int c){collapsed=std::clamp(a,3,9);columns=std::clamp(b,3,9);rows=std::clamp(c,3,9);}
 int width()const{return expanded?columns:collapsed;}
 std::size_t pageSize()const{return expanded?std::size_t(columns*rows):std::size_t(collapsed);}
 std::size_t first()const{return selected/pageSize()*pageSize();}
 void reset(std::size_t n){count=n;selected=0;expanded=false;}
 void horizontal(int delta){if(count)selected=std::size_t(std::clamp<long long>(static_cast<long long>(selected)+delta,0,static_cast<long long>(count)-1));}
 void vertical(int delta){if(!expanded){expanded=true;return;}horizontal(delta*columns);}
 void page(int delta){horizontal(delta*int(pageSize()));}
 std::size_t digit(unsigned d)const{auto index=selected/std::size_t(width())*std::size_t(width())+d-1;return d>=1&&d<=unsigned(width())&&index<count?index:count;}
 unsigned shortcut(std::size_t index)const{return index<count&&index/std::size_t(width())==selected/std::size_t(width())?unsigned(index%std::size_t(width()))+1:0;}
};
}
