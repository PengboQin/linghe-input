package live.linghe.privateinput;
import java.math.BigInteger;import java.util.*;
/** Immutable in-memory control index. Ordinary selection must not enqueue cloud-state IO. */
final class LearningRelearnGate {
 static final LearningRelearnGate EMPTY=new LearningRelearnGate(Collections.emptyList());
 private final Map<String,LearningModel.Entry> local;
 LearningRelearnGate(List<LearningModel.Entry> entries){Map<String,LearningModel.Entry> rows=new HashMap<>();for(LearningModel.Entry entry:entries)rows.put(entry.id(),entry);local=Collections.unmodifiableMap(rows);}
 static String key(String reading,String text){return LearningModel.canonical(reading.toLowerCase(Locale.ROOT).trim()+'\u001f'+text);}
 boolean dispatchIfNeeded(String reading,String text,boolean suppressed,BigInteger cloudDeletion,Runnable dispatch){
  LearningModel.Entry row=local.get(key(reading,text));
  boolean deleted=row!=null&&row.deleted;
  boolean remoteDeleted=cloudDeletion!=null&&(row==null||row.generation.compareTo(cloudDeletion)<=0);
  if(!suppressed&&!deleted&&!remoteDeleted)return false;
  dispatch.run();return true;
 }
}
