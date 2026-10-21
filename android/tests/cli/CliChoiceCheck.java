package live.linghe.privateinput;
import java.io.*;import java.nio.file.*;import java.nio.charset.StandardCharsets;import java.util.*;import org.json.*;

public final class CliChoiceCheck {
 private static int checks;private static void require(boolean b,String why){if(!b)throw new AssertionError(why);}
 interface Work{void run()throws Exception;}private static void reject(Work work)throws Exception{boolean failed=false;try{work.run();}catch(Exception invalid){failed=true;}require(failed,"invalid record rejected");}
 private static Object replacement(OwnCommitTracker.Replacement r)throws Exception{return r==null?JSONObject.NULL:new JSONObject().put("code",r.code).put("context",r.context).put("rejected",r.rejected).put("reading",r.reading==null?JSONObject.NULL:r.reading);}
 private static String decode(String value){return new String(Base64.getDecoder().decode(value),StandardCharsets.UTF_8);}
 public static void main(String[] args){try{run(args);}catch(Throwable error){error.printStackTrace();System.exit(1);}}
 private static void run(String[] args)throws Exception {
  File base=new File(args[0]);require(!base.exists()&&base.mkdirs(),"fresh synthetic directory");ChoiceMemory memory=new ChoiceMemory();OwnCommitTracker tracker=new OwnCommitTracker();int traces=0;
  for(String line:Files.readAllLines(Paths.get(args[1]),StandardCharsets.UTF_8)){String[] fields=line.split("\t");String op=fields[0];JSONObject a=new JSONObject(decode(fields[1]));Object expected=new JSONTokener(decode(fields[2])).nextValue();Object actual=null;
   switch(op){
    case "repeat":for(int i=0;i<a.getInt("times");i++)memory=memory.record(a.getString("code"),a.getString("reading"),a.getString("text"),a.getString("context"),1,false);break;
    case "record":case "correction":memory=memory.record(a.getString("code"),a.getString("reading"),a.getString("text"),a.getString("context"),op.equals("correction")?3:a.getInt("strength"),op.equals("correction"));break;
    case "reset":memory=memory.reset(a.getString("text"),a.getString("reading"));break;
    case "load":memory=ChoiceMemory.decode(decode(a.getString("archive"))).migrated();break;
    case "boost":double score=memory.boost(a.getString("code"),a.getString("reading"),a.getString("text"),a.getString("context"));require(Math.abs(score-((Number)expected).doubleValue())<1e-9,"Swift boost "+traces);traces++;continue;
    case "stage":tracker.stage(a.getInt("doc"),a.getString("anchor"),"after",a.getString("text"),a.getString("code"),a.getString("context"),a.getLong("time"),a.getString("reading"));actual=tracker.expected(a.getInt("doc"),a.getLong("time"));break;
    case "delete":actual=replacement(tracker.deleted(a.getInt("doc"),a.getString("anchor"),"after",a.getLong("time")));break;
    case "partial":actual=replacement(tracker.partial(a.getInt("doc"),a.getString("anchor"),"after",a.getLong("time")));break;
    case "expected":actual=tracker.expected(a.getInt("doc"),a.getLong("time"));break;
    default:throw new AssertionError(op);
   }
   if(Arrays.asList("repeat","record","correction","reset","load").contains(op))actual=new JSONObject(memory.encode());
   require(LosslessJson.canonical(actual).equals(LosslessJson.canonical(expected)),"Swift trace "+traces+" "+op);traces++;
  }
  require(traces>=20,"Swift traces loaded");Files.write(new File(base,"android-choice-result.json").toPath(),memory.encode().getBytes(StandardCharsets.UTF_8));checks++;
  ChoiceMemory bounded=new ChoiceMemory();for(int i=0;i<1025;i++)bounded=bounded.record("64426","ni hao","合成"+i,"",1,false);require(bounded.entries.size()==1024&&bounded.entries.get(0).text.equals("合成1"),"bounded recent choices evict oldest");bounded=bounded.record("64426","ni hao","合成1","",3,false);require(bounded.entries.get(1023).text.equals("合成1")&&bounded.entries.get(1023).count==4,"updated choice becomes most recent");checks++;
  ChoiceMemory saturated=new ChoiceMemory();for(int i=0;i<335;i++)saturated=saturated.record("64426","ni hao","拟好","我说",3,false);saturated=saturated.record("64426","ni hao","你好","我说",3,true);require(saturated.entries.get(0).count==1000&&saturated.entries.get(1).count==1000,"bounded counts and correction saturation");checks++;
  ChoiceMemory.Store store=new ChoiceMemory.Store(new File(base,"store"));store.change(old->old.record("64426","ni hao","你好","我说",2,false));File file=new File(base,"store/nine-choice-memory-v3.json");long timestamp=1700000000000L;file.setLastModified(timestamp);store.change(old->old);require(file.lastModified()==timestamp&&store.load().entries.size()==1,"stable persistence without unchanged rewrites");String original=new String(Files.readAllBytes(file.toPath()),StandardCharsets.UTF_8);store.change(old->old.reset("你好","ni hao"));require(store.load().entries.isEmpty(),"frequency reset removes local preferences");checks++;
  Files.write(file.toPath(),"damaged archive".getBytes(StandardCharsets.UTF_8));reject(store::load);reject(()->store.change(old->old.record("64426","ni hao","你好","",1,false)));require(new String(Files.readAllBytes(file.toPath()),StandardCharsets.UTF_8).equals("damaged archive"),"damaged personalization retained");checks++;
  reject(()->ChoiceMemory.decode(original.replace("\"version\":3","\"version\":99")));reject(()->new ChoiceMemory().record("111","ni hao","坏码","",1,false));reject(()->new ChoiceMemory().record("64426","ni hao","bad\nword","",1,false));require(!ChoiceMemory.canRecord("64426","ni hao",String.join("",Collections.nCopies(300,"字")),""),"oversized candidates skipped without disabling future learning");checks++;
  String[][] rows={{"","","64426","",""},{"0","你好","ni hao"},{"1","拟好","ni hao"},{"2","里号","li hao"},{"custom:a","自定","ni hao"}};
  String[][] reversed=rows.clone();reversed[1]=rows[2];reversed[2]=rows[1];String[][] order=ChoiceOrder.apply(reversed,"我说",saturated,null,7,10000,item->false);require(order[1][1].equals("你好")&&order[2][1].equals("拟好")&&order[3][1].equals("里号")&&order[4][0].equals("custom:a"),"saturated tie uses most recent within exact same reading slots");OwnCommitTracker.Replacement retry=new OwnCommitTracker.Replacement(7,"64426","我说","你好","ni hao",10000);order=ChoiceOrder.apply(rows,"我说",new ChoiceMemory(),retry,7,11000,item->false);require(order[1][1].equals("拟好")&&order[3][1].equals("里号"),"temporary rejection does not cross reading groups");order=ChoiceOrder.apply(rows,"我说",new ChoiceMemory(),retry,7,11000,item->item.id.equals("0"));require(order[1][1].equals("你好"),"pin overrides temporary rejection");order=ChoiceOrder.apply(rows,"我说",new ChoiceMemory(),retry,8,11000,item->false);require(order[1][1].equals("你好"),"different document ignores rejection");checks++;
  tracker.stage(7,"a","z","你好","64426","",10000,"ni hao");require(tracker.partial(7,"a","changed",11000)==null,"changed right anchor rejects");require(tracker.deleted(7,"changed","z",11000)==null&&tracker.expected(7,11000)==null,"changed prefix invalidates token");checks++;
  System.out.println("Passed "+traces+" actual Swift choice/tracker traces and "+checks+" Android persistence/order/boundary groups; no installed app data or UI");
 }
}
