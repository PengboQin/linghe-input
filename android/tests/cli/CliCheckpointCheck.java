package live.linghe.privateinput;

import java.io.*;import java.util.*;import java.nio.file.*;import java.nio.charset.StandardCharsets;

public final class CliCheckpointCheck {
 interface Work{void run()throws Exception;}
 private static long session;private static int checks;
 private static void require(boolean ok,String label){if(!ok)throw new AssertionError(label);}
 private static void reject(Work work,String label)throws Exception{boolean invalid=false;try{work.run();}catch(Exception expected){invalid=true;}require(invalid,label);}
 private static void type(String text){for(char c:text.toCharArray())NativeCore.key(session,c);}
 private static void select(String raw,String target)throws Exception {
  NativeCore.mode(session,false,false);type(raw);String[][] state=NativeCore.snapshot(session);long index=-1;for(int i=1;i<state.length;i++)if(state[i][1].equals(target)){index=Long.parseLong(state[i][0]);break;}require(index>=0,"synthetic word available");NativeCore.choose(session,index);require(NativeCore.snapshot(session)[0][1].equals(target),"one native commit");
 }
 private static long frequency(List<LearningModel.Entry> entries,String word){for(LearningModel.Entry entry:entries)if(entry.text.equals(word))return entry.frequency();return 0;}
 static final class NativeEngine implements LearningCoordinator.Engine {
  public int exportTo(File file){return NativeCore.exportLearning(file.getAbsolutePath());}
  public int importFrom(File file){return NativeCore.importLearning(file.getAbsolutePath());}
  public int reset(LearningModel.Entry entry){return NativeCore.resetFrequency(entry.reading,entry.text,entry.frequency());}
 }
 static final class FakeEngine implements LearningCoordinator.Engine {
  long count=3;
  public int exportTo(File file)throws Exception{Files.write(file.toPath(),(count==0?"":"你好\tni hao\t"+count+"\n").getBytes(StandardCharsets.UTF_8));return count==0?0:1;}
  public int importFrom(File file)throws Exception {for(String line:Files.readAllLines(file.toPath(),StandardCharsets.UTF_8)){if(line.startsWith("#")||line.isEmpty())continue;String[] parts=line.split("\t");long value=Long.parseLong(parts[2]);if(value<0)count=0;else count=Math.max(count,value);}return 1;}
  public int reset(LearningModel.Entry entry){count=entry.frequency();return 1;}
 }
 public static void main(String[] args){try{run(args);}catch(Throwable error){error.printStackTrace();System.exit(1);}finally{NativeCore.destroy(session);}}
 private static void run(String[] args)throws Exception {
  File root=new File(args[0]),rime=new File(args[1]),user=new File(root,"user");require(!root.exists()&&root.mkdirs()&&user.mkdirs(),"fresh fixture only");String sharedPath=rime.getAbsolutePath(),userPath=user.getAbsolutePath();
  session=NativeCore.create(sharedPath,userPath);require(session!=0,"actual Rime initialized");
  NativeCore.mode(session,false,false);type("shi");String[][] ordinary=NativeCore.snapshot(session);String baseline=ordinary[1][1];String pinned=baseline.equals("时")?"是":"时";require(NativeCore.pin("shi",pinned,true),"pin native function");String[][] promoted=NativeCore.snapshot(session);require(promoted[1][1].equals(pinned)&&promoted[0][2].equals("shi"),"native pin promotes exact word and keeps draft");NativeCore.pin("shi",pinned,false);require(NativeCore.snapshot(session)[1][1].equals(baseline),"unpin restores native leading order");checks++;
  NativeCore.clear(session);for(int i=0;i<3;i++)select("nihao","你好");NativeCore.mode(session,false,false);type("nihao");NativeCore.query(session,"shi",false,4);String raw=NativeCore.draft(session)[0];require(!NativeCore.closeForCheckpoint(session)&&NativeCore.draft(session)[0].equals(raw),"checkpoint cannot close pending input");require(NativeCore.exportLearning(new File(root,"forbidden.tsv").getAbsolutePath())==-2,"no export of a running dictionary");require(NativeCore.resetFrequency("ni hao","你好",0)==-2,"no reset of running dictionary");checks++;
  NativeCore.clear(session);require(NativeCore.closeForCheckpoint(session),"quiescent close releases live and private probe");session=0;
  LearningCoordinator coordinator=new LearningCoordinator(new File(root,"local"),new File(root,"Shared"));NativeEngine engine=new NativeEngine();List<LearningModel.Entry> learned=coordinator.checkpoint(engine,new File(root,"checkpoint1"),true);long count=frequency(learned,"你好");require(count==3,"actual Rime count checkpoint: "+count);checks++;
  session=NativeCore.create(sharedPath,userPath);select("nihao","你好");require(NativeCore.closeForCheckpoint(session),"close after fourth commit");session=0;learned=coordinator.checkpoint(engine,new File(root,"checkpoint2"),true);require(frequency(learned,"你好")==4,"new typing counted once");learned=coordinator.checkpoint(engine,new File(root,"checkpoint3"),true);require(frequency(learned,"你好")==4,"repeated import not counted as new typing");checks++;
  coordinator.manage("ni hao","你好",true);coordinator.manage("ni hao","你好",null);learned=coordinator.checkpoint(engine,new File(root,"checkpoint-reset"),true);require(frequency(learned,"你好")==0&&learned.stream().anyMatch(entry->entry.text.equals("你好")&&entry.pinned),"actual native reset keeps pin and word");checks++;
  session=NativeCore.create(sharedPath,userPath);select("nihao","你好");require(NativeCore.closeForCheckpoint(session),"close after post-reset selection");session=0;learned=coordinator.checkpoint(engine,new File(root,"checkpoint-after-reset"),true);require(frequency(learned,"你好")==1,"actual engine learns afresh after reset");checks++;
  LearningModel stale=new LearningModel();stale.setDeviceCount("ni hao","你好","old-peer",99);new LearningSnapshotFile(new File(root,"Shared")).publish(stale.export());learned=coordinator.checkpoint(engine,new File(root,"checkpoint-stale"),true);require(frequency(learned,"你好")==1,"stale peer cannot resurrect pre-reset counts");checks++;
  NativeCore.destroy(0);
  File fakeRoot=new File(root,"fake"),fakeShared=new File(fakeRoot,"Shared");FakeEngine fake=new FakeEngine();LearningModel remote=new LearningModel();remote.setDeviceCount("ni hao","你好","B",7);new LearningSnapshotFile(fakeShared).publish(remote.export());
  LearningCoordinator crashing=new LearningCoordinator(new File(fakeRoot,"local"),fakeShared,phase->{if(phase.equals("native-imported"))throw new IOException("synthetic crash after native import");});reject(()->crashing.checkpoint(fake,new File(fakeRoot,"first"),true),"simulated native-import crash");require(crashing.requiresPrivateRecovery()&&fake.count==10,"incomplete import marker survives crash");reject(()->crashing.manage("ni hao","你好",true),"management cannot overwrite an unfinished import");checks++;
  LearningCoordinator recovered=new LearningCoordinator(new File(fakeRoot,"local"),fakeShared);learned=recovered.checkpoint(fake,new File(fakeRoot,"recover1"),true);require(!recovered.requiresPrivateRecovery()&&frequency(learned,"你好")==10,"recovery never counts imported peer counts as local typing");fake.count=11;learned=recovered.checkpoint(fake,new File(fakeRoot,"typed"),true);require(frequency(learned,"你好")==11,"genuine typing after recovery counted once");checks++;
  LearningCoordinator stateCrash=new LearningCoordinator(new File(fakeRoot,"local"),fakeShared,phase->{if(phase.equals("state-saved"))throw new IOException("synthetic crash before completion marker");});reject(()->stateCrash.checkpoint(fake,new File(fakeRoot,"state-crash"),true),"simulated checkpoint publication crash");require(stateCrash.requiresPrivateRecovery(),"state-save window still requires cold recovery");learned=recovered.checkpoint(fake,new File(fakeRoot,"recover2"),true);require(frequency(learned,"你好")==11,"state-save recovery idempotent");checks++;
  LearningCoordinator completedCrash=new LearningCoordinator(new File(fakeRoot,"local"),fakeShared,phase->{if(phase.equals("completed"))throw new IOException("synthetic crash before marker cleanup");});reject(()->completedCrash.checkpoint(fake,new File(fakeRoot,"completed-crash"),true),"simulated completed marker cleanup crash");require(!completedCrash.requiresPrivateRecovery(),"completed import does not disable future learning");fake.count=12;learned=recovered.checkpoint(fake,new File(fakeRoot,"recover3"),true);require(frequency(learned,"你好")==12,"completed marker cannot discard new typing");checks++;
  System.out.println("Passed "+checks+" actual pinned-Rime export/import/reset/pin and crash-recovery checks; all fixtures isolated, no installed app/UI/network touched");
 }
}
