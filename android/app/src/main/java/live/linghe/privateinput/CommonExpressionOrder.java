package live.linghe.privateinput;
import java.io.*;import java.nio.*;import java.nio.channels.*;import java.nio.charset.*;import java.util.*;import java.util.function.Predicate;

/** Same bounded public-frequency tiers as Apple. Native IDs and tail stay intact. */
final class CommonExpressionOrder {
 interface Scorer {double score(String before,String text);}
 private final ByteBuffer data;private final Scorer scorer;private final Map<String,Long> cache=new HashMap<>();
 CommonExpressionOrder(File file,Scorer scorer)throws IOException{try(FileInputStream in=new FileInputStream(file)){long size=in.getChannel().size();if(size<1||size>8*1024*1024)throw new IOException("essay size");data=in.getChannel().map(FileChannel.MapMode.READ_ONLY,0,size);}this.scorer=scorer;}
 long frequency(String text){Long cached=cache.get(text);if(cached!=null)return cached;byte[] wanted=text.getBytes(StandardCharsets.UTF_8);int lo=0,hi=data.limit();long value=0;
  while(lo<hi){int start=(lo+hi)/2;while(start>lo&&data.get(start-1)!=10)start--;int tab=start;while(tab<data.limit()&&data.get(tab)!=9&&data.get(tab)!=10)tab++;int end=tab;while(end<data.limit()&&data.get(end)!=10)end++;int comparison=0;int n=Math.min(tab-start,wanted.length);for(int i=0;i<n;i++){comparison=Integer.compare(data.get(start+i)&255,wanted[i]&255);if(comparison!=0)break;}if(comparison==0)comparison=Integer.compare(tab-start,wanted.length);
   if(comparison==0){if(tab<end&&data.get(tab)==9)for(int i=tab+1;i<end;i++){int b=data.get(i)&255;if(b==13)break;if(b<48||b>57||value>(Long.MAX_VALUE-9)/10){value=0;break;}value=value*10+b-48;}break;}
   if(comparison<0)lo=Math.min(data.limit(),end+1);else hi=start;
  }
  if(cache.size()>=512)cache.clear();cache.put(text,value);return value;
 }
 private int tier(String text,String context){long frequency=frequency(text);double isolated=scorer.score("",text);int tier=frequency>=3000?3:0;
  if(tier==0&&text.codePointCount(0,text.length())<=4&&frequency>=200&&Double.isFinite(isolated)&&isolated>-3.5){boolean common=true;for(int cp:text.codePoints().toArray())if(frequency(new String(Character.toChars(cp)))<5000){common=false;break;}if(common)tier=2;}
  if(tier<3&&!context.isEmpty()&&Double.isFinite(isolated)&&isolated>-11){double contextual=scorer.score(context,text);if(Double.isFinite(contextual)&&contextual-isolated>=1.5)tier=3;}return tier;
 }
 String[][] apply(String[][] rows,boolean nine,String context,Predicate<String[]> protectedRow){
  if(rows.length<3||rows[0].length<5||!rows[0][4].isEmpty()||rows[0][2].length()<4)return rows;
  String raw=rows[0][2],code=NineSpelling.rawCode(raw);if(code==null)return rows;Map<String,List<Integer>> groups=new LinkedHashMap<>();
  for(int i=1;i<Math.min(rows.length,65);i++){String[] row=rows[i];if(row.length<3||!row[0].matches("[0-9]+")||row[1].codePointCount(0,row[1].length())<2||protectedRow.test(row)||!code.equals(NineSpelling.encode(row[2]))||!nine&&!PinyinMatch.isFullSpelling(raw,row[2]))continue;groups.computeIfAbsent(row[2].trim().replaceAll("[ ']+","'"),k->new ArrayList<>()).add(i);}
  String[][] result=rows.clone();String bounded=new ContextWindow(context,"").before;
  for(List<Integer> positions:groups.values()){if(positions.size()<2||frequency(rows[positions.get(0)][1])>=3000)continue;Map<Integer,Integer> tiers=new HashMap<>();for(int i:positions)tiers.put(i,tier(rows[i][1],bounded));List<Integer> order=new ArrayList<>(positions);order.sort((a,b)->{int c=Integer.compare(tiers.get(b),tiers.get(a));return c==0?Integer.compare(a,b):c;});for(int i=0;i<positions.size();i++)result[positions.get(i)]=rows[order.get(i)];}
  return result;
 }
}
