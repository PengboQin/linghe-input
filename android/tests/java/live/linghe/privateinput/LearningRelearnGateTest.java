package live.linghe.privateinput;
import java.math.BigInteger;import java.util.*;import org.json.*;
public final class LearningRelearnGateTest {
 static int checks;static void check(boolean value,String message){if(!value)throw new AssertionError(message);checks++;}
 public static void main(String[]args)throws Exception{
  final int[] reads={0};Runnable readState=()->reads[0]++;
  LearningModel active=new LearningModel();active.setDeviceCount("ni hao","你好","owner",1);
  LearningRelearnGate gate=new LearningRelearnGate(active.entries());
  for(int i=0;i<10000;i++)gate.dispatchIfNeeded("ni hao","你好",false,null,readState);
  check(reads[0]==0,"10000 ordinary selections enqueue zero additional cloud state reads");
  check(!gate.dispatchIfNeeded("ling he","灵鹤",false,null,readState)&&reads[0]==0,"unknown new phrase skips recovery IO");
  check(gate.dispatchIfNeeded("ni hao","你好",true,null,readState)&&reads[0]==1,"local suppression dispatches recovery");
  LearningModel removed=new LearningModel();removed.forget("ling he","灵鹤",BigInteger.valueOf(7));
  LearningRelearnGate deleted=new LearningRelearnGate(removed.entries());
  check(deleted.dispatchIfNeeded("ling he","灵鹤",false,null,readState)&&reads[0]==2,"persisted local tombstone dispatches without rank");
  JSONObject rank=new JSONObject().put("fences",new JSONObject().put("ling he\u001f灵鹤",new JSONObject().put("generation",8).put("deleted",true)).put("ni hao\u001f你好",new JSONObject().put("generation",7).put("deleted",false)));
  Map<String,BigInteger> index=CloudLearningRankSnapshot.deletionIndex(rank);
  check(index.size()==1&&index.get("ling he\u001f灵鹤").intValue()==8,"rank index retains remote-only tombstone");
  check(gate.dispatchIfNeeded("ling he","灵鹤",false,index.get("ling he\u001f灵鹤"),readState)&&reads[0]==3,"remote-only deletion enters authority revalidation");
  removed.selectedAgain("ling he","灵鹤","owner",BigInteger.valueOf(8),true);LearningRelearnGate restored=new LearningRelearnGate(removed.entries());
  check(!restored.dispatchIfNeeded("ling he","灵鹤",false,BigInteger.valueOf(8),readState)&&reads[0]==3,"newer local restore skips old cloud tombstone IO");
  check(restored.dispatchIfNeeded("ling he","灵鹤",false,BigInteger.valueOf(10),readState)&&reads[0]==4,"newer remote deletion dispatches");
  check(!LearningRelearnGate.EMPTY.dispatchIfNeeded("ling he","灵鹤",false,null,readState)&&reads[0]==4,"reset drops prior control gate");
  System.out.println("PASS "+checks+" relearn gate checks; ordinary selection additional state reads=0");
 }
}
