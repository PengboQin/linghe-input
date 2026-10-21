package live.linghe.privateinput;
import java.util.*;
final class SymbolOrder {
 static List<String> ordered(List<String> seed,List<String> catalog,Map<String,Long> counts,int limit){
  LinkedHashSet<String> set=new LinkedHashSet<>(seed);for(String symbol:catalog)if(counts.containsKey(symbol))set.add(symbol);ArrayList<String> result=new ArrayList<>(set);result.sort((a,b)->Long.compare(counts.getOrDefault(b,0L),counts.getOrDefault(a,0L)));return new ArrayList<>(result.subList(0,Math.min(result.size(),Math.max(0,Math.min(limit,128)))));
 }
}
