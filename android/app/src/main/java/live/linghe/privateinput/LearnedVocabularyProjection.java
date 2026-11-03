package live.linghe.privateinput;

import android.util.AtomicFile;
import java.io.File;import java.io.IOException;import java.util.*;

/** Read-only projection for the learned-vocabulary settings page.
 *  No native engine, running Rime database, network or learning writes. The
 *  formal shared snapshot and the last committed checkpoint are merged with the
 *  existing generation/tombstone rules, so a newer local undo cannot be
 *  resurrected by an older shared snapshot and one device counter is not added
 *  twice. A corrupt checkpoint fails closed and is kept for retry; a corrupt shared snapshot is also an error. */
final class LearnedVocabularyProjection {
 private LearnedVocabularyProjection(){}
 static List<LearningModel.Entry> read(File directory,File shared)throws Exception {
  String epoch=PersonalReset.fileGeneration(directory);
  LearningModel model=new LearningModel(LearningCapacityProfiles.EXPANDED_10000);
  String archive=new LearningSnapshotFile(shared).read();
  if(archive!=null)model.merge(archive);
  String checkpoint=AppFiles.readOptional(new AtomicFile(new File(directory,"learning-checkpoint-v1.json")),RimeCheckpoint.MAX_STATE_BYTES);
  if(checkpoint!=null)try{
   RimeCheckpoint state=RimeCheckpoint.decode(checkpoint);
   if(state.model.capacityProfile()!=LearningCapacityProfiles.EXPANDED_10000)state.upgradeCapacity(LearningCapacityProfiles.EXPANDED_10000);
   model.merge(state.model.export());
  }catch(Exception broken){
   // A present checkpoint is the newer local source. Falling back to an older
   // shared snapshot here could resurrect a word whose deletion exists only in
   // the checkpoint. Fail closed and keep the original file for retry/repair.
   throw new IOException("学习记录损坏，请刷新重试",broken);
  }
  if(!epoch.equals(PersonalReset.fileGeneration(directory)))throw new IOException("个人资料已重置");
  ArrayList<LearningModel.Entry> rows=new ArrayList<>();
  for(LearningModel.Entry entry:model.entries())if(!entry.deleted&&(entry.frequency()>0||entry.pinned))rows.add(entry);
  rows.sort((a,b)->{int n=Long.compare(b.frequency(),a.frequency());return n!=0?n:a.id().compareTo(b.id());});
  return rows;
 }
 static List<LearningModel.Entry> filter(List<LearningModel.Entry> rows,String query){
  String needle=query==null?"":query.trim().toLowerCase(Locale.ROOT);
  if(needle.isEmpty())return rows;
  ArrayList<LearningModel.Entry> result=new ArrayList<>();
  for(LearningModel.Entry entry:rows)if(entry.text.toLowerCase(Locale.ROOT).contains(needle)||entry.reading.toLowerCase(Locale.ROOT).contains(needle))result.add(entry);
  return result;
 }
}
