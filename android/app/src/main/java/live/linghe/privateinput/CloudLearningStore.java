package live.linghe.privateinput;
import android.content.Context;import android.content.SharedPreferences;import android.util.AtomicFile;import java.io.*;import java.math.BigInteger;import java.util.*;import org.json.*;
/** One app-private/FBE model file. No secrets or engine DB; group credential
 * remains in SyncStore. All disk/JSON work belongs to SyncTasks/recent IO. */
final class CloudLearningStore {
 static final int MAX=12*1024*1024;static final String ENABLED="cloud-learning-enabled",RANK="cloud-learning-rank-authorized",VALID="cloud-learning-rank-valid",REVOKE="cloud-learning-revoke-pending";
 final Context context;final File directory;private final AtomicFile file;private final String privacy;
 CloudLearningStore(Context context){this.context=context;privacy=PersonalReset.generation(context);directory=new File(new File(context.getFilesDir(),"Shared"),"CloudLearning");file=new AtomicFile(new File(directory,"state-v1.json"));}
 static void requestDisable(Context context){SharedPreferences p=context.getSharedPreferences("sync-consent",0);boolean pending=p.getBoolean(ENABLED,false)||p.getBoolean(VALID,false)||p.getBoolean(REVOKE,false);p.edit().putBoolean(ENABLED,false).putBoolean(RANK,false).putBoolean(VALID,false).putBoolean(REVOKE,pending).commit();PersonalChangeSignal.notifyChanged(context);}
 private void allowed()throws IOException{if(!privacy.equals(PersonalReset.generation(context)))throw new IOException("cloud personal epoch changed");}
 JSONObject read()throws Exception{return AppFiles.locked(directory,"state.lock",()->{allowed();String value=AppFiles.readOptional(file,MAX);return value==null?null:LosslessJson.object(value,MAX);});}
 void write(JSONObject value)throws Exception{AppFiles.locked(directory,"state.lock",()->{allowed();LearningCapacityMetadata.archive(value,1,2);AppFiles.write(file,CloudLearningCanonical.encode(value),MAX);return null;});}
 /** Highest generation the shared model has published for this term (0 when unknown). */
 java.math.BigInteger termGeneration(String reading,String text){
  try{JSONObject value=read();if(value==null)return java.math.BigInteger.ZERO;String key=LearningModel.canonical(reading+'\u001f'+text);java.math.BigInteger best=java.math.BigInteger.ZERO;
   for(String table:new String[]{"fences","terms"}){JSONObject rows=value.optJSONObject(table);JSONObject row=rows==null?null:rows.optJSONObject(key);if(row==null)continue;Object raw=row.opt(table.equals("fences")?"generation":"term_generation");if(raw!=null)best=best.max(new java.math.BigInteger(raw.toString()));}
   return best;}catch(Exception unavailable){return java.math.BigInteger.ZERO;}
 }
 String installation()throws Exception{return AppFiles.locked(directory,"state.lock",()->{allowed();AtomicFile id=new AtomicFile(new File(directory,"installation.txt"));String old=AppFiles.readOptional(id,128);if(old!=null)return PersonalLexicon.uuid(old);String fresh=UUID.randomUUID().toString().toUpperCase(Locale.ROOT);AppFiles.write(id,fresh,128);return fresh;});}
 void invalidateRank(){context.getSharedPreferences("sync-consent",0).edit().putBoolean(VALID,false).commit();PersonalChangeSignal.notifyChanged(context);}
 void publishRank(CloudLearningState state,String group,BigInteger membershipEpoch,String producer)throws Exception{
  if(!context.getSharedPreferences("sync-consent",0).getBoolean(ENABLED,false)||!context.getSharedPreferences("sync-consent",0).getBoolean(RANK,false)){invalidateRank();return;}
  if(!state.value.optBoolean("ready"))return; // Keep the last verified model while new components await worker ACK.
  JSONObject data=new JSONObject().put("version",2).put("capacity_profile",LearningCapacityMetadata.encode(LearningCapacityProfiles.EXPANDED_10000)).put("group",PersonalLexicon.uuid(group)).put("membershipEpoch",membershipEpoch).put("privacy",privacy).put("producer",PersonalLexicon.uuid(producer)).put("installation",state.value.getString("installation")).put("expiresAt",System.currentTimeMillis()/1000+7*86400).put("modelVersion",state.value.get("modelVersion")).put("terms",state.value.getJSONObject("terms")).put("fences",state.value.getJSONObject("fences")).put("represented",new JSONObject().put(PersonalLexicon.uuid(producer),state.value.getJSONObject("represented")));
  data.put("checksum",CloudLearningCanonical.hash(data));AppFiles.locked(directory,"state.lock",()->{allowed();AppFiles.write(new AtomicFile(new File(directory,"rank-v1.json")),CloudLearningCanonical.encode(data),8*1024*1024);return null;});context.getSharedPreferences("sync-consent",0).edit().putBoolean(VALID,true).commit();PersonalChangeSignal.notifyChanged(context);
 }
 /** Return a scope only for an already validated and locally authorized rank
  * snapshot from this current membership and installation. No RPC, mutation or
  * loading user dictionaries. Failure leaves the normal v2 cadence untouched. */
 String compatibilityScope(JSONObject sync)throws Exception{
  SharedPreferences p=context.getSharedPreferences("sync-consent",0);if(!p.getBoolean(ENABLED,false)||!p.getBoolean(RANK,false)||!p.getBoolean(VALID,false)||p.getBoolean(REVOKE,false)||!p.getBoolean("learning",false))return null;
  String encoded=AppFiles.locked(directory,"state.lock",()->{allowed();return AppFiles.readOptional(new AtomicFile(new File(directory,"rank-v1.json")),8*1024*1024);});if(encoded==null)return null;JSONObject rank=LosslessJson.object(encoded,8*1024*1024);String checksum=rank.getString("checksum");rank.remove("checksum");if(!CloudLearningCanonical.hash(rank).equals(checksum))return null;
  JSONObject membership=sync.getJSONObject("membership"),identity=sync.getJSONObject("identity");String group=SyncCrypto.id(membership.getString("group"));BigInteger epoch=SyncCrypto.u(membership,"epoch"),revision=SyncCrypto.u(membership,"revision");if((SyncCrypto.find(membership,identity.getString("device")).getInt("permissions")&1)==0||!privacy.equals(rank.getString("privacy"))||!group.equals(SyncCrypto.id(rank.getString("group")))||!epoch.equals(SyncCrypto.u(rank,"membershipEpoch")))return null;
  long remaining=LosslessJson.unsigned(rank.get("expiresAt")).longValueExact()-System.currentTimeMillis()/1000;if(remaining<=0||remaining>7*86400||SyncCrypto.u(rank,"modelVersion").signum()<=0||!installation().equals(PersonalLexicon.uuid(rank.optString("installation"))))return null;
  JSONObject ownerState=read();if(ownerState==null||!rank.getString("installation").equals(ownerState.getString("installation"))||!rank.getString("producer").equals(ownerState.getString("producer")))return null;String owner=LearningDeltaIndex.hash(group+"/"+PersonalLexicon.uuid(rank.getString("producer"))+"/"+sync.getString("endpoint")+"/"+privacy);if(!owner.equals(ownerState.getString("owner")))return null;
  // This file can be ahead of rank while a newer publication waits for worker
  // ACK; the old checksum-verified rank remains the acknowledged baseline.
  new CloudLearningState(ownerState).validate(CloudLearningPolicy.get(context));
  return LearningDeltaIndex.hash(owner+"/"+epoch+"/"+revision+"/"+rank.getString("installation"));
 }
 JSONObject status()throws Exception{JSONObject state=read(),out=new JSONObject().put("enabled",context.getSharedPreferences("sync-consent",0).getBoolean(ENABLED,false)).put("rankAuthorized",context.getSharedPreferences("sync-consent",0).getBoolean(RANK,false)).put("rankValid",context.getSharedPreferences("sync-consent",0).getBoolean(VALID,false)).put("revokePending",context.getSharedPreferences("sync-consent",0).getBoolean(REVOKE,false));if(state!=null){out.put("modelVersion",state.opt("modelVersion")).put("ready",state.optBoolean("ready")).put("shadowVerified",state.optBoolean("shadowVerified")).put("acceptedComponents",state.optJSONObject("accepted")==null?0:state.getJSONObject("accepted").length()).put("pending",state.has("pending")).put("baselineComplete",state.optBoolean("baselineComplete"));if(state.optJSONObject("receipt")!=null)out.put("producerRevision",state.getJSONObject("receipt").opt("producer_revision"));}return out;}
}
