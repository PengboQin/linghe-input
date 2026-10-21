package live.linghe.privateinput;

import java.io.*;import java.math.*;import java.text.Normalizer;import java.util.*;import org.json.*;

/** Apple's bounded per-replica counters, independent reset epochs and pin versions. */
final class LearningModel {
 static final int MAX_BYTES=2*1024*1024;static final long MAX_COUNT=1000000000L;
 static String canonical(String text){return Normalizer.normalize(text,Normalizer.Form.NFC);}
 private static void require(boolean ok,String message)throws IOException{if(!ok)throw new IOException(message);}
 static final class Version implements Comparable<Version> {
  final BigInteger sequence;final String device;
  Version(BigInteger sequence,String device)throws Exception{require(sequence.signum()>=0&&sequence.compareTo(LosslessJson.UINT64_MAX)<=0&&PersonalLexicon.bytes(device)<=128,"Invalid logical version");LosslessJson.unicode(device);this.sequence=sequence;this.device=device;}
  static Version zero()throws Exception{return new Version(BigInteger.ZERO,"");}
  static Version decode(JSONObject value)throws Exception{return new Version(LosslessJson.unsigned(value.get("sequence")),PersonalLexicon.string(value,"device"));}
  JSONObject json()throws Exception{return new JSONObject().put("sequence",sequence).put("device",device);}
  public int compareTo(Version other){int n=sequence.compareTo(other.sequence);return n!=0?n:canonical(device).compareTo(canonical(other.device));}
 }
 static final class Entry {
  final String reading,text;final BigInteger generation;final boolean deleted,pinned;final Map<String,Long> counts;final Version pinVersion;
  Entry(String reading,String text,BigInteger generation,boolean deleted,Map<String,Long> counts,boolean pinned,Version version)throws Exception {
   this.reading=reading;this.text=text;this.generation=generation;this.deleted=deleted;this.counts=Collections.unmodifiableMap(new LinkedHashMap<>(counts));this.pinned=pinned;pinVersion=version;validate();
  }
  static Entry fresh(String reading,String text)throws Exception{return new Entry(reading.toLowerCase(Locale.ROOT),canonical(text),BigInteger.ZERO,false,Collections.emptyMap(),false,Version.zero());}
  String id(){return canonical(reading+'\u001f'+text);}
  long frequency(){long sum=0;for(long value:counts.values())sum=Math.min(MAX_COUNT,sum+value);return sum;}
  void validate()throws Exception {
   LosslessJson.unicode(reading);LosslessJson.unicode(text);
   require(!reading.isEmpty()&&PersonalLexicon.bytes(reading)<=128&&reading.matches("[a-zA-Z ']+")&&!text.isEmpty()&&PersonalLexicon.bytes(text)<=1024&&!text.matches("(?s).*[\\u001f\\t\\n\\r\\u0000].*"),"Invalid learned entry");
   require(generation.signum()>=0&&generation.compareTo(LosslessJson.UINT64_MAX)<=0&&counts.size()<=64,"Invalid learning generation");
   for(Map.Entry<String,Long> item:counts.entrySet()){LosslessJson.unicode(item.getKey());require(!item.getKey().isEmpty()&&PersonalLexicon.bytes(item.getKey())<=128&&item.getValue()>=0&&item.getValue()<=MAX_COUNT,"Invalid learning counter");}
  }
  static Entry decode(JSONObject value)throws Exception {
   LinkedHashMap<String,Long> counts=new LinkedHashMap<>();JSONObject source=value.getJSONObject("counts");Iterator<String> keys=source.keys();
   while(keys.hasNext()){String key=keys.next(),normalized=canonical(key);BigInteger number=LosslessJson.unsigned(source.get(key));require(number.compareTo(BigInteger.valueOf(MAX_COUNT))<=0&&!counts.containsKey(normalized),"Invalid duplicate learning counter");counts.put(normalized,number.longValueExact());}
   require(value.get("deleted") instanceof Boolean&&value.get("pinned") instanceof Boolean,"Invalid learning flags");
   return new Entry(PersonalLexicon.string(value,"reading"),PersonalLexicon.string(value,"text"),LosslessJson.unsigned(value.get("generation")),value.getBoolean("deleted"),counts,value.getBoolean("pinned"),Version.decode(value.getJSONObject("pinVersion")));
  }
  JSONObject json()throws Exception {
   JSONObject values=new JSONObject();for(Map.Entry<String,Long> entry:counts.entrySet())values.put(entry.getKey(),entry.getValue());
   return new JSONObject().put("reading",reading).put("text",text).put("generation",generation).put("deleted",deleted).put("counts",values).put("pinned",pinned).put("pinVersion",pinVersion.json());
  }
  Entry merging(Entry other)throws Exception {
   require(id().equals(other.id()),"Learning key mismatch");Entry pin=pinVersion.compareTo(other.pinVersion)<0?other:this;
   if(!generation.equals(other.generation)){Entry newest=generation.compareTo(other.generation)>0?this:other;return new Entry(newest.reading,newest.text,newest.generation,newest.deleted,newest.counts,pin.pinned,pin.pinVersion);}
   LinkedHashMap<String,Long> combined=new LinkedHashMap<>(counts);for(Map.Entry<String,Long> value:other.counts.entrySet())combined.put(value.getKey(),Math.max(combined.getOrDefault(value.getKey(),0L),value.getValue()));
   return new Entry(reading,text,generation,deleted||other.deleted,combined,pin.pinned,pin.pinVersion);
  }
 }
 private LinkedHashMap<String,Entry> entries=new LinkedHashMap<>();private PersonalLexicon.Snapshot personal;
 boolean learningEnabled=true;
 LearningModel copy(){LearningModel next=new LearningModel();next.entries=new LinkedHashMap<>(entries);next.personal=personal;next.learningEnabled=learningEnabled;return next;}
 List<Entry> entries(){return Collections.unmodifiableList(new ArrayList<>(entries.values()));}
 Entry get(String id){return entries.get(canonical(id));}
 private Entry get(String reading,String text)throws Exception{Entry fresh=Entry.fresh(reading,text);return entries.getOrDefault(fresh.id(),fresh);}
 private void put(Entry entry)throws Exception{require(entries.containsKey(entry.id())||entries.size()<5000,"Learning capacity exceeded");entries.put(entry.id(),entry);}
 void record(String reading,String text,String device)throws Exception {
  if(!learningEnabled)return;Entry old=get(reading,text);if(old.deleted)return;LinkedHashMap<String,Long> counts=new LinkedHashMap<>(old.counts);String key=canonical(device);counts.put(key,Math.min(MAX_COUNT,counts.getOrDefault(key,0L)+1));put(new Entry(old.reading,old.text,old.generation,false,counts,old.pinned,old.pinVersion));
 }
 void setDeviceCount(String reading,String text,String device,long count)throws Exception {
  if(!learningEnabled)return;require(count>=0&&count<=MAX_COUNT,"Learning counter out of bounds");Entry old=get(reading,text);if(old.deleted)return;LinkedHashMap<String,Long> counts=new LinkedHashMap<>(old.counts);String key=canonical(device);counts.put(key,Math.max(counts.getOrDefault(key,0L),count));put(new Entry(old.reading,old.text,old.generation,false,counts,old.pinned,old.pinVersion));
 }
 void remove(String id)throws Exception{Entry old=get(id);if(old!=null)put(new Entry(old.reading,old.text,old.generation,true,old.counts,old.pinned,old.pinVersion));}
 void setPinned(String reading,String text,boolean pinned,String device)throws Exception {
  Entry old=get(reading,text);require(!old.deleted,"Cannot pin deleted entry");BigInteger highest=BigInteger.ZERO;for(Entry entry:entries.values())highest=highest.max(entry.pinVersion.sequence);require(highest.compareTo(LosslessJson.UINT64_MAX)<0,"Pin version exhausted");put(new Entry(old.reading,old.text,old.generation,false,old.counts,pinned,new Version(highest.add(BigInteger.ONE),device)));
 }
 void resetFrequency(String reading,String text)throws Exception {
  Entry old=get(reading,text);require(!old.deleted&&old.generation.compareTo(LosslessJson.UINT64_MAX)<0,"Reset generation exhausted");put(new Entry(old.reading,old.text,old.generation.add(BigInteger.ONE),false,Collections.emptyMap(),old.pinned,old.pinVersion));
 }
 void restore(String id)throws Exception {
  Entry old=get(id);if(old==null||!old.deleted)return;require(old.generation.compareTo(LosslessJson.UINT64_MAX)<0,"Restore generation exhausted");put(new Entry(old.reading,old.text,old.generation.add(BigInteger.ONE),false,Collections.emptyMap(),old.pinned,old.pinVersion));
 }
 String export()throws Exception {
  require(entries.size()<=5000,"Learning capacity exceeded");ArrayList<String> keys=new ArrayList<>(entries.keySet());Collections.sort(keys);JSONArray values=new JSONArray();for(String key:keys){Entry entry=entries.get(key);entry.validate();values.put(entry.json());}
  JSONObject archive=new JSONObject().put("version",1).put("schemaID","private_pinyin").put("entries",values);if(personal!=null)archive.put("personalLexicon",personal.synchronizationObject());String encoded=LosslessJson.canonical(archive);require(PersonalLexicon.bytes(encoded)<=MAX_BYTES,"Learning archive too large");return encoded;
 }
 void merge(String encoded)throws Exception {
  JSONObject archive=LosslessJson.object(encoded,MAX_BYTES);require(PersonalLexicon.version(archive)&&PersonalLexicon.string(archive,"schemaID").equals("private_pinyin"),"Incompatible learning schema");JSONArray values=archive.getJSONArray("entries");require(values.length()<=5000,"Learning capacity exceeded");
  LearningModel next=copy();Set<String> seen=new HashSet<>();for(int i=0;i<values.length();i++){Entry entry=Entry.decode(values.getJSONObject(i));require(seen.add(entry.id()),"Duplicate learned entry");Entry local=next.entries.get(entry.id());next.put(local==null?entry:local.merging(entry));}
  if(archive.has("personalLexicon")&&!archive.isNull("personalLexicon")){PersonalLexicon.Snapshot incoming=PersonalLexicon.decodeSynchronized(archive.getJSONObject("personalLexicon"));next.personal=PersonalLexicon.combine(next.personal==null?PersonalLexicon.empty():next.personal,incoming);}
  next.export();entries=next.entries;personal=next.personal;
 }
 void mergePersonalLexicon(String encoded)throws Exception {
  LearningModel next=copy();PersonalLexicon.Snapshot incoming=PersonalLexicon.decodeSynchronized(LosslessJson.object(encoded,PersonalLexicon.MAX_BYTES));next.personal=PersonalLexicon.combine(next.personal==null?PersonalLexicon.empty():next.personal,incoming);next.export();personal=next.personal;
 }
 String personalSnapshot()throws Exception{return personal==null?null:personal.synchronizationObject().toString();}
 JSONObject stateObject()throws Exception {
  JSONObject values=new JSONObject();for(Map.Entry<String,Entry> entry:entries.entrySet())values.put(entry.getKey(),entry.getValue().json());JSONObject state=new JSONObject().put("entries",values).put("learningEnabled",learningEnabled);if(personal!=null)state.put("personalLexicon",personal.synchronizationObject());return state;
 }
 static LearningModel fromState(JSONObject state)throws Exception {
  require(state.get("learningEnabled") instanceof Boolean,"Invalid learning consent");LearningModel model=new LearningModel();model.learningEnabled=state.getBoolean("learningEnabled");JSONObject values=state.getJSONObject("entries");require(values.length()<=5000,"Learning capacity exceeded");Iterator<String> keys=values.keys();while(keys.hasNext()){String key=keys.next();Entry entry=Entry.decode(values.getJSONObject(key));require(canonical(key).equals(entry.id())&&!model.entries.containsKey(entry.id()),"Invalid learned dictionary key");model.put(entry);}
  if(state.has("personalLexicon")&&!state.isNull("personalLexicon"))model.personal=PersonalLexicon.decodeSynchronized(state.getJSONObject("personalLexicon"));model.export();return model;
 }
}
