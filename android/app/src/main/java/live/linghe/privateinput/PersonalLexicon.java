package live.linghe.privateinput;

import android.util.AtomicFile;
import org.json.*;
import java.io.*;
import java.math.BigInteger;
import java.nio.channels.*;
import java.nio.charset.StandardCharsets;
import java.util.*;

/** Same explicit-entry and Lamport/tombstone schema as the Apple client. */
final class PersonalLexicon {
 static final int MAX_BYTES=512*1024;
 static final class Entry {
  final String id,kind,text,trigger;
  Entry(String id,String kind,String text,String trigger){this.id=uuid(id);this.kind=kind;this.text=text;this.trigger=trigger;}
  static Entry create(String kind,String text,String trigger){return new Entry(UUID.randomUUID().toString(),kind,text,normalize(trigger));}
  static Entry decode(JSONObject v)throws Exception{Entry e=new Entry(string(v,"id"),string(v,"kind"),string(v,"text"),string(v,"trigger"));e.validate(null);return e;}
  JSONObject json()throws Exception{return new JSONObject().put("id",id).put("kind",kind).put("text",text).put("trigger",trigger);}
  String key(){return kind+'\u001f'+trigger+'\u001f'+java.text.Normalizer.normalize(text,java.text.Normalizer.Form.NFC);}
  boolean same(Entry e){return e!=null&&id.equals(e.id)&&key().equals(e.key());}
  void validate(Set<String> syllables)throws Exception{
   require((kind.equals("word")||kind.equals("phrase"))&&hasContent(text)&&bytes(text)<=2048,"内容不符合词条格式");
   for(int i=0;i<text.length();){char first=text.charAt(i);if(Character.isSurrogate(first))require(Character.isHighSurrogate(first)&&i+1<text.length()&&Character.isLowSurrogate(text.charAt(i+1)),"内容包含无效字符");int c=text.codePointAt(i);int type=Character.getType(c);require((type!=Character.CONTROL&&type!=Character.FORMAT)||c=='\n'||c=='\t',"内容不能包含控制字符");i+=Character.charCount(c);}
   require(trigger.equals(normalize(trigger))&&!trigger.isEmpty()&&bytes(trigger)<=192&&trigger.matches("[a-z]+(?: [a-z]+)*"),"请输入字母或拼音");
   String[] parts=trigger.split(" ");
   if(kind.equals("word")){require(parts.length<=32&&trigger.replace(" ","").length()<=96&&graphemes(text)<=64&&!text.contains("\n")&&!text.contains("\t"),"个人词条过长");for(String part:parts){require(part.length()<=8,"拼音音节过长");if(syllables!=null)require(syllables.contains(part),"请按音节填写拼音，例如 ling he");}}
   else require(parts.length==1&&trigger.length()>=2&&trigger.length()<=16,"短语缩写请输入 2–16 个字母");
  }
 }
 private static final class Revision implements Comparable<Revision>{
  final BigInteger sequence;final String device;
  Revision(long n,String device){this(BigInteger.valueOf(n),device);}
  Revision(BigInteger n,String device){if(n.signum()<1||n.compareTo(LosslessJson.UINT64_MAX)>0)throw new IllegalArgumentException("Invalid logical revision");sequence=n;uuid(device);this.device=device;}
  static Revision decode(JSONObject j)throws Exception{return new Revision(LosslessJson.unsigned(j.get("sequence")),string(j,"device"));}
  JSONObject json()throws Exception{return new JSONObject().put("sequence",sequence).put("device",device);}
  public int compareTo(Revision b){int c=sequence.compareTo(b.sequence);return c!=0?c:device.compareTo(b.device);}
 }
 private static final class Record{
  final Entry entry;final boolean deleted;final Revision revision,created;
  Record(Entry e,boolean deleted,Revision revision,Revision created){entry=e;this.deleted=deleted;this.revision=revision;this.created=created;}
  JSONObject json()throws Exception{return new JSONObject().put("entry",entry.json()).put("deleted",deleted).put("revision",revision.json()).put("created",created.json());}
  boolean same(Record b){return entry.same(b.entry)&&deleted==b.deleted&&revision.compareTo(b.revision)==0&&created.compareTo(b.created)==0;}
 }
 static final class Snapshot {
  final List<Entry> entries;private final LinkedHashMap<String,Record> records;private boolean seededFromLegacy=false;
  Snapshot(LinkedHashMap<String,Record> records)throws Exception{this.records=records;entries=Collections.unmodifiableList(materialize(records));}
  List<Entry> matches(String input,boolean nine){ArrayList<Entry> result=new ArrayList<>();for(Entry e:entries)if(matchesEntry(e,input,nine))result.add(e);return result;}
  List<Entry> removed(){ArrayList<Entry> result=new ArrayList<>();for(Record record:records.values())if(record.deleted)result.add(record.entry);return result;}
  JSONObject synchronizationObject()throws Exception {JSONObject value=new JSONObject();for(Map.Entry<String,Record> entry:records.entrySet())value.put(entry.getKey(),entry.getValue().json());return new JSONObject().put("version",1).put("records",value);}
  String encode()throws Exception{
   JSONArray values=new JSONArray();for(Entry e:entries)values.put(e.json());JSONObject recordsJSON=new JSONObject();for(Map.Entry<String,Record> item:records.entrySet())recordsJSON.put(item.getKey(),item.getValue().json());String encoded=new JSONObject().put("version",1).put("entries",values).put("synchronization",new JSONObject().put("version",1).put("records",recordsJSON)).toString();require(bytes(encoded)<=MAX_BYTES,"个人词库已达到容量上限");return encoded;
  }
 }
 private final File directory;private final AtomicFile file;
 private final String epoch;
 PersonalLexicon(File directory){this.directory=directory;this.epoch=PersonalReset.fileGeneration(directory);file=new AtomicFile(new File(directory,"personal-lexicon-v1.json"));}
 static boolean whitespace(int cp){return Character.isWhitespace(cp)||Character.isSpaceChar(cp);}
 static boolean hasContent(String value){for(int i=0;i<value.length();){int cp=value.codePointAt(i);if(!whitespace(cp))return true;i+=Character.charCount(cp);}return false;}
 static String normalize(String input){String value=input.toLowerCase(Locale.ROOT).replace("ü","v").replace('\'',' ');StringBuilder out=new StringBuilder();boolean space=false;for(int i=0;i<value.length();){int cp=value.codePointAt(i);i+=Character.charCount(cp);if(whitespace(cp)){space=out.length()>0;continue;}if(space)out.append(' ');space=false;out.appendCodePoint(cp);}return out.toString();}
 static String uuid(String value){UUID id=UUID.fromString(value);if(!id.toString().equalsIgnoreCase(value))throw new IllegalArgumentException("Invalid UUID");return id.toString().toUpperCase(Locale.ROOT);}
 static String string(JSONObject json,String key)throws Exception{Object value=json.get(key);require(value instanceof String,"Invalid string field");return (String)value;}
 static boolean version(JSONObject json)throws Exception{return LosslessJson.unsigned(json.get("version")).equals(BigInteger.ONE);}
 static int graphemes(String value){android.icu.text.BreakIterator iterator=android.icu.text.BreakIterator.getCharacterInstance(Locale.ROOT);iterator.setText(value);int count=0;while(iterator.next()!=android.icu.text.BreakIterator.DONE)count++;return count;}
 static int bytes(String value){return value.getBytes(StandardCharsets.UTF_8).length;}
 static void require(boolean ok,String message)throws IOException{if(!ok)throw new IOException(message);}
 static Snapshot empty()throws Exception{return new Snapshot(new LinkedHashMap<>());}
 private interface Locked<T>{T run()throws Exception;}
 private <T>T locked(Locked<T> action)throws Exception{
  synchronized(PersonalLexicon.class){require(epoch.equals(PersonalReset.fileGeneration(directory)),"个人资料已重置");require(directory.isDirectory()||directory.mkdirs(),"无法打开个人词库");try(RandomAccessFile lock=new RandomAccessFile(new File(directory,"personal-lexicon.lock"),"rw");FileLock held=lock.getChannel().lock()){return action.run();}}
 }
 Snapshot load()throws Exception{return locked(this::read);}
 private Snapshot read()throws Exception{
  if(!file.getBaseFile().exists()&&!new File(file.getBaseFile()+".bak").exists())return empty();
  try(InputStream in=file.openRead()){ByteArrayOutputStream out=new ByteArrayOutputStream();byte[] buf=new byte[8192];int n;while((n=in.read(buf))>0){require(out.size()+n<=MAX_BYTES,"个人词库文件过大");out.write(buf,0,n);}return decodeLocal(StandardCharsets.UTF_8.newDecoder().onMalformedInput(java.nio.charset.CodingErrorAction.REPORT).decode(java.nio.ByteBuffer.wrap(out.toByteArray())).toString());}
 }
 private void write(Snapshot state)throws Exception{byte[] data=state.encode().getBytes(StandardCharsets.UTF_8);FileOutputStream out=null;try{out=file.startWrite();out.write(data);file.finishWrite(out);}catch(Exception error){if(out!=null)file.failWrite(out);throw error;}}
 private String replica()throws Exception{AtomicFile identity=new AtomicFile(new File(directory,"personal-replica-id.txt"));if(identity.getBaseFile().exists())return uuid(new String(identity.readFully(),StandardCharsets.UTF_8));String id=uuid(UUID.randomUUID().toString());FileOutputStream out=identity.startWrite();try{out.write(id.getBytes(StandardCharsets.UTF_8));identity.finishWrite(out);}catch(Exception error){identity.failWrite(out);throw error;}return id;}
 Snapshot upsert(Entry entry,Set<String> syllables)throws Exception{entry.validate(syllables);return locked(()->{Snapshot state=read();for(Entry old:state.entries){if(old.same(entry))return state;require(old.id.equals(entry.id)||!old.key().equals(entry.key()),"词条已存在");}Snapshot next=change(state,entry,false,replica());write(next);return next;});}
 Snapshot remove(String id)throws Exception{return locked(()->{Snapshot state=read();Record old=state.records.get(uuid(id));if(old==null)return state;Snapshot next=change(state,old.entry,true,replica());write(next);return next;});}
 Snapshot merge(String encoded)throws Exception{return mergeState(decode(encoded));}
 private Snapshot mergeState(Snapshot incoming)throws Exception{return locked(()->{
  Snapshot previous=read(),state=seedLegacy(previous),next=combine(state,incoming);String encodedNext=next.encode();if(previous.seededFromLegacy||!state.encode().equals(encodedNext))write(next);return next;
 });}
 static Snapshot combine(Snapshot state,Snapshot incoming)throws Exception {
  LinkedHashMap<String,Record> records=new LinkedHashMap<>(state.records);
  for(Map.Entry<String,Record> item:incoming.records.entrySet()){
   Record a=records.get(item.getKey()),b=item.getValue();
   if(a==null)records.put(item.getKey(),b);
   else if(a.revision.compareTo(b.revision)==0)require(a.same(b),"Conflicting equal logical revision");
   else if(a.revision.sequence.equals(b.revision.sequence)&&a.deleted!=b.deleted){if(b.deleted)records.put(item.getKey(),b);}
   else if(a.revision.compareTo(b.revision)<0)records.put(item.getKey(),b);
  }
  Snapshot next=new Snapshot(records);next.encode();return next;
 }
 static Snapshot decodeSynchronized(JSONObject sync)throws Exception{Snapshot state=new Snapshot(syncRecords(sync));state.encode();return state;}
 Snapshot mergeSynchronized(String encoded)throws Exception {
  return mergeState(decodeSynchronized(LosslessJson.object(encoded,MAX_BYTES)));
 }
 String synchronizationSnapshot()throws Exception{return locked(()->{
  Snapshot state=read();
  if(state.seededFromLegacy){state=seedLegacy(state);write(state);}
  JSONObject records=new JSONObject();for(Map.Entry<String,Record> entry:state.records.entrySet())records.put(entry.getKey(),entry.getValue().json());
  return new JSONObject().put("version",1).put("records",records).toString();
 });}
 private Snapshot seedLegacy(Snapshot state)throws Exception {
  if(!state.seededFromLegacy)return state;
  String device=replica();LinkedHashMap<String,Record> records=new LinkedHashMap<>();long sequence=0;
  ArrayList<Record> legacy=new ArrayList<>(state.records.values());legacy.sort((a,b)->a.created.compareTo(b.created));for(Record record:legacy){Entry entry=record.entry;Revision v=new Revision(++sequence,device);records.put(entry.id,new Record(entry,false,v,v));}
  return new Snapshot(records);
 }
 /** Manual import is additive. It never applies another archive's deletes or revisions. */
 Snapshot importEntries(String encoded,Set<String> syllables)throws Exception {
  Snapshot incoming=decode(encoded);for(Entry entry:incoming.entries)entry.validate(syllables);
  return locked(()->{
   Snapshot current=read();Set<String> ids=new HashSet<>(),keys=new HashSet<>();for(Entry entry:current.entries){ids.add(entry.id);keys.add(entry.key());}
   ArrayList<Entry> additions=new ArrayList<>();for(Entry entry:incoming.entries)if(!ids.contains(entry.id)&&!keys.contains(entry.key())){additions.add(entry);ids.add(entry.id);keys.add(entry.key());}
   if(additions.isEmpty())return current;
   current=seedLegacy(current);
   require(current.entries.size()+additions.size()<=1000,"个人词条过多");
   BigInteger highest=BigInteger.ZERO;for(Record record:current.records.values())highest=highest.max(record.revision.sequence);
   require(highest.add(BigInteger.valueOf(additions.size())).compareTo(LosslessJson.UINT64_MAX)<=0,"Logical revision limit reached");
   String device=replica();LinkedHashMap<String,Record> records=new LinkedHashMap<>(current.records);
   for(Entry entry:additions){Record old=records.get(entry.id);highest=highest.add(BigInteger.ONE);Revision revision=new Revision(highest,device);records.put(entry.id,new Record(entry,false,revision,old==null?revision:old.created));}
   Snapshot next=new Snapshot(records);next.encode();write(next);return next;
  });
 }
 /** Same visible-entry-only export as the Apple settings page. */
 String exportEntries()throws Exception {
  Snapshot current=load();JSONArray entries=new JSONArray();for(Entry entry:current.entries)entries.put(entry.json());
  String encoded=new JSONObject().put("version",1).put("entries",entries).toString();require(bytes(encoded)<=MAX_BYTES,"个人词库文件过大");return encoded;
 }
 private static Snapshot change(Snapshot state,Entry entry,boolean deleted,String replica)throws Exception{
  BigInteger highest=BigInteger.ZERO;for(Record record:state.records.values())highest=highest.max(record.revision.sequence);require(highest.compareTo(LosslessJson.UINT64_MAX)<0,"Logical revision limit reached");Revision revision=new Revision(highest.add(BigInteger.ONE),replica);LinkedHashMap<String,Record> records=new LinkedHashMap<>(state.records);Record old=records.get(entry.id);
  if(old!=null)for(Map.Entry<String,Record> item:state.records.entrySet()){Record alias=item.getValue();if(!item.getKey().equals(entry.id)&&!alias.deleted&&alias.entry.key().equals(old.entry.key()))records.put(item.getKey(),new Record(alias.entry,true,revision,alias.created));}
  records.put(entry.id,new Record(entry,deleted,revision,old==null?revision:old.created));Snapshot next=new Snapshot(records);next.encode();return next;
 }
 static Snapshot decode(String encoded)throws Exception{return decode(encoded,false);}
 private static Snapshot decodeLocal(String encoded)throws Exception{return decode(encoded,true);}
 private static Snapshot decode(String encoded,boolean localAliases)throws Exception{
  require(bytes(encoded)<=MAX_BYTES,"个人词库文件过大");JSONObject root=LosslessJson.object(encoded,MAX_BYTES);require(version(root),"不支持的个人词库版本");JSONArray entries=root.getJSONArray("entries");require(entries.length()<=1000,"个人词条过多");ArrayList<Entry> visible=new ArrayList<>(),allVisible=new ArrayList<>();Set<String> ids=new HashSet<>(),keys=new HashSet<>();for(int i=0;i<entries.length();i++){Entry entry=Entry.decode(entries.getJSONObject(i));require(ids.add(entry.id),"词条重复");boolean fresh=keys.add(entry.key());require(fresh||localAliases,"词条重复");allVisible.add(entry);if(fresh)visible.add(entry);}
  LinkedHashMap<String,Record> records=new LinkedHashMap<>();JSONObject sync=root.optJSONObject("synchronization");require(!root.has("synchronization")||root.isNull("synchronization")||sync!=null,"Invalid synchronization field");if(sync==null){long seq=0;String legacy="00000000-0000-0000-0000-000000000001";for(Entry entry:allVisible){Revision v=new Revision(++seq,legacy);records.put(entry.id,new Record(entry,false,v,v));}}
  else records=syncRecords(sync);
  Snapshot result=new Snapshot(records);result.seededFromLegacy=sync==null;require(result.entries.size()==visible.size(),"词条与同步资料不一致");for(int i=0;i<visible.size();i++)require(visible.get(i).same(result.entries.get(i)),"词条顺序与同步资料不一致");result.encode();return result;
 }
 private static LinkedHashMap<String,Record> syncRecords(JSONObject sync)throws Exception {
  require(version(sync),"不支持的同步资料版本");JSONObject rows=sync.getJSONObject("records");require(rows.length()<=4000,"个人词条历史过多");
  LinkedHashMap<String,Record> records=new LinkedHashMap<>();Iterator<String> all=rows.keys();
  while(all.hasNext()){
   String id=all.next();JSONObject row=rows.getJSONObject(id);Entry entry=Entry.decode(row.getJSONObject("entry"));require(id.equals(entry.id),"Invalid record ID");
   Revision revision=Revision.decode(row.getJSONObject("revision")),created=Revision.decode(row.getJSONObject("created"));require(created.sequence.compareTo(revision.sequence)<=0,"Invalid creation revision");require(row.get("deleted") instanceof Boolean,"Invalid deletion flag");
   records.put(id,new Record(entry,row.getBoolean("deleted"),revision,created));
  }
  return records;
 }
 private static ArrayList<Entry> materialize(Map<String,Record> records)throws Exception{require(records.size()<=4000,"个人词条历史过多");ArrayList<Record> sorted=new ArrayList<>(records.values());sorted.sort((a,b)->{int compare=a.created.compareTo(b.created);return compare!=0?compare:a.entry.id.compareTo(b.entry.id);});ArrayList<Entry> result=new ArrayList<>();Set<String> keys=new HashSet<>();for(Record record:sorted)if(!record.deleted&&keys.add(record.entry.key())){record.entry.validate(null);result.add(record.entry);}require(result.size()<=1000,"个人词条过多");return result;}
 static boolean matchesEntry(Entry entry,String input,boolean nine){String normalized=normalize(input).replace(" ","");if(normalized.isEmpty()||normalized.length()>192)return false;if(!nine)return normalized.equals(entry.trigger.replace(" ",""));if(!code(normalized).equals(code(entry.trigger.replace(" ",""))))return false;String[] parts=input.split("'"),reading=entry.trigger.split(" ");int locked=0;for(String part:parts){if(!part.matches("[a-zA-Z]+"))break;if(!entry.kind.equals("word")||locked>=reading.length||!reading[locked].equals(part.toLowerCase(Locale.ROOT)))return false;locked++;}return true;}
 static String code(String input){StringBuilder out=new StringBuilder();for(char c:input.toLowerCase(Locale.ROOT).toCharArray()){if(c>='2'&&c<='9')out.append(c);else if(c>='a'&&c<='z')out.append(c<='c'?'2':c<='f'?'3':c<='i'?'4':c<='l'?'5':c<='o'?'6':c<='s'?'7':c<='v'?'8':'9');else return "";}return out.toString();}
}
