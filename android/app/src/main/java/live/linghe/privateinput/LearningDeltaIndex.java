package live.linghe.privateinput;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.*;
/** Pure CRDT row selection. Complete row values, not arithmetic count differences,
 * preserve per-replica MAX counters, reset generations, pins and tombstones. */
final class LearningDeltaIndex {
 static final long REPAIR_SECONDS=86400;
 static final class Checkpoint {
  final String context;final Map<String,String> entries,personal;final long fullRepairAt;
  Checkpoint(String context,Map<String,String> entries,Map<String,String> personal,long fullRepairAt)throws Exception{
   if(context==null||context.isEmpty()||fullRepairAt<0)throw new IOException("Invalid delta checkpoint context");
   this.context=context;this.entries=checked(entries,LearningCapacityProfiles.EXPANDED_10000.termRows);this.personal=personal==null?null:checked(personal,4000);this.fullRepairAt=fullRepairAt;
  }
 }
 static Map<String,String> checked(Map<String,String> values,int limit)throws Exception{
  if(values.size()>limit)throw new IOException("Delta checkpoint capacity exceeded");Map<String,String> result=new TreeMap<>();
  for(Map.Entry<String,String> row:values.entrySet()){if(row.getKey()==null||row.getKey().isEmpty()||row.getKey().getBytes(StandardCharsets.UTF_8).length>2048||Base64.getDecoder().decode(row.getValue()).length!=32)throw new IOException("Invalid delta checkpoint row");result.put(row.getKey(),row.getValue());}
  return Collections.unmodifiableMap(result);
 }
 static String hash(String text)throws Exception{return Base64.getEncoder().encodeToString(MessageDigest.getInstance("SHA-256").digest(text.getBytes(StandardCharsets.UTF_8)));}
 private static Map<String,String> hashes(Map<String,String> source)throws Exception{Map<String,String> result=new TreeMap<>();for(Map.Entry<String,String> row:source.entrySet())result.put(row.getKey(),hash(row.getValue()));return result;}
 static final class Prepared {
  final Map<String,String> entries,personal;final Checkpoint checkpoint;final boolean full;
  Prepared(Map<String,String> entries,Map<String,String> personal,Checkpoint checkpoint,boolean full){this.entries=entries;this.personal=personal;this.checkpoint=checkpoint;this.full=full;}
  boolean hasPayload(){return full||!entries.isEmpty()||personal!=null;}
 }
 static Prepared prepare(String context,Map<String,String> entries,Map<String,String> personal,Checkpoint previous,long now,boolean repairRequired)throws Exception{
  if(now<0||entries.size()>LearningCapacityProfiles.EXPANDED_10000.termRows||personal!=null&&personal.size()>4000)throw new IOException("Delta publication bounds");
  Checkpoint prior=previous!=null&&previous.context.equals(context)?previous:null;
  Map<String,String> nextHashes=hashes(entries),nextPersonal=personal==null?null:hashes(personal);
  if(prior!=null&&(!nextHashes.keySet().containsAll(prior.entries.keySet())||prior.personal!=null&&(nextPersonal==null||!nextPersonal.keySet().containsAll(prior.personal.keySet()))))throw new IOException("Missing explicit learning tombstone");
  boolean full=prior==null||repairRequired||now<prior.fullRepairAt||now-prior.fullRepairAt>=REPAIR_SECONDS;
  Map<String,String> changed=new TreeMap<>();for(Map.Entry<String,String> row:entries.entrySet())if(full||!Objects.equals(nextHashes.get(row.getKey()),prior.entries.get(row.getKey())))changed.put(row.getKey(),row.getValue());
  Map<String,String> personalDelta=null;if(personal!=null&&(full||!Objects.equals(nextPersonal,prior.personal))){personalDelta=new TreeMap<>();for(Map.Entry<String,String> row:personal.entrySet())if(full||prior.personal==null||!Objects.equals(nextPersonal.get(row.getKey()),prior.personal.get(row.getKey())))personalDelta.put(row.getKey(),row.getValue());}
  return new Prepared(Collections.unmodifiableMap(changed),personalDelta==null?null:Collections.unmodifiableMap(personalDelta),new Checkpoint(context,nextHashes,nextPersonal,full?now:prior.fullRepairAt),full);
 }
}
