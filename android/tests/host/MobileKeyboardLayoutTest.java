package live.linghe.privateinput;
import java.util.HashSet;
import java.util.Set;

public final class MobileKeyboardLayoutTest {
 private static int checks;
 private static void require(boolean ok,String why){checks++;if(!ok)throw new AssertionError(why);}
 public static void main(String[] args){
  require(EnglishKeyboardRows.fullWidth(true,false,false,false),"English letters use all available body width");
  require(EnglishKeyboardRows.fullWidth(false,true,false,false),"textual password keyboard keeps the same letter geometry");
  require(!EnglishKeyboardRows.fullWidth(false,false,false,false),"Chinese layout retains its existing rails");
  require(!EnglishKeyboardRows.fullWidth(true,false,true,false),"number panel takes precedence over English flag");
  require(!EnglishKeyboardRows.fullWidth(true,false,false,true),"symbol panel retains its existing category region");
  Set<Character> alphabet=new HashSet<>();
  for(int row=0;row<3;row++){
   String letters=EnglishKeyboardRows.letters(row);require(letters.length()==new int[]{10,9,7}[row],"standard 10/9/7 mobile rows");
   for(char c:letters.toCharArray())require(alphabet.add(c),"each letter has exactly one key");
   require(letters.length()+2*EnglishKeyboardRows.outerWeight(row)==10,"every row spans exactly ten letter units");
  }
  require(alphabet.size()==26,"all 26 letters remain available");
  for(int width:new int[]{320,360,392,411,592}){
   float unit=width/10f;require(Math.abs((9*unit+2*unit*.5f)-width)<0.001f,"second row stays centered at compact and large widths");
   require(Math.abs((7*unit+2*unit*1.5f)-width)<0.001f,"Shift and Delete consume symmetric row ends");
  }
  TapReleaseState tap=new TapReleaseState();tap.begin();require(tap.finish(55,47,56,48),"full visible expansion target is tappable");
  require(!tap.finish(55,47,56,48),"duplicate UP cannot toggle twice");
  tap.begin();tap.cancel();require(!tap.finish(10,10,56,48),"interrupted gesture cannot leave a pending click");
  tap.begin();tap.move(90,10,56,48,8);require(!tap.finish(10,10,56,48),"drag outside and back does not select a key");
  tap.begin();require(!tap.finish(-1,10,56,48),"release outside the visible target is cancelled");
  int toggles=0;KeyboardRenderGate gate=new KeyboardRenderGate();
  for(int i=0;i<100;i++){gate.begin(true);tap.begin();if(tap.finish(12,12,56,48))toggles++;require(gate.defer(true),"synchronous release action remains protected until root UP ends");require(gate.end(),"one protected tap drains its redraw");}
  require(toggles==100,"rapid expand/collapse taps deliver exactly once per completed gesture");
  System.out.println("PASS mobile letter/tap contracts="+checks+" nativeViewRuntime=false");
 }
}
