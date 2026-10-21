#include "CandidateLayout.h"
#include <cassert>
#include <climits>
#include <iostream>

using namespace private_input;
void validate(const CandidateLayout& layout,int width,int height,std::size_t count){
 assert(layout.width>=0&&layout.width<=width&&layout.height>=0&&layout.height<=height);
 for(const auto& slot:layout.slots){const auto& r=slot.rect;
  assert(slot.index<count&&r.left>=layout.border&&r.right<=layout.width-layout.border);
  assert(r.top>=layout.border&&r.bottom<=layout.height-layout.border&&r.left<r.right&&r.top<r.bottom);
  assert(layout.hit(r.left,r.top)==slot.index);
  assert(layout.hit(r.right-1,r.bottom-1)==slot.index);
 }
 assert(!layout.hit(-1,0)&&!layout.hit(0,-1)&&!layout.hit(layout.width,layout.height));
 for(int y=0;y<layout.height;++y)for(int x=0;x<layout.width;++x){
  int matches=0;for(const auto& slot:layout.slots)matches+=slot.rect.contains(x,y);
  assert(matches<=1);assert(bool(layout.hit(x,y))==(matches==1));
 }
}
int main(){
 DesktopCandidates state;state.reset(6);
 const std::vector<int> shortWords{32,32,16,16,32,16};
 auto compact=candidateLayout(shortWords,state,1920,1080,96);
 validate(compact,1920,1080,6);assert(compact.width<6*104);
 assert(compact.slots[0].rect.right-compact.slots[0].rect.left==66);
 auto longWords=shortWords;longWords[0]=320;
 auto longer=candidateLayout(longWords,state,1920,1080,96);
 assert(longer.width>compact.width&&longer.slots[0].rect.right-longer.slots[0].rect.left==354);
 auto capped=candidateLayout(std::vector<int>(6,INT_MAX),state,1920,1080,96);
 validate(capped,1920,1080,6);assert(capped.width==900);
 auto narrow=candidateLayout(longWords,state,97,1080,96);
 validate(narrow,97,1080,6);assert(narrow.width==97&&narrow.slots.size()==6);
 auto doubled=shortWords;for(auto& width:doubled)width*=2;
 auto dpi=candidateLayout(doubled,state,3840,2160,192);
 validate(dpi,3840,2160,6);assert(dpi.width==compact.width*2&&dpi.height==compact.height*2);
 state.reset(8);state.vertical(1);
 auto grid=candidateLayout(std::vector<int>(8,300),state,1920,1080,96);
 validate(grid,1920,1080,8);assert(grid.slots.size()==8&&grid.width==626&&grid.height==66);
 assert(!grid.hit(300,40)); // Last row's empty cells never select an out-of-range candidate.
 assert(!grid.hit(0,10)&&!grid.hit(grid.width-1,10));
 for(const auto& slot:grid.slots)assert(slot.rect.right-slot.rect.left==104);
 auto clipped=candidateLayout(std::vector<int>(8,300),state,1920,40,96);
 validate(clipped,1920,40,8);assert(clipped.height==34&&clipped.slots.size()==6);
 state.selected=7;
 auto selectedShortScreen=candidateLayout(std::vector<int>(8,300),state,1920,40,96);
 validate(selectedShortScreen,1920,40,8);assert(selectedShortScreen.slots.front().index==6&&selectedShortScreen.slots.size()==2);
 assert(selectedShortScreen.hit(110,10)==7);
 state.reset(40);state.expanded=true;state.selected=38;
 auto finalPage=candidateLayout(std::vector<int>(40,16),state,1920,1080,96);
 validate(finalPage,1920,1080,40);assert(finalPage.slots.size()==4&&finalPage.slots.front().index==36&&finalPage.width==grid.width);
 assert(!finalPage.hit(500,10));
 state.reset(1);auto singleton=candidateLayout({16},state,1000,1000,96);assert(singleton.slots.size()==1);
 assert(candidateLayout({},state,100,100,96).slots.empty());
 assert(candidateLayout({16},state,2,100,96).slots.empty());
 const CandidateRect work{-1280,-100,-280,700};
 auto position=candidatePosition({-300,680,-290,700},work,626,194,4);
 assert(position.x==-906&&position.y==482);
 position=candidatePosition({-1400,-200,-1390,-180},work,626,194,4);
 assert(position.x==-1280&&position.y==-100);
 for(unsigned scale:{48u,96u,120u,144u,192u,288u,768u})for(int width:{16,50,97,624,900}){
  state.reset(11);state.expanded=true;state.selected=10;
  auto sample=candidateLayout(std::vector<int>(11,INT_MAX),state,width,93,scale);
  validate(sample,width,93,11);
  bool selectedVisible=false;for(const auto& slot:sample.slots)selectedVisible|=slot.index==state.selected;
  assert(selectedVisible);
 }
 std::cout<<"PASS natural widths, bounded long sentences, narrow-screen pixel ownership, DPI, stable grid, empty-cell rejection and screen placement\n";
}
