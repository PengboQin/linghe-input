package live.linghe.privateinput;
import android.content.*;
import java.io.*;
import java.math.BigInteger;
import java.nio.charset.StandardCharsets;
import java.security.KeyStore;
import java.util.*;
import org.json.*;
/** Same-UID signed instrumentation only. Fresh app-private diagnostic store;
 * no user archive, clipboard, group credentials, or network calls. No UI/exported entry. */
final class LearningDeltaDiagnostics {
 static int checks;static void ok(boolean value,String label){++checks;if(!value)throw new AssertionError(label);}
 interface Work{void run()throws Exception;}static void rejects(Work work,String label)throws Exception{boolean bad=false;try{work.run();}catch(Exception expected){bad=true;}ok(bad,label);}
 static JSONObject copy(JSONObject value)throws Exception{return LosslessJson.object(LosslessJson.canonical(value),6*1024*1024);}
 static JSONObject personalRecord(String id,String text,long revision,boolean deleted)throws Exception{
  JSONObject v=new JSONObject().put("sequence",revision).put("device","11111111-2222-3333-4444-555555555555"),created=new JSONObject().put("sequence",1).put("device","11111111-2222-3333-4444-555555555555");
  return new JSONObject().put("entry",new JSONObject().put("id",id).put("kind","phrase").put("text",text).put("trigger",id.startsWith("A")?"cs":"tt")).put("deleted",deleted).put("revision",v).put("created",created);
 }
 static LearningDeltaPublication.Prepared plan(LearningModel model,JSONObject state,long now)throws Exception{return LearningDeltaPublication.prepare(model,"22222222-3333-4444-5555-666666666666",BigInteger.ONE,"https://sync.example.invalid","fixture",state.optJSONObject(LearningDeltaPublication.CHECKPOINT),now,state.optBoolean(LearningDeltaPublication.REPAIR,false));}
 static JSONObject wire(byte[] payload,JSONObject state)throws Exception{return new JSONObject().put("domain",1).put("event",UUID.randomUUID().toString()).put("sequence",state.get("sequence")).put("ciphertext",java.util.Base64.getEncoder().encodeToString(payload)).put("fixtureOnly",true);}
 static void erase(File file)throws Exception{if(!file.exists())return;if(java.nio.file.Files.isSymbolicLink(file.toPath()))throw new IOException("Unexpected fixture symlink");if(file.isDirectory())for(File child:Objects.requireNonNull(file.listFiles()))erase(child);if(!file.delete())throw new IOException("Fixture cleanup failed");}
 static synchronized JSONObject run(Context app,String token)throws Exception{
  checks=0;if(!app.getPackageName().equals("live.linghe.privateinput")||!token.matches("[0-9a-f]{16}"))throw new SecurityException("diagnostic target");
  File parent=new File(app.getFilesDir(),"diagnostics");if(!parent.isDirectory()&&!parent.mkdirs())throw new IOException("diagnostics directory");File directory=new File(parent,"delta-"+token);ok(!directory.exists()&&directory.mkdirs(),"fresh sandbox only");
  String alias="live.linghe.privateinput.diagnostics.delta."+token;KeyStore keys=KeyStore.getInstance("AndroidKeyStore");keys.load(null);ok(!keys.containsAlias(alias),"refuse existing test alias");
  Context context=new ContextWrapper(app){@Override public File getFilesDir(){return directory;}@Override public Context getApplicationContext(){return this;}};
  SyncStore store=new SyncStore(context,alias);JSONObject report=new JSONObject();
  try{
   JSONObject[] state={store.load()};JSONObject clipboard=new JSONObject().put("wire",new JSONObject().put("domain",2).put("event","clipboard-fixture").put("ciphertext","unchanged")).put("generation",7);state[0].getJSONArray("outbox").put(clipboard);store.save(state[0]);String clipboardBytes=LosslessJson.canonical(clipboard);
   LearningModel model=new LearningModel();model.record("ni hao","你好","fixture");model.record("shi jie","世界","fixture");
   String firstID="AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",secondID="BBBBBBBB-BBBB-CCCC-DDDD-EEEEEEEEEEEE";JSONObject records=new JSONObject().put(firstID,personalRecord(firstID,"合成快捷短语一",1,false)).put(secondID,personalRecord(secondID,"合成快捷短语二",1,false));model.mergePersonalLexicon(new JSONObject().put("version",1).put("records",records).toString());
   LearningDeltaPublication.Prepared full=plan(model,state[0],1000);ok(full.full&&full.changedEntries==2&&full.changedPersonal==2,"bootstrap full archive");state[0]=LearningDeltaPublication.enqueue(state[0],full,7,LearningDeltaDiagnostics::wire,next->{store.save(next);state[0]=next;});
   JSONObject persisted=store.load();ok(persisted.getJSONArray("outbox").length()==2&&persisted.getJSONObject(LearningDeltaPublication.CHECKPOINT).getLong("fullRepairAt")==1000,"queue and baseline recovered from actual encrypted store");
   model.record("ni hao","你好","fixture");LearningDeltaPublication.Prepared delta=plan(model,state[0],1600);ok(!delta.full&&delta.changedEntries==1&&delta.changedPersonal==0,"single changed row payload");String baseline=LosslessJson.canonical(state[0].getJSONObject(LearningDeltaPublication.CHECKPOINT));int[] saves={0};
   rejects(()->LearningDeltaPublication.enqueue(state[0],delta,7,LearningDeltaDiagnostics::wire,next->{
    if(++saves[0]==2){File obstacle=new File(directory,"Sync/state-v1.enc.new");ok(obstacle.mkdir(),"inject actual AtomicFile startWrite failure");try{store.save(next);}finally{ok(obstacle.delete(),"remove only test AtomicFile obstacle");}}
    else{store.save(next);state[0]=next;}
   }),"actual AtomicFile publication failure propagated");
   persisted=store.load();ok(saves[0]==2&&persisted.getJSONArray("outbox").length()==2&&LosslessJson.canonical(persisted.getJSONObject(LearningDeltaPublication.CHECKPOINT)).equals(baseline),"failed publication cannot advance queue or baseline");ok(persisted.getLong("sequence")==2&&state[0].getLong("sequence")==2,"failed final save burns nonce sequence durably");
   state[0]=LearningDeltaPublication.enqueue(state[0],delta,7,LearningDeltaDiagnostics::wire,next->{store.save(next);state[0]=next;});persisted=store.load();ok(persisted.getLong("sequence")==3&&persisted.getJSONArray("outbox").length()==3,"retry reserves new nonce and queues missing delta");ok(persisted.getJSONObject(LearningDeltaPublication.CHECKPOINT).getLong("fullRepairAt")==1000,"delta does not postpone daily repair");
   JSONObject deltaBody=LosslessJson.object(delta.payload,LearningModel.MAX_BYTES);LearningModel oldPeer=new LearningModel();oldPeer.merge(full.payload);oldPeer.merge(delta.payload);oldPeer.merge(delta.payload);ok(oldPeer.get("ni hao\u001f你好").frequency()==2,"legacy v1 peer MAX merges delta idempotently");
   model.mergePersonalLexicon(new JSONObject().put("version",1).put("records",new JSONObject().put(firstID,personalRecord(firstID,"合成快捷短语一",2,true))).toString());LearningDeltaPublication.Prepared personal=plan(model,state[0],2200);ok(personal.changedEntries==0&&personal.changedPersonal==1,"one personal tombstone uses one UUID record");state[0]=LearningDeltaPublication.enqueue(state[0],personal,7,LearningDeltaDiagnostics::wire,next->{store.save(next);state[0]=next;});oldPeer.merge(personal.payload);ok(PersonalLexicon.decodeSynchronized(LosslessJson.object(oldPeer.personalSnapshot(),PersonalLexicon.MAX_BYTES)).entries.size()==1,"old peer merges personal deletion without losing other records");
   LearningDeltaPublication.Prepared daily=plan(model,state[0],87400);ok(daily.full&&daily.changedEntries==2&&daily.changedPersonal==2,"independent 24-hour full repair due");state[0]=LearningDeltaPublication.enqueue(state[0],daily,7,LearningDeltaDiagnostics::wire,next->{store.save(next);state[0]=next;});
   state[0]=LearningDeltaPublication.discardLearning(state[0],1,next->{store.save(next);state[0]=next;});persisted=store.load();ok(!persisted.has(LearningDeltaPublication.CHECKPOINT)&&persisted.getBoolean(LearningDeltaPublication.REPAIR),"expired learning envelope invalidates baseline atomically");ok(LosslessJson.canonical(persisted.getJSONArray("outbox").getJSONObject(0)).equals(clipboardBytes),"clipboard queue unaffected by learning repair");LearningDeltaPublication.Prepared repaired=plan(model,state[0],88000);ok(repaired.full&&repaired.changedEntries==2&&repaired.changedPersonal==2,"expiry forces next complete repair");state[0]=LearningDeltaPublication.enqueue(state[0],repaired,7,LearningDeltaDiagnostics::wire,next->{store.save(next);state[0]=next;});ok(!store.load().optBoolean(LearningDeltaPublication.REPAIR),"committed repair clears repair flag");
   LearningDeltaPublication.Prepared none=plan(model,state[0],88600);ok(none.payload==null,"unchanged archive does not enqueue");int[] unexpectedSave={0};JSONObject same=LearningDeltaPublication.enqueue(state[0],none,7,LearningDeltaDiagnostics::wire,next->{unexpectedSave[0]++;store.save(next);});ok(same==state[0]&&unexpectedSave[0]==0,"unchanged operation does not allocate nonce or write state");
   report.put("checks",checks).put("actualSyncStore",true).put("actualKeystore",true).put("actualAtomicFileFailure",true).put("networkCalls",0).put("realWireCrypto",false).put("userFilesRead",false);
  }finally{
   store.resetForDeparture();keys.load(null);ok(!keys.containsAlias(alias),"dedicated test alias removed");erase(directory);ok(!directory.exists(),"owned diagnostic files removed");report.put("aliasRemoved",true).put("fixtureFilesRemoved",true);
  }
  return report;
 }
}
