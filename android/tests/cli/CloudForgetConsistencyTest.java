package live.linghe.privateinput;
import android.content.Context;import android.util.AtomicFile;
import java.io.*;import java.math.BigInteger;import java.nio.charset.StandardCharsets;import java.nio.file.*;import java.util.*;import java.lang.reflect.Field;import org.json.*;
/** Synthetic Android owners -> op6 -> isolated server -> Android rank round trip. */
public final class CloudForgetConsistencyTest {
 static final String A="11111111-1111-4111-8111-111111111111",B="22222222-2222-4222-8222-222222222222",I="33333333-3333-4333-8333-333333333333",KEY="ling he\u001f灵鹤";
 static int checks;static void check(boolean value,String label){if(!value)throw new AssertionError(label);checks++;}
 static void write(File file,String value)throws Exception{Files.write(file.toPath(),value.getBytes(StandardCharsets.UTF_8));}
 static JSONObject read(File file)throws Exception{return LosslessJson.object(new String(Files.readAllBytes(file.toPath()),StandardCharsets.UTF_8),12*1024*1024);}
 static CloudLearningState fresh(String producer)throws Exception{return CloudLearningState.fresh("synthetic",producer,I,BigInteger.ONE,BigInteger.ONE);}
 public static void main(String[]args)throws Exception{
  if(args.length!=2||!args[0].matches("/data/local/tmp/linghe-forget-[0-9a-f]{16}"))throw new IllegalArgumentException("synthetic scope required");
  File root=new File(args[0]),data=new File(root,"data");CloudLearningPolicy policy=LearningCapacityOwnerTest.policy(new File(root,"standard-8105.txt"));Field cached=CloudLearningPolicy.class.getDeclaredField("cached");cached.setAccessible(true);cached.set(null,policy);
  if(args[1].equals("produce")){
   LearningForgetTest.main(new String[0]);
   check(!data.exists()&&data.mkdirs(),"fresh fixture data");write(new File(data,"local-replica-id.txt"),A);
   Context context=LearningCapacityOwnerTest.context(data);CloudLearningStore store=new CloudLearningStore(context);check(store.termGeneration("ling he","灵鹤").signum()==0,"missing state is unknown");
   CloudLearningState cloud=fresh(A);cloud.value.getJSONObject("fences").put(KEY,new JSONObject().put("generation",7).put("deleted",false));store.write(cloud.value);
   check(store.termGeneration("ling he","灵鹤").intValue()==7,"cloud fence generation read");
   LearningCoordinator owner=new LearningCoordinator(data,new File(data,"Shared"));owner.forget("ling he","灵鹤",store.termGeneration("ling he","灵鹤"));
   owner=new LearningCoordinator(data,new File(data,"Shared"));LearningModel.Entry gone=owner.entries().get(0);check(gone.deleted&&gone.generation.intValue()==8&&gone.counts.containsKey(A)&&gone.frequency()==0,"reopened owned tombstone");
   JSONObject projected=CloudLearningState.project(owner.entries(),A,policy,new JSONObject());check(projected.has(KEY),"never learned local control reaches projection");JSONObject forgotten=fresh(A).prepare(projected);check(forgotten.getJSONArray("records").length()==1,"operation6 carries tombstone");
   RimeCheckpoint cp=RimeCheckpoint.decode(new String(Files.readAllBytes(new File(data,"learning-checkpoint-v1.json").toPath()),StandardCharsets.UTF_8));cp.observeExport("灵鹤\tling he\t500\n",B);check(cp.model.get(KEY).deleted&&cp.model.get(KEY).frequency()==0,"old native export cannot restore");
   check(owner.selectedAgain("ling he","灵鹤",new CloudLearningStore.TermControl(BigInteger.valueOf(8),true)),"explicit selection restores");
   owner=new LearningCoordinator(data,new File(data,"Shared"));LearningModel.Entry restored=owner.entries().get(0);check(!restored.deleted&&restored.generation.intValue()==9&&restored.counts.get(A)==1,"relearn persisted with one owned count");
   CloudLearningState again=fresh(A);again.value.put("baselineComplete",true).put("accepted",projected);JSONObject relearn=again.prepare(CloudLearningState.project(owner.entries(),A,policy,projected));
   write(new File(root,"publications.json"),CloudLearningCanonical.encode(new JSONObject().put("forget",forgotten).put("relearn",relearn)));
   File cache=new File(store.directory,"state-v1.json");write(cache,"{broken");boolean rejected=false;try{store.termGeneration("ling he","灵鹤");}catch(Exception expected){rejected=true;}check(rejected,"corrupt cache never becomes generation zero");
   JSONObject bad=cloud.value;bad.getJSONObject("fences").getJSONObject(KEY).put("generation",-1);rejected=false;try{CloudLearningStore.termControl(bad,"ling he","灵鹤");}catch(Exception expected){rejected=true;}check(rejected,"invalid fence rejected");
  }else if(args[1].equals("consume")){
   JSONObject responses=read(new File(root,"models.json"));LearningModel stale=new LearningModel();stale.forget("ling he","灵鹤",BigInteger.valueOf(6));stale.restore(KEY); // gen8, overridden below by actual old producer generation7
   JSONObject row=new JSONObject().put("reading","ling he").put("text","灵鹤").put("generation",7).put("deleted",false).put("counts",new JSONObject().put(B,500)).put("pinned",false).put("pinVersion",new JSONObject().put("sequence",0).put("device",""));
   LearningModel.Entry old=LearningModel.Entry.decode(row);Map<String,List<LearningModel.Entry>> local=Collections.singletonMap(B,Collections.singletonList(old));
   for(String name:new String[]{"forgotten","stale","relearned","stale_after_relearn"}){CloudLearningState peer=fresh(B);peer.stage(responses.getJSONObject(name),policy);peer.validate(policy);JSONObject rank=new JSONObject().put("terms",peer.value.getJSONObject("terms")).put("fences",peer.value.getJSONObject("fences")).put("represented",new JSONObject());double score=CloudLearningRankSnapshot.build(rank,local).getOrDefault(KEY,0.0);boolean active=name.contains("relearn");check(active?score>0:score==0,"peer rank "+name);if(active){double clean=CloudLearningRankSnapshot.build(rank,Collections.emptyMap()).get(KEY);check(score==clean,"stale500 count excluded "+name);}}
   LearningModel deleted=new LearningModel();deleted.forget("ling he","灵鹤",BigInteger.valueOf(7));CloudLearningState newest=fresh(B);newest.stage(responses.getJSONObject("relearned"),policy);JSONObject rank=new JSONObject().put("terms",newest.value.getJSONObject("terms")).put("fences",newest.value.getJSONObject("fences")).put("represented",new JSONObject());check(CloudLearningRankSnapshot.build(rank,Collections.singletonMap(B,deleted.entries())).get(KEY)>0,"new cloud generation supersedes old local tombstone");
  }else throw new IllegalArgumentException("phase");
  System.out.println("PASS "+checks+" Android cloud forget "+args[1]+" checks; actual JSON/AtomicFile; synthetic data only");
 }
}
