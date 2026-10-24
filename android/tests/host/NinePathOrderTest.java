package live.linghe.privateinput;

import java.util.Arrays;

/** A reordered visible row must still select the same text and native ID. */
public final class NinePathOrderTest {
 private static void require(boolean ok,String message){if(!ok)throw new AssertionError(message);}
 private static String[] row(String id,String text,String reading){return new String[]{id,text,reading};}
 public static void main(String[] args){
  String[][] rows={row("metadata","你 shuo sha","7486742"),row("81","说舌","shuo she"),row("36","说啥","shuo sha"),row("105","说","shuo"),row("repair:9","手刹","shou sha"),row("64","硕砂","shuo sha")};
  String[][] copy=rows.clone();
  String[][] ordered=NinePathOrder.apply(rows,new int[]{2,0,1,2,0},0);
  require(Arrays.equals(ordered,new String[][]{rows[0],rows[2],rows[5],rows[3],rows[1],rows[4]}),"full remaining path, alternatives and stable homophones");
  require(Arrays.equals(rows,copy),"source snapshot order unchanged");
  for(String[] original:rows){boolean identity=false;for(String[] value:ordered)if(value==original)identity=true;require(identity,"original ID/text/reading identity preserved");}
  require(ordered[1][0].equals("36")&&ordered[1][1].equals("说啥"),"first visible selection still targets native36");
  String[][] pinned=NinePathOrder.apply(rows,new int[]{2,0,1,2,0},1);
  require(pinned[1]==rows[1]&&pinned[2]==rows[2],"explicit leading pin survives soft path preference");
  require(NinePathOrder.apply(rows,null,0)==rows,"missing native result leaves snapshot intact");
  require(NinePathOrder.apply(rows,new int[]{0},0)==rows,"incomplete native result cannot drop visible rows");
  require(NinePathOrder.apply(rows,new int[]{0,0,0,0,0},6)==rows,"invalid pin boundary leaves snapshot intact");
  String[][] unknown=NinePathOrder.apply(rows,new int[]{-1,9,1,2,0},0);
  require(unknown.length==rows.length&&unknown[1]==rows[5]&&unknown[3]==rows[1],"unknown tiers keep alternatives rather than hiding them");
  require(NinePathOrder.apply(new String[0][],new int[0],0).length==0,"empty state safe");
  String[][] empty={{"","","64746742","","你"}};
  String[][] carry=NinePathOrder.carry(empty,"说啥","shuo sha",true,0);
  require(carry.length==3&&carry[1][0].equals("path:full")&&carry[1][1].equals("说啥")&&carry[2][0].equals("path:prefix")&&carry[2][1].equals("说"),"known tail and first character available before async recall");
  String[][] source={rows[0],row("7","说","shuo"),row("9","说舌","shuo she")};
  String[][] mapped=NinePathOrder.carry(source,"说啥","shuo sha",true,0);
  require(mapped.length==4&&mapped[2][0].equals("path:prefix")&&mapped[3]==source[2],"mapped prefix uses guarded selection, unrelated native identity retained");
  require(NinePathOrder.carry(source,"说啥","shuo",true,0)==source,"ambiguous text to syllable mapping cannot invent a carried word");
  System.out.println("PASS nine-key path publication, original native IDs, pins, invalid native results and stable alternatives");
 }
}
