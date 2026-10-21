package live.linghe.privateinput;

import android.util.AtomicFile;import java.io.*;import java.nio.charset.StandardCharsets;import java.util.*;import org.json.*;

/** Rime operations run only after the frontend closes every app-owned session. */
final class LearningCoordinator {
 interface Engine {int exportTo(File file)throws Exception;int importFrom(File file)throws Exception;int reset(LearningModel.Entry entry)throws Exception;}
 interface StepObserver {void reached(String phase)throws Exception;}
 private final File directory;private final AtomicFile stateFile,pending,replicaFile;private final LearningSnapshotFile shared;private final PersonalLexicon personal;private final StepObserver observer;private String completedArchive;
 String completedArchive(){return completedArchive;}
 LearningCoordinator(File directory,File shared)throws Exception{this(directory,shared,phase->{});}
 LearningCoordinator(File directory,File shared,StepObserver observer)throws Exception {
  this.directory=directory;this.shared=new LearningSnapshotFile(shared);personal=new PersonalLexicon(shared);this.observer=observer;stateFile=new AtomicFile(new File(directory,"learning-checkpoint-v1.json"));pending=new AtomicFile(new File(directory,"learning-import-pending-v1.json"));replicaFile=new AtomicFile(new File(directory,"local-replica-id.txt"));
 }
 private RimeCheckpoint readState()throws Exception{String text=AppFiles.readOptional(stateFile,RimeCheckpoint.MAX_STATE_BYTES);return text==null?new RimeCheckpoint():RimeCheckpoint.decode(text);}
 private JSONObject readPending()throws Exception {
  String text=AppFiles.readOptional(pending,RimeCheckpoint.MAX_STATE_BYTES+4096);if(text==null)return null;JSONObject value=LosslessJson.object(text,RimeCheckpoint.MAX_STATE_BYTES+4096);String phase=PersonalLexicon.string(value,"phase");if(!phase.equals("preparing")&&!phase.equals("completed"))throw new IOException("Invalid import checkpoint");RimeCheckpoint.decode(value.getJSONObject("checkpoint").toString());return value;
 }
 boolean requiresPrivateRecovery(){try{JSONObject value=readPending();return value!=null&&PersonalLexicon.string(value,"phase").equals("preparing");}catch(Exception invalid){return true;}}
 String replica()throws Exception {
  String text=AppFiles.readOptional(replicaFile,128);if(text!=null){PersonalLexicon.uuid(text);return text;}
  String id=UUID.randomUUID().toString().toUpperCase(Locale.ROOT);AppFiles.write(replicaFile,id,128);return id;
 }
 List<LearningModel.Entry> entries()throws Exception{return AppFiles.locked(directory,"learning-coordination.lock",()->{JSONObject queued=readPending();RimeCheckpoint state=queued!=null&&PersonalLexicon.string(queued,"phase").equals("preparing")?RimeCheckpoint.decode(queued.getJSONObject("checkpoint").toString()):readState();completedArchive=state.model.export();return state.model.entries();});}
 String legacySnapshot()throws Exception{return AppFiles.locked(directory,"learning-coordination.lock",()->{if(requiresPrivateRecovery())throw new IOException("输入记忆正在恢复");return readState().model.export();});}
 void manage(String reading,String text,Boolean pinned)throws Exception {
  AppFiles.locked(directory,"learning-coordination.lock",()->{if(requiresPrivateRecovery())throw new IOException("输入记忆正在恢复");RimeCheckpoint state=readState();if(pinned==null)state.resetFrequency(reading,text);else state.setPinned(reading,text,pinned,replica());AppFiles.write(stateFile,state.encode(),RimeCheckpoint.MAX_STATE_BYTES);completedArchive=state.model.export();return null;});
 }
 private void mark(String phase,RimeCheckpoint state)throws Exception {
  JSONObject marker=new JSONObject().put("phase",phase).put("checkpoint",LosslessJson.object(state.encode(),RimeCheckpoint.MAX_STATE_BYTES));AppFiles.write(pending,LosslessJson.canonical(marker),RimeCheckpoint.MAX_STATE_BYTES+4096);
 }
 List<LearningModel.Entry> checkpoint(Engine engine,File work,boolean publish)throws Exception {
  if(!work.isDirectory()&&!work.mkdirs())throw new IOException("无法准备词库快照");
  return AppFiles.locked(directory,"learning-coordination.lock",()->{
   JSONObject queued=readPending();boolean recovering=queued!=null&&PersonalLexicon.string(queued,"phase").equals("preparing");
   RimeCheckpoint state=recovering?RimeCheckpoint.decode(queued.getJSONObject("checkpoint").toString()):readState();File exported=new File(work,"engine.tsv"),imported=new File(work,"incoming.tsv");
   if(engine.exportTo(exported)<0)throw new IOException("词库导出未完成");String before=AppFiles.read(exported,LearningModel.MAX_BYTES);
   // A cold frontend recovers this marker before enabling learning. The plan
   // already includes all local deltas, so partially imported counts are not
   // new typing, regardless of which native step completed before the crash.
   if(!recovering)state.observeExport(before,replica());
   String archive=shared.read();if(archive!=null)state.mergeRemote(archive);
   state.model.mergePersonalLexicon(personal.synchronizationSnapshot());String combinedPersonal=state.model.personalSnapshot();if(combinedPersonal!=null)personal.mergeSynchronized(combinedPersonal);
   state.model.export();mark("preparing",state);observer.reached("prepared");
   for(LearningModel.Entry entry:state.pendingResets())if(engine.reset(entry)<0)throw new IOException("词频重置未完成");
   try(OutputStream output=new FileOutputStream(imported)){output.write(state.engineImport().getBytes(StandardCharsets.UTF_8));}
   if(engine.importFrom(imported)<0)throw new IOException("词库合并未完成");observer.reached("native-imported");
   if(engine.exportTo(exported)<0)throw new IOException("词库基线未完成");state.establishBaselineAfterImport(AppFiles.read(exported,LearningModel.MAX_BYTES));AppFiles.write(stateFile,state.encode(),RimeCheckpoint.MAX_STATE_BYTES);observer.reached("state-saved");
   mark("completed",state);observer.reached("completed");pending.delete();
   completedArchive=state.model.export();if(publish)shared.publish(completedArchive);return state.model.entries();
  });
 }
}
