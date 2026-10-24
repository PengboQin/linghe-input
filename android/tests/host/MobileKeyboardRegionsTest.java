package live.linghe.privateinput;
import java.util.*;
/** Production geometry/state/binding helpers only; no Android window or physical device. */
public final class MobileKeyboardRegionsTest {
 static int checks;static void require(boolean ok,String label){checks++;if(!ok)throw new AssertionError(label);}
 static int dp(float value,float density){return Math.round(value*density);}
 public static void main(String[] args){
  for(float density:new float[]{1,1.5f,2,2.625f,3.0625f,3.5f})for(int widthDP:new int[]{320,360,393,411,480})for(int heightDP:new int[]{46,58,76}){
   int width=dp(widthDP,density)-2*dp(4,density),margin=dp(2,density),height=dp(heightDP,density),actions=dp(48,density),rail=dp(80,density);
   int pitch=MobileKeyboardRegions.rowPitch(height,margin),body=MobileKeyboardRegions.bodyHeight(height,margin),footer=pitch;
   require(body+footer==MobileKeyboardRegions.totalKeysHeight(height,margin),"expanded body plus unchanged footer retains total keyboard height");
   require(body==3*pitch,"all ordinary rows and expanded body use same pixel rounding");
   require(MobileKeyboardRegions.insetKeyWidth(rail,margin)+2*margin==rail,"footer symbol slot exactly matches rail outer width");
   require(MobileKeyboardRegions.insetKeyWidth(actions,margin)+2*margin==actions,"footer return and right action column exactly align");
   require(MobileKeyboardRegions.expandedWidth(width,actions)==MobileKeyboardRegions.actionLeft(width,actions),"expanded deletion column starts at unchanged x");
   int center=MobileKeyboardRegions.centerWidth(width,rail,actions);require(center+rail+actions==width,"Chinese and number/symbol central widths stay constant");
   int columns=MobileKeyboardRegions.symbolColumns(center,dp(48,density),margin);require(columns>=3&&columns<=5,"symbol columns bounded by content width");require(center/columns-2*margin>=dp(48,density),"symbol target width at least48dp on target-width matrix");
   require(dp(MobileKeyboardRegions.SYMBOL_ROW_DP,density)>=dp(48,density),"rail vertical target raised32to48dp");
  }
  for(int extent:new int[]{48,64,126,147})for(int[] ink:new int[][]{{0,4},{-2,8},{14,20},{1,29},{-20,-1}}){float origin=MobileKeyboardRegions.inkOrigin(extent,ink[0],ink[1]);require(Math.abs(origin+(ink[0]+ink[1])/2f-extent/2f)<0.01f,"comma/period/bracket ink centers are independent of font bearings");}
  DeleteRepeatState repeat=new DeleteRepeatState();long first=repeat.begin();require(repeat.current(first),"press starts owned repeat");repeat.cancel();require(!repeat.current(first),"UP CANCEL detach or new layout cancels old callback");long second=repeat.begin();require(!repeat.current(first)&&repeat.current(second),"old delayed callback cannot delete under a new finger press");require(!repeat.move(0,0,48,58,8)&&repeat.current(second),"edge presses remain within actual button");require(repeat.move(60,20,48,58,8)&&!repeat.current(second),"drag beyond slop stops repeat");long third=repeat.begin();repeat.cancel();require(!repeat.current(third)&&!repeat.move(0,0,48,58,8),"detached view cannot restart repeat by a late move");require(DeleteRepeatState.DELAY_MS==400&&DeleteRepeatState.INTERVAL_MS==65,"existing hold feel preserved");
  KeyboardRenderGate gate=new KeyboardRenderGate();gate.begin(false);require(gate.deferRail(),"native candidate change does not rebuild symbol/filter cells under finger");require(gate.end(),"release drains deferred rail render");require(!gate.deferRail(),"idle rail update does not add delay");
  CandidateViews.Item original=new CandidateViews.Item(new String[]{"0","第一项","di yi xiang"});List<CandidateViews.Item> old=CandidateViews.bindItems(Collections.singletonList(original),11);List<CandidateViews.Item> next=CandidateViews.bindItems(Collections.singletonList(new CandidateViews.Item(new String[]{"0","新第一项","xin di yi xiang"})),12);require(old.get(0).generation==11&&old.get(0).text.equals("第一项"),"pressed candidate retains old item and generation");require(next.get(0).generation==12&&!next.get(0).text.equals(old.get(0).text),"new candidate update is separately bound");try{old.clear();throw new AssertionError("mutable candidate binding");}catch(UnsupportedOperationException expected){checks++;}
  System.out.println("PASS checks="+checks+" productionGeometryAndGestureState=true SDKViewRuntime=false devices=false");
 }
}
