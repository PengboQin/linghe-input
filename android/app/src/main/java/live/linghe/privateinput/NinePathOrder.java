package live.linghe.privateinput;

import java.util.ArrayList;
import java.util.List;

/** Presentation of a core-validated, remaining reading; never rewrites input. */
final class NinePathOrder {
 private static boolean same(String[] row,String text,String reading){return row.length>=3&&row[1].equals(text)&&row[2].trim().replaceAll("[ ']+"," ").equals(reading);}
 static String[][] carry(String[][] rows,String text,String reading,boolean mapped,int protectedCount){
  if(rows.length==0||text==null||text.isEmpty()||reading==null||protectedCount<0||protectedCount>=rows.length)return rows;
  String canonical=reading.trim().replaceAll("[ ']+"," ");String[] parts=canonical.split(" ");
  if(!canonical.matches("[a-z]+(?: [a-z]+)*")||text.codePointCount(0,text.length())!=parts.length)return rows;
  String first=text.substring(0,text.offsetByCodePoints(0,1));boolean fullExists=false,firstExists=false;
  for(int i=1;i<rows.length;i++){fullExists|=same(rows[i],text,canonical);firstExists|=same(rows[i],first,parts[0]);}
  boolean protectedFirst=false;for(int i=1;i<=protectedCount;i++)protectedFirst|=same(rows[i],first,parts[0]);
  boolean addFull=!fullExists,addFirst=parts.length>1&&!protectedFirst&&(!firstExists||mapped);
  if(!addFull&&!addFirst)return rows;
  List<String[]> output=new ArrayList<>();for(int i=0;i<=protectedCount;i++)output.add(rows[i]);
  if(addFull)output.add(new String[]{"path:full",text,canonical});
  if(addFirst)output.add(new String[]{"path:prefix",first,parts[0]});
  for(int i=1+protectedCount;i<rows.length;i++)if(!addFirst||!same(rows[i],first,parts[0]))output.add(rows[i]);
  return output.toArray(new String[0][]);
 }
 static String[][] apply(String[][] rows,int[] priorities,int protectedCount) {
  if(rows.length<2||priorities==null||priorities.length!=rows.length-1||protectedCount<0||protectedCount>priorities.length)return rows;
  List<String[]> ordered=new ArrayList<>(rows.length);ordered.add(rows[0]);
  for(int i=1;i<=protectedCount;i++)ordered.add(rows[i]);
  // Stable partition: IDs, spelling, text and every alternative stay intact.
  // The shared core computes tiers, including edit mappings and fresh keys.
  for(int tier=0;tier<3;tier++)for(int i=1+protectedCount;i<rows.length;i++){
   String[] row=rows[i];int score=priorities[i-1];if(score<0||score>2)score=2;
   if(score==tier)ordered.add(row);
  }
  return ordered.toArray(new String[0][]);
 }
}
