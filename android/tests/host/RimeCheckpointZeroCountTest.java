package live.linghe.privateinput;

import java.lang.reflect.Field;
import java.util.*;

/** Actual checkpoint paths on the host; no Android JSON runtime, native DB or device. */
public final class RimeCheckpointZeroCountTest {
 static int checks,failures;
 interface Work {void run() throws Exception;}
 static void ok(boolean value,String label){++checks;if(!value)throw new AssertionError(label);}
 static void rejects(Work work,String label)throws Exception{boolean rejected=false;try{work.run();}catch(Exception expected){rejected=true;}ok(rejected,label);}
 @SuppressWarnings("unchecked") static Map<String,Long> observed(RimeCheckpoint state)throws Exception{Field field=RimeCheckpoint.class.getDeclaredField("observed");field.setAccessible(true);return (Map<String,Long>)field.get(state);}
 static Object applied(RimeCheckpoint state)throws Exception{Field field=RimeCheckpoint.class.getDeclaredField("applied");field.setAccessible(true);return field.get(state);}
 static String id(String text){return "ce shi\u001f"+text;}
 static String row(String text,int count){return text+"\tce shi\t"+count+"\n";}
 static String export(int positive,int zero){StringBuilder out=new StringBuilder();for(int i=0;i<positive;i++)out.append(row("合成正词"+i,1));for(int i=0;i<zero;i++)out.append(row("合成零词"+i,0));return out.toString();}
 static void unchanged(RimeCheckpoint state,RimeCheckpoint before,String label)throws Exception{
  ok(state.model.entries().equals(before.model.entries()),label+" retains every immutable model entry, count, pin, generation and tombstone");
  ok(state.model.learningEnabled==before.model.learningEnabled&&observed(state).equals(observed(before))&&Objects.equals(applied(state),applied(before)),label+" retains baseline and reset state");
 }
 static void largeExport()throws Exception{
  String text=export(4650,615);ok(RimeCheckpoint.parseExport(text).size()==5265,"5265 valid rows retained with only 4650 positive");
  RimeCheckpoint state=new RimeCheckpoint();state.observeExport(text,"host");ok(state.model.entries().size()==4650,"zero rows never invent model entries");ok(observed(state).size()==4650,"observe stores only positive baselines");
  RimeCheckpoint before=state.copy();state.observeExport(text,"host");unchanged(state,before,"repeated full batch");
  state.establishBaselineAfterImport(text);ok(observed(state).size()==4650,"import baseline stores positive rows only");ok(state.model.entries().equals(before.model.entries()),"baseline does not replace model");
 }
 static void zeroTransition()throws Exception{
  RimeCheckpoint state=new RimeCheckpoint();state.observeExport(row("回零",3)+row("保留",7),"host");
  observed(state).put(id("旧零基线"),0L);state.observeExport(row("回零",0)+row("从零",0),"host");
  ok(state.model.get(id("回零")).frequency()==3,"native zero preserves learned positive frequency");ok(!observed(state).containsKey(id("回零"))&&!observed(state).containsKey(id("从零"))&&!observed(state).containsKey(id("旧零基线")),"zero native and legacy baselines compact after traversal");
  ok(observed(state).get(id("保留"))==7,"absent nonzero baseline is never removed");
  state.observeExport(row("回零",1)+row("从零",0),"host");ok(state.model.get(id("回零")).frequency()==4,"old positive to native zero to one adds exactly one");
  RimeCheckpoint before=state.copy();for(int i=0;i<3;i++)state.observeExport(row("回零",1)+row("从零",0),"host");unchanged(state,before,"same batch repeated three times");
 }
 static void controlState()throws Exception{
  RimeCheckpoint state=new RimeCheckpoint();state.observeExport(row("置顶",4)+row("墓碑",5)+row("代际",9),"host");state.setPinned("ce shi","置顶",true,"host");state.model.remove(id("墓碑"));state.resetFrequency("ce shi","代际");
  RimeCheckpoint before=state.copy();state.observeExport(row("置顶",0)+row("墓碑",0)+row("代际",0),"host");
  ok(state.model.entries().equals(before.model.entries()),"zero rows preserve pins, tombstones and pending reset generations");ok(observed(state).get(id("代际"))==9,"pending reset keeps its nonzero observation baseline");
  ok(state.pendingResets().size()==1,"zero observation cannot clear pending native reset");state.establishBaselineAfterImport(row("置顶",0)+row("墓碑",0)+row("代际",0));ok(observed(state).isEmpty(),"zero-only imported baseline is empty");ok(state.pendingResets().isEmpty(),"import still acknowledges reset generations");ok(state.model.entries().equals(before.model.entries()),"baseline import preserves all semantic controls");
 }
 static void rejectedRows()throws Exception{
  RimeCheckpoint state=new RimeCheckpoint();state.observeExport(row("保留",8),"host");state.establishBaselineAfterImport(row("保留",8));
  String[] invalid={row("重复零",0)+row("重复零",0),row("同词",2)+row("同词",0),"é\tce shi\t0\ne\u0301\tce shi\t0\n","坏码\tce1\t0\n","坏\u0000字\tce shi\t0\n","坏\u001f字\tce shi\t0\n","坏\ud800字\tce shi\t0\n","坏计数\tce shi\t-0\n","溢出\tce shi\t1000000001\n"};
  for(int i=0;i<invalid.length;i++){
   final String text=row("保留",9)+invalid[i];RimeCheckpoint before=state.copy();rejects(()->state.observeExport(text,"host"),"invalid/duplicate zero row "+i+" rejected after valid prefix");unchanged(state,before,"rejected observation "+i);rejects(()->state.establishBaselineAfterImport(text),"invalid imported baseline "+i+" rejected");unchanged(state,before,"rejected baseline "+i);
  }
 }
 static void bounds()throws Exception{
  ok(RimeCheckpoint.parseExport(export(5000,1)).size()==5001,"exactly 5000 positives plus a zero remains valid");
  RimeCheckpoint state=new RimeCheckpoint();state.observeExport(row("保留",8),"host");RimeCheckpoint before=state.copy();String tooMany=export(5001,0);
  rejects(()->state.observeExport(tooMany,"host"),"5001 positive observations refused");unchanged(state,before,"positive observation overflow");rejects(()->state.establishBaselineAfterImport(tooMany),"5001 positive import baseline refused");unchanged(state,before,"positive baseline overflow");
  char[] comment=new char[LearningModel.MAX_BYTES+1];Arrays.fill(comment,'x');comment[0]='#';String tooLarge=new String(comment);rejects(()->state.observeExport(tooLarge,"host"),"2 MiB byte guard still applies even with no positive rows");unchanged(state,before,"byte overflow");
 }
 static void run(String name,Work work){try{work.run();System.out.println("PASS "+name);}catch(Throwable error){++failures;System.out.println("FAIL "+name+": "+error);}}
 public static void main(String[] args)throws Exception{
  run("large export",RimeCheckpointZeroCountTest::largeExport);run("zero transition",RimeCheckpointZeroCountTest::zeroTransition);run("control state",RimeCheckpointZeroCountTest::controlState);run("strict rejection atomicity",RimeCheckpointZeroCountTest::rejectedRows);run("positive and byte bounds",RimeCheckpointZeroCountTest::bounds);
  System.out.println("checks="+checks+" failures="+failures+"; synthetic host only; no APK/device/native DB/JSON runtime");if(failures!=0)System.exit(1);
 }
}
