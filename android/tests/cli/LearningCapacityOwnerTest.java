package live.linghe.privateinput;

import android.content.*;import android.util.AtomicFile;
import java.io.*;import java.math.BigInteger;import java.nio.charset.StandardCharsets;import java.nio.file.*;import java.lang.reflect.*;import java.security.MessageDigest;import java.util.*;import org.json.*;

/** Actual Android JSON/AtomicFile owners in a fresh shell-owned sandbox.
 * Engine is a controlled already-imported export fixture, not native Rime. */
public final class LearningCapacityOwnerTest {
 static int checks;interface Work{void run()throws Exception;}
 static final long START=System.nanoTime();static void phase(String name){System.out.println("PHASE "+name+" "+((System.nanoTime()-START)/1000000)+"ms");System.out.flush();}
 static void check(boolean ok,String label){checks++;if(!ok)throw new AssertionError(label);}
 static void rejects(Work work,String label)throws Exception{boolean bad=false;try{work.run();}catch(Exception expected){bad=true;}check(bad,label);}
 static String dump(int count,int head){StringBuilder s=new StringBuilder();for(int i=0;i<count;i++)s.append("合成").append(i).append("\the cheng\t").append(i==0?head:1).append('\n');return s.toString();}
 static JSONObject clone(JSONObject value)throws Exception{return LosslessJson.object(CloudLearningCanonical.encode(value),12*1024*1024);}
 static String file(File value,int limit)throws Exception{return AppFiles.read(value,limit);}
 static final class Engine implements LearningCoordinator.Engine {
  final String actual,original;int imports;
  Engine(String actual,String original){this.actual=actual;this.original=original;}
  public int exportTo(File path)throws Exception{Files.write(path.toPath(),actual.getBytes(StandardCharsets.UTF_8));return 5001;}
  public int importFrom(File path)throws Exception{String incoming=file(path,LearningModel.MAX_BYTES);if(imports++==0)check(incoming.equals(original),"old pending imports original target before upgrade");return 5000;}
  public int reset(LearningModel.Entry e){return 0;}
 }
 static SharedPreferences preferences(){return (SharedPreferences)Proxy.newProxyInstance(LearningCapacityOwnerTest.class.getClassLoader(),new Class[]{SharedPreferences.class},(proxy,method,args)->{
  switch(method.getName()){
   case "getString":return args[1];case "getBoolean":return args[0].toString().startsWith("cloud-learning-")?true:args[1];
   case "getLong":case "getInt":case "getFloat":return args[1];case "getAll":return Collections.emptyMap();case "contains":return false;
   case "edit":return Proxy.newProxyInstance(LearningCapacityOwnerTest.class.getClassLoader(),new Class[]{SharedPreferences.Editor.class},(editor,m,a)->{if(m.getName().equals("commit"))return true;if(m.getReturnType()==SharedPreferences.Editor.class)return editor;return null;});
   default:return null;
  }
 });}
 static Context context(File directory){return new ContextWrapper(null){final SharedPreferences p=preferences();public File getFilesDir(){return directory;}public Context getApplicationContext(){return this;}public SharedPreferences getSharedPreferences(String name,int mode){return p;}public String getPackageName(){return "live.linghe.fixture.capacity";}public void sendBroadcast(Intent intent){/* isolated fixture signal */}};}
 static CloudLearningPolicy policy(File charset)throws Exception{
  byte[] data=Files.readAllBytes(charset.toPath());StringBuilder hash=new StringBuilder();for(byte b:MessageDigest.getInstance("SHA-256").digest(data))hash.append(String.format(Locale.ROOT,"%02x",b&255));check(hash.toString().equals("668f69e856c357157720ab5a6f8644dca8a253b439772f92cd762b186a53b421"),"public charset exact hash");Set<Integer> standard=new HashSet<>();for(String line:new String(data,StandardCharsets.UTF_8).split("\n"))standard.add(line.codePointAt(0));check(standard.size()==8105,"public charset count");Constructor<CloudLearningPolicy> ctor=CloudLearningPolicy.class.getDeclaredConstructor(Set.class);ctor.setAccessible(true);return ctor.newInstance(standard);
 }
 public static void main(String[]args)throws Exception {
  check(args.length==2&&args[0].matches("/data/local/tmp/linghe-capacity-owner-[0-9a-f]{16}"),"dedicated synthetic scope");File root=new File(args[0]),directory=new File(root,"data"),shared=new File(directory,"Shared");
  if(args[1].equals("checkpoint")){check(!directory.exists()&&directory.mkdirs(),"fresh owner only");checkpoint(root,directory,shared);}
  else{check(directory.isDirectory(),"prior synthetic phase required");if(args[1].equals("snapshot-delta"))snapshot(root,directory,shared);else if(args[1].equals("cloud"))cloud(root,directory,shared);else throw new IllegalArgumentException("unknown phase");}
  System.out.println(new JSONObject().put("phase",args[1]).put("checks",checks).put("passed",true).put("terms",5001).put("nativeEngineExecuted",false).put("first5001FullPublicationValidated",false).put("actualAndroidJSONAndAtomicFile",true).put("appUserDataNetworkOrUIAccess",false));
 }
 static RimeCheckpoint reopen(File directory)throws Exception{return RimeCheckpoint.decode(file(new File(directory,"learning-checkpoint-v1.json"),RimeCheckpoint.MAX_STATE_BYTES));}
 static void checkpoint(File root,File directory,File shared)throws Exception {
  phase("fresh");LearningCoordinator seed=new LearningCoordinator(directory,shared);String owner=seed.replica(),peer="22222222-2222-4222-8222-222222222222";
  RimeCheckpoint old=new RimeCheckpoint();old.observeExport(dump(5000,1),owner);old.model.setDeviceCount("he cheng","合成0",peer,4);old.setPinned("he cheng","合成0",true,owner);
  phase("seed-legacy5000");String original=old.engineImport();JSONObject marker=new JSONObject().put("phase","preparing").put("checkpoint",new JSONObject(old.encode()));String markerBytes=LosslessJson.canonical(marker);
  AppFiles.write(new AtomicFile(new File(directory,"learning-import-pending-v1.json")),markerBytes,RimeCheckpoint.MAX_STATE_BYTES+4096);
  Engine first=new Engine(dump(5001,7),original);
  LearningCoordinator crash=new LearningCoordinator(directory,shared,step->{phase("first:"+step);if(step.equals("recovered-state-saved"))throw new IOException("synthetic interruption");});
  rejects(()->crash.checkpoint(first,new File(root,"work1"),true),"save interruption retains original pending");
  check(file(new File(directory,"learning-import-pending-v1.json"),RimeCheckpoint.MAX_STATE_BYTES+4096).equals(markerBytes),"original target not overwritten by baseline-only state");
  check(crash.requiresPrivateRecovery(),"recovery remains required after interrupted commit");
  phase("interrupted-recovery");LearningCoordinator recovered=new LearningCoordinator(directory,shared,step->phase("replay:"+step));Engine replay=new Engine(dump(5001,7),original);
  check(recovered.checkpoint(replay,new File(root,"work2"),true).size()==5001,"coordinator completes all5001");
  check(!recovered.requiresPrivateRecovery(),"original intent completed");
  RimeCheckpoint persisted=RimeCheckpoint.decode(file(new File(directory,"learning-checkpoint-v1.json"),RimeCheckpoint.MAX_STATE_BYTES));
  check(persisted.model.capacityProfile()==LearningCapacityProfiles.EXPANDED_10000,"checkpoint saved current profile");
  LearningModel.Entry head=persisted.model.get("he cheng\u001f合成0");check(head.pinned&&head.counts.get(owner)==3&&head.counts.get(peer)==4&&head.frequency()==7,"native excess excludes imported peer total and preserves pin");
  check(persisted.model.get("he cheng\u001f合成5000").counts.get(owner)==1,"previously unknown last native word recorded, not baseline-only");
 }
 static void snapshot(File root,File directory,File shared)throws Exception {
  LearningCoordinator recovered=new LearningCoordinator(directory,shared,step->phase("repeat:"+step));String owner=recovered.replica();RimeCheckpoint persisted=reopen(directory);
  recovered.checkpoint(new Engine(dump(5001,7),persisted.engineImport()),new File(root,"work3"),true);
  persisted=RimeCheckpoint.decode(file(new File(directory,"learning-checkpoint-v1.json"),RimeCheckpoint.MAX_STATE_BYTES));check(persisted.model.get("he cheng\u001f合成0").counts.get(owner)==3,"repeat checkpoint does not recount excess");
  phase("checkpoint-repeat-complete");LearningSnapshotFile snapshot=new LearningSnapshotFile(shared);LearningModel received=new LearningModel(LearningCapacityProfiles.EXPANDED_10000);received.merge(snapshot.read());check(received.entries().size()==5001&&new JSONObject(snapshot.read()).getInt("version")==2,"snapshot owner persisted/reopened current5001");
  LearningModel queuedV1=new LearningModel();queuedV1.record("he cheng","合成5000",owner);snapshot.publish(queuedV1.export());received=new LearningModel(LearningCapacityProfiles.EXPANDED_10000);received.merge(snapshot.read());check(received.entries().size()==5001&&received.get("he cheng\u001f合成5000").frequency()==1,"known old queued archive merges without replay or loss");
  RecentLearningStore recent=new RecentLearningStore(directory);RecentLearningStore.Snapshot recentState=recent.snapshot();check(recentState.model.capacityProfile()==LearningCapacityProfiles.EXPANDED_10000&&recentState.model.entries().size()==5001,"recent owner save/reopen5001");
  check(recentState.model.get("he cheng","合成0").counts.get(owner)==3&&recentState.model.get("he cheng","合成0").buckets.isEmpty(),"excess is MAX cumulative and undated");
  LearningModel projection=new LearningModel(LearningCapacityProfiles.EXPANDED_10000);projection.merge(RecentLearningStore.legacyProjection(recentState));check(projection.entries().size()==5001,"recent projection retains expanded identity");
  phase("snapshot-recent-complete");LearningDeltaPublication.Prepared delta=LearningDeltaPublication.prepare(received,"33333333-3333-4333-8333-333333333333",BigInteger.ONE,"https://example.invalid","synthetic",null,1000,false);check(delta.changedEntries==5001&&new JSONObject(delta.payload).getInt("version")==2,"delta actual source/producer5001 current payload");
  LearningModel peerModel=new LearningModel(LearningCapacityProfiles.EXPANDED_10000);peerModel.merge(delta.payload);check(peerModel.entries().size()==5001,"new receiver merges full current delta");
  check(LearningDeltaPublication.prepare(received,"33333333-3333-4333-8333-333333333333",BigInteger.ONE,"https://example.invalid","synthetic",delta.checkpoint,1001,false).payload==null,"persisted delta hash index resumes5001 without resend");
 }
 static void cloud(File root,File directory,File shared)throws Exception {
  String owner=new LearningCoordinator(directory,shared).replica();RimeCheckpoint persisted=reopen(directory);
  phase("delta-complete");CloudLearningPolicy policy=policy(new File(root,"standard-8105.txt"));CloudLearningState cloud=CloudLearningState.fresh("synthetic",owner,"44444444-4444-4444-8444-444444444444",BigInteger.ONE,BigInteger.ONE);
  JSONObject projected=CloudLearningState.project(persisted.model.entries(),owner,policy,new JSONObject());check(projected.length()==5001,"cloud producer projects all5001");
  JSONObject firstPublication=cloud.prepare(projected);check(firstPublication.getJSONArray("records").length()==128,"producer remains bounded128 from full5001 source");
  String digest=CloudLearningState.componentDigest(owner,projected);int revision=40;
  cloud.recover(new JSONObject().put("exists",true).put("producer_id",owner).put("producer_revision",revision).put("component_digest",digest).put("records",CloudLearningState.orderedRows(projected)),policy);
  JSONObject handshake=cloud.prepare(projected);check(handshake.getJSONArray("records").length()==0,"recovered own5001 uses exact empty handshake");
  cloud.receive(new JSONObject().put("accepted_publication_id",handshake.getString("publication_id")).put("producer_id",owner).put("producer_revision",revision).put("changed_records",0).put("generation",1).put("consent_version",1).put("component_digest",digest));
  check(cloud.prepare(projected)==null,"all5001 retained after recovery, no duplicate publication");
  phase("producer-recovery-complete");check(cloud.value.getJSONObject("accepted").length()==5001,"all producer receipts retained");
  JSONArray upserts=new JSONArray();for(LearningModel.Entry entry:persisted.model.entries())upserts.put(new JSONObject().put("reading",entry.reading).put("text",entry.text).put("layout","shared").put("term_generation",entry.generation).put("weight",1000).put("pinned",entry.pinned));
  JSONObject terms=new JSONObject();for(int i=0;i<upserts.length();i++){JSONObject row=upserts.getJSONObject(i);terms.put(CloudLearningState.id(row),row);}upserts=CloudLearningState.orderedRows(terms);
  JSONArray marks=new JSONArray().put(new JSONObject().put("producer_id",owner).put("producer_revision",revision).put("component_digest",cloud.value.getJSONObject("receipt").getString("component_digest")));
  JSONObject full=new JSONObject().put("generation",1).put("algorithm_version",CloudLearningState.ALGORITHM).put("upserts",upserts).put("watermarks",new JSONArray()).put("producer_watermarks",marks);String hash=CloudLearningCanonical.hash(full);
  JSONObject model=clone(full).put("from_version",0).put("to_version",1).put("tombstones",new JSONArray()).put("model_sha256",hash).put("has_more",false);cloud.stage(model,policy);cloud.validate(policy);
  check(cloud.value.getJSONObject("terms").length()==5001&&cloud.value.getJSONObject("represented").length()==5001&&cloud.value.getBoolean("ready"),"cloud model/accepted/represented supports5001 with exact watermark");
  phase("cloud-stage-complete");Context context=context(directory);CloudLearningStore cache=new CloudLearningStore(context);cache.write(cloud.value);CloudLearningState reopened=new CloudLearningState(cache.read());reopened.validate(policy);check(reopened.value.getString("modelHash").equals(hash)&&reopened.value.getJSONObject("terms").length()==5001,"actual AtomicFile cloud cache reopen5001 hash verified");
  cache.publishRank(reopened,"33333333-3333-4333-8333-333333333333",BigInteger.ONE,owner);CloudLearningRankSnapshot rank=CloudLearningRankSnapshot.read(context,persisted.model.entries(),owner);check(rank!=null&&rank.score("he cheng","合成5000")>0,"rank source/cache actual5001 read and lookup");
  JSONObject oldCache=CloudLearningState.fresh("old",owner,"44444444-4444-4444-8444-444444444444",BigInteger.ONE,BigInteger.ONE).value;oldCache.put("version",1);oldCache.remove("capacity_profile");CloudLearningState migrated=new CloudLearningState(oldCache);JSONObject one=new JSONObject().put(CloudLearningState.id(projected.getJSONObject(projected.keys().next())),projected.getJSONObject(projected.keys().next()));migrated.prepare(one);String pending=CloudLearningCanonical.encode(migrated.value.getJSONObject("pending"));migrated.upgradeCapacity(policy);check(migrated.capacityProfile()==LearningCapacityProfiles.EXPANDED_10000&&pending.equals(CloudLearningCanonical.encode(migrated.value.getJSONObject("pending"))),"legacy cloud upgrade preserves exact pending publication");
 }
}
