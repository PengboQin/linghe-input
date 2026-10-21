#pragma once
#include <algorithm>
#include <cstddef>
#include <optional>
#include <vector>
#include "desktop_candidates.hpp"

namespace private_input {
// Physical pixels, shared by painting and hit testing. No platform UI required.
struct CandidateRect {
 int left=0,top=0,right=0,bottom=0;
 bool contains(int x,int y)const{return x>=left&&x<right&&y>=top&&y<bottom;}
};
struct CandidateSlot {std::size_t index;CandidateRect rect;};
struct CandidateLayout {
 int width=0,height=0,border=1;
 std::vector<CandidateSlot> slots;
 std::optional<std::size_t> hit(int x,int y)const{
  for(const auto& slot:slots)if(slot.rect.contains(x,y))return slot.index;
  return std::nullopt;
 }
};
inline int candidateScale(int value,unsigned dpi){return std::max(1,int((static_cast<long long>(value)*std::clamp(dpi,48u,768u)+48)/96));}
inline CandidateLayout candidateLayout(const std::vector<int>& textWidths,const DesktopCandidates& state,int availableWidth,int availableHeight,unsigned dpi){
 CandidateLayout result;
 if(textWidths.empty()||availableWidth<3||availableHeight<3)return result;
 const auto first=state.first();if(first>=textWidths.size())return result;
 const int columns=state.expanded?state.width():std::min(state.width(),int(textWidths.size()-first));
 if(columns<1)return result;
 result.border=std::min(candidateScale(1,dpi),std::min(std::max(1,(availableWidth-columns)/2),(availableHeight-1)/2));
 const int maxWidth=std::min(availableWidth,candidateScale(900,dpi));
 const int contentLimit=maxWidth-2*result.border;
 if(contentLimit<columns)return result;
 const auto count=std::min(state.pageSize(),textWidths.size()-first);
 const int rows=state.expanded?int((count+columns-1)/columns):1;
 const int rowHeight=candidateScale(32,dpi);
 std::vector<int> widths(columns);
 if(state.expanded){
  const int contentWidth=std::min(contentLimit,columns*candidateScale(104,dpi));
  for(int c=0;c<columns;++c)widths[c]=(c+1)*contentWidth/columns-c*contentWidth/columns;
 }else{
  const int minimum=candidateScale(48,dpi),maximum=candidateScale(360,dpi),gutter=candidateScale(34,dpi);
  long long desired=0;
  for(int c=0;c<columns;++c){widths[c]=std::clamp(std::clamp(textWidths[first+c],0,maximum)+gutter,minimum,maximum);desired+=widths[c];}
  if(desired>contentLimit){
   // Preserve natural proportions until space becomes smaller than the minimum
   // touch target. Integer partitioning fills every pixel without overlap.
   const int floor=std::min(minimum,contentLimit/columns);
   long long flexibility=0;for(int width:widths)flexibility+=width-floor;
   const int room=contentLimit-columns*floor;
   long long accumulated=0,previous=0;
   for(int& width:widths){accumulated+=width-floor;const auto share=flexibility?accumulated*room/flexibility:0;width=floor+int(share-previous);previous=share;}
  }
 }
 result.width=2*result.border;for(int width:widths)result.width+=width;
 const int visibleRows=std::min(rows,std::max(1,(availableHeight-2*result.border)/rowHeight));
 result.height=std::min(availableHeight,visibleRows*rowHeight+2*result.border);
 const int selectedRow=state.selected>=first&&state.selected<first+count?int((state.selected-first)/columns):0;
 const int firstVisibleRow=std::clamp(selectedRow-visibleRows+1,0,rows-visibleRows);
 const int bottom=result.height-result.border;
 for(std::size_t offset=0;offset<count;++offset){
  const int row=int(offset/columns),column=int(offset%columns);
  if(row<firstVisibleRow)continue;
  int left=result.border;for(int c=0;c<column;++c)left+=widths[c];
  const int top=result.border+(row-firstVisibleRow)*rowHeight;
  if(top>=bottom)break;
  result.slots.push_back({first+offset,{left,top,left+widths[column],std::min(top+rowHeight,bottom)}});
 }
 return result;
}
struct CandidatePosition {int x=0,y=0;};
inline CandidatePosition candidatePosition(CandidateRect anchor,CandidateRect work,int width,int height,int gap){
 const int maxX=std::max(work.left,work.right-width),maxY=std::max(work.top,work.bottom-height);
 int y=anchor.bottom+gap;if(y>maxY)y=anchor.top-height-gap;
 return {std::clamp(anchor.left,work.left,maxX),std::clamp(y,work.top,maxY)};
}
}
