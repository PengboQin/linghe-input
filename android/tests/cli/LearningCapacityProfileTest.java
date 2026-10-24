package live.linghe.privateinput;

import java.io.*;
import java.math.BigInteger;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;
import org.json.*;

/** Pure production model/codec checks in Android's JSON runtime. No app data. */
public final class LearningCapacityProfileTest {
 private static int checks;
 interface Checked {void run()throws Exception;}
 private static void check(boolean ok,String reason){checks++;if(!ok)throw new AssertionError(reason);}
 private static void rejects(Checked action,String reason)throws Exception{boolean rejected=false;try{action.run();}catch(Exception e){rejected=true;}check(rejected,reason);}
 private static String dump(int count,int head){StringBuilder s=new StringBuilder();for(int i=0;i<count;i++)s.append("合成").append(i).append("\the cheng\t").append(i==0?head:1).append('\n');return s.toString();}
 private static void save(Path dir,String name,String data)throws Exception{Files.write(dir.resolve(name),data.getBytes(StandardCharsets.UTF_8));}
 public static void main(String[]args)throws Exception {
  if(args.length!=1)throw new IllegalArgumentException("Synthetic output directory required");
  Path dir=Paths.get(args[0]);if(!Files.isDirectory(dir)||Files.isSymbolicLink(dir))throw new IOException("Invalid synthetic directory");
  LearningCapacityProfiles.Profile legacy=LearningCapacityProfiles.LEGACY_5000,expanded=LearningCapacityProfiles.EXPANDED_10000;
  check(new LearningModel().capacityProfile()==legacy,"default remains legacy");
  rejects(()->LearningCapacityProfiles.require("expanded-10000",1),"mismatched identity rejected");
  rejects(()->LearningCapacityMetadata.decode(new JSONObject().put("profile_id",expanded.id).put("profile_version",new BigInteger("4294967298"))),"wide version cannot truncate");
  RimeCheckpoint state=new RimeCheckpoint();state.observeExport(dump(5000,1),"synthetic");
  state.setPinned("he cheng","合成0",true,"synthetic");state.model.remove("he cheng\u001f合成1");state.resetFrequency("he cheng","合成2");
  String initial=state.encode(),wire=state.model.export();check(!new JSONObject(wire).has("capacity_profile"),"legacy wire unchanged");
  rejects(()->state.observeExport(dump(5001,2),"synthetic"),"legacy5001 remains bounded");check(initial.equals(state.encode()),"failed observation is atomic");
  state.upgradeCapacity(expanded);check(state.model.capacityProfile()==expanded,"explicit checkpoint upgrade");
  check(state.model.get("he cheng\u001f合成0").pinned&&state.model.get("he cheng\u001f合成1").deleted&&state.model.get("he cheng\u001f合成2").generation.equals(BigInteger.ONE),"upgrade preserves controls");
  state.observeExport(dump(5001,2),"synthetic");check(state.model.entries().size()==5001,"expanded accepts501st after5000");
  check(state.model.get("he cheng\u001f合成0").counts.get("synthetic")==2,"known delta advances with new word");
  check(state.model.get("he cheng\u001f合成5000").counts.get("synthetic")==1,"new count preserved");
  String encoded=state.encode();RimeCheckpoint reopened=RimeCheckpoint.decode(encoded);check(encoded.equals(reopened.encode()),"profiled checkpoint reopens exact");
  reopened.observeExport(dump(5001,2),"synthetic");check(encoded.equals(reopened.encode()),"same native snapshot does not double count");
  rejects(()->reopened.upgradeCapacity(legacy),"downgrade rejected");check(encoded.equals(reopened.encode()),"failed downgrade preserves state");
  LearningModel legacyTarget=new LearningModel();rejects(()->legacyTarget.merge(reopened.model.export()),"expanded wire cannot enter legacy");check(legacyTarget.entries().isEmpty(),"failed legacy merge atomic");
  LearningModel target=new LearningModel(expanded);target.merge(wire);check(target.entries().size()==5000,"expanded accepts legacy archive");
  LearningModel tiny=new LearningModel(expanded);tiny.record("he cheng","合成","synthetic");
  JSONObject tinyWire=new JSONObject(tiny.export());check(tinyWire.getInt("version")==2&&tinyWire.getJSONObject("capacity_profile").getString("profile_id").equals(expanded.id),"small expanded wire explicit");
  check(!tiny.stateObject().has("entries")&&tiny.stateObject().has("profiled_model"),"small persistent profile cannot be silently flattened");
  JSONObject unknown=LosslessJson.object(tiny.stateObject().toString(),LearningModel.MAX_BYTES);unknown.getJSONObject("capacity_profile").put("profile_id","future");
  rejects(()->LearningModel.fromState(unknown),"unknown persistent profile rejected");
  JSONObject mismatch=LosslessJson.object(tinyWire.toString(),LearningModel.MAX_BYTES);mismatch.put("version",1);rejects(()->new LearningModel(expanded).merge(mismatch.toString()),"wire outer and inner profile mismatch rejected");
  rejects(()->RimeCheckpoint.parseExport(dump(5001,1)),"standalone native parser still defaults legacy");
  check(RimeCheckpoint.parseExport(dump(5001,1),expanded).size()==5001,"explicit native parser supports profile2");
  rejects(()->RimeCheckpoint.parseExport(new String(new char[expanded.nativeTsvBytes+1]).replace('\0','x'),expanded),"native byte ceiling unchanged");
  rejects(()->new LearningModel(expanded).merge(new String(new char[expanded.learningArchiveBytes+1]).replace('\0','x')),"archive byte ceiling unchanged");
  RecentLearning.Policy policy=new RecentLearning.Policy(20000);RecentLearning recent=new RecentLearning();List<RecentLearning.Entry> rows=new ArrayList<>();
  for(int i=0;i<5000;i++)rows.add(new RecentLearning.Entry("he cheng","合成"+i,BigInteger.ZERO,i==1,Collections.singletonMap("synthetic",1L),i==0,new RecentLearning.Version(BigInteger.valueOf(i==0?3:0),i==0?"synthetic":""),Collections.emptyMap()));
  recent.merge(rows,policy);String recentLegacy=RecentLearningStore.encode(new RecentLearningStore.Snapshot(recent,null),policy);
  rejects(()->recent.record("he cheng","合成5000","synthetic",1,20000,policy),"legacy recent stays bounded");check(recent.entries().size()==5000,"recent overflow atomic");
  recent.upgradeCapacity(expanded);recent.record("he cheng","合成5000","synthetic",1,20000,policy);
  String recentWire=RecentLearningStore.encode(new RecentLearningStore.Snapshot(recent,null),policy);RecentLearningStore.Snapshot snapshot=RecentLearningStore.decode(recentWire,policy);
  check(snapshot.model.capacityProfile()==expanded&&snapshot.model.entries().size()==5001,"recent expanded codec reopen");
  check(snapshot.model.get("he cheng","合成0").pinned&&snapshot.model.get("he cheng","合成1").deleted,"recent controls preserved");
  rejects(()->new RecentLearning().merge(snapshot.model,policy),"expanded recent cannot merge into legacy even small");
  rejects(()->RecentLearningStore.legacyProjection(snapshot),"expanded recency not disguised as legacy");
  RecentLearning recentTiny=new RecentLearning(expanded);recentTiny.record("he cheng","合成","synthetic",1,20000,policy);
  String tinyRecent=RecentLearningStore.encode(new RecentLearningStore.Snapshot(recentTiny,null),policy);check(new JSONObject(tinyRecent).getInt("version")==3,"small recent wire is explicit profile version");
  check(RecentLearningStore.decode(recentLegacy,policy).model.capacityProfile()==legacy,"legacy recent remains readable");
  save(dir,"expanded-model-small.json",tiny.export());save(dir,"expanded-model-state-small.json",tiny.stateObject().toString());
  save(dir,"expanded-checkpoint.json",encoded);save(dir,"expanded-recent-small.json",tinyRecent);save(dir,"legacy-model.json",wire);save(dir,"legacy-recent.json",recentLegacy);
  System.out.println("{\"checks\":"+checks+",\"passed\":true,\"profile\":\"expanded-10000/v2\",\"defaultStillLegacy\":true,\"persistedModelTerms\":"+reopened.model.entries().size()+",\"persistedRecentTerms\":"+snapshot.model.entries().size()+",\"syntheticOnly\":true,\"appUserDataOrNetworkTouched\":false}");
 }
}
