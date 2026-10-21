package live.linghe.privateinput;

import java.io.*;import java.math.*;import java.util.*;import org.json.*;

/** Same no-double-count checkpoint and independent pending-reset contract as iOS. */
final class RimeCheckpoint {
 static final int MAX_STATE_BYTES=8*1024*1024;
 static final class Word {final String reading,text;final long count;Word(String reading,String text,long count){this.reading=reading;this.text=text;this.count=count;}String id(){return LearningModel.canonical(reading+'\u001f'+text);}}
 LearningModel model=new LearningModel();private LinkedHashMap<String,Long> observed=new LinkedHashMap<>();private LinkedHashMap<String,BigInteger> applied;
 RimeCheckpoint copy(){RimeCheckpoint next=new RimeCheckpoint();next.model=model.copy();next.observed=new LinkedHashMap<>(observed);next.applied=applied==null?null:new LinkedHashMap<>(applied);return next;}
 private static void require(boolean value,String label)throws IOException{if(!value)throw new IOException(label);}
 static List<Word> parseExport(String text)throws Exception {
  require(PersonalLexicon.bytes(text)<=LearningModel.MAX_BYTES,"Rime export too large");LosslessJson.unicode(text);List<Word> result=new ArrayList<>();Set<String> ids=new HashSet<>();
  for(String line:text.split("\n",-1)) {
   if(line.isEmpty()||line.startsWith("#"))continue;String[] fields=line.split("\t",-1);require(fields.length==3&&fields[2].matches("[0-9]+")&&fields[2].length()<=20,"Invalid Rime export");BigInteger count=new BigInteger(fields[2]);require(count.compareTo(BigInteger.valueOf(LearningModel.MAX_COUNT))<=0,"Rime frequency out of bounds");
   String reading=fields[1].toLowerCase(Locale.ROOT).trim(),word=LearningModel.canonical(fields[0]);LearningModel.Entry.fresh(reading,word).validate();Word value=new Word(reading,word,count.longValueExact());require(ids.add(value.id()),"Duplicate Rime export");result.add(value);require(result.size()<=5000,"Rime export capacity exceeded");
  }
  return result;
 }
 void observeExport(String text,String device)throws Exception {
  List<Word> words=parseExport(text);RimeCheckpoint next=copy();
  for(Word word:words) {
   LearningModel.Entry entry=next.model.get(word.id());BigInteger appliedGeneration=applied==null?BigInteger.ZERO:applied.getOrDefault(word.id(),BigInteger.ZERO);if(entry!=null&&entry.generation.compareTo(appliedGeneration)>0)continue;
   long baseline=observed.getOrDefault(word.id(),0L),delta=word.count>=baseline?word.count-baseline:0;
   if(delta>0){long local=entry==null?0:entry.counts.getOrDefault(LearningModel.canonical(device),0L);next.model.setDeviceCount(word.reading,word.text,device,Math.min(LearningModel.MAX_COUNT,local+delta));}
   next.observed.put(word.id(),word.count);
  }
  model=next.model;observed=next.observed;
 }
 void mergeRemote(String archive)throws Exception{model.merge(archive);}
 void setPinned(String reading,String text,boolean pinned,String device)throws Exception{model.setPinned(reading,text,pinned,device);}
 void resetFrequency(String reading,String text)throws Exception{model.resetFrequency(reading,text);}
 List<LearningModel.Entry> pendingResets(){List<LearningModel.Entry> result=new ArrayList<>();for(LearningModel.Entry entry:model.entries())if(!entry.deleted&&entry.generation.compareTo(applied==null?BigInteger.ZERO:applied.getOrDefault(entry.id(),BigInteger.ZERO))>0)result.add(entry);return result;}
 void establishBaselineAfterImport(String export)throws Exception {
  LinkedHashMap<String,Long> counts=new LinkedHashMap<>();for(Word word:parseExport(export))counts.put(word.id(),word.count);LinkedHashMap<String,BigInteger> generations=new LinkedHashMap<>();for(LearningModel.Entry entry:model.entries())generations.put(entry.id(),entry.generation);observed=counts;applied=generations;
 }
 String engineImport()throws Exception {
  StringBuilder text=new StringBuilder("# Private Input semantic learning snapshot; no host document or engine user ID\n");List<LearningModel.Entry> entries=new ArrayList<>(model.entries());entries.sort(Comparator.comparing(LearningModel.Entry::id));
  for(LearningModel.Entry entry:entries){entry.validate();if(!entry.deleted&&entry.frequency()==0)continue;text.append(entry.text).append('\t').append(entry.reading).append('\t').append(entry.deleted?-1:entry.frequency()).append('\n');}
  require(PersonalLexicon.bytes(text.toString())<=LearningModel.MAX_BYTES,"Rime import too large");return text.toString();
 }
 String encode()throws Exception {
  model.export();require(observed.size()<=5000&&(applied==null||applied.size()<=5000),"Checkpoint capacity exceeded");JSONObject counts=new JSONObject();for(Map.Entry<String,Long> entry:observed.entrySet())counts.put(entry.getKey(),entry.getValue());JSONObject root=new JSONObject().put("model",model.stateObject()).put("observedCounts",counts);
  if(applied!=null){JSONObject generations=new JSONObject();for(Map.Entry<String,BigInteger> entry:applied.entrySet())generations.put(entry.getKey(),entry.getValue());root.put("appliedGenerations",generations);}String text=LosslessJson.canonical(root);require(PersonalLexicon.bytes(text)<=MAX_STATE_BYTES,"Checkpoint too large");return text;
 }
 static RimeCheckpoint decode(String text)throws Exception {
  JSONObject root=LosslessJson.object(text,MAX_STATE_BYTES);RimeCheckpoint state=new RimeCheckpoint();state.model=LearningModel.fromState(root.getJSONObject("model"));JSONObject counts=root.getJSONObject("observedCounts");require(counts.length()<=5000,"Checkpoint capacity exceeded");Iterator<String> keys=counts.keys();
  while(keys.hasNext()){String key=keys.next();validateID(key);BigInteger value=LosslessJson.unsigned(counts.get(key));require(value.compareTo(BigInteger.valueOf(LearningModel.MAX_COUNT))<=0,"Checkpoint count out of bounds");String id=LearningModel.canonical(key);require(!state.observed.containsKey(id),"Duplicate checkpoint key");state.observed.put(id,value.longValueExact());}
  if(root.has("appliedGenerations")&&!root.isNull("appliedGenerations")){JSONObject generations=root.getJSONObject("appliedGenerations");require(generations.length()<=5000,"Checkpoint capacity exceeded");state.applied=new LinkedHashMap<>();keys=generations.keys();while(keys.hasNext()){String key=keys.next();validateID(key);String id=LearningModel.canonical(key);require(!state.applied.containsKey(id),"Duplicate checkpoint key");state.applied.put(id,LosslessJson.unsigned(generations.get(key)));}}
  state.encode();return state;
 }
 private static void validateID(String id)throws Exception {int split=id.indexOf('\u001f');require(split>0&&id.lastIndexOf('\u001f')==split,"Invalid checkpoint key");LearningModel.Entry.fresh(id.substring(0,split),id.substring(split+1)).validate();}
}
