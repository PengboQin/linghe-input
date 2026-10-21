package live.linghe.privateinput;
import android.util.AtomicFile;import java.io.*;

/** Shared semantic archive only. Never copies a running Rime database or local context memory. */
final class LearningSnapshotFile {
 private final File directory;private final AtomicFile file;private final String epoch;
 LearningSnapshotFile(File directory){this.directory=directory;this.epoch=PersonalReset.fileGeneration(directory);file=new AtomicFile(new File(directory,"learning-v1.json"));}
 String read()throws Exception{String text=AppFiles.readOptional(file,LearningModel.MAX_BYTES);if(text!=null){LearningModel validation=new LearningModel();validation.merge(text);}return text;}
 void publish(String incoming)throws Exception {
  if(!epoch.equals(PersonalReset.fileGeneration(directory)))throw new IOException("个人资料已重置");
  LearningModel validation=new LearningModel();validation.merge(incoming);
  AppFiles.locked(directory,"learning-publication.lock",()->{String current=read();LearningModel merged=new LearningModel();merged.merge(incoming);if(current!=null)merged.merge(current);String next=merged.export();if(!next.equals(current))AppFiles.write(file,next,LearningModel.MAX_BYTES);return null;});
 }
}
