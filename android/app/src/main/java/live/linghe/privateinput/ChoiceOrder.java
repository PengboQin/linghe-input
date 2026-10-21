package live.linghe.privateinput;
import java.util.*;import java.util.function.Predicate;import java.util.function.ToDoubleFunction;

/** Reorder only unpinned native candidates with the exact same syllable identity. */
final class ChoiceOrder {
 static String identity(String reading){return reading.toLowerCase(Locale.ROOT).trim().replaceAll("[ ']+","'");}
 static String[][] apply(String[][] rows,String own,ChoiceMemory memory,OwnCommitTracker.Replacement retry,int document,long now,Predicate<CandidateViews.Item> pinned){
  return apply(rows,own,memory,retry,document,now,pinned,item->0);
 }
 static String[][] apply(String[][] rows,String own,ChoiceMemory memory,OwnCommitTracker.Replacement retry,int document,long now,Predicate<CandidateViews.Item> pinned,ToDoubleFunction<CandidateViews.Item> recent){
  if(rows.length<3||rows[0].length<5||!rows[0][4].isEmpty())return rows;String code=NineSpelling.rawCode(rows[0][2]);if(code==null)return rows;Map<String,List<Integer>> groups=new LinkedHashMap<>();
  for(int i=1;i<rows.length;i++)if(rows[i][0].matches("[0-9]+")&&!pinned.test(new CandidateViews.Item(rows[i]))&&!identity(rows[i][2]).isEmpty())groups.computeIfAbsent(identity(rows[i][2]),k->new ArrayList<>()).add(i);
  String[][] result=rows.clone();boolean reject=retry!=null&&retry.current(document,now,own)&&retry.code.equals(code)&&retry.reading!=null;
  for(Map.Entry<String,List<Integer>> group:groups.entrySet()){List<Integer> positions=group.getValue(),order=new ArrayList<>(positions);order.sort((a,b)->{boolean ra=reject&&OwnText.equal(rows[a][1],retry.rejected)&&group.getKey().equals(identity(retry.reading)),rb=reject&&OwnText.equal(rows[b][1],retry.rejected)&&group.getKey().equals(identity(retry.reading));if(ra!=rb)return ra?1:-1;double x=memory.boost(code,rows[a][2],rows[a][1],own)+recent.applyAsDouble(new CandidateViews.Item(rows[a])),y=memory.boost(code,rows[b][2],rows[b][1],own)+recent.applyAsDouble(new CandidateViews.Item(rows[b]));int c=Double.compare(y,x);if(c!=0)return c;if(x>0){c=Integer.compare(memory.recency(code,rows[b][2],rows[b][1]),memory.recency(code,rows[a][2],rows[a][1]));if(c!=0)return c;}return Integer.compare(a,b);});for(int i=0;i<positions.size();i++)result[positions.get(i)]=rows[order.get(i)];}
  return result;
 }
}
