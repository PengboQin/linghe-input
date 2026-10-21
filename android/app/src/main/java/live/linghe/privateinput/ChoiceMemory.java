package live.linghe.privateinput;
import java.io.*;import java.util.*;import java.nio.charset.StandardCharsets;import android.util.AtomicFile;import org.json.*;

/** Apple NineKeyChoiceMemory v3 semantics; local only, never part of learning sync. */
final class ChoiceMemory {
 static final int MAX_BYTES=512*1024;
 static final class Entry {final String code,reading,text,context;final int count;Entry(String code,String reading,String text,String context,int count){this.code=code;this.reading=reading;this.text=text;this.context=context;this.count=count;}}
 final int version;final List<Entry> entries;
 ChoiceMemory(){this(3,Collections.emptyList());}
 private ChoiceMemory(int version,List<Entry> entries){this.version=version;this.entries=Collections.unmodifiableList(new ArrayList<>(entries));}
 static String reading(String value){return value.toLowerCase(Locale.ROOT).replace(" ","").replace("'","");}
 private static boolean same(Entry e,String code,String reading,String text,String context){return e.code.equals(code)&&OwnText.equal(e.reading,reading)&&OwnText.equal(e.text,text)&&OwnText.equal(e.context,context);}
 void validate()throws IOException {
  if(version<1||version>3||entries.size()>(version==1?512:1024))throw new IOException("Invalid choice schema");Set<String> keys=new HashSet<>();
  for(Entry e:entries){LosslessJson.unicode(e.text);LosslessJson.unicode(e.context);String target=NineSpelling.encode(e.reading);Double cost=target==null?null:version<3?NineSpelling.editCost(e.code,target):NineSpelling.jointEditCost(e.code,target);String key=java.text.Normalizer.normalize(e.code+'\u001f'+e.reading+'\u001f'+e.text+'\u001f'+e.context,java.text.Normalizer.Form.NFC);
   if(!NineSpelling.isCode(e.code)||e.code.length()>(version==1?24:128)||e.reading.getBytes(StandardCharsets.UTF_8).length>512||cost==null||e.text.isEmpty()||e.text.getBytes(StandardCharsets.UTF_8).length>256||e.text.indexOf('\u001f')>=0||e.text.indexOf('\n')>=0||e.text.indexOf('\r')>=0||e.text.indexOf('\0')>=0||OwnText.characters(e.context).size()>(version==1?4:12)||e.count<1||e.count>1000||!keys.add(key))throw new IOException("Invalid choice record");
  }
 }
 static boolean canRecord(String code,String reading,String text,String context){try{new ChoiceMemory().record(code,reading,text,context,1,false);return true;}catch(Exception invalid){return false;}}
 ChoiceMemory migrated()throws IOException{validate();ChoiceMemory result=new ChoiceMemory(3,entries);result.validate();return result;}
 static ChoiceMemory decode(String value)throws Exception {JSONObject object=LosslessJson.object(value,MAX_BYTES);int version=LosslessJson.unsigned(object.get("version")).intValueExact();JSONArray rows=object.getJSONArray("entries");if(rows.length()>1024)throw new IOException("Choice capacity");ArrayList<Entry> entries=new ArrayList<>();for(int i=0;i<rows.length();i++){JSONObject row=rows.getJSONObject(i);for(String key:new String[]{"code","reading","text","context"})if(!(row.get(key) instanceof String))throw new IOException("Invalid choice string");entries.add(new Entry(row.getString("code"),row.getString("reading"),row.getString("text"),row.getString("context"),LosslessJson.unsigned(row.get("count")).intValueExact()));}ChoiceMemory result=new ChoiceMemory(version,entries);result.validate();return result;}
 String encode()throws Exception {validate();JSONArray rows=new JSONArray();for(Entry e:entries)rows.put(new JSONObject().put("code",e.code).put("reading",e.reading).put("text",e.text).put("context",e.context).put("count",e.count));return LosslessJson.canonical(new JSONObject().put("version",version).put("entries",rows));}
 ChoiceMemory record(String code,String reading,String text,String context,int strength,boolean correction)throws Exception {
  if(strength<1||strength>3)throw new IOException("Invalid strength");String normalized=reading(reading),local=OwnText.preference(context);ArrayList<Entry> next=new ArrayList<>(entries);int count=strength,prior=0;
  for(Entry e:entries)if(e.code.equals(code)&&OwnText.equal(e.reading,normalized)&&OwnText.equal(e.context,local))prior=Math.max(prior,e.count);
  for(int i=0;i<next.size();i++)if(same(next.get(i),code,normalized,text,local)){count=Math.min(1000,next.remove(i).count+strength);break;}
  if(correction)count=Math.min(1000,Math.max(count,prior+3));if(next.size()>=1024)next.remove(0);next.add(new Entry(code,normalized,text,local,count));ChoiceMemory result=new ChoiceMemory(3,next);result.validate();return result;
 }
 ChoiceMemory reset(String text,String reading)throws Exception {String code=NineSpelling.encode(reading);ArrayList<Entry> next=new ArrayList<>();for(Entry e:entries)if(!OwnText.equal(e.text,text)||!Objects.equals(NineSpelling.encode(e.reading),code))next.add(e);ChoiceMemory result=new ChoiceMemory(3,next);result.validate();return result;}
 double boost(String code,String reading,String text,String context){String normalized=reading(reading),local=OwnText.preference(context),raw=OwnText.suffix(context,12);int exact=0,shortCount=0,total=0;double backoff=0;
  for(Entry e:entries)if(e.code.equals(code)&&OwnText.equal(e.reading,normalized)&&OwnText.equal(e.text,text)){total=Math.min(1000,total+e.count);if(OwnText.equal(e.context,local)||OwnText.equal(e.context,raw))exact=Math.max(exact,e.count);if(!e.context.isEmpty()&&OwnText.characters(e.context).size()<=4&&local.endsWith(e.context))shortCount=Math.max(shortCount,e.count);List<String> a=OwnText.characters(local),b=OwnText.characters(OwnText.preference(e.context));int common=0;while(common<Math.min(a.size(),b.size())&&OwnText.equal(a.get(a.size()-1-common),b.get(b.size()-1-common)))common++;if(common>=2&&e.count>=2)backoff=Math.max(backoff,Math.min(4,Math.log1p(e.count)*Math.min(common,6)/3));}
  return Math.max(Math.max(backoff,Math.max(Math.min(8,Math.log1p(exact)*3),Math.min(6,Math.log1p(shortCount)*2.5))),total>=2?Math.min(4,Math.log1p(total)*1.2):0);
 }
 int recency(String code,String reading,String text){for(int i=entries.size()-1;i>=0;i--){Entry e=entries.get(i);if(e.code.equals(code)&&OwnText.equal(e.reading,reading(reading))&&OwnText.equal(e.text,text))return i;}return -1;}
 static final class Store {
  private final File directory;private final AtomicFile file;private final String epoch;
  Store(File directory){this.directory=directory;this.epoch=PersonalReset.fileGeneration(directory);file=new AtomicFile(new File(directory,"nine-choice-memory-v3.json"));}
  ChoiceMemory load()throws Exception {String value=AppFiles.readOptional(file,MAX_BYTES);return value==null?new ChoiceMemory():decode(value).migrated();}
  interface Change{ChoiceMemory apply(ChoiceMemory old)throws Exception;}
  ChoiceMemory change(Change change)throws Exception{return AppFiles.locked(directory,"choice-memory.lock",()->{if(!epoch.equals(PersonalReset.fileGeneration(directory)))throw new IOException("个人资料已重置");ChoiceMemory old=load(),next=change.apply(old);String encoded=next.encode();if(!encoded.equals(old.encode()))AppFiles.write(file,encoded,MAX_BYTES);return next;});}
 }
}
