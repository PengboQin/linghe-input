package live.linghe.privateinput;
import java.io.IOException;
import java.math.BigInteger;
import java.nio.charset.StandardCharsets;
import java.util.*;
import org.json.*;
/** Existing v1 archive, changed rows only. Queue+hash baseline share the same
 * encrypted SyncStore AtomicFile commit; no separate checkpoint file. */
final class LearningDeltaPublication {
 static final String CHECKPOINT="learningDeltaCheckpointV1",REPAIR="learningDeltaRepairRequired";
 interface Save{void run(JSONObject next)throws Exception;}
 interface Seal{JSONObject run(byte[] payload,JSONObject reserved)throws Exception;}
 static final class Prepared {
  final String payload,publication,priorCheckpoint;final JSONObject checkpoint;final boolean full;final int changedEntries,changedPersonal;
  Prepared(String payload,String publication,String prior,JSONObject checkpoint,boolean full,int entries,int personal){this.payload=payload;this.publication=publication;priorCheckpoint=prior;this.checkpoint=checkpoint;this.full=full;changedEntries=entries;changedPersonal=personal;}
 }
 private static Map<String,String> strings(JSONObject object)throws Exception{Map<String,String> rows=new TreeMap<>();Iterator<String> keys=object.keys();while(keys.hasNext()){String key=keys.next();rows.put(key,PersonalLexicon.string(object,key));}return rows;}
 private static JSONObject object(Map<String,String> rows)throws Exception{JSONObject result=new JSONObject();for(Map.Entry<String,String> row:rows.entrySet())result.put(row.getKey(),row.getValue());return result;}
 private static LearningDeltaIndex.Checkpoint previous(JSONObject old)throws Exception{
  if(old==null)return null;
  try{if(!LosslessJson.unsigned(old.get("version")).equals(BigInteger.ONE))return null;return new LearningDeltaIndex.Checkpoint(old.getString("context"),strings(old.getJSONObject("entries")),old.has("personalEntries")&&!old.isNull("personalEntries")?strings(old.getJSONObject("personalEntries")):null,LosslessJson.unsigned(old.get("fullRepairAt")).longValueExact());}
  catch(Exception malformedOptimization){return null;}
 }
 static Prepared prepare(LearningModel model,String group,BigInteger epoch,String endpoint,String privacy,JSONObject old,long now,boolean repairRequired)throws Exception{
  if(epoch.signum()<=0||epoch.compareTo(LosslessJson.UINT64_MAX)>0)throw new IOException("Invalid learning epoch");String canonical=model.export();String groupID=PersonalLexicon.uuid(group);String context=groupID+"/"+epoch+"/"+endpoint+"/"+privacy;
  Map<String,String> rows=new TreeMap<>();Map<String,JSONObject> values=new TreeMap<>();for(LearningModel.Entry entry:model.entries()){JSONObject value=entry.json();rows.put(entry.id(),LosslessJson.canonical(value));values.put(entry.id(),value);}
  String personalEncoded=model.personalSnapshot();JSONObject personal=personalEncoded==null?null:LosslessJson.object(personalEncoded,PersonalLexicon.MAX_BYTES);Map<String,String> personalRows=null;if(personal!=null){personalRows=new TreeMap<>();JSONObject records=personal.getJSONObject("records");Iterator<String> keys=records.keys();while(keys.hasNext()){String key=keys.next();personalRows.put(key,LosslessJson.canonical(records.getJSONObject(key)));}}
  LearningDeltaIndex.Prepared delta=LearningDeltaIndex.prepare(context,rows,personalRows,previous(old),now,repairRequired);JSONArray changed=new JSONArray();for(String id:delta.entries.keySet())changed.put(values.get(id));JSONObject payload=new JSONObject().put("version",LearningCapacityMetadata.legacy(model.capacityProfile())?1:2).put("schemaID","private_pinyin").put("entries",changed);if(!LearningCapacityMetadata.legacy(model.capacityProfile()))payload.put("capacity_profile",LearningCapacityMetadata.encode(model.capacityProfile()));
  if(delta.personal!=null){JSONObject records=new JSONObject();for(String id:delta.personal.keySet())records.put(id,personal.getJSONObject("records").getJSONObject(id));payload.put("personalLexicon",new JSONObject().put("version",1).put("records",records));}
  String encoded=delta.hasPayload()?LosslessJson.canonical(payload):null;if(encoded!=null){LearningModel compatible=new LearningModel(model.capacityProfile());compatible.merge(encoded);}
  JSONObject checkpoint=new JSONObject().put("version",1).put("context",context).put("entries",object(delta.checkpoint.entries)).put("fullRepairAt",delta.checkpoint.fullRepairAt);if(delta.checkpoint.personal!=null)checkpoint.put("personalEntries",object(delta.checkpoint.personal));
  return new Prepared(encoded,groupID+"/"+epoch+"/"+LearningDeltaIndex.hash(canonical),old==null?null:LosslessJson.canonical(old),checkpoint,delta.full,delta.entries.size(),delta.personal==null?0:delta.personal.size());
 }
 static JSONObject enqueue(JSONObject current,Prepared prepared,long generation,Seal seal,Save save)throws Exception{
  JSONObject old=current.optJSONObject(CHECKPOINT);String actual=old==null?null:LosslessJson.canonical(old);if(!Objects.equals(actual,prepared.priorCheckpoint))throw new IOException("Learning delta checkpoint changed");
  if(prepared.payload==null)return current;
  JSONObject reservation=LosslessJson.object(LosslessJson.canonical(current),6*1024*1024);if(reservation.getJSONArray("outbox").length()>=32)throw new IOException("Learning outbox full");BigInteger sequence=LosslessJson.unsigned(reservation.get("sequence")).add(BigInteger.ONE);if(sequence.compareTo(LosslessJson.UINT64_MAX)>0)throw new IOException("Learning sequence exhausted");reservation.put("sequence",sequence);
  // E2EE nonces derive from sequence. Reserve it durably BEFORE encryption;
  // failure may burn a number, never reuse a nonce for another payload.
  // The save callback adopts this durable reservation in the caller as well.
  save.run(reservation);
  JSONObject next=LosslessJson.object(LosslessJson.canonical(reservation),6*1024*1024);JSONArray out=next.getJSONArray("outbox");
  JSONObject wire=seal.run(prepared.payload.getBytes(StandardCharsets.UTF_8),next);if(wire.getInt("domain")!=1)throw new IOException("Learning publication domain mismatch");
  out.put(new JSONObject().put("wire",wire).put("generation",generation));next.put(CHECKPOINT,prepared.checkpoint).put("publishedDigest",prepared.publication);next.remove(REPAIR);
  save.run(next);return next;
 }
 static JSONObject discardLearning(JSONObject current,int index,Save save)throws Exception{
  if(current.getJSONArray("outbox").getJSONObject(index).getJSONObject("wire").getInt("domain")!=1)throw new IOException("Learning discard domain mismatch");
  JSONObject next=LosslessJson.object(LosslessJson.canonical(current),6*1024*1024);next.getJSONArray("outbox").remove(index);next.remove(CHECKPOINT);next.remove("publishedDigest");next.put(REPAIR,true);save.run(next);return next;
 }
}
