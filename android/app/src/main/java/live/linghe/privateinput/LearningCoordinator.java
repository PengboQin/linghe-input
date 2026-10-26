package live.linghe.privateinput;

import android.util.AtomicFile;
import java.io.*;import java.nio.charset.StandardCharsets;import java.nio.channels.*;import java.nio.file.Files;import java.security.MessageDigest;import java.util.*;import org.json.*;

/** IO owns plans/JSON; the existing native worker owns only one short batch. */
final class LearningCoordinator {
 interface Engine {int exportTo(File file)throws Exception;int importFrom(File file)throws Exception;int reset(LearningModel.Entry entry)throws Exception;}
 interface StepObserver {void reached(String phase)throws Exception;}
 static final String PREPARED="learning-import-prepared-v2",STARTED="learning-native-started-v2",REVISION="learning-checkpoint-revision-v2";
 private final File directory;private final AtomicFile stateFile,pending,prepared,started,revision,replicaFile;
 private final LearningSnapshotFile shared;private final PersonalLexicon personal;private final StepObserver observer;private final String epoch;private volatile String completedArchive;
 private volatile int nativeLeaseReason;
 int nativeLeaseReason(){return nativeLeaseReason;}
 String completedArchive(){return completedArchive;}
 LearningCoordinator(File directory,File shared)throws Exception{this(directory,shared,phase->{});}
 LearningCoordinator(File directory,File shared,StepObserver observer)throws Exception{
  this.directory=directory;this.epoch=PersonalReset.fileGeneration(directory);this.shared=new LearningSnapshotFile(shared);personal=new PersonalLexicon(shared);this.observer=observer;
  stateFile=new AtomicFile(new File(directory,"learning-checkpoint-v1.json"));pending=new AtomicFile(new File(directory,"learning-import-pending-v1.json"));prepared=new AtomicFile(new File(directory,PREPARED));started=new AtomicFile(new File(directory,STARTED));revision=new AtomicFile(new File(directory,REVISION));replicaFile=new AtomicFile(new File(directory,"local-replica-id.txt"));
 }
 private static boolean exists(AtomicFile file){return file.getBaseFile().exists()||new File(file.getBaseFile()+".bak").exists();}
 /** Native-ready path: no JSON, export, coordination lock or model validation. */
 boolean mayRequirePrivateRecovery(){return exists(pending)||exists(started);}
 boolean requiresPrivateRecovery(){if(exists(started))return true;if(!exists(pending))return false;try{JSONObject old=legacy();return old!=null&&!old.getString("phase").equals("completed");}catch(Exception invalid){return true;}}
 private void allowed()throws IOException{if(epoch.equals("unavailable")||!epoch.equals(PersonalReset.fileGeneration(directory)))throw new IOException("个人资料已重置");}
 private static String hash(String text)throws Exception{StringBuilder s=new StringBuilder();for(byte b:MessageDigest.getInstance("SHA-256").digest(text.getBytes(StandardCharsets.UTF_8)))s.append(String.format(Locale.ROOT,"%02x",b&255));return s.toString();}
 private static String stamp(String nonce,String epoch)throws Exception{
  PersonalLexicon.uuid(nonce);if(!epoch.equals("initial"))PersonalLexicon.uuid(epoch);String value="v2 "+nonce+" "+epoch+"\n";if(value.getBytes(StandardCharsets.UTF_8).length>128)throw new IOException("Invalid native intent stamp");return value;
 }
 private static String readStamp(AtomicFile file)throws Exception{
  if(!exists(file))return null;if(Files.isSymbolicLink(file.getBaseFile().toPath()))throw new IOException("Invalid intent file");
  try(InputStream input=file.openRead();ByteArrayOutputStream bytes=new ByteArrayOutputStream()){
   for(int i=0;i<128;i++){int b=input.read();if(b<0)break;bytes.write(b);if(b=='\n'){return checkedStamp(new String(bytes.toByteArray(),StandardCharsets.UTF_8));}}
  }throw new IOException("Native intent stamp missing");
 }
 private static String checkedStamp(String value)throws Exception{String[] p=value.trim().split(" ",-1);if(p.length!=3||!p[0].equals("v2")||!stamp(p[1],p[2]).equals(value))throw new IOException("Invalid native intent stamp");return value;}
 private String startedStamp()throws Exception{String value=AppFiles.readOptional(started,128);return value==null?null:checkedStamp(value);}
 private static final class Committed{final RimeCheckpoint state;final String fingerprint;Committed(RimeCheckpoint s,String f){state=s;fingerprint=f;}}
 /** IO only. Repair revision after an interrupted checkpoint write, under lock. */
 private Committed committed()throws Exception{
  allowed();String text=AppFiles.readOptional(stateFile,RimeCheckpoint.MAX_STATE_BYTES);RimeCheckpoint state=text==null?new RimeCheckpoint():RimeCheckpoint.decode(text);
  if(state.model.capacityProfile()!=LearningCapacityProfiles.EXPANDED_10000)state.upgradeCapacity(LearningCapacityProfiles.EXPANDED_10000);
  String fingerprint=hash(text==null?"absent\n":text),old=AppFiles.readOptional(revision,128);if(!fingerprint.equals(old))AppFiles.write(revision,fingerprint,128);return new Committed(state,fingerprint);
 }
 private void commitState(RimeCheckpoint state)throws Exception{
  String encoded=state.encode();allowed();AppFiles.write(revision,"writing "+UUID.randomUUID(),128);allowed();AppFiles.write(stateFile,encoded,RimeCheckpoint.MAX_STATE_BYTES);allowed();AppFiles.write(revision,hash(encoded),128);
 }
 private JSONObject legacy()throws Exception{
  String text=AppFiles.readOptional(pending,RimeCheckpoint.MAX_STATE_BYTES+4096);if(text==null)return null;JSONObject value=LosslessJson.object(text,RimeCheckpoint.MAX_STATE_BYTES+4096);String phase=PersonalLexicon.string(value,"phase");if(!phase.equals("preparing")&&!phase.equals("completed"))throw new IOException("Invalid old import intent");RimeCheckpoint.decode(value.getJSONObject("checkpoint").toString());return value;
 }
 private JSONObject cleanCompletedLegacy()throws Exception{
  JSONObject value=legacy();if(value!=null&&value.getString("phase").equals("completed")){
   if(!exists(stateFile))commitState(RimeCheckpoint.decode(value.getJSONObject("checkpoint").toString()));pending.delete();return null;
  }return value;
 }
 String replica()throws Exception{String text=AppFiles.readOptional(replicaFile,128);if(text!=null){PersonalLexicon.uuid(text);return text;}String id=UUID.randomUUID().toString().toUpperCase(Locale.ROOT);allowed();AppFiles.write(replicaFile,id,128);return id;}
 static final class Prepared{
  final String stamp,fingerprint,legacyHash;final boolean recovery;final File importFile,actualFile;final List<LearningModel.Entry> resets;private final RimeCheckpoint target;
  Prepared(String stamp,String fingerprint,String legacyHash,boolean recovery,RimeCheckpoint target,File work)throws Exception{
   this.stamp=stamp;this.fingerprint=fingerprint;this.legacyHash=legacyHash;this.recovery=recovery;this.target=target;importFile=new File(work,"incoming.tsv");actualFile=new File(work,"actual.tsv");resets=Collections.unmodifiableList(new ArrayList<>(target.pendingResets()));
   if(!work.isDirectory()&&!work.mkdirs())throw new IOException("无法准备词库快照");Files.write(importFile.toPath(),target.engineImport().getBytes(StandardCharsets.UTF_8));
  }
 }
 private Prepared stored(File work)throws Exception{
  String raw=AppFiles.readOptional(prepared,RimeCheckpoint.MAX_STATE_BYTES+4096),header=readStamp(prepared),active=startedStamp();if(raw==null||header==null||!header.equals(active)||!raw.startsWith(header))throw new IOException("Native intent nonce mismatch");
  if(!header.trim().endsWith(" "+epoch))throw new IOException("Native intent epoch mismatch");JSONObject value=LosslessJson.object(raw.substring(header.length()),RimeCheckpoint.MAX_STATE_BYTES+4096);if(LosslessJson.unsigned(value.get("version")).intValueExact()!=2)throw new IOException("Native intent version");String fp=PersonalLexicon.string(value,"committedFingerprint"),old=value.optString("legacyHash",null);if(!fp.matches("[0-9a-f]{64}")||old!=null&&!old.matches("[0-9a-f]{64}"))throw new IOException("Invalid intent fingerprint");return new Prepared(header,fp,old,true,RimeCheckpoint.decode(value.getJSONObject("checkpoint").toString()),work);
 }
 /** IO only, after the worker has exported a closed-session snapshot/reopened. */
 Prepared prepare(File observed,File work)throws Exception{
  Prepared result=AppFiles.locked(directory,"learning-coordination.lock",()->{
   observer.reached("prepare-locked");
   allowed();if(exists(started))return stored(work);
   // Never-started plans are derived only; raw native counts/shared survive.
   if(exists(prepared))prepared.delete();JSONObject old=cleanCompletedLegacy();Committed base=committed();RimeCheckpoint target;String legacyHash=null;
   if(old!=null){target=RimeCheckpoint.decode(old.getJSONObject("checkpoint").toString());legacyHash=hash(AppFiles.readOptional(pending,RimeCheckpoint.MAX_STATE_BYTES+4096));}
   else{target=base.state;target.observeExport(AppFiles.read(observed,LearningModel.MAX_BYTES),replica());String archive=shared.read();if(archive!=null)target.mergeRemote(archive);target.model.mergePersonalLexicon(personal.synchronizationSnapshot());String combined=target.model.personalSnapshot();if(combined!=null)personal.mergeSynchronized(combined);}
   String header=stamp(UUID.randomUUID().toString().toUpperCase(Locale.ROOT),epoch);JSONObject body=new JSONObject().put("version",2).put("committedFingerprint",base.fingerprint).put("checkpoint",LosslessJson.object(target.encode(),RimeCheckpoint.MAX_STATE_BYTES));if(legacyHash!=null)body.put("legacyHash",legacyHash);
   Prepared plan=new Prepared(header,base.fingerprint,legacyHash,old!=null,target,work);allowed();AppFiles.write(prepared,header+LosslessJson.canonical(body),RimeCheckpoint.MAX_STATE_BYTES+4096);return plan;
  });observer.reached("prepared");return result;
 }
 final class NativeLease implements AutoCloseable{
  private final RandomAccessFile file;private final FileLock lock;private final Prepared plan;
  NativeLease(RandomAccessFile f,FileLock l,Prepared p){file=f;lock=l;plan=p;}
  /** Called only after the session is closed and the final in-memory lease check. */
  void start()throws Exception{allowed();String active=startedStamp();if(active!=null&&!active.equals(plan.stamp))throw new IOException("Native intent changed");if(active==null)AppFiles.write(started,plan.stamp,128);}
  public void close()throws IOException{try{lock.release();}finally{file.close();}}
 }
 /** Worker only: try-lock and <=128B reads, never wait on an IO-held lock. */
 NativeLease tryNativeLease(Prepared plan)throws Exception{
  nativeLeaseReason=0;
  File path=new File(directory,"learning-coordination.lock");if(Files.isSymbolicLink(path.toPath()))throw new IOException("Invalid coordination lock");RandomAccessFile f=new RandomAccessFile(path,"rw");FileLock lock=null;
  try{try{lock=f.getChannel().tryLock();}catch(OverlappingFileLockException busy){nativeLeaseReason=1;f.close();return null;}if(lock==null){nativeLeaseReason=2;f.close();return null;}allowed();if(!plan.stamp.equals(readStamp(prepared)))throw new IOException("Prepared intent changed");String active=startedStamp();if(active!=null&&!active.equals(plan.stamp))throw new IOException("Native intent nonce mismatch");if(active==null&&!plan.fingerprint.equals(AppFiles.readOptional(revision,128))){nativeLeaseReason=3;lock.release();f.close();return null;}return new NativeLease(f,lock,plan);}
  catch(Exception error){nativeLeaseReason=4;if(lock!=null&&lock.isValid())lock.release();f.close();throw error;}
 }
 /** One worker task: all mutations and actual export, no JSON or model encoding. */
 void applyNative(Prepared plan,Engine engine)throws Exception{
  if(!plan.stamp.equals(startedStamp())||!plan.stamp.equals(readStamp(prepared)))throw new IOException("Native batch has not started");
  for(LearningModel.Entry entry:plan.resets){allowed();if(engine.reset(entry)<0)throw new IOException("词频重置未完成");}allowed();if(engine.importFrom(plan.importFile)<0)throw new IOException("词库合并未完成");observer.reached("native-imported");allowed();if(engine.exportTo(plan.actualFile)<0)throw new IOException("词库基线未完成");
 }
 /** IO only. Started keeps manage/control writers out until both states durable. */
 List<LearningModel.Entry> finish(Prepared plan,boolean publish)throws Exception{
  return AppFiles.locked(directory,"learning-coordination.lock",()->{
   observer.reached("finish-locked");
   allowed();if(!plan.stamp.equals(startedStamp())||!plan.stamp.equals(readStamp(prepared)))throw new IOException("Native completion nonce mismatch");RimeCheckpoint done=plan.target.completeImportAtCurrentCapacity(AppFiles.read(plan.actualFile,LearningModel.MAX_BYTES),replica());
   String archive=done.model.export();new RecentLearningStore(directory).mergeLegacy(archive);commitState(done);observer.reached(plan.recovery?"recovered-state-saved":"state-saved");
   if(plan.legacyHash!=null&&exists(pending)){if(!plan.legacyHash.equals(hash(AppFiles.readOptional(pending,RimeCheckpoint.MAX_STATE_BYTES+4096))))throw new IOException("Old native intent changed");pending.delete();}
   started.delete();prepared.delete();completedArchive=archive;observer.reached("completed");if(publish)shared.publish(archive);return done.model.entries();
  });
 }
 void cancel(Prepared plan)throws Exception{AppFiles.locked(directory,"learning-coordination.lock",()->{allowed();if(!exists(started)&&plan.stamp.equals(readStamp(prepared)))prepared.delete();return null;});}
 List<LearningModel.Entry> entries()throws Exception{return AppFiles.locked(directory,"learning-coordination.lock",()->{allowed();RimeCheckpoint state;if(exists(started)){String raw=AppFiles.readOptional(prepared,RimeCheckpoint.MAX_STATE_BYTES+4096),head=readStamp(prepared);if(head==null||!head.equals(startedStamp()))throw new IOException("Native intent nonce mismatch");state=RimeCheckpoint.decode(LosslessJson.object(raw.substring(head.length()),RimeCheckpoint.MAX_STATE_BYTES+4096).getJSONObject("checkpoint").toString());}else{JSONObject old=cleanCompletedLegacy();state=old==null?committed().state:RimeCheckpoint.decode(old.getJSONObject("checkpoint").toString());}completedArchive=state.model.export();return state.model.entries();});}
 String legacySnapshot()throws Exception{return AppFiles.locked(directory,"learning-coordination.lock",()->{cleanCompletedLegacy();if(mayRequirePrivateRecovery())throw new IOException("输入记忆正在恢复");return committed().state.model.export();});}
 /** Same durable path as manage(); records a cross-device deletion for the next checkpoint and cloud publication. */
 void forget(String reading,String text,java.math.BigInteger knownCloudGeneration)throws Exception{AppFiles.locked(directory,"learning-coordination.lock",()->{allowed();if(!exists(started))cleanCompletedLegacy();if(mayRequirePrivateRecovery())throw new IOException("输入记忆正在恢复");RimeCheckpoint state=committed().state;state.forget(reading,text,knownCloudGeneration);commitState(state);completedArchive=state.model.export();File dirty=new File(directory,"learning-maintenance-dirty-v1");if(!dirty.exists())try(FileOutputStream out=new FileOutputStream(dirty)){out.write(1);out.getFD().sync();}return null;});}
 void manage(String reading,String text,Boolean pinned)throws Exception{AppFiles.locked(directory,"learning-coordination.lock",()->{allowed();if(!exists(started))cleanCompletedLegacy();if(mayRequirePrivateRecovery())throw new IOException("输入记忆正在恢复");RimeCheckpoint state=committed().state;if(pinned==null)state.resetFrequency(reading,text);else state.setPinned(reading,text,pinned,replica());commitState(state);completedArchive=state.model.export();File dirty=new File(directory,"learning-maintenance-dirty-v1");if(!dirty.exists())try(FileOutputStream out=new FileOutputStream(dirty)){out.write(1);out.getFD().sync();}return null;});}
 /** Blocking fixture/closed-engine owner helper; IME uses the split API above. */
 List<LearningModel.Entry> checkpoint(Engine engine,File work,boolean publish)throws Exception{
  if(!work.isDirectory()&&!work.mkdirs())throw new IOException("无法准备词库快照");File observed=new File(work,"observed.tsv");if(engine.exportTo(observed)<0)throw new IOException("词库导出未完成");Prepared plan=prepare(observed,work);try(NativeLease lease=tryNativeLease(plan)){if(lease==null)throw new IOException("Native checkpoint changed");lease.start();applyNative(plan,engine);}return finish(plan,publish);
 }
}
