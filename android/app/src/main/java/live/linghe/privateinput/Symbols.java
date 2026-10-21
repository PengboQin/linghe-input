package live.linghe.privateinput;
import android.content.Context;import org.json.*;import java.io.*;import java.util.*;
final class Symbols {
 final String[] titles;final String[][] pages;
 Symbols(Context c){try(InputStream in=c.getAssets().open("symbols.json")){ByteArrayOutputStream bytes=new ByteArrayOutputStream();byte[] buf=new byte[4096];int n;while((n=in.read(buf))>0)bytes.write(buf,0,n);JSONArray categories=new JSONObject(bytes.toString("UTF-8")).getJSONArray("categories");titles=new String[categories.length()];pages=new String[titles.length][];for(int i=0;i<titles.length;i++){JSONObject item=categories.getJSONObject(i);titles[i]=item.getString("title");JSONArray values=item.getJSONArray("symbols");pages[i]=new String[values.length()];for(int j=0;j<values.length();j++)pages[i][j]=values.getString(j);}}catch(Exception e){throw new IllegalStateException("Symbol catalog unavailable",e);}}
 void record(String symbol,android.content.SharedPreferences prefs){Set<String> allowed=new HashSet<>();for(String[] page:pages)allowed.addAll(Arrays.asList(page));for(int i=0;i<4;i++)allowed.add(prefs.getString("rail"+i,new String[]{"，","。","！","？"}[i]));if(!allowed.contains(symbol)||symbol.getBytes(java.nio.charset.StandardCharsets.UTF_8).length>32)return;Map<String,Long> counts=counts(prefs);if(!counts.containsKey(symbol)&&counts.size()>=512)return;prefs.edit().putLong("symbol-use-"+symbol,Math.min(1000000,counts.getOrDefault(symbol,0L)+1)).apply();}
 private Map<String,Long> counts(android.content.SharedPreferences prefs){Map<String,Long> result=new HashMap<>();for(Map.Entry<String,?> entry:prefs.getAll().entrySet())if(entry.getKey().startsWith("symbol-use-")&&entry.getValue() instanceof Long){long count=(Long)entry.getValue();if(count>0&&count<=1000000)result.put(entry.getKey().substring(11),count);}return result;}
 String[] rail(String[] seed,boolean numeric,boolean useLearning,android.content.SharedPreferences prefs){
  if(!useLearning)return seed.clone();ArrayList<String> allowed=new ArrayList<>();
  for(String[] page:pages)for(String symbol:page)if(!numeric||symbol.matches("[\\x21-\\x2f\\x3a-\\x40\\x5b-\\x60\\x7b-\\x7e]"))allowed.add(symbol);
  return SymbolOrder.ordered(Arrays.asList(seed),allowed,counts(prefs),64).toArray(new String[0]);
 }
 String[] page(int index,android.content.SharedPreferences prefs){if(index!=0)return pages[index].clone();ArrayList<String> catalog=new ArrayList<>();for(String[] page:pages)catalog.addAll(Arrays.asList(page));return SymbolOrder.ordered(Arrays.asList(pages[0]),catalog,counts(prefs),64).toArray(new String[0]);}
}
