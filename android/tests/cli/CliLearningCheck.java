package live.linghe.privateinput;
import java.io.*;import java.nio.file.*;import java.nio.charset.StandardCharsets;import java.math.*;import java.util.*;import org.json.*;

public final class CliLearningCheck {
 interface Work{void run()throws Exception;}
 static void require(boolean ok,String label){if(!ok)throw new AssertionError(label);}
 static void reject(Work work,String label)throws Exception{boolean invalid=false;try{work.run();}catch(Exception expected){invalid=true;}require(invalid,label);}
 static String string(JSONObject object,String key)throws Exception{return PersonalLexicon.string(object,key);}
 static String from64(String text){return new String(Base64.getDecoder().decode(text),StandardCharsets.UTF_8);}
 static void write(File file,String text)throws Exception{Files.write(file.toPath(),text.getBytes(StandardCharsets.UTF_8));}
 static void same(String actual,String expected,String label)throws Exception {String a=LosslessJson.canonical(LosslessJson.object(actual,RimeCheckpoint.MAX_STATE_BYTES)),b=LosslessJson.canonical(LosslessJson.object(expected,RimeCheckpoint.MAX_STATE_BYTES));require(a.equals(b),label+"\nactual="+a+"\nexpected="+b);}
 public static void main(String[] args){try{run(args);}catch(Throwable error){error.printStackTrace();System.exit(1);}}
 static void run(String[] args)throws Exception {
  LearningModel model=new LearningModel();RimeCheckpoint checkpoint=new RimeCheckpoint();int traces=0,checks=0;File result=new File(args[1]);require(!result.exists()&&result.mkdirs(),"fresh synthetic result directory");
  for(String line:Files.readAllLines(Paths.get(args[0]),StandardCharsets.UTF_8)) {
   String[] row=line.split("\t",-1);JSONObject input=LosslessJson.object(from64(row[2]),LearningModel.MAX_BYTES);String operation=row[1];
   if(row[0].equals("M")) {
    switch(operation) {
     case "count":model.setDeviceCount(string(input,"reading"),string(input,"text"),string(input,"device"),LosslessJson.unsigned(input.get("count")).longValueExact());break;
     case "record":model.record(string(input,"reading"),string(input,"text"),string(input,"device"));break;
     case "disabledRecord":case "enabledRecord":model.learningEnabled=operation.equals("enabledRecord");model.record(string(input,"reading"),string(input,"text"),string(input,"device"));break;
     case "merge":model.merge(from64(string(input,"archive")));break;
     case "personal":model.mergePersonalLexicon(from64(string(input,"archive")));break;
     case "pin":model.setPinned(string(input,"reading"),string(input,"text"),input.getBoolean("pinned"),string(input,"device"));break;
     case "reset":model.resetFrequency(string(input,"reading"),string(input,"text"));break;
     case "remove":model.remove(string(input,"id"));break;
     case "restore":model.restore(string(input,"id"));break;
     default:throw new AssertionError("Unknown model operation");
    }
    same(model.export(),from64(row[3]),"model trace "+(traces+1)+" "+operation);
   } else {
    switch(operation) {
     case "observe":checkpoint.observeExport(string(input,"text"),string(input,"device"));break;
     case "merge":checkpoint.mergeRemote(from64(string(input,"archive")));break;
     case "baseline":checkpoint.establishBaselineAfterImport(string(input,"text"));break;
     case "pin":checkpoint.setPinned(string(input,"reading"),string(input,"text"),input.getBoolean("pinned"),string(input,"device"));break;
     case "reset":checkpoint.resetFrequency(string(input,"reading"),string(input,"text"));break;
     default:throw new AssertionError("Unknown checkpoint operation");
    }
    same(checkpoint.encode(),from64(row[3]),"checkpoint trace "+(traces+1)+" "+operation);
   }
   traces++;
  }
  require(traces==27,"complete Swift traces");checks++;
  String stable=model.export();reject(()->model.resetFrequency("bian jie","边界"),"generation overflow");require(model.export().equals(stable),"overflow cannot mutate model");reject(()->model.setPinned("ni hao","你好",true,"C"),"pin counter overflow");require(model.export().equals(stable),"failed pin cannot mutate model");checks++;
  LearningModel saturated=new LearningModel();saturated.setDeviceCount("ni hao","你好","A",LearningModel.MAX_COUNT);saturated.setDeviceCount("ni hao","你好","B",LearningModel.MAX_COUNT);saturated.record("ni hao","你好","A");require(saturated.entries().get(0).frequency()==LearningModel.MAX_COUNT,"counter sum safely saturates");String before=saturated.export();reject(()->saturated.setDeviceCount("ni hao","你好","B",LearningModel.MAX_COUNT+1),"counter bound");require(saturated.export().equals(before),"bad counter retained");checks++;
  LearningModel a=new LearningModel(),b=new LearningModel();a.setDeviceCount("ni hao","你好","A",2);b.setDeviceCount("ni hao","你好","B",3);String first=a.export(),second=b.export();a.merge(second);b.merge(first);require(a.export().equals(b.export()),"merge order has deterministic publication bytes");String combined=a.export();a.merge(second);require(a.export().equals(combined),"repeated peer archive idempotent");checks++;
  LearningModel accent=new LearningModel();accent.record("e","e\u0301","A");accent.record("e","é","A");require(accent.entries().size()==1&&accent.entries().get(0).frequency()==2,"canonical Unicode word identity");checks++;
  JSONObject duplicate=LosslessJson.object(a.export(),LearningModel.MAX_BYTES);duplicate.getJSONArray("entries").put(duplicate.getJSONArray("entries").getJSONObject(0));reject(()->a.merge(duplicate.toString()),"duplicate wire IDs");require(a.export().equals(combined),"duplicate archive is atomic");checks++;
  String snapshot=checkpoint.encode();RimeCheckpoint recovered=RimeCheckpoint.decode(snapshot);same(recovered.encode(),snapshot,"checkpoint roundtrip");require(recovered.model.entries().get(0).frequency()==1&&recovered.pendingResets().isEmpty(),"import baseline excludes remote counts and pending reset clears");checks++;
  reject(()->RimeCheckpoint.parseExport("坏\tni hao\t-1\n"),"negative tombstone never accepted as local export");reject(()->RimeCheckpoint.parseExport("你好\tni hao\t2\n你好\tni hao\t3\n"),"duplicate engine counters");checks++;
  LearningModel deletion=new LearningModel();deletion.record("ni hao","你好","A");deletion.remove("ni hao\u001f你好");RimeCheckpoint tombstone=new RimeCheckpoint();tombstone.mergeRemote(deletion.export());require(tombstone.engineImport().contains("你好\tni hao\t-1"),"explicit engine tombstone");LearningModel zero=new LearningModel();zero.setPinned("ni hao","你好",true,"A");RimeCheckpoint zeroCheckpoint=new RimeCheckpoint();zeroCheckpoint.mergeRemote(zero.export());require(!zeroCheckpoint.engineImport().contains("你好"),"pin-only state never invents a frequency");checks++;
  write(new File(result,"learning-final.json"),model.export());write(new File(result,"checkpoint-final.json"),checkpoint.encode());
  System.out.println("Passed "+traces+" actual Swift learning/checkpoint states and "+checks+" CRDT, reset, baseline, overflow and import invariants; synthetic-only, no UI/network/app data");
 }
}
